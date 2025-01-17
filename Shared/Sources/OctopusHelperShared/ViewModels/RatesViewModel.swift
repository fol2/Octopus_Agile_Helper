//
//  RatesViewModel.swift
//  Octopus_Agile_Helper
//
//  Description:
//    - Multi-product coverage in one ViewModel
//    - Per-product aggregator logic
//    - Preserves old Agile cooldown & forced refresh approach
//    - Uses RatesRepository for actual DB & API operations
//
//  Principles:
//    - SOLID: Single responsibility (managing rates for multiple products).
//    - KISS, DRY: Minimal duplication, each product stored in a dictionary.
//    - YAGNI: Only what's needed for aggregator & coverage checks.
//
//  NOTE: If you want a simpler approach that only handles "AGILE-24-10-01,"
//        you can skip the dictionary-based approach and keep the original code.

import Combine
import CoreData
import Foundation
import SwiftUI

public enum ProductFetchStatus: Equatable, CustomStringConvertible {
    case none
    case fetching
    case done
    case pending
    case failed(Error)

    public static func == (lhs: ProductFetchStatus, rhs: ProductFetchStatus) -> Bool {
        switch (lhs, rhs) {
        case (.none, .none): return true
        case (.fetching, .fetching): return true
        case (.done, .done): return true
        case (.pending, .pending): return true
        case (.failed(_), .failed(_)): return true
        default: return false
        }
    }

    public var description: String {
        switch self {
        case .none:
            return "Not Started"
        case .fetching:
            return "Fetching..."
        case .done:
            return "Complete"
        case .pending:
            return "Pending"
        case .failed(let error):
            return "Error: \(error.localizedDescription)"
        }
    }
}

/// Data container for each product's local state
public struct ProductRatesState {
    public var allRates: [NSManagedObject] = []
    public var upcomingRates: [NSManagedObject] = []
    public var standingCharges: [NSManagedObject] = []
    public var currentStandingCharge: NSManagedObject? = nil
    public var fetchStatus: ProductFetchStatus = .none
    public var nextFetchEarliestTime: Date? = nil
    public var isLoading: Bool = false
    
    public init() {}
}

/// Our multi-product RatesViewModel
@MainActor
public final class RatesViewModel: ObservableObject {
    // MARK: - Dependencies
    private let repository = RatesRepository.shared
    private let productDetailRepository = ProductDetailRepository.shared
    private let productsRepository = ProductsRepository.shared
    private let context = PersistenceController.shared.container.viewContext
    private var cancellables = Set<AnyCancellable>()
    private var currentTimer: GlobalTimer?
    
    // MARK: - Published State
    @Published public var currentAgileCode: String = ""
    @Published public var fetchStatus: ProductFetchStatus = .none
    @Published public var productStates: [String: ProductRatesState] = [:]
    private var cachedRegionUsedLastTime: String = ""

    // If you want a single array that merges all products, you can compute it on the fly
    public var allRatesMerged: [NSManagedObject] {
        productStates.values.flatMap { $0.allRates }
    }

    // Minimal placeholder so aggregator compiles
    public struct AveragedRateWindow: Identifiable {
        public let id = UUID()
        public let average: Double
        public let start: Date
        public let end: Date

        public init(average: Double, start: Date, end: Date) {
            self.average = average
            self.start = start
            self.end = end
        }
    }

    // ------------------------------------------------------
    // MARK: - Public Helpers to fix "fileprivate" access in Cards
    // ------------------------------------------------------
    /// Returns whether the given product code is currently loading data.
    public func isLoading(for productCode: String) -> Bool {
        productStates[productCode]?.isLoading ?? false
    }

    /// Returns the typed [RateEntity] array for a specific product code.
    public func allRates(for productCode: String) -> [NSManagedObject] {
        let raw = productStates[productCode]?.allRates ?? []
        return raw
    }

    /// Example aggregator for "lowest averages" (similar to your old code).
    public func lowestAverageRates(productCode: String, count: Int = 10) -> Double? {
        guard let state = productStates[productCode] else { return nil }
        let now = Date()
        let future = state.upcomingRates.filter {
            guard let validFrom = $0.value(forKey: "valid_from") as? Date else { return false }
            return validFrom > now
        }
        let sorted = future.sorted {
            let lv = $0.value(forKey: "value_including_vat") as? Double ?? 999999
            let rv = $1.value(forKey: "value_including_vat") as? Double ?? 999999
            return lv < rv
        }
        let topN = Array(sorted.prefix(count))
        if topN.isEmpty { return nil }
        let sum = topN.reduce(0.0) { partial, obj in
            partial + (obj.value(forKey: "value_including_vat") as? Double ?? 0.0)
        }
        return sum / Double(topN.count)
    }

