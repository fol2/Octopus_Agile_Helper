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

/// Data container for each product's local state
public struct ProductRatesState {
    public var allRates: [NSManagedObject] = []
    public var upcomingRates: [NSManagedObject] = []
    public var standingCharges: [NSManagedObject] = []
    public var currentStandingCharge: NSManagedObject? = nil
    public var nextFetchEarliestTime: Date? = nil
    public var isLoading: Bool = false
    
    // New properties for cache tracking
    public var lastFetchTimestamp: Date? = nil  // When was the data last fetched
    public var lastFetchWasAfter4PMUK: Bool = false  // Was it after 4PM UK
    
    public init() {}
}

/// Our multi-product RatesViewModel
@MainActor
public final class RatesViewModel: ObservableObject, AccountRepositoryDelegate {
    // MARK: - Dependencies
    private let repository = RatesRepository.shared
    private let productDetailRepository = ProductDetailRepository.shared
    private let productsRepository = ProductsRepository.shared
    private let context = PersistenceController.shared.container.viewContext
    private var cancellables = Set<AnyCancellable>()
    private var currentTimer: GlobalTimer?
    
    // MARK: - Published State
    @Published public var currentAgileCode: String = "" {
        didSet {
            if !currentAgileCode.isEmpty {
                productsToInitialize = [currentAgileCode]
            } else {
                productsToInitialize = []
            }
        }
    }
    @Published public var fetchState: DataFetchState = .idle
    @Published public var productStates: [String: ProductRatesState] = [:]
    @Published public var productsToInitialize: [String] = []  // Array of tariff codes to initialize
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

