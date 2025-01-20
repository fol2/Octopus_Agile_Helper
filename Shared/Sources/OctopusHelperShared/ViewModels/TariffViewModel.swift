import CoreData
import Foundation
import SwiftUI

@MainActor
public final class TariffViewModel: ObservableObject {
    // MARK: - Types
    public enum IntervalType: String, CaseIterable {
        case daily = "Daily"
        case weekly = "Weekly"
        case monthly = "Monthly"
    }

    public struct TariffCalculation {
        public let periodStart: Date
        public let periodEnd: Date
        public let totalKWh: Double
        public let costExcVAT: Double
        public let costIncVAT: Double
        public let averageUnitRateExcVAT: Double
        public let averageUnitRateIncVAT: Double
        public let standingChargeExcVAT: Double
        public let standingChargeIncVAT: Double
    }

    // MARK: - Published Properties
    @Published public private(set) var currentCalculation: TariffCalculation?
    @Published public private(set) var isCalculating = false
    @Published public private(set) var error: Error?

    // MARK: - Dependencies
    private let calculationRepository: TariffCalculationRepository

    // MARK: - Memory Cache
    private struct CacheKey: Hashable {
        let tariffCode: String
        let intervalType: IntervalType
        let startTimestamp: TimeInterval
        let endTimestamp: TimeInterval

        var debugDescription: String {
            "[\(tariffCode)][\(intervalType.rawValue)] \(Date(timeIntervalSince1970: startTimestamp).formatted()) - \(Date(timeIntervalSince1970: endTimestamp).formatted())"
        }
    }

    private struct CacheEntry {
        let calculation: TariffCalculation
        let timestamp: Date
    }

    private var calculationCache: [CacheKey: CacheEntry] = [:]
    private let maxCacheSize = 200  // Increased to 200 entries
    private let cacheCleanupThreshold = 180  // Clean when reaching 180 entries

    // MARK: - Initialization
    public init() {
        self.calculationRepository = TariffCalculationRepository()
        DebugLogger.debug("🔄 Initializing TariffViewModel", component: .tariffViewModel)
    }

    // MARK: - Cache Management
    private func cacheKey(tariffCode: String, date: Date, intervalType: IntervalType) -> CacheKey {
        let (start, end) = calculateDateRange(for: date, intervalType: intervalType)
        return CacheKey(
            tariffCode: tariffCode,
            intervalType: intervalType,
            startTimestamp: start.timeIntervalSince1970,
            endTimestamp: end.timeIntervalSince1970
        )
    }

    private func cleanupCache() {
        guard calculationCache.count > cacheCleanupThreshold else { return }

        DebugLogger.debug("🧹 Starting cache cleanup", component: .tariffViewModel)

        // If too large, remove oldest entries
        if calculationCache.count > maxCacheSize {
            let sortedEntries = calculationCache.sorted { $0.value.timestamp > $1.value.timestamp }
            calculationCache = Dictionary(
                uniqueKeysWithValues:
                    sortedEntries
                    .prefix(maxCacheSize)
                    .map { ($0.key, $0.value) }
            )
        }

        DebugLogger.debug(
            """
            ✨ Cache cleanup complete:
            - Entries: \(calculationCache.count)
            - Memory entries:
            \(calculationCache.map { "  • \($0.key.debugDescription)" }.joined(separator: "\n"))
            """, component: .tariffViewModel)
    }

    public func invalidateCache() {
        DebugLogger.debug("🗑 Invalidating calculation cache", component: .tariffViewModel)
        calculationCache.removeAll()
    }

    // MARK: - Public Methods