    /// A minimal helper struct mirroring your old "ThreeHourAverageEntry".
    /// Adjust naming if needed.
    public struct ThreeHourAverageEntry: Identifiable {
        public let id = UUID()
        public let start: Date
        public let end: Date
        public let average: Double
    }

    /// Updated to replicate your old computeLowestAverages approach,
    /// but using NSManagedObject instead of RateEntity.
    private func computeLowestAverages(
        _ inputRates: [NSManagedObject],
        fromNow: Bool,
        hours: Double,
        maxCount: Int
    ) -> [ThreeHourAverageEntry] {
        let now = Date()

        // We only want upcoming ones if fromNow == true
        let sorted = inputRates
            .filter {
                guard
                    let validFrom = $0.value(forKey: "valid_from") as? Date,
                    let validTo = $0.value(forKey: "valid_to") as? Date
                else { return false }
                // If fromNow is true, filter out anything before 'now'
                return fromNow ? (validFrom >= now) : true
            }
            .sorted {
                let lhs = ($0.value(forKey: "valid_from") as? Date) ?? .distantPast
                let rhs = ($1.value(forKey: "valid_from") as? Date) ?? .distantPast
                return lhs < rhs
            }

        // We assume half-hour slots, so hours * 2 slots
        let neededSlots = Int(hours * 2)

        var results = [ThreeHourAverageEntry]()
        for (index, slot) in sorted.enumerated() {
            let endIndex = index + (neededSlots - 1)
            if endIndex >= sorted.count { break }

            // Sum up these half-hour slots
            let window = sorted[index...endIndex]
            let sum = window.reduce(0.0) { partial, obj in
                (obj.value(forKey: "value_including_vat") as? Double ?? 0) + partial
            }
            let avg = sum / Double(neededSlots)

            let startDate = (slot.value(forKey: "valid_from") as? Date) ?? now
            let lastSlot = window.last!
            let endDate = (lastSlot.value(forKey: "valid_to") as? Date)
                ?? startDate.addingTimeInterval(1800) // fallback half-hour

            results.append(
                ThreeHourAverageEntry(start: startDate, end: endDate, average: avg)
            )
        }

        // Sort by ascending average, take up to maxCount
        results.sort { $0.average < $1.average }
        return Array(results.prefix(maxCount))
    }

    /// Replaces the old "getLowestAverages" function with your old logic
    /// (now adapted to NSManagedObject). Hours can be 0.5...20.0, etc.
    public func getLowestAverages(productCode: String, hours: Double, maxCount: Int) -> [ThreeHourAverageEntry] {
        guard let state = productStates[productCode] else { return [] }
        return computeLowestAverages(
            state.upcomingRates,
            fromNow: true,
            hours: hours,
            maxCount: maxCount
        )
    }

    // MARK: - Rate Queries
    
    /// Get the lowest upcoming rate for a specific product
    public func lowestUpcomingRate(productCode: String) -> NSManagedObject? {
        guard let state = productStates[productCode] else { return nil }
        return state.upcomingRates.min { a, b in
            let aValue = (a.value(forKey: "value_including_vat") as? Double) ?? Double.infinity
            let bValue = (b.value(forKey: "value_including_vat") as? Double) ?? Double.infinity
            return aValue < bValue
        }
    }

    /// Get the highest upcoming rate for a specific product
    public func highestUpcomingRate(productCode: String) -> NSManagedObject? {
        guard let state = productStates[productCode] else { return nil }
        return state.upcomingRates.max { a, b in
            let aValue = (a.value(forKey: "value_including_vat") as? Double) ?? Double.infinity
            let bValue = (b.value(forKey: "value_including_vat") as? Double) ?? Double.infinity
            return aValue < bValue
        }
    }

    // ------------------------------------------------------