    // MARK: - Init
    public init(globalTimer: GlobalTimer) {
        setupTimer(globalTimer)
        fetchState = .idle
        AccountRepository.shared.delegate = self
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
        let currentStatus = self.fetchState
        
        // Update timer
        setupTimer(timer)
        
        // Restore status if it was loading
        if case .loading = currentStatus {
            self.fetchState = currentStatus
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
                // set status back to .loading to avoid showing "Failed" while re-fetching
                if self.fetchState.isFailure { self.fetchState = .loading }

                if now >= earliest {
                    shouldRefresh = true
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
                    if self.fetchState.isFailure {
                        withAnimation {
                            self.fetchState = .loading
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
            if self.fetchState.isFailure {
                self.fetchState = .loading
            }
            productStates[productCode] = state
            return
        }

        state.nextFetchEarliestTime = nil
        withAnimation {
            state.isLoading = true
            self.fetchState = .loading
        }
        productStates[productCode] = state
        
        do {
            let details = try await productDetailRepository.loadLocalProductDetailByTariffCode(tariffCode: productCode)
            guard let detail = details.first,
                  let tCode = detail.value(forKey: "tariff_code") as? String,
                  let link = detail.value(forKey: "link_rate") as? String else {
                withAnimation {
                    self.fetchState = .failure(NSError(domain: "com.octopus", code: -1, userInfo: [NSLocalizedDescriptionKey: "No product detail found"]))
                    state.isLoading = false
                    state.nextFetchEarliestTime = now.addingTimeInterval(60 * 5) // 5 min cooldown
                }
                productStates[productCode] = state
                return
            }
            
            // Now fetch rates
            // Phase 1: Initial fetch (BLUE state)
            withAnimation {
                self.fetchState = .loading
            }
            let (firstPhaseRates, totalPages) = try await repository.fetchAndStoreRates(tariffCode: tCode)
            
            // Load only windowed rates into memory
            let windowedRates = try await repository.fetchRatesByTariffCode(tCode, pastHours: 48)
            
            // Filter rates for this tariff code
            state.allRates = windowedRates.filter { rate in
                (rate.value(forKey: "tariff_code") as? String) == tCode
            }
            state.upcomingRates = filterUpcoming(rates: state.allRates, now: now)
            
            if totalPages > 1 {
                // Phase 2: Background fetch (ORANGE state)
                withAnimation {
                    self.fetchState = .partial
                    state.isLoading = true
                }
                productStates[productCode] = state
                
                // Wait for background fetch to complete
                try await repository.waitForBackgroundFetch()
                
                // After background fetch completes, get all rates
                let allRates = try await repository.fetchRatesByTariffCode(tCode, pastHours: 48)
                state.allRates = allRates.filter { rate in
                    (rate.value(forKey: "tariff_code") as? String) == tCode
                }
                state.upcomingRates = filterUpcoming(rates: state.allRates, now: now)
            }
            
            // All fetches complete (GREEN state)
            withAnimation {
                self.fetchState = .success
                state.isLoading = false
                state.nextFetchEarliestTime = now.addingTimeInterval(60 * 60) // 1 hour cooldown on success
            }
            productStates[productCode] = state
            
            // Auto-transition to idle after 3 seconds
            DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
                if case .success = self.fetchState {
                    withAnimation(.easeInOut(duration: 0.35)) {
                        self.fetchState = .idle
                    }
                }
            }
            
        } catch {
            print("❌ Error in refreshRatesForProduct: \(error)")
            withAnimation {
                self.fetchState = .failure(error)
                state.isLoading = false
                state.nextFetchEarliestTime = now.addingTimeInterval(60 * 5) // 5 min cooldown
            }
            productStates[productCode] = state
        }
    }

    // MARK: - Public Methods

    /// Initialize local state for multiple products. Usually called at launch.
    public func initializeProducts() async {
        print("initializeProducts: 🔍 Starting")
        self.fetchState = .loading
        
        do {
            guard !productsToInitialize.isEmpty else {
                print("initializeProducts: ⚠️ No products to initialize")
                self.fetchState = .failure(NSError(domain: "com.octopus", code: -1, 
                    userInfo: [NSLocalizedDescriptionKey: "No products to initialize"]))
                return
            }
            
            let now = Date()
            let requiredEndTime = expectedEndTime(now: now)
            print("initializeProducts: 📅 Required data until: \(requiredEndTime)")
            
            // Initialize each product
            for productCode in productsToInitialize {
                print("initializeProducts: 🔄 Processing \(productCode)")
                
                // 1. Check cache freshness
                if var state = productStates[productCode] {
                    print("initializeProducts: 🔍 Found existing state for \(productCode), checking freshness")
                    if isCacheFresh(state: state) && 
                       isDataSufficient(state.allRates, endTime: requiredEndTime) {
                        print("initializeProducts: ✅ Cache is fresh and sufficient for \(productCode)")
                        continue
                    }
                    print("initializeProducts: ⚠️ Cache stale or insufficient for \(productCode)")
                }
                
                // 2. Check CoreData completeness (using full dataset)
                print("initializeProducts: 💾 Checking CoreData completeness for \(productCode)")
                let allLocalRates = try await repository.fetchRatesByTariffCode(productCode)
                
                if !allLocalRates.isEmpty && isDataSufficient(allLocalRates, endTime: requiredEndTime) {
                    print("initializeProducts: ✅ CoreData has sufficient data for \(productCode)")
                    // Load only the time-windowed data into memory
                    let windowedRates = try await repository.fetchRatesByTariffCode(productCode, pastHours: 48)
                    
                    // Update cache with windowed data
                    var state = productStates[productCode] ?? ProductRatesState()
                    state.allRates = windowedRates
                    state.upcomingRates = filterUpcoming(rates: windowedRates, now: now)
                    state.lastFetchTimestamp = now
                    state.lastFetchWasAfter4PMUK = isAfter4PMUK(date: now)
                    state.isLoading = false
                    productStates[productCode] = state
                    continue
                }
                
                // 3. Fetch from API using two-phase approach
                print("initializeProducts: 🌐 Starting two-phase fetch for \(productCode)")
                
                // Phase 1: Quick fetch of first page
                let (firstPhaseRates, totalPages) = try await repository.fetchAndStoreRates(tariffCode: productCode)
                
                // Update UI with first phase data
                var state = productStates[productCode] ?? ProductRatesState()
                withAnimation {
                    state.allRates = firstPhaseRates
                    state.upcomingRates = filterUpcoming(rates: firstPhaseRates, now: now)
                    state.lastFetchTimestamp = now
                    state.lastFetchWasAfter4PMUK = isAfter4PMUK(date: now)
                    productStates[productCode] = state
                }
                
                if totalPages > 1 {
                    // Phase 2: Background fetch (ORANGE state)
                    withAnimation {
                        state.isLoading = true
                        self.fetchState = .partial
                    }
                    productStates[productCode] = state
                    
                    // Wait for background fetch to complete
                    try await repository.waitForBackgroundFetch()
                    
                    // After background fetch completes, get all rates
                    let allRates = try await repository.fetchRatesByTariffCode(productCode)
                    state.allRates = allRates
                    state.upcomingRates = filterUpcoming(rates: allRates, now: now)
                    state.isLoading = false
                }
                
                // All fetches complete (GREEN state)
                withAnimation {
                    self.fetchState = .success
                }
                
                print("initializeProducts: ✅ Successfully initialized \(productCode) with initial data")
            }
            
            self.fetchState = .success
            
            // Auto-transition to idle after 3 seconds
            DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
                if case .success = self.fetchState {
                    withAnimation(.easeInOut(duration: 0.35)) {
                        self.fetchState = .idle
                    }
                }
            }
            
        } catch {
            print("initializeProducts: ❌ Error: \(error)")
            self.fetchState = .failure(error)
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
            state.isLoading = true
            productStates[productCode] = state
            
            await refreshRatesForProduct(productCode: productCode, now: Date())
        } catch {
            print("❌ Error refreshing rates: \(error)")
            state.nextFetchEarliestTime = Date().addingTimeInterval(60 * 5) // 5 min cooldown on error
            productStates[productCode] = state
        }
    }

    /// Fetch rates for a specific tariff code
    public func fetchRates(tariffCode: String) async {
        print("🔄 开始获取费率，tariffCode: \(tariffCode)")
        
        self.fetchState = .loading

        do {
            let details = try await productDetailRepository.loadLocalProductDetailByTariffCode(tariffCode: tariffCode)
            guard let detail = details.first,
                  let tCode = detail.value(forKey: "tariff_code") as? String,
                  let link = detail.value(forKey: "link_rate") as? String,
                  let standingChargeLink = detail.value(forKey: "link_standing_charge") as? String else {
                print("❌ No product detail found for tariff code \(tariffCode)")
                var state = productStates[tariffCode] ?? ProductRatesState()
                self.fetchState = .failure(NSError(domain: "com.octopus", code: -1, userInfo: [NSLocalizedDescriptionKey: "No product detail found"]))
                productStates[tariffCode] = state
                return
            }
            
            print("📦 Found product detail - tariff: \(tCode)")
            print("📊 Rate link: \(link)")
            print("💰 Standing charge link: \(standingChargeLink)")
            
            var state = productStates[tariffCode] ?? ProductRatesState()
            productStates[tariffCode] = state
            
            // Fetch both rates and standing charges
            async let ratesTask = repository.fetchAndStoreRates(tariffCode: tCode)
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
            
            self.fetchState = .success
            state.nextFetchEarliestTime = Date().addingTimeInterval(60 * 60) // 1 hour cooldown
            productStates[tariffCode] = state
            
            // Auto-transition to idle after 3 seconds
            DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
                if case .success = self.fetchState {
                    withAnimation(.easeInOut(duration: 0.35)) {
                        self.fetchState = .idle
                    }
                }
            }
            
            print("✅ Successfully fetched rates and standing charges for \(tariffCode)")
        } catch {
            print("❌ Error fetching rates: \(error.localizedDescription)")
            var state = productStates[tariffCode] ?? ProductRatesState()
            self.fetchState = .failure(error)
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
            
            // After syncing, ensure current Agile code is in productsToInitialize
            await MainActor.run {
                if !currentAgileCode.isEmpty {
                    productsToInitialize = [currentAgileCode]
                }
            }
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
            // First try to sync products if we haven't today
            _ = try await productsRepository.syncAllProducts()
            
            // Now search for an Agile product
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
            
            return sortedProducts.first?.value(forKey: "code") as? String
        } catch {
            print("fallbackAgileCodeFromProductEntity: ❌ Error: \(error)")
            return nil
        }
    }