    /// Calculate tariff costs for a specific date and interval type
    /// - Parameters:
    ///   - date: The reference date for calculation
    ///   - tariffCode: The tariff code to calculate for, use "savedAccount" to calculate for saved account
    ///   - intervalType: The type of interval (daily, weekly, monthly)
    ///   - accountData: The account data, required when tariffCode is "savedAccount"
    public func calculateCosts(
        for date: Date,
        tariffCode: String,
        intervalType: IntervalType,
        accountData: OctopusAccountResponse? = nil
    ) async {
        DebugLogger.debug(
            """
            🔄 Starting cost calculation:
            - Date: \(date)
            - Tariff: \(tariffCode)
            - Interval: \(intervalType.rawValue)
            """, component: .tariffViewModel)

        isCalculating = true
        error = nil

        do {
            if tariffCode == "savedAccount" {
                guard let accountData = accountData else {
                    throw TariffCalculationError.noDataAvailable(period: date...date)
                }
                try await calculateAccountCosts(
                    for: date, intervalType: intervalType, accountData: accountData)
            } else {
                try await calculateSingleTariffCosts(
                    for: date, tariffCode: tariffCode, intervalType: intervalType)
            }
        } catch {
            self.error = error
            DebugLogger.debug(
                "❌ Error calculating costs: \(error.localizedDescription)",
                component: .tariffViewModel)
        }

        isCalculating = false
        cleanupCache()  // Cleanup after calculation
    }

    // MARK: - Private Methods

    /// Calculate costs for a single tariff
    private func calculateSingleTariffCosts(
        for date: Date, tariffCode: String, intervalType: IntervalType
    ) async throws {
        let cacheKey = cacheKey(tariffCode: tariffCode, date: date, intervalType: intervalType)

        DebugLogger.debug(
            "🔍 Looking for calculation: \(cacheKey.debugDescription)", component: .tariffViewModel)

        // 1. Check memory cache first
        if let cached = calculationCache[cacheKey] {
            DebugLogger.debug(
                """
                ✅ USING MEMORY CACHE:
                - Key: \(cacheKey.debugDescription)
                - Total kWh: \(cached.calculation.totalKWh)
                - Total cost inc VAT: \(cached.calculation.costIncVAT)p
                """, component: .tariffViewModel)
            currentCalculation = cached.calculation
            return
        } else {
            DebugLogger.debug(
                "🔍 No memory cache found, checking CoreData...", component: .tariffViewModel)
        }

        let (start, end) = calculateDateRange(for: date, intervalType: intervalType)

        // 2. Check CoreData cache
        if let existingCalculation = try await calculationRepository.fetchStoredCalculation(
            tariffCode: tariffCode,
            intervalType: intervalType.rawValue,
            periodStart: start,
            periodEnd: end
        ) {
            DebugLogger.debug(
                """
                ✅ USING COREDATA CACHE:
                - Key: \(cacheKey.debugDescription)
                - Total kWh: \(existingCalculation.value(forKey: "total_consumption_kwh") as? Double ?? 0.0)
                - Total cost inc VAT: \(existingCalculation.value(forKey: "total_cost_inc_vat") as? Double ?? 0.0)p
                """, component: .tariffViewModel)

            let calculation = convertToCalculation(
                managedObject: existingCalculation, start: start, end: end)

            // Store in memory cache
            calculationCache[cacheKey] = CacheEntry(
                calculation: calculation,
                timestamp: Date()
            )
            currentCalculation = calculation

            DebugLogger.debug(
                """
                ✅ FRESH CALCULATION STORED:
                - Key: \(cacheKey.debugDescription)
                - Total kWh: \(calculation.totalKWh)
                - Total cost inc VAT: \(calculation.costIncVAT)p
                """, component: .tariffViewModel)

            cleanupCache()
            return
        }

        DebugLogger.debug(
            "🔄 No cached data found, calculating fresh values...",
            component: .tariffViewModel
        )

        // 3. Calculate new if not found in either cache
        let result = try await calculationRepository.calculateCostForPeriod(
            tariffCode: tariffCode,
            startDate: start,
            endDate: end,
            intervalType: intervalType.rawValue
        )

        let calculation = convertToCalculation(managedObject: result, start: start, end: end)

        // Store in memory cache
        calculationCache[cacheKey] = CacheEntry(
            calculation: calculation,
            timestamp: Date()
        )
        currentCalculation = calculation

        DebugLogger.debug(
            """
            ✅ FRESH CALCULATION STORED:
            - Key: \(cacheKey.debugDescription)
            - Total kWh: \(calculation.totalKWh)
            - Total cost inc VAT: \(calculation.costIncVAT)p
            """, component: .tariffViewModel)

        cleanupCache()
    }