    // MARK: - New Rate Fetching Logic
    /// Helper to get the active agile tariff code (e.g. "E-1R-AGILE-24-04-03-H") from account data if present.
    /// Returns nil if no valid active agreement or if account data is missing.
    private func activeAgileTariffFromAccount() -> String? {
        let manager = GlobalSettingsManager()
        guard
            let data = manager.settings.accountData,
            !data.isEmpty,
            let account = try? JSONDecoder().decode(OctopusAccountResponse.self, from: data),
            let firstProperty = account.properties.first,
            let firstMeterPoint = firstProperty.electricity_meter_points?.first,
            let agreements = firstMeterPoint.agreements
        else {
            return nil
        }

        let now = Date()
        // Filter to find any active agreement that has "AGILE" in the tariff_code
        let possibleAgile = agreements.first { agreement in
            agreement.tariff_code.contains("AGILE") && isAgreementActive(agreement: agreement, now: now)
        }
        return possibleAgile?.tariff_code
    }

    /// Helper to find the rate link in a list of product details
    private func findRateLink(in details: [NSManagedObject]) -> String? {
        guard let detail = details.first else { return nil }
        return detail.value(forKey: "link_rate") as? String
    }

    public func fetchRatesForDefaultProduct() async {
        print("\n🔍 Starting fetchRatesForDefaultProduct")
        self.fetchStatus = .fetching  // Set initial fetching status
        
        do {
            // First check if we have a full account-based agile tariff code
            if let fullTariffCode = activeAgileTariffFromAccount() {
                print("📦 Using account-based agile tariff: \(fullTariffCode)")
                
                // Try account-based approach
                do {
                    var details = try await productDetailRepository.loadLocalProductDetailByTariffCode(tariffCode: fullTariffCode)
                    print("📊 Found \(details.count) product details via fullTariffCode")
                    
                    if details.isEmpty {
                        print("🔄 No local product detail found for \(fullTariffCode), fetching from API...")
                        details = try await productDetailRepository.fetchAndStoreProductDetail(productCode: fullTariffCode)
                    }
                    
                    guard !details.isEmpty else {
                        print("❌ No local product detail found even after fetch.")
                        // Don't set failed yet - we'll try fallback
                        throw NSError(domain: "com.octopus", code: -1, userInfo: [NSLocalizedDescriptionKey: "No product details found"])
                    }
                    
                    guard let rateLink = findRateLink(in: details) else {
                        print("❌ Could not find rate link in product details.")
                        // Don't set failed yet - we'll try fallback
                        throw NSError(domain: "com.octopus", code: -2, userInfo: [NSLocalizedDescriptionKey: "No rate link found"])
                    }
                    
                    try await repository.fetchAndStoreRates(tariffCode: fullTariffCode, url: rateLink)
                    
                    // Also fetch standing charges if available
                    let standingChargeLink = details
                        .compactMap { $0.value(forKey: "link_standing_charge") as? String }
                        .first
                    if let scLink = standingChargeLink {
                        print("🔗 Found standing charge link: \(scLink)")
                        try await repository.fetchAndStoreStandingCharges(
                            tariffCode: fullTariffCode,
                            url: scLink
                        )
                    }
                    
                    self.currentAgileCode = fullTariffCode
                    UserDefaults(suiteName: "group.com.jamesto.octopus-agile-helper")?.set(fullTariffCode, forKey: "agile_code_for_widget")
                    self.fetchStatus = .done  // Success! Set to done
                    print("\n✅ Completed account-based fetchRatesForDefaultProduct")
                    return
                } catch {
                    // Account-based approach failed, continue to fallback
                    print("⚠️ Account-based approach failed, trying fallback...")
                    // Keep fetchStatus as .fetching
                }
            }
            
            // Fallback approach
            if !self.currentAgileCode.isEmpty,
               self.currentAgileCode.contains("AGILE") {
                print("⚠️ Skipping fallback: already have full tariff code \(self.currentAgileCode)")
                self.fetchStatus = .done
                return
            }
            
            // Try fallback approach
            guard let fallbackCode = await fallbackAgileCodeFromProductEntity() else {
                print("❌ No fallback Agile product found")
                self.fetchStatus = .failed(NSError(domain: "com.octopus", code: -3, userInfo: [NSLocalizedDescriptionKey: "No fallback product found"]))
                return
            }
            
            print("📦 Found fallback agile product code: \(fallbackCode)")
            
            var details = try await productDetailRepository.loadLocalProductDetail(code: fallbackCode)
            print("📊 Found \(details.count) product details from fallback")
            
            if details.isEmpty {
                print("🔄 No local product details found, fetching from API...")
                details = try await productDetailRepository.fetchAndStoreProductDetail(productCode: fallbackCode)
                print("📥 Fetched \(details.count) product details from API")
            }
            
            let effectiveRegion = GlobalSettingsManager().settings.effectiveRegion.uppercased()
            print("📍 Using effective region: \(effectiveRegion)")
            
            let filteredDetails = details.filter { detail in
                let detailRegion = detail.value(forKey: "region") as? String
                return detailRegion == effectiveRegion
            }
            
            var chosenDetail: NSManagedObject? = nil
            if !filteredDetails.isEmpty {
                print("📊 Found \(filteredDetails.count) details matching region \(effectiveRegion)")
                chosenDetail = filteredDetails.first
            } else {
                print("⚠️ No details found for region \(effectiveRegion), using first available detail")
                chosenDetail = details.first
            }
            
            guard let chosen = chosenDetail,
                  let tariffCode = chosen.value(forKey: "tariff_code") as? String,
                  let rateLink = chosen.value(forKey: "link_rate") as? String else {
                print("❌ Could not find tariff code or rate link in product details")
                self.fetchStatus = .failed(NSError(domain: "com.octopus", code: -4, userInfo: [NSLocalizedDescriptionKey: "No valid product details found"]))
                return
            }
            
            print("📊 Selected product detail - Region: \(chosen.value(forKey: "region") as? String ?? "unknown"), Tariff: \(tariffCode)")
            
            try await repository.fetchAndStoreRates(tariffCode: tariffCode, url: rateLink)
            
            if let standingChargeLink = chosen.value(forKey: "link_standing_charge") as? String {
                print("🔗 Found standing charge link: \(standingChargeLink)")
                try await repository.fetchAndStoreStandingCharges(
                    tariffCode: tariffCode,
                    url: standingChargeLink
                )
            }
            
            self.currentAgileCode = tariffCode
            UserDefaults(suiteName: "group.com.jamesto.octopus-agile-helper")?.set(tariffCode, forKey: "agile_code_for_widget")
            self.fetchStatus = .done  // Success! Set to done
            print("\n✅ Completed fallback-based fetchRatesForDefaultProduct")
            
        } catch {
            // Only set failed if we've exhausted all options
            print("❌ Error fetching rates: \(error)")
            self.fetchStatus = .failed(error)
        }
    }

