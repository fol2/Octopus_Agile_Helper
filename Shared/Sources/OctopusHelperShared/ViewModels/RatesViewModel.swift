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

public enum ProductFetchStatus: Equatable {
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
}

/// Data container for each product's local state
fileprivate struct ProductRatesState {
    var allRates: [NSManagedObject] = []
    var upcomingRates: [NSManagedObject] = []
    var fetchStatus: ProductFetchStatus = .none
    var nextFetchEarliestTime: Date? = nil
    var isLoading: Bool = false
}

/// Our multi-product RatesViewModel
@MainActor
public final class RatesViewModel: ObservableObject {
    // MARK: - Dependencies
    private let repository = RatesRepository.shared
    private let productsRepository = ProductsRepository.shared
    private var cancellables = Set<AnyCancellable>()
    private var currentTimer: GlobalTimer?

    // NEW: Store a single "current agile code" for convenience
    @Published public private(set) var currentAgileCode: String = ""

    // NEW: Publish a single fetchStatus to observe in ContentView
    @Published public var fetchStatus: ProductFetchStatus = .none

    /// A dictionary mapping productCode => ProductRatesState
    @Published fileprivate var productStates: [String: ProductRatesState] = [:]
    // This way, no public property references a private struct => no more linter error

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
    public func allRates(for productCode: String) -> [RateEntity] {
        let raw = productStates[productCode]?.allRates ?? []
        return raw.compactMap { $0 as? RateEntity }
    }