    /// Calculate costs for saved account
    private func calculateAccountCosts(
        for date: Date,
        intervalType: IntervalType,
        accountData: OctopusAccountResponse
    ) async throws {
        let (start, end) = calculateDateRange(for: date, intervalType: intervalType)
        let cacheKey = cacheKey(tariffCode: "savedAccount", date: date, intervalType: intervalType)

        DebugLogger.debug(
            """
            🔍 Looking for account calculation:
            - Key: \(cacheKey.debugDescription)
            - Period: \(start.formatted()) to \(end.formatted())
            """, component: .tariffViewModel)

        // 1. Check memory cache first
        if let cached = calculationCache[cacheKey] {
            DebugLogger.debug(
                """
                ✅ USING MEMORY CACHE:
                - Key: \(cacheKey.debugDescription)
                - Total kWh: \(cached.calculation.totalKWh)
                - Total cost inc VAT: \(cached.calculation.costIncVAT)p
                """, component: .tariffViewModel)
            currentCalculation = cached.calculation
            return
        }

        // 2. Check CoreData cache
        let results = try await calculationRepository.calculateCostForAccount(
            accountData: accountData,
            startDate: start,
            endDate: end,
            intervalType: intervalType.rawValue
        )

        // 3. Process results
        if let combinedCalculation = combineAccountCalculations(results, start: start, end: end) {
            currentCalculation = combinedCalculation

            // Store in memory cache
            calculationCache[cacheKey] = CacheEntry(
                calculation: combinedCalculation,
                timestamp: Date()
            )

            DebugLogger.debug(
                """
                ✅ Calculation stored in memory cache:
                - Key: \(cacheKey.debugDescription)
                - Total kWh: \(combinedCalculation.totalKWh)
                - Total cost inc VAT: \(combinedCalculation.costIncVAT)p
                """, component: .tariffViewModel)
        } else {
            DebugLogger.debug(
                "❌ No valid calculations found for account", component: .tariffViewModel)
            throw TariffCalculationError.noDataAvailable(period: start...end)
        }
    }

    /// Converts NSManagedObject to TariffCalculation struct
    private func convertToCalculation(managedObject: NSManagedObject, start: Date, end: Date)
        -> TariffCalculation
    {
        let calculation = TariffCalculation(
            periodStart: managedObject.value(forKey: "period_start") as? Date ?? start,
            periodEnd: managedObject.value(forKey: "period_end") as? Date ?? end,
            totalKWh: managedObject.value(forKey: "total_consumption_kwh") as? Double ?? 0.0,
            costExcVAT: managedObject.value(forKey: "total_cost_exc_vat") as? Double ?? 0.0,
            costIncVAT: managedObject.value(forKey: "total_cost_inc_vat") as? Double ?? 0.0,
            averageUnitRateExcVAT: managedObject.value(forKey: "average_unit_rate_exc_vat")
                as? Double ?? 0.0,
            averageUnitRateIncVAT: managedObject.value(forKey: "average_unit_rate_inc_vat")
                as? Double ?? 0.0,
            standingChargeExcVAT: managedObject.value(forKey: "standing_charge_cost_exc_vat")
                as? Double ?? 0.0,
            standingChargeIncVAT: managedObject.value(forKey: "standing_charge_cost_inc_vat")
                as? Double ?? 0.0
        )

        let costExcVATFormatted = String(format: "%.2f", calculation.costExcVAT / 100)
        let costIncVATFormatted = String(format: "%.2f", calculation.costIncVAT / 100)
        let avgRateExcVATFormatted = String(format: "%.2f", calculation.averageUnitRateExcVAT)
        let avgRateIncVATFormatted = String(format: "%.2f", calculation.averageUnitRateIncVAT)
        let standingChargeExcVATFormatted = String(
            format: "%.2f", calculation.standingChargeExcVAT / 100)
        let standingChargeIncVATFormatted = String(
            format: "%.2f", calculation.standingChargeIncVAT / 100)

        DebugLogger.debug(
            """
            📊 Calculation details:
            - Period: \(calculation.periodStart) to \(calculation.periodEnd)
            - Total kWh: \(calculation.totalKWh)
            - Cost (exc VAT): £\(costExcVATFormatted)
            - Cost (inc VAT): £\(costIncVATFormatted)
            - Avg Rate (exc VAT): \(avgRateExcVATFormatted)p/kWh
            - Avg Rate (inc VAT): \(avgRateIncVATFormatted)p/kWh
            - Standing Charge (exc VAT): £\(standingChargeExcVATFormatted)
            - Standing Charge (inc VAT): £\(standingChargeIncVATFormatted)
            """, component: .tariffViewModel)

        return calculation
    }