    // MARK: - Init
    public init(globalTimer: GlobalTimer) {
        setupTimer(globalTimer)
        fetchStatus = .none
    }

    // If you want a minimal init for a widget (like your old code):
    public convenience init(widgetRates: [NSManagedObject], productCode: String) {
        self.init(globalTimer: GlobalTimer())
        // Just store them for that product
        var state = ProductRatesState()
        state.allRates = widgetRates
        state.upcomingRates = widgetRates.filter { obj in
            guard let validTo = obj.value(forKey: "valid_to") as? Date else { return false }
            return validTo > Date()
        }
        productStates[productCode] = state
    }

    // NEW: Provide a method to reattach the real GlobalTimer if changed externally
    public func updateTimer(_ timer: GlobalTimer) {
        // Preserve current status
        let currentStatus = self.fetchStatus
        
        // Update timer
        setupTimer(timer)
        
        // Restore status if it was fetching
        if case .fetching = currentStatus {
            self.fetchStatus = currentStatus
        }
    }

    // MARK: - Timer Setup
    private func setupTimer(_ timer: GlobalTimer) {
        currentTimer = timer
        timer.$currentTime
            .dropFirst()
            .receive(on: RunLoop.main)
            .sink { [weak self] newTime in
                self?.handleTimerTick(newTime)
            }
            .store(in: &cancellables)
    }

    private func handleTimerTick(_ now: Date) {
        // For each product in productStates, re-filter upcoming
        for (code, var state) in productStates {
            // 2) Skip if productCode is empty (avoid repeated tries with no code)
            if code.isEmpty {
                continue
            }

            state.upcomingRates = filterUpcoming(rates: state.allRates, now: now)
            
            // Check if we should attempt a refresh
            var shouldRefresh = false

            if let earliest = state.nextFetchEarliestTime {
                // If we've previously shown .failed and are trying again,
                // set status back to .fetching to avoid showing "Failed" while re-fetching
                if case .failed = state.fetchStatus { state.fetchStatus = .fetching }

                if now >= earliest {
                    shouldRefresh = true
                    state.nextFetchEarliestTime = nil
                }
            } else {
                // Only auto-refresh if we don't have rates or they're stale
                if state.allRates.isEmpty || state.upcomingRates.isEmpty {
                    shouldRefresh = true
                }
            }
            
            if shouldRefresh {
                Task {
                    // Reset status before new attempt
                    if case .failed = self.fetchStatus {
                        withAnimation {
                            self.fetchStatus = .fetching
                        }
                    }
                    await self.refreshRatesForProduct(productCode: code, now: now)
                }
            }
            
            productStates[code] = state
        }
    }