    /// Example aggregator for "lowest averages" (similar to your old code).
    /// Adjust the return type to match your aggregator's structure (e.g. [AveragedRateWindow]).
    public func getLowestAverages(
        productCode: String,
        hours: Double,
        maxCount: Int
    ) -> [AveragedRateWindow] {
        // Stub aggregator example returning empty to avoid errors
        // For demonstration, we return an empty array or a dummy array:

        return []
    }
    // ------------------------------------------------------

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
                        do {
                            try await self.repository.updateRates(force: false) // or pass product code if needed
                            // Re-fetch from DB
                            let freshRates = try await self.repository.fetchAllRates()
                            state.allRates = freshRates
                            state.upcomingRates = self.filterUpcoming(rates: freshRates, now: now)
                            state.fetchStatus = .done
                        } catch {
                            state.fetchStatus = .failed(error)
                            // set cooldown again if desired
                            state.nextFetchEarliestTime = Date().addingTimeInterval(10 * 60)
                        }
                        // update productStates
                        self.productStates[code] = state
                    }
                }
            } else {
                // Normal logic: fetch every minute if needed
                Task {
                    do {
                        try await self.repository.updateRates(force: false)
                        let freshRates = try await self.repository.fetchAllRates()
                        state.allRates = freshRates
                        state.upcomingRates = self.filterUpcoming(rates: freshRates, now: now)
                        state.fetchStatus = .done
                    } catch {
                        state.fetchStatus = .failed(error)
                        // 10-min cooldown
                        state.nextFetchEarliestTime = Date().addingTimeInterval(10 * 60)
                    }
                    self.productStates[code] = state
                }
            }
            productStates[code] = state
        }
    }

    // MARK: - Public Methods

    /// Initialize local state for multiple products. Usually called at launch.
    /// For each product code, we attempt to see if coverage is complete. If not, we do a fetch.
    public func loadRates(for productCodes: [String]) async {
        // Mark overall status => .fetching if any needed fetch
        fetchStatus = .fetching

        // Ensure we have an entry in productStates for each code
        for code in productCodes {
            if productStates[code] == nil {
                productStates[code] = ProductRatesState()
            }
        }

        // For each product, attempt to load from DB or do a fetch
        for code in productCodes {
            var state = productStates[code] ?? ProductRatesState()
            do {
                if repository.hasDataThroughExpectedEndUKTime() {
                    // If coverage complete, just fetch from DB
                    let results = try await repository.fetchAllRates()
                    state.allRates = results
                    state.upcomingRates = filterUpcoming(rates: results, now: Date())
                    state.fetchStatus = .none
                    fetchStatus = .done
                } else {
                    // No coverage => do a fetch
                    state.fetchStatus = .fetching
                    state.isLoading = true
                    try await repository.updateRates(force: false)
                    let results = try await repository.fetchAllRates()
                    state.allRates = results
                    state.upcomingRates = filterUpcoming(rates: results, now: Date())
                    state.fetchStatus = .none
                    state.isLoading = false
                    fetchStatus = .done
                }
            } catch {
                state.fetchStatus = .failed(error)
                state.isLoading = false
                fetchStatus = .failed(error)
            }
            productStates[code] = state
        }
    }

    /// Refresh coverage for a single product code
    public func refreshRates(productCode: String, force: Bool = false) async {
        guard var state = productStates[productCode] else {
            // If we have no record, create one
            productStates[productCode] = ProductRatesState()
            return
        }

        // If we have coverage and not forcing, do nothing
        if !force && repository.hasDataThroughExpectedEndUKTime() {
            return
        }
        state.fetchStatus = .pending
        state.isLoading = true
        productStates[productCode] = state

        do {
            state.fetchStatus = .fetching
            try await repository.updateRates(force: force)
            let results = try await repository.fetchAllRates()
            state.allRates = results
            state.upcomingRates = filterUpcoming(rates: results, now: Date())
            state.fetchStatus = .done

            // Show "done" for 3 seconds, revert to .none
            DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
                if self.productStates[productCode]?.fetchStatus == .done {
                    // fade out
                    var s = self.productStates[productCode]!
                    s.fetchStatus = .none
                    self.productStates[productCode] = s
                }
            }
        } catch {
            state.fetchStatus = .failed(error)
            // If partial data is available, fade out quickly
            let hasCoverage = repository.hasDataThroughExpectedEndUKTime()
            if hasCoverage {
                DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
                    if self.productStates[productCode]?.fetchStatus == .failed(error) {
                        var s = self.productStates[productCode]!
                        s.fetchStatus = .none
                        self.productStates[productCode] = s
                    }
                }
            } else {
                // no coverage => 10-min cooldown
                state.nextFetchEarliestTime = Date().addingTimeInterval(10 * 60)
            }
        }
        state.isLoading = false
        productStates[productCode] = state
    }

    // MARK: - Aggregators

    /// Lowest upcoming rate for a single product
    public func lowestUpcomingRate(productCode: String) -> NSManagedObject? {
        guard let state = productStates[productCode] else { return nil }
        let now = Date()
        let futureRates = state.upcomingRates.filter { obj in
            guard let validFrom = obj.value(forKey: "valid_from") as? Date else { return false }
            return validFrom > now
        }
        return futureRates.min { lhs, rhs in
            let lv = lhs.value(forKey: "value_including_vat") as? Double ?? 999999
            let rv = rhs.value(forKey: "value_including_vat") as? Double ?? 999999
            return lv < rv
        }
    }

    /// Highest upcoming rate for a single product
    public func highestUpcomingRate(productCode: String) -> NSManagedObject? {
        guard let state = productStates[productCode] else { return nil }
        let now = Date()
        let futureRates = state.upcomingRates.filter { obj in
            guard let validFrom = obj.value(forKey: "valid_from") as? Date else { return false }
            return validFrom > now
        }
        return futureRates.max { lhs, rhs in
            let lv = lhs.value(forKey: "value_including_vat") as? Double ?? 0
            let rv = rhs.value(forKey: "value_including_vat") as? Double ?? 0
            return lv < rv
        }
    }

    /// Example aggregator for "lowest 10 average" 
    /// (similar to your old code, but here we do it per product)
    public func lowestTenAverageRate(productCode: String) -> Double? {
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
        let topTen = Array(sorted.prefix(10))
        guard !topTen.isEmpty else { return nil }
        let sum = topTen.reduce(0.0) { partial, obj in
            partial + (obj.value(forKey: "value_including_vat") as? Double ?? 0.0)
        }
        return sum / Double(topTen.count)
    }

    // MARK: - Pagination

    /// If you want to do DB paging per product, you can call repository with product param
    public func fetchRatesPage(
        productCode: String,
        offset: Int,
        limit: Int,
        ascending: Bool = true
    ) async throws -> [NSManagedObject] {
        // If your repository supports product-based paging, pass productCode
        // For now, we just do the existing paging, ignoring productCode:
        return try await repository.fetchRatesPage(offset: offset, limit: limit, ascending: ascending)
    }

    public func countAllRates(productCode: String) async throws -> Int {
        // Same note as above
        return try await repository.countAllRates()
    }

    // MARK: - Helpers for formatting, same signatures

    public func formatRate(_ value: Double, showRatesInPounds: Bool = false) -> String {
        if showRatesInPounds {
            let poundsValue = value / 100.0
            return String(format: "£%.4f /kWh", poundsValue)
        } else {
            return String(format: "%.2fp /kWh", value)
        }
    }

    public func formatTime(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.timeStyle = .short
        return formatter.string(from: date)
    }

    // ------------------------------------------------------
    // MARK: - Public fetchRatesForDay method
    // ------------------------------------------------------
    public func fetchRatesForDay(_ day: Date) async throws -> [RateEntity] {
        let objects = try await repository.fetchRatesForDay(day)
        // Convert the NSManagedObject array into a [RateEntity]
        let typed = objects.compactMap { $0 as? RateEntity }
        // If any item is not RateEntity, it's dropped to avoid runtime errors
        return typed
    }

    // MARK: - Private

    private func filterUpcoming(rates: [NSManagedObject], now: Date) -> [NSManagedObject] {
        rates.filter {
            guard let validFrom = $0.value(forKey: "valid_from") as? Date,
                  let validTo = $0.value(forKey: "valid_to") as? Date
            else { return false }
            return validTo > now
        }
    }

    // NEW: Called at app startup or whenever account might have changed
    // Checks user's accountData for an active agile agreement code, else fallback
    public func setAgileProductFromAccountOrFallback(globalSettings: GlobalSettingsManager) async {
        let sharedDefaults = UserDefaults(suiteName: "group.com.jamesto.octopus-agile-helper")
        
        // Attempt to find an 'AGILE' product from local DB
        let fallbackCode = await fallbackAgileCodeFromProductEntity()
        
        // If we have no account data => rely solely on fallback from local ProductEntity
        guard let accountData = globalSettings.settings.accountData,
              !accountData.isEmpty
        else {
            // If ProductEntity also had nothing, do nothing or keep the existing code:
            if let code = fallbackCode {
                self.currentAgileCode = code
                sharedDefaults?.set(code, forKey: "agile_code_for_widget")
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

    private func fallbackAgileCodeFromProductEntity() async -> String? {
        // 从本地数据库中查找包含 "AGILE" 的最新 ProductEntity
        do {
            let products = try await Task {
                try await productsRepository.fetchLocalProducts()
            }.value
            
            // 过滤出包含 "AGILE" 的产品，并按照创建时间降序排序
            let agileProducts = products.filter { product in
                guard let code = product.value(forKey: "code") as? String else { return false }
                return code.contains("AGILE")
            }.sorted { lhs, rhs in
                guard let lhsDate = lhs.value(forKey: "available_from") as? Date,
                      let rhsDate = rhs.value(forKey: "available_from") as? Date
                else { return false }
                return lhsDate > rhsDate
            }
            
            // 返回最新的 AGILE 产品代码
            if let latestProduct = agileProducts.first,
               let code = latestProduct.value(forKey: "code") as? String {
                return code
            }
        } catch {
            print("Error fetching products from DB: \(error)")
        }
        return nil
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