    /// Called at app startup or whenever account might have changed.
    /// Checks user's `accountData` for an active agile agreement code, else falls back.
    public func setAgileProductFromAccountOrFallback(
        globalSettings: GlobalSettingsManager
    ) async {
        print("setAgileProductFromAccountOrFallback: 🔍 Starting")
        
        // 1. First priority: Check account data for active AGILE agreement
        if let newTariffCode = await findTariffCodeInAccount(globalSettings: globalSettings) {
            if newTariffCode != currentAgileCode {
                print("setAgileProductFromAccountOrFallback: 🔍 Found new active Agile tariff in account: \(newTariffCode)")
                await MainActor.run {
                    currentAgileCode = newTariffCode
                    globalSettings.settings.currentAgileCode = newTariffCode
                    productsToInitialize = [newTariffCode]
                }
                return
            }
            print("setAgileProductFromAccountOrFallback: 🔍 Account has same active Agile tariff, keeping current")
            return
        }
        
        // 2. No valid account tariff, try fallback
        print("setAgileProductFromAccountOrFallback: 🔍 No valid tariff from account, checking fallback options")
        let sharedDefaults = UserDefaults(suiteName: "group.com.jamesto.octopus-agile-helper")
        
        // Check region only for fallback scenario
        let newRegion = globalSettings.settings.effectiveRegion
        if newRegion != cachedRegionUsedLastTime {
            print("setAgileProductFromAccountOrFallback: 🔍 Region changed from \(cachedRegionUsedLastTime) to \(newRegion), clearing currentAgileCode for fallback")
            await MainActor.run {
                currentAgileCode = ""
                globalSettings.settings.currentAgileCode = ""
            }
            cachedRegionUsedLastTime = newRegion
        }
        
        // If we still have a valid code for current region, keep it
        if !currentAgileCode.isEmpty && currentAgileCode.contains("AGILE") {
            print("setAgileProductFromAccountOrFallback: 🔍 Keeping existing valid AGILE code for current region")
            // Sync the codes if they're different
            if currentAgileCode != globalSettings.settings.currentAgileCode {
                await MainActor.run {
                    globalSettings.settings.currentAgileCode = currentAgileCode
                }
            }
            return
        }
        
        // Last resort - try fallback
        print("setAgileProductFromAccountOrFallback: 🔍 No valid current code, trying fallback")
        await applyFallbackTariffCode(globalSettings: globalSettings, sharedDefaults: sharedDefaults)
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
                print("applyFallbackTariffCode: 🔄 No local details found for \(fallbackCode), fetching from API...")
                details = try await productDetailRepository.fetchAndStoreProductDetail(productCode: fallbackCode)
            }

