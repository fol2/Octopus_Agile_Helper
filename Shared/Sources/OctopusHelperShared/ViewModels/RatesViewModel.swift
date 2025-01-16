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
        do {
            print("\n🔍 Starting fetchRatesForDefaultProduct")
            
            // First check if we have a full account-based agile tariff code (e.g. "E-1R-AGILE-24-04-03-H")
            if let fullTariffCode = activeAgileTariffFromAccount() {
                print("📦 Using account-based agile tariff: \(fullTariffCode)")

                // Directly load local detail by full tariff code
                var details = try await productDetailRepository.loadLocalProductDetailByTariffCode(tariffCode: fullTariffCode)
                print("📊 Found \(details.count) product details via fullTariffCode")

                // If nothing is in local DB, fetch from API (the user might have run ensureProductExists, or not)
                if details.isEmpty {
                    print("🔄 No local product detail found for \(fullTariffCode), fetching from API...")
                    details = try await productDetailRepository.fetchAndStoreProductDetail(productCode: fullTariffCode)
                }

                // If still empty, bail out
                guard !details.isEmpty else {
                    print("❌ No local product detail found even after fetch. Aborting.")
                    return
                }
                
                // From here you can skip region-based fallback entirely, and just proceed with rates fetching
                guard let rateLink = findRateLink(in: details) else {
                    print("❌ Could not find rate link in product details. Aborting.")
                    return
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
                } else {
                    print("⚠️ No standing charge link found, skipping fetch.")
                }

                // e.g. set self.currentAgileCode, store in widget, etc., then return
                self.currentAgileCode = fullTariffCode
                UserDefaults(suiteName: "group.com.jamesto.octopus-agile-helper")?.set(fullTariffCode, forKey: "agile_code_for_widget")
                print("\n✅ Completed account-based fetchRatesForDefaultProduct")
                return
            }

            // If we got here, either no account data or no active agile agreement => fallback
            guard let fallbackCode = await fallbackAgileCodeFromProductEntity() else {
                print("❌ No fallback Agile product found")
                return
            }
            print("📦 Found fallback agile product code: \(fallbackCode)")

            // Step 2: Try to load product detail from local storage first (fallback approach)
            var details = try await productDetailRepository.loadLocalProductDetail(code: fallbackCode)
            print("📊 Found \(details.count) product details from fallback")

            // If no local data, then fetch from API
            if details.isEmpty {
                print("🔄 No local product details found, fetching from API...")
                details = try await productDetailRepository.fetchAndStoreProductDetail(productCode: fallbackCode)
                print("📥 Fetched \(details.count) product details from API")
            }

            // Step 3: Check if we have valid account information
            let accountData = GlobalSettingsManager().settings.accountData
            var chosenDetail: NSManagedObject? = nil
            var tariffCode: String? = nil
            var rateLink: String? = nil

            if
                let data = accountData,
                !data.isEmpty,
                let account = try? JSONDecoder().decode(OctopusAccountResponse.self, from: data),
                let firstProperty = account.properties.first,
                let firstMeterPoint = firstProperty.electricity_meter_points?.first,
                let agreements = firstMeterPoint.agreements,
                let activeAgreement = agreements.first(where: { agreement in
                    // Find the active agreement
                    if let validFrom = ISO8601DateFormatter().date(from: agreement.valid_from ?? ""),
                       let validTo = agreement.valid_to.flatMap(ISO8601DateFormatter().date(from:)) {
                        let now = Date()
                        return validFrom <= now && validTo >= now
                    }
                    return false
                })
            {
                print("🔍 Looking for product detail matching agreement: \(activeAgreement.tariff_code)")

                // Step 4A: Find the matching product detail from local DB
                if let matchingDetail = details.first(where: { detail in
                    let detailTariffCode = detail.value(forKey: "tariff_code") as? String
                    return detailTariffCode == activeAgreement.tariff_code
                }),
                let foundRateLink = matchingDetail.value(forKey: "link_rate") as? String,
                let foundTariffCode = matchingDetail.value(forKey: "tariff_code") as? String {
                    chosenDetail = matchingDetail
                    rateLink = foundRateLink
                    tariffCode = foundTariffCode
                } else {
                    print("❌ No matching product detail found for agreement: \(activeAgreement.tariff_code)")
                    return
                }

            } else {
                // Fallback: no account data or invalid, rely on local product details & region from GlobalSettings
                print("⚠️ No valid account data found, using fallback region from GlobalSettings (if available).")
                let regionInput = GlobalSettingsManager().settings.regionInput.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
                
                // If you store the region in GlobalSettings, attempt to match a detail with that region
                if !regionInput.isEmpty {
                    chosenDetail = details.first(where: { detail in
                        let detailRegion = detail.value(forKey: "region") as? String
                        return detailRegion == regionInput
                    })
                }
                
                // If no region matched or region is nil, simply pick the first detail
                if chosenDetail == nil {
                    chosenDetail = details.first
                }
                
                // Extract the tariff code and link from the chosen detail
                if let chosen = chosenDetail,
                   let foundTariffCode = chosen.value(forKey: "tariff_code") as? String,
                   let foundRateLink = chosen.value(forKey: "link_rate") as? String {
                    tariffCode = foundTariffCode
                    rateLink = foundRateLink
                } else {
                    print("❌ Could not determine fallback region/tariff code from product detail.")
                    return
                }
            }

            // Print final product detail info
            if let chosen = chosenDetail {
                if let code = chosen.value(forKey: "tariff_code") as? String {
                    print("\n📋 Product Detail Info:")
                    print("🏷️ Tariff Code: \(code)")
                }
                if let region = chosen.value(forKey: "region") as? String {
                    print("🌍 Region: \(region)")
                }
                if let payment = chosen.value(forKey: "payment") as? String {
                    print("💳 Payment: \(payment)")
                }
                if let link = chosen.value(forKey: "link_rate") as? String {
                    print("🔗 Rate Link: \(link)")
                }
            }

            guard let finalTariffCode = tariffCode, let finalRateLink = rateLink else {
                print("❌ Missing tariffCode or rateLink, cannot fetch rates.")
                return
            }

            // Step 5: Use the tariff code
            print("\n🎯 Using tariff code: \(finalTariffCode)")
            
            // Step 6: Fetch and store rates
            try await repository.fetchAndStoreRates(tariffCode: finalTariffCode, url: finalRateLink)

            // Also fetch standing charges if available
            if let finalSCLink = chosenDetail?.value(forKey: "link_standing_charge") as? String {
                print("🔗 Found standing charge link: \(finalSCLink)")
                try await repository.fetchAndStoreStandingCharges(
                    tariffCode: finalTariffCode,
                    url: finalSCLink
                )
            } else {
                print("⚠️ No standing charge link found for fallback scenario, skipping fetch.")
            }

            // Step 7: Update current agile code
            self.currentAgileCode = fallbackCode
            
            // Step 8: Save to shared defaults for widget
            let sharedDefaults = UserDefaults(suiteName: "group.com.jamesto.octopus-agile-helper")
            sharedDefaults?.set(fallbackCode, forKey: "agile_code_for_widget")
            
            print("\n✅ Completed fetchRatesForDefaultProduct")
            
        } catch {
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
        setupTimer(timer)
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
            state.upcomingRates = filterUpcoming(rates: state.allRates, now: now)
            // Check cooldown
            if let earliest = state.nextFetchEarliestTime {
                if now >= earliest {
                    // Attempt to fetch again
                    state.nextFetchEarliestTime = nil
                    Task {
                        await self.refreshRatesForProduct(productCode: code, now: now)
                    }
                }
            } else {
                // Normal logic: fetch every minute if needed
                Task {
                    await self.refreshRatesForProduct(productCode: code, now: now)
                }
            }
            productStates[code] = state
        }
    }

    /// Refresh rates for a given product code
    private func refreshRatesForProduct(productCode: String, now: Date) async {
        var state = productStates[productCode] ?? ProductRatesState()
        
        // Check if we need to fetch
        if let nextFetchTime = state.nextFetchEarliestTime {
            if now < nextFetchTime {
                print("⏳ Too soon to fetch rates for \(productCode), next fetch at \(nextFetchTime)")
                return
            }
        }
        
        // Check if already fetching
        if state.isLoading {
            print("⏳ Already fetching rates for \(productCode)")
            return
        }
        
        state.isLoading = true
        productStates[productCode] = state
        
        // First get product detail using tariff code
        do {
            let details = try await productDetailRepository.loadLocalProductDetailByTariffCode(tariffCode: productCode)
            guard let detail = details.first,
                  let tCode = detail.value(forKey: "tariff_code") as? String,
                  let link = detail.value(forKey: "link_rate") as? String else {
                state.fetchStatus = .failed(NSError(domain: "com.octopus", code: -1, userInfo: [NSLocalizedDescriptionKey: "No product detail found"]))
                state.isLoading = false
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
            state.fetchStatus = .done
            state.isLoading = false
            state.nextFetchEarliestTime = now.addingTimeInterval(60 * 60) // 1 hour
            productStates[productCode] = state
        } catch {
            state.fetchStatus = .failed(error)
            state.isLoading = false
            state.nextFetchEarliestTime = now.addingTimeInterval(60 * 5) // 5 minutes on error
            productStates[productCode] = state
        }
    }

    // MARK: - Public Methods

    /// Initialize local state for multiple products. Usually called at launch.
    public func initializeProducts(_ codes: [String]) async {
        do {
            print("\n🔍 Starting initializeProducts for \(codes)")
            
            for code in codes {
                // First try to get details by tariff code directly (in case it's a full tariff code)
                var details = try await productDetailRepository.loadLocalProductDetailByTariffCode(tariffCode: code)
                
                // If no details found, try loading by product code
                if details.isEmpty {
                    details = try await productDetailRepository.loadLocalProductDetail(code: code)
                }
                
                // If still empty, fetch from API
                if details.isEmpty {
                    details = try await productDetailRepository.fetchAndStoreProductDetail(productCode: code)
                }
                
                // Filter details by region if we have a region input
                let regionInput = GlobalSettingsManager().settings.regionInput.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
                if !regionInput.isEmpty {
                    let filteredDetails = details.filter { detail in
                        let detailRegion = detail.value(forKey: "region") as? String
                        return detailRegion == regionInput
                    }
                    if !filteredDetails.isEmpty {
                        details = filteredDetails
                    }
                }
                
                guard let detail = details.first,
                      let tariffCode = detail.value(forKey: "tariff_code") as? String,
                      let rateLink = detail.value(forKey: "link_rate") as? String else {
                    print("❌ Could not find tariff code or rate link for \(code)")
                    continue
                }
                
                print("📊 Selected product detail - Region: \(detail.value(forKey: "region") as? String ?? "unknown"), Tariff: \(tariffCode)")
                
                // Initialize state for this product if needed
                if productStates[tariffCode] == nil {
                    productStates[tariffCode] = ProductRatesState()
                }
                
                // Set loading state
                productStates[tariffCode]?.isLoading = true
                
                // Load rates using the rate link
                try await repository.fetchAndStoreRates(tariffCode: tariffCode, url: rateLink)
                
                // Update state with loaded rates
                let request = NSFetchRequest<NSManagedObject>(entityName: "RateEntity")
                request.predicate = NSPredicate(format: "tariff_code == %@", tariffCode)
                let rates = try await context.perform {
                    try self.context.fetch(request)
                }
                
                // Update state with loaded rates
                if var state = productStates[tariffCode] {
                    state.allRates = rates
                    state.upcomingRates = rates.filter {
                        guard let validFrom = $0.value(forKey: "valid_from") as? Date else { return false }
                        return validFrom > Date()
                    }
                    productStates[tariffCode] = state
                }
                
                // Clear loading state
                productStates[tariffCode]?.isLoading = false
                
                // Update currentAgileCode to use the full tariff code
                if code == currentAgileCode {
                    currentAgileCode = tariffCode
                    // Also update the widget
                    UserDefaults(suiteName: "group.com.jamesto.octopus-agile-helper")?.set(tariffCode, forKey: "agile_code_for_widget")
                }
            }
            
            fetchStatus = .done
        } catch {
            print("❌ Error in initializeProducts: \(error)")
            fetchStatus = .failed(error)
        }
    }

    /// Public method to refresh rates for a single product
    public func refreshRates(productCode: String, force: Bool = false) async {
        print("🔄 开始刷新费率数据 (自动) - 产品代码: \(productCode)")
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
            let freshRates = try await repository.fetchAllRates()
            let freshStandingCharges = try await repository.fetchAllStandingCharges()
            
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

    // NEW: Called at app startup or whenever account might have changed
    // Checks user's accountData for an active agile agreement code, else fallback
    public func setAgileProductFromAccountOrFallback(globalSettings: GlobalSettingsManager) async {
        let sharedDefaults = UserDefaults(suiteName: "group.com.jamesto.octopus-agile-helper")
        
        // 1) Attempt dynamic fallback from local DB
        let fallbackCode = await fallbackAgileCodeFromProductEntity()

        // If we have no account data => rely solely on fallback from ProductEntity
        guard let accountData = globalSettings.settings.accountData,
              !accountData.isEmpty
        else {
            // If account lacks an 'AGILE' tariff => fallback only if DB has an AGILE product
            if let code = fallbackCode {
                self.currentAgileCode = code
            } else {
                return
            }
            return
        }

        do {
            let decoder = JSONDecoder()
            let account = try decoder.decode(OctopusAccountResponse.self, from: accountData)
            // parse the account for an agile-based code, e.g. "AGILE-24-04-03"
            if let matched = findAgileShortCode(in: account) {
                currentAgileCode = matched
            } else {
                // If account lacks an 'AGILE' tariff => fallback only if DB has an AGILE product
                if let code = fallbackCode {
                    currentAgileCode = code
                } else {
                    // No fallback => do nothing or keep existing
                    // currentAgileCode stays as-is
                    return
                }
            }

            // After we decide the actual code, store it for the widget to read:
            sharedDefaults?.set(currentAgileCode, forKey: "agile_code_for_widget")

        } catch {
            // If JSON decode fails => fallback only if DB found an AGILE code
            if let code = fallbackCode {
                currentAgileCode = code
                sharedDefaults?.set(code, forKey: "agile_code_for_widget")
            }
        }
    }

    // Find an active agile code from the user's agreements
    private func findAgileShortCode(in account: OctopusAccountResponse) -> String? {
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
                    if let shortCode = extractShortCode(agreement.tariff_code) {
                        return shortCode
                    }
                }
            }
        }
        
        // If no active AGILE agreement found, check if there's any active non-AGILE agreement
        for agreement in agreements {
            let isActive = isAgreementActive(agreement: agreement, now: now)
            if isActive {
                // If there's an active non-AGILE agreement, we should return nil
                // to trigger the fallback to default AGILE
                return nil
            }
        }
        
        // If no active agreements at all, return nil to trigger fallback
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

    private func extractShortCode(_ fullTariffCode: String) -> String? {
        // typical pattern: "E-1R-AGILE-24-04-03-H"
        // we can split by "-" and pick index 2..5 => "AGILE-24-04-03"
        // minimal approach:
        let parts = fullTariffCode.components(separatedBy: "-")
        // e.g. ["E", "1R", "AGILE", "24", "04", "03", "H"]
        guard parts.count >= 6 else { return nil }
        if parts[2].starts(with: "AGILE") {
            // join back up to the 5th index
            let joined = parts[2...5].joined(separator: "-")
            return joined // "AGILE-24-04-03"
        }
        return nil
    }
}