    /// Refresh rates for a given product code
    private func refreshRatesForProduct(productCode: String, now: Date) async {
        var state = productStates[productCode] ?? ProductRatesState()
        
        // Check if already fetching
        if state.isLoading {
            print("⏳ Already fetching rates for \(productCode)")
            // If we're re-fetching after a "failed" state, update to .fetching
            if case .failed = state.fetchStatus {
                state.fetchStatus = .fetching
            }
            productStates[productCode] = state
            return
        }

        // Set loading state
        state.nextFetchEarliestTime = nil
        withAnimation {
            state.isLoading = true
            state.fetchStatus = .fetching
            // If main fetchStatus was "failed", set it back to "fetching" to reflect an in-progress retry
            switch self.fetchStatus {
            case .failed:
                withAnimation { self.fetchStatus = .fetching }
            case .none, .done, .fetching, .pending:
                break
            }
        }
        productStates[productCode] = state
        
        do {
            let details = try await productDetailRepository.loadLocalProductDetailByTariffCode(tariffCode: productCode)
            guard let detail = details.first,
                  let tCode = detail.value(forKey: "tariff_code") as? String,
                  let link = detail.value(forKey: "link_rate") as? String else {
                withAnimation {
                    state.fetchStatus = .failed(NSError(domain: "com.octopus", code: -1, userInfo: [NSLocalizedDescriptionKey: "No product detail found"]))
                    state.isLoading = false
                    state.nextFetchEarliestTime = now.addingTimeInterval(60 * 5) // 5 min cooldown
                }
                productStates[productCode] = state
                return
            }
            
            // Now fetch rates
            try await repository.fetchAndStoreRates(tariffCode: tCode, url: link)
            let freshRates = try await repository.fetchAllRates()
            
            // Filter rates for this tariff code
            state.allRates = freshRates.filter { rate in
                (rate.value(forKey: "tariff_code") as? String) == tCode
            }
            state.upcomingRates = filterUpcoming(rates: state.allRates, now: now)
            
            withAnimation {
                state.fetchStatus = .done
                state.isLoading = false
                state.nextFetchEarliestTime = now.addingTimeInterval(60 * 60) // 1 hour cooldown on success
                self.fetchStatus = .done
            }
            productStates[productCode] = state
            
        } catch {
            print("❌ Error in refreshRatesForProduct: \(error)")
            withAnimation {
                state.fetchStatus = .failed(error)
                // If in practice we are still calling fetchAllRates or re-trying,
                // we can set a short .fetching again, but let's keep the "failed" state
                // until next scheduled refresh or user force refresh
                // (to avoid flickering UI)
                state.isLoading = false
                state.nextFetchEarliestTime = now.addingTimeInterval(60 * 5) // 5 min cooldown

                productStates[productCode] = state
            }
        }
    }

    // MARK: - Public Methods

    /// Initialize local state for multiple products. Usually called at launch.
    public func initializeProducts() async {
        print("\n🔍 Starting initializeProducts")
        self.fetchStatus = .fetching
        
        do {
            // Skip if we don't have a valid tariff code
            guard !currentAgileCode.isEmpty else {
                print("⚠️ No valid tariff code available, skipping initialization")
                self.fetchStatus = .failed(NSError(domain: "com.octopus", code: -1, userInfo: [NSLocalizedDescriptionKey: "No valid tariff code"]))
                return
            }
            
            print("📦 Initializing product state for: \(currentAgileCode)")
            
            // Initialize or get existing product state
            var state = productStates[currentAgileCode] ?? ProductRatesState()
            
            // Try loading from local storage first
            let localRates = try await repository.fetchRatesByTariffCode(currentAgileCode)
            
            if localRates.isEmpty {
                print("🔄 No local rates found, fetching from API...")
                try await repository.fetchAndStoreAgileRates(tariffCode: currentAgileCode)
                state.allRates = try await repository.fetchRatesByTariffCode(currentAgileCode)
            } else {
                print("📝 Using \(localRates.count) local rates")
                state.allRates = localRates
            }
            
            // Update upcoming rates
            state.upcomingRates = filterUpcoming(rates: state.allRates, now: Date())
            
            // Store the updated state
            productStates[currentAgileCode] = state
            
            self.fetchStatus = .done
            
        } catch {
            print("❌ Error initializing products: \(error)")
            self.fetchStatus = .failed(error)
        }
    }