    /// Combines multiple account calculations into a single TariffCalculation
    private func combineAccountCalculations(
        _ calculations: [NSManagedObject], start: Date, end: Date
    ) -> TariffCalculation? {
        guard !calculations.isEmpty else { return nil }

        var totalKWh = 0.0
        var totalCostExcVAT = 0.0
        var totalCostIncVAT = 0.0
        var totalStandingChargeExcVAT = 0.0
        var totalStandingChargeIncVAT = 0.0

        for calc in calculations {
            totalKWh += calc.value(forKey: "total_consumption_kwh") as? Double ?? 0.0
            totalCostExcVAT += calc.value(forKey: "total_cost_exc_vat") as? Double ?? 0.0
            totalCostIncVAT += calc.value(forKey: "total_cost_inc_vat") as? Double ?? 0.0
            totalStandingChargeExcVAT +=
                calc.value(forKey: "standing_charge_cost_exc_vat") as? Double ?? 0.0
            totalStandingChargeIncVAT +=
                calc.value(forKey: "standing_charge_cost_inc_vat") as? Double ?? 0.0
        }

        // Calculate average rates
        let avgRateExcVAT =
            totalKWh > 0 ? (totalCostExcVAT - totalStandingChargeExcVAT) / totalKWh : 0.0
        let avgRateIncVAT =
            totalKWh > 0 ? (totalCostIncVAT - totalStandingChargeIncVAT) / totalKWh : 0.0

        return TariffCalculation(
            periodStart: start,
            periodEnd: end,
            totalKWh: totalKWh,
            costExcVAT: totalCostExcVAT,
            costIncVAT: totalCostIncVAT,
            averageUnitRateExcVAT: avgRateExcVAT,
            averageUnitRateIncVAT: avgRateIncVAT,
            standingChargeExcVAT: totalStandingChargeExcVAT,
            standingChargeIncVAT: totalStandingChargeIncVAT
        )
    }

    /// Calculates the start and end dates for a given reference date and interval type
    private func calculateDateRange(for date: Date, intervalType: IntervalType) -> (
        start: Date, end: Date
    ) {
        let calendar = Calendar.current

        switch intervalType {
        case .daily:
            // Start of the day (00:00)
            let start = calendar.startOfDay(for: date)
            // Start of next day (00:00)
            let end = calendar.date(byAdding: .day, value: 1, to: start) ?? date
            return (start, end)

        case .weekly:
            // Start of the week (Monday 00:00)
            let start =
                calendar.date(
                    from: calendar.dateComponents([.yearForWeekOfYear, .weekOfYear], from: date))
                ?? date
            // Start of next week (Monday 00:00)
            let end = calendar.date(byAdding: .weekOfYear, value: 1, to: start) ?? date
            return (start, end)

        case .monthly:
            // Start of the month (1st 00:00)
            let start =
                calendar.date(from: calendar.dateComponents([.year, .month], from: date)) ?? date
            // Start of next month (1st 00:00)
            let end = calendar.date(byAdding: .month, value: 1, to: start) ?? date
            return (start, end)
        }
    }
}
