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
        case quarterly = "Quarterly"
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
    private let skipCoreDataStorage: Bool

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
    public init(skipCoreDataStorage: Bool = false) {
        self.calculationRepository = TariffCalculationRepository()
        self.skipCoreDataStorage = skipCoreDataStorage
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

    /// Reset the calculation state
    @MainActor
    public func resetCalculationState() async {
        isCalculating = false
    }

    /// Calculate tariff costs for a specific date and interval type
    /// - Parameters:
    ///   - date: The reference date for calculation
    ///   - tariffCode: The tariff code to calculate for, use "savedAccount" to calculate for saved account
    ///   - intervalType: The type of interval (daily, weekly, monthly)
    ///   - accountData: The account data, required when tariffCode is "savedAccount"
    ///   - partialStart: Optional start date for partial coverage calculation
    ///   - partialEnd: Optional end date for partial coverage calculation
    public func calculateCosts(
        for date: Date,
        tariffCode: String,
        intervalType: IntervalType,
        accountData: OctopusAccountResponse? = nil,
        partialStart: Date? = nil,
        partialEnd: Date? = nil
    ) async {
        DebugLogger.debug(
            """
            🔄 Starting cost calculation:
            - Date: \(date)
            - Tariff: \(tariffCode)
            - Interval: \(intervalType.rawValue)
            - Partial Range: \(partialStart?.formatted() ?? "none") to \(partialEnd?.formatted() ?? "none")
            """, component: .tariffViewModel)

        // Reset state at the start
        error = nil
        isCalculating = true
        currentCalculation = nil  // Clear current calculation while loading

        do {
            // 1) Compute the default full range for the given date & interval
            let (stdStart, stdEnd) = calculateDateRange(for: date, intervalType: intervalType)
            let (finalStart, finalEnd) = (
                partialStart ?? stdStart,
                partialEnd ?? stdEnd
            )

            // 2) Calculate costs over the range
            let calculation = try await computeCostsOverRange(
                startDate: finalStart,
                endDate: finalEnd,
                tariffCode: tariffCode,
                accountData: accountData,
                storeInCoreData: !skipCoreDataStorage && partialStart == nil && partialEnd == nil
            )

            currentCalculation = calculation
        } catch {
            self.error = error
            DebugLogger.debug(
                "❌ Error calculating costs: \(error.localizedDescription)",
                component: .tariffViewModel)
        }

        isCalculating = false
        cleanupCache()  // Cleanup after calculation
    }

    /// Internal method that handles both single-tariff and "savedAccount" calculations
    /// over any arbitrary date range. Optionally can skip storing in Core Data (for partial coverage).
    private func computeCostsOverRange(
        startDate: Date,
        endDate: Date,
        tariffCode: String,
        accountData: OctopusAccountResponse?,
        storeInCoreData: Bool
    ) async throws -> TariffCalculation {
        // 0) Quick sanity check
        guard endDate > startDate else {
            throw TariffCalculationError.noDataAvailable(period: startDate...endDate)
        }

        // 1) Build a cache key that includes the exact start/end
        let cKey = CacheKey(
            tariffCode: tariffCode,
            intervalType: .daily,  // "daily" nominal for partial ranges
            startTimestamp: startDate.timeIntervalSince1970,
            endTimestamp: endDate.timeIntervalSince1970
        )

        DebugLogger.debug(
            "🔍 Checking memory cache for \(cKey.debugDescription)",
            component: .tariffViewModel)

        // 2) Check memory cache first
        if let cached = calculationCache[cKey] {
            DebugLogger.debug(
                "✅ USING MEMORY CACHE: \(cKey.debugDescription)",
                component: .tariffViewModel)
            return cached.calculation
        }

        // 3) Calculate based on tariff type
        let result: NSManagedObject
        if tariffCode == "savedAccount" {
            guard let accData = accountData else {
                throw TariffCalculationError.noDataAvailable(period: startDate...endDate)
            }
            let results = try await calculationRepository.calculateCostForAccount(
                accountData: accData,
                startDate: startDate,
                endDate: endDate,
                intervalType: "CUSTOM"
            )
            guard let firstResult = results.first else {
                throw TariffCalculationError.noDataAvailable(period: startDate...endDate)
            }
            result = firstResult
        } else {
            result = try await calculationRepository.calculateCostForPeriod(
                tariffCode: tariffCode,
                startDate: startDate,
                endDate: endDate,
                intervalType: "CUSTOM",
                storeInCoreData: storeInCoreData
            )
        }

        // 4) Convert to TariffCalculation struct
        let calculation = convertToCalculation(
            managedObject: result, start: startDate, end: endDate)

        // 5) Store in memory cache
        calculationCache[cKey] = CacheEntry(calculation: calculation, timestamp: Date())

        return calculation
    }

    // MARK: - Private Methods

    /// Calculates the start and end dates for a given reference date and interval type
    public func calculateDateRange(for date: Date, intervalType: IntervalType) -> (Date, Date) {
        let calendar = Calendar.current
        let components = calendar.dateComponents([.year, .month, .day], from: date)

        guard let start = calendar.date(from: components) else {
            return (date, date)
        }

        var end: Date
        switch intervalType {
        case .daily:
            end = calendar.date(byAdding: .day, value: 1, to: start) ?? date
        case .weekly:
            end = calendar.date(byAdding: .day, value: 7, to: start) ?? date
        case .monthly:
            end = calendar.date(byAdding: .month, value: 1, to: start) ?? date
        case .quarterly:
            end = calendar.date(byAdding: .month, value: 3, to: start) ?? date
        }

        return (start, end)
    }

    /// Converts NSManagedObject to TariffCalculation struct
    private func convertToCalculation(managedObject: NSManagedObject, start: Date, end: Date)
        -> TariffCalculation
    {
        let totalKWh = managedObject.value(forKey: "total_consumption_kwh") as? Double ?? 0.0
        let costExcVAT = managedObject.value(forKey: "total_cost_exc_vat") as? Double ?? 0.0
        let costIncVAT = managedObject.value(forKey: "total_cost_inc_vat") as? Double ?? 0.0
        let avgRateExcVAT =
            managedObject.value(forKey: "average_unit_rate_exc_vat") as? Double ?? 0.0
        let avgRateIncVAT =
            managedObject.value(forKey: "average_unit_rate_inc_vat") as? Double ?? 0.0
        let standingChargeExcVAT =
            managedObject.value(forKey: "standing_charge_cost_exc_vat") as? Double ?? 0.0
        let standingChargeIncVAT =
            managedObject.value(forKey: "standing_charge_cost_inc_vat") as? Double ?? 0.0

        return TariffCalculation(
            periodStart: start,
            periodEnd: end,
            totalKWh: totalKWh,
            costExcVAT: costExcVAT,
            costIncVAT: costIncVAT,
            averageUnitRateExcVAT: avgRateExcVAT,
            averageUnitRateIncVAT: avgRateIncVAT,
            standingChargeExcVAT: standingChargeExcVAT,
            standingChargeIncVAT: standingChargeIncVAT
        )
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
}

// MARK: - Date Navigation & Bounds
extension TariffViewModel {
    /// Returns `true` if `date` is at or before the min boundary (for the given interval type).
    /// If `minDate` is nil, we treat no lower bound.
    public func isDateAtMinimum(
        _ date: Date,
        intervalType: IntervalType,
        minDate: Date?
    ) -> Bool {
        guard let minDate = minDate else { return false }
        let calendar = Calendar.current

        switch intervalType {
        case .daily:
            return calendar.isDate(date, inSameDayAs: minDate)
        case .weekly:
            let currentWeekStart = calendar.date(
                from: calendar.dateComponents([.yearForWeekOfYear, .weekOfYear], from: date))!
            let minWeekStart = calendar.date(
                from: calendar.dateComponents([.yearForWeekOfYear, .weekOfYear], from: minDate))!
            return currentWeekStart <= minWeekStart
        case .monthly:
            let currentMonthStart = calendar.date(
                from: calendar.dateComponents([.year, .month], from: date))!
            let minMonthStart = calendar.date(
                from: calendar.dateComponents([.year, .month], from: minDate))!
            return currentMonthStart <= minMonthStart
        case .quarterly:
            // For now, treat "quarterly" like monthly but in 3-month increments
            let currentRange = self.calculateDateRange(for: date, intervalType: .quarterly)
            let minRange = self.calculateDateRange(for: minDate, intervalType: .quarterly)
            return currentRange.0 <= minRange.0
        }
    }

    /// Returns `true` if `date` is at or after the max boundary (for the given interval type).
    /// If `maxDate` is nil, treat no upper bound.
    public func isDateAtMaximum(
        _ date: Date,
        intervalType: IntervalType,
        maxDate: Date?
    ) -> Bool {
        guard let maxDate = maxDate else { return false }
        let calendar = Calendar.current

        switch intervalType {
        case .daily:
            return calendar.isDate(date, inSameDayAs: maxDate)
        case .weekly:
            let currentWeekStart = calendar.date(
                from: calendar.dateComponents([.yearForWeekOfYear, .weekOfYear], from: date))!
            let maxWeekStart = calendar.date(
                from: calendar.dateComponents([.yearForWeekOfYear, .weekOfYear], from: maxDate))!
            return currentWeekStart >= maxWeekStart
        case .monthly:
            let currentMonthStart = calendar.date(
                from: calendar.dateComponents([.year, .month], from: date))!
            let maxMonthStart = calendar.date(
                from: calendar.dateComponents([.year, .month], from: maxDate))!
            return currentMonthStart >= maxMonthStart
        case .quarterly:
            let currentRange = self.calculateDateRange(for: date, intervalType: .quarterly)
            let maxRange = self.calculateDateRange(for: maxDate, intervalType: .quarterly)
            return currentRange.0 >= maxRange.0
        }
    }

    /// Advances `currentDate` forward/backward by one unit of the given interval type,
    /// clamping to [minDate, maxDate].
    ///
    /// If `intervalType == .daily` and `dailyAvailableDates` is provided, it tries to find
    /// the next valid day in `dailyAvailableDates`.
    /// Otherwise it simply increments by 1 day/week/month/quarter.
    ///
    /// Returns `nil` if we cannot move further in that direction.
    public func nextDate(
        from currentDate: Date,
        forward: Bool,
        intervalType: IntervalType,
        minDate: Date?,
        maxDate: Date?,
        dailyAvailableDates: Set<Date>? = nil
    ) -> Date? {
        let calendar = Calendar.current

        // If daily and we have a set of valid daily dates with data:
        if intervalType == .daily, let dailySet = dailyAvailableDates, !dailySet.isEmpty {
            // Start from the *startOfDay* of currentDate
            var candidate = calendar.startOfDay(for: currentDate)
            while true {
                guard
                    let nextDay = calendar.date(
                        byAdding: .day, value: forward ? 1 : -1, to: candidate)
                else {
                    return nil
                }
                candidate = calendar.startOfDay(for: nextDay)

                // Bounds check
                if let minDate = minDate, candidate < calendar.startOfDay(for: minDate) {
                    return nil
                }
                if let maxDate = maxDate, candidate > calendar.startOfDay(for: maxDate) {
                    return nil
                }

                // If the candidate is in the set, we found our next valid day
                if dailySet.contains(candidate) {
                    return candidate
                }
                // If we keep going and never find a day, eventually we return nil
                // once we pass the bounds.
            }
        }

        // Otherwise, we do a simpler approach for weekly/monthly/quarterly
        switch intervalType {
        case .daily:
            // No daily set => normal ±1 day
            guard
                let newDate = calendar.date(
                    byAdding: .day, value: forward ? 1 : -1, to: currentDate)
            else {
                return nil
            }
            return clampDate(newDate, minDate: minDate, maxDate: maxDate)

        case .weekly:
            guard
                let newDate = calendar.date(
                    byAdding: .weekOfYear, value: forward ? 1 : -1, to: currentDate)
            else {
                return nil
            }
            return clampDate(newDate, minDate: minDate, maxDate: maxDate)

        case .monthly:
            guard
                let newDate = calendar.date(
                    byAdding: .month, value: forward ? 1 : -1, to: currentDate)
            else {
                return nil
            }
            return clampDate(newDate, minDate: minDate, maxDate: maxDate)

        case .quarterly:
            // move by 3 months
            let month = calendar.component(.month, from: currentDate)
            let quarterStartMonth = ((month - 1) / 3) * 3 + 1
            var components = calendar.dateComponents([.year], from: currentDate)
            components.month = quarterStartMonth + (forward ? 3 : -3)
            components.day = 1

            guard let newDate = calendar.date(from: components) else {
                return nil
            }
            return clampDate(newDate, minDate: minDate, maxDate: maxDate)
        }
    }

    /// Helper that bounds a date between optional minDate and maxDate.
    private func clampDate(
        _ date: Date,
        minDate: Date?,
        maxDate: Date?
    ) -> Date? {
        if let minDate = minDate, date < minDate {
            return nil
        }
        if let maxDate = maxDate, date > maxDate {
            return nil
        }
        return date
    }
}
