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

    /// Get lowest average rates for a specific product
    public func getLowestAverages(productCode: String, hours: Int) -> [(startTime: Date, average: Double)] {
        guard let state = productStates[productCode] else { return [] }
        let now = Date()
        
        // Group rates by their start hour
        var hourlyGroups: [Date: [NSManagedObject]] = [:]
        state.upcomingRates.forEach { rate in
            guard let validFrom = rate.value(forKey: "valid_from") as? Date,
                  validFrom > now else { return }
            
            // Round down to the hour
            let calendar = Calendar.current
            let hourStart = calendar.date(
                bySetting: .minute,
                value: 0,
                of: calendar.date(
                    bySetting: .second,
                    value: 0,
                    of: validFrom
                ) ?? validFrom
            ) ?? validFrom
            
            var group = hourlyGroups[hourStart] ?? []
            group.append(rate)
            hourlyGroups[hourStart] = group
        }
        
        // Calculate averages for each complete hour
        var averages: [(startTime: Date, average: Double)] = []
        for (startTime, rates) in hourlyGroups {
            guard rates.count == 2 else { continue } // Skip incomplete hours
            
            let sum = rates.reduce(0.0) { sum, rate in
                sum + (rate.value(forKey: "value_including_vat") as? Double ?? 0)
            }
            let average = sum / Double(rates.count)
            averages.append((startTime: startTime, average: average))
        }
        
        // Sort by average rate and take the requested number of hours
        return averages
            .sorted { $0.average < $1.average }
            .prefix(hours)
            .sorted { $0.startTime < $1.startTime }
    }

    // MARK: - Rate Queries
    
    /// Get the lowest upcoming rate for a specific product
    public func lowestUpcomingRate(productCode: String) -> NSManagedObject? {
        guard let state = productStates[productCode] else { return nil }
        return state.upcomingRates.min { a, b in
            let aValue = (a as? RateEntity)?.valueIncludingVAT ?? Double.infinity
            let bValue = (b as? RateEntity)?.valueIncludingVAT ?? Double.infinity
            return aValue < bValue
        }
    }

    /// Get the highest upcoming rate for a specific product
    public func highestUpcomingRate(productCode: String) -> NSManagedObject? {
        guard let state = productStates[productCode] else { return nil }
        return state.upcomingRates.max { a, b in
            let aValue = (a as? RateEntity)?.valueIncludingVAT ?? Double.infinity
            let bValue = (b as? RateEntity)?.valueIncludingVAT ?? Double.infinity
            return aValue < bValue
        }
    }

    // ------------------------------------------------------

    // MARK: - New Rate Fetching Logic
    public func fetchRatesForDefaultProduct() async {
        do {
            // Step 1: Get the product code using fallback logic
            guard let productCode = await fallbackAgileCodeFromProductEntity() else {
                print("❌ No Agile product found")
                return
            }
            
            // Step 2: Fetch product detail and store it
            let details = try await productDetailRepository.fetchAndStoreProductDetail(productCode: productCode)
            
            // Step 3: Find the rate link from the product detail
            guard let detail = details.first,
                  let rateLink = detail.value(forKey: "link_rate") as? String,
                  let tariffCode = detail.value(forKey: "tariff_code") as? String else {
                print("❌ No rate link found in product detail")
                return
            }
            
            // Step 4: If no region in tariff code, append "-H"
            let finalTariffCode = tariffCode.contains("-[A-Z]$") ? tariffCode : "\(tariffCode)-H"
            
            // Step 5: Fetch and store rates
            try await repository.fetchAndStoreRates(tariffCode: finalTariffCode, url: rateLink)
            
            // Step 6: Update current agile code
            self.currentAgileCode = productCode
            
            // Step 7: Save to shared defaults for widget
            let sharedDefaults = UserDefaults(suiteName: "group.com.jamesto.octopus-agile-helper")
            sharedDefaults?.set(productCode, forKey: "agile_code_for_widget")
            
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

        // First get product detail to get the link and tariff code
        do {
            let details = try await productDetailRepository.loadLocalProductDetail(code: productCode)
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
            state.allRates = freshRates
            state.upcomingRates = filterUpcoming(rates: freshRates, now: now)
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
        for code in codes {
            // Always force fetch on initial load to ensure we have data
            print("🔄 Fetching rates for \(code)")
            await refreshRatesForProduct(productCode: code, now: Date())
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
    /// 2. tariff_type = single_register_electricity_tariffs
    /// 3. direction = IMPORT
    public func fallbackAgileCodeFromProductEntity() async -> String? {
        do {
            let products = try await productDetailRepository.fetchAllLocalProductDetails()
            
            // Filter for Agile products
            let agileProducts = products.filter { obj in
                guard let tariffType = obj.value(forKey: "tariff_type") as? String,
                      let tariffCode = obj.value(forKey: "tariff_code") as? String else {
                    return false
                }
                return tariffType == "single_register_electricity_tariffs" &&
                       tariffCode.contains("AGILE")
            }
            
            // Return first found code
            return agileProducts.first?.value(forKey: "code") as? String
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

    // Example logic to find an active agile code from the user's agreements
    private func findAgileShortCode(in account: OctopusAccountResponse) -> String? {
        // We only examine the first property + first electricity agreement for brevity
        guard let firstProp = account.properties.first,
              let elecMP = firstProp.electricity_meter_points?.first,
              let agreements = elecMP.agreements
        else { return nil }

        // e.g. "E-1R-AGILE-24-04-03-H" => short code "AGILE-24-04-03"
        // We check valid_from, valid_to if needed, but this is minimal
        let now = Date()
        for ag in agreements {
            // parse "E-1R-AGILE-24-04-03-H"
            if ag.tariff_code.contains("AGILE") {
                // Optional: check if now is within valid_from..valid_to if you want strict
                if let shortCode = extractShortCode(ag.tariff_code) {
                    return shortCode
                }
            }
        }
        return nil
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