    /// Public method to refresh rates for a single product
    public func refreshRates(productCode: String, force: Bool = false) async {
        // 1) Skip if productCode is empty
        guard !productCode.isEmpty else {
            print("⚠️ Skipping refreshRates: product code is empty")
            return
        }
        print("开始刷新费率数据 (自动) - 产品代码: \(productCode)")
        print("强制刷新: \(force ? "是" : "否")")
        var state = productStates[productCode] ?? ProductRatesState()
        if !force {
            // Check cooldown
            if let nextFetch = state.nextFetchEarliestTime {
                if Date() < nextFetch {
                    print("⏳ Too soon to fetch rates for \(productCode)")
                    return
                }
            }
        }
        
        if state.isLoading {
            print("⏳ Already fetching rates for \(productCode)")
            return
        }
        
        do {
            state.fetchStatus = .fetching
            productStates[productCode] = state
            
            await refreshRatesForProduct(productCode: productCode, now: Date())
        } catch {
            print("❌ Error refreshing rates: \(error)")
            state.fetchStatus = .failed(error)
            state.nextFetchEarliestTime = Date().addingTimeInterval(60 * 5) // 5 min cooldown on error
            productStates[productCode] = state
        }
    }

    /// Fetch rates for a specific tariff code
    public func fetchRates(tariffCode: String) async {
        print("🔄 开始获取费率，tariffCode: \(tariffCode)")
        
        do {
            let details = try await productDetailRepository.loadLocalProductDetailByTariffCode(tariffCode: tariffCode)
            guard let detail = details.first,
                  let tCode = detail.value(forKey: "tariff_code") as? String,
                  let rateLink = detail.value(forKey: "link_rate") as? String,
                  let standingChargeLink = detail.value(forKey: "link_standing_charge") as? String else {
                print("❌ No product detail found for tariff code \(tariffCode)")
                var state = productStates[tariffCode] ?? ProductRatesState()
                state.fetchStatus = .failed(NSError(domain: "com.octopus", code: -1, userInfo: [NSLocalizedDescriptionKey: "No product detail found"]))
                productStates[tariffCode] = state
                return
            }
            
            print("📦 Found product detail - tariff: \(tCode)")
            print("📊 Rate link: \(rateLink)")
            print("💰 Standing charge link: \(standingChargeLink)")
            
            var state = productStates[tariffCode] ?? ProductRatesState()
            state.fetchStatus = .fetching
            productStates[tariffCode] = state
            
            // Fetch both rates and standing charges
            async let ratesTask = repository.fetchAndStoreRates(tariffCode: tCode, url: rateLink)
            async let standingChargesTask = repository.fetchAndStoreStandingCharges(tariffCode: tCode, url: standingChargeLink)
            
            // Wait for both to complete
            try await (ratesTask, standingChargesTask)
            
            // Get fresh rates and standing charges
            let freshRates = try await repository.fetchRatesByTariffCode(tariffCode)
            let freshStandingCharges = try await repository.fetchStandingChargesByTariffCode(tariffCode)
            
            state.allRates = freshRates.filter { rate in
                (rate.value(forKey: "tariff_code") as? String) == tariffCode
            }
            state.upcomingRates = filterUpcoming(rates: state.allRates, now: Date())
            
            // Filter and sort standing charges
            let filteredCharges = freshStandingCharges.filter { charge in
                (charge.value(forKey: "tariff_code") as? String) == tariffCode
            }
            state.standingCharges = filteredCharges
            
            // Find current standing charge (valid now)
            let now = Date()
            state.currentStandingCharge = filteredCharges.first { charge in
                guard let validFrom = charge.value(forKey: "valid_from") as? Date,
                      let validTo = charge.value(forKey: "valid_to") as? Date else {
                    return false
                }
                return validFrom <= now && validTo >= now
            }
            
            state.fetchStatus = .done
            state.nextFetchEarliestTime = Date().addingTimeInterval(60 * 60) // 1 hour cooldown
            productStates[tariffCode] = state
            
            print("✅ Successfully fetched rates and standing charges for \(tariffCode)")
        } catch {
            print("❌ Error fetching rates: \(error.localizedDescription)")
            var state = productStates[tariffCode] ?? ProductRatesState()
            state.fetchStatus = .failed(error)
            state.nextFetchEarliestTime = Date().addingTimeInterval(60 * 5) // 5 min cooldown on error
            productStates[tariffCode] = state
        }
    }
    