            // Determine the region
            let region = globalSettings.settings.effectiveRegion
            print("applyFallbackTariffCode: 🌍 Using effective region: \(region)")

            // Find the tariff code from the product details
            guard let tariffCode = try await productDetailRepository.findTariffCode(productCode: fallbackCode,
                                                                                    region: region)
            else {
                print("applyFallbackTariffCode: ❌ No tariff code found for \(fallbackCode) in region \(region)")
                return
            }

            print("applyFallbackTariffCode: ✅ Found tariff code: \(tariffCode)")
            await MainActor.run {
                currentAgileCode = tariffCode
                globalSettings.settings.currentAgileCode = tariffCode
            }

            // Store for widget access
            sharedDefaults?.set(tariffCode, forKey: "agile_code_for_widget")

        } catch {
            print("applyFallbackTariffCode: ❌ Error processing fallback code: \(error)")
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

    // MARK: - Cache Validation Helpers
    
    private func isAfter4PMUK(date: Date = Date()) -> Bool {
        let ukTimeZone = TimeZone(identifier: "Europe/London") ?? .current
        let ukCalendar = Calendar.current
        let components = ukCalendar.dateComponents(in: ukTimeZone, from: date)
        return (components.hour ?? 0) >= 16
    }

    private func expectedEndTime(now: Date) -> Date {
        let ukTimeZone = TimeZone(identifier: "Europe/London") ?? .current
        var ukCalendar = Calendar.current
        ukCalendar.timeZone = ukTimeZone
        
        // If after 4PM UK, expect data until 11PM tomorrow
        // If before 4PM UK, expect data until 11PM today
        let daysToAdd = isAfter4PMUK(date: now) ? 1 : 0
        
        var components = ukCalendar.dateComponents([.year, .month, .day], from: now)
        components.hour = 23  // 11 PM
        components.minute = 0
        components.second = 0
        components.day! += daysToAdd
        
        return ukCalendar.date(from: components) ?? now.addingTimeInterval(3600 * 24)
    }

    private func isCacheFresh(state: ProductRatesState) -> Bool {
        guard let lastFetch = state.lastFetchTimestamp else { return false }
        
        let now = Date()
        let currentlyAfter4PM = isAfter4PMUK(date: now)
        
        // If it's after 4PM UK now
        if currentlyAfter4PM {
            // Cache must have been fetched after 4PM today
            return state.lastFetchWasAfter4PMUK && 
                   Calendar.current.isDateInToday(lastFetch)
        } else {
            // If before 4PM, cache from after 4PM yesterday or before 4PM today is valid
            if state.lastFetchWasAfter4PMUK {
                return Calendar.current.isDateInYesterday(lastFetch)
            } else {
                return Calendar.current.isDateInToday(lastFetch)
            }
        }
    }

    private func isDataSufficient(_ rates: [NSManagedObject], endTime: Date) -> Bool {
        return rates.contains { rate in
            guard let validTo = rate.value(forKey: "valid_to") as? Date else { return false }
            return validTo >= endTime
        }
    }

    // MARK: - AccountRepositoryDelegate
    public func accountRepository(_ repository: AccountRepository, didFindProductCodes codes: Set<String>) {
        // We don't need to do anything here anymore since we only use currentAgileCode
    }
}