    /// Get current standing charge for a tariff code
    public func currentStandingCharge(tariffCode: String) -> NSManagedObject? {
        return productStates[tariffCode]?.currentStandingCharge
    }
    
    /// Get all standing charges for a tariff code
    public func standingCharges(tariffCode: String) -> [NSManagedObject] {
        return productStates[tariffCode]?.standingCharges ?? []
    }

    // ------------------------------------------------------
    // MARK: - Public fetchRatesForDay method
    // ------------------------------------------------------
    public func fetchRatesForDay(_ day: Date) async throws -> [NSManagedObject] {
        let objects = try await repository.fetchAllRates()
        // Filter for the specific day
        let calendar = Calendar.current
        return objects.filter { obj in
            guard let validFrom = obj.value(forKey: "valid_from") as? Date else { return false }
            return calendar.isDate(validFrom, inSameDayAs: day)
        }
    }

    // MARK: - Product Sync
    
    /// Sync only basic product information
    public func syncProducts() async {
        do {
            // Only sync basic product information
            _ = try await productsRepository.syncAllProducts()
        } catch {
            print("❌ Error syncing products: \(error)")
        }
    }
    
    // MARK: - Formatting
    
    /// Format a rate value for display
    public func formatRate(_ value: Double, showRatesInPounds: Bool = false) -> String {
        if showRatesInPounds {
            let poundsValue = value / 100.0
            return String(format: "£%.4f /kWh", poundsValue)
        } else {
            return String(format: "%.2fp /kWh", value)
        }
    }

    /// Format a date to show only the time component
    public func formatTime(_ date: Date, locale: Locale = .current) -> String {
        let formatter = DateFormatter()
        formatter.timeStyle = .short
        formatter.locale = locale
        return formatter.string(from: date)
    }

    // MARK: - Private

    /// Filter rates to only include upcoming ones
    public func filterUpcoming(rates: [NSManagedObject], now: Date) -> [NSManagedObject] {
        rates.filter { rate in
            guard let validFrom = rate.value(forKey: "valid_from") as? Date else { return false }
            return validFrom > now
        }
    }

    /// Try to find an Agile code from local product details
    /// Filters:
    /// 1. brand = OCTOPUS_ENERGY
    /// 2. direction = IMPORT
    /// 3. code contains "AGILE"
    /// Sorted by available_from descending (most recent first)
    public func fallbackAgileCodeFromProductEntity() async -> String? {
        do {
            let products = try await productsRepository.fetchAllLocalProducts()
            
            // Filter for Agile products
            let agileProducts = products.filter { obj in
                guard let direction = obj.value(forKey: "direction") as? String,
                      let code = obj.value(forKey: "code") as? String,
                      let brand = obj.value(forKey: "brand") as? String else {
                    return false
                }
                return direction == "IMPORT" &&
                       code.contains("AGILE") &&
                       brand == "OCTOPUS_ENERGY"
            }
            
            // Sort by available_from date (most recent first)
            let sortedProducts = agileProducts.sorted { obj1, obj2 in
                guard let date1 = obj1.value(forKey: "available_from") as? Date,
                      let date2 = obj2.value(forKey: "available_from") as? Date else {
                    return false
                }
                return date1 > date2
            }
            
            // Return first (most recent) code
            return sortedProducts.first?.value(forKey: "code") as? String
        } catch {
            print("❌ Error fetching local products: \(error)")
            return nil
        }
    }

    /// Called at app startup or whenever account might have changed.
    /// Checks user's `accountData` for an active agile agreement code, else falls back.
    public func setAgileProductFromAccountOrFallback(
        globalSettings: GlobalSettingsManager
    ) async {
        print("DEBUG: Starting setAgileProductFromAccountOrFallback")
        let sharedDefaults = UserDefaults(suiteName: "group.com.jamesto.octopus-agile-helper")
        print("DEBUG: Current Agile code: \(currentAgileCode)")

        // Check if region has changed
        let newRegion = globalSettings.settings.effectiveRegion
        if newRegion != cachedRegionUsedLastTime {
            print("DEBUG: region changed from \(cachedRegionUsedLastTime) to \(newRegion), clearing currentAgileCode")
            currentAgileCode = ""
            cachedRegionUsedLastTime = newRegion
        }

        // 1) Exit early if we already have a valid 'AGILE' code
        guard currentAgileCode.isEmpty || !currentAgileCode.contains("AGILE") else {
            print("DEBUG: Exiting early - valid AGILE code already exists")
            return
        }

        // 2) Try fetching from the account data
        print("DEBUG: Attempting to fetch tariff code from account")
        if let tariffCode = await findTariffCodeInAccount(globalSettings: globalSettings) {
            print("DEBUG: Found tariff code in account: \(tariffCode)")
            currentAgileCode = tariffCode
            return
        }
        print("DEBUG: No tariff code found in account")

        // 3) If no tariff code in account, use fallback
        print("DEBUG: Applying fallback tariff code")
        await applyFallbackTariffCode(globalSettings: globalSettings, sharedDefaults: sharedDefaults)
        print("DEBUG: Final Agile code after fallback: \(currentAgileCode)")
    }

    // MARK: - Helper Methods

    /// Attempt to decode the user's account data and find an active agile tariff code.
    private func findTariffCodeInAccount(
        globalSettings: GlobalSettingsManager
    ) async -> String? {
        guard
            let accountData = globalSettings.settings.accountData,
            !accountData.isEmpty,
            let account = try? JSONDecoder().decode(OctopusAccountResponse.self, from: accountData),
            let matchedAgreement = tryFindActiveAgileAgreement(in: account)
        else {
            return nil
        }

        return matchedAgreement.tariff_code
    }

    /// Apply the fallback tariff code from the local DB if available, otherwise fetch from API.
    private func applyFallbackTariffCode(
        globalSettings: GlobalSettingsManager,
        sharedDefaults: UserDefaults?
    ) async {
        // Attempt to get the fallback code
        guard let fallbackCode = await fallbackAgileCodeFromProductEntity() else {
            return  // No fallback available, exit quietly.
        }

        do {
            // Try loading local product details
            var details = try await productDetailRepository.loadLocalProductDetail(code: fallbackCode)

            // If no local details, fetch them from the API
            if details.isEmpty {
                print("🔄 No local details found for \(fallbackCode), fetching from API...")
                details = try await productDetailRepository.fetchAndStoreProductDetail(productCode: fallbackCode)
            }

            // Determine the region
            let region = globalSettings.settings.effectiveRegion
            print("🌍 Using effective region: \(region)")

            // Find the tariff code from the product details
            guard let tariffCode = try await productDetailRepository.findTariffCode(productCode: fallbackCode,
                                                                                    region: region)
            else {
                print("❌ No tariff code found for \(fallbackCode) in region \(region)")
                return
            }

            print("✅ Found tariff code: \(tariffCode)")
            currentAgileCode = tariffCode

            // Store for widget access
            sharedDefaults?.set(tariffCode, forKey: "agile_code_for_widget")

        } catch {
            print("❌ Error processing fallback code: \(error)")
        }
    }

    private func tryFindActiveAgileAgreement(in account: OctopusAccountResponse) -> OctopusAgreement? {
        // We only examine the first property + first electricity agreement for brevity
        guard let firstProp = account.properties.first,
              let elecMP = firstProp.electricity_meter_points?.first,
              let agreements = elecMP.agreements
        else { return nil }

        let now = Date()

        // First try to find an active AGILE agreement
        for agreement in agreements {
            if agreement.tariff_code.contains("AGILE") {
                // Check if agreement is currently active
                let isActive = isAgreementActive(agreement: agreement, now: now)
                if isActive {
                    return agreement
                }
            }
        }
        return nil
    }

    // Helper to check if an agreement is active
    private func isAgreementActive(agreement: OctopusAgreement, now: Date) -> Bool {
        let dateFormatter = ISO8601DateFormatter()
        dateFormatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        
        // Check valid_from
        if let validFromStr = agreement.valid_from,
           let validFrom = dateFormatter.date(from: validFromStr) {
            if validFrom > now {
                return false
            }
        }
        
        // Check valid_to
        if let validToStr = agreement.valid_to,
           let validTo = dateFormatter.date(from: validToStr) {
            if validTo < now {
                return false
            }
        }
        
        return true
    }
}
