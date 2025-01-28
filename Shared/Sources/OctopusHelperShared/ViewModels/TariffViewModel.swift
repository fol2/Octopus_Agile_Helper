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

    // Fixed calendar for weekly calculations
    private let fixedWeeklyCalendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.firstWeekday = 2  // 2 represents Monday
        calendar.minimumDaysInFirstWeek = 4  // ISO-8601 standard
        return calendar
    }()

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
    @Published public private(set) var currentCalculation: TariffCalculation? {
        didSet {
            DebugLogger.debug(
                "🔄 TariffViewModel currentCalculation changed: \(currentCalculation != nil ? "has value" : "nil")",
                component: .tariffViewModel)
        }
    }
    @Published public private(set) var isCalculating: Bool = false {
        didSet {
            DebugLogger.debug(
                "🔄 TariffViewModel isCalculating changed: \(oldValue) -> \(isCalculating)",
                component: .tariffViewModel)
        }
    }
    @Published public private(set) var error: Error? {
        didSet {
            if let error = error {
                DebugLogger.debug(
                    "❌ TariffViewModel error set: \(error.localizedDescription)",
                    component: .tariffViewModel)
            }
        }
    }

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

    private var calculationCache: [CacheKey: CacheEntry] = [:] {
        didSet {
            DebugLogger.debug(
                "🔄 TariffViewModel cache updated - entries: \(calculationCache.count)",
                component: .tariffViewModel)
        }
    }

    private let maxCacheSize = 200  // Increased to 200 entries
    private let cacheCleanupThreshold = 180  // Clean when reaching 180 entries

    // MARK: - Manual Plan Rate Tracking
    private struct ComparisonCardSettings: Codable {
        var selectedPlanCode: String
        var isManualPlan: Bool
        var manualRatePencePerKWh: Double
        var manualStandingChargePencePerDay: Double
    }

    private struct ManualRates {
        let kwhRate: Double
        let standingCharge: Double
        let timestamp: Date

        var isStale: Bool {
            // Consider rates stale after 1 second to ensure rate changes are always picked up
            Date().timeIntervalSince(timestamp) > 1
        }
    }

    private var lastUsedManualRates: ManualRates?

    private func haveManualRatesChanged() -> Bool {
        guard let data = UserDefaults.standard.data(forKey: "TariffComparisonCardSettings"),
            let settings = try? JSONDecoder().decode(ComparisonCardSettings.self, from: data)
        else {
            // If we can't read settings, consider it as changed to force recalculation
            DebugLogger.debug(
                "⚠️ Could not read manual rates from settings", component: .tariffViewModel)
            return true
        }

        // Check if rates have changed or are stale
        let ratesChanged =
            lastUsedManualRates?.kwhRate != settings.manualRatePencePerKWh
            || lastUsedManualRates?.standingCharge != settings.manualStandingChargePencePerDay
            || lastUsedManualRates?.isStale == true

        if ratesChanged {
            DebugLogger.debug(
                """
                🔄 Manual rates changed:
                - Old: \(String(describing: lastUsedManualRates))
                - New: kWh=\(settings.manualRatePencePerKWh)p, standing=\(settings.manualStandingChargePencePerDay)p
                """,
                component: .tariffViewModel
            )
        }

        // Update tracking
        lastUsedManualRates = ManualRates(
            kwhRate: settings.manualRatePencePerKWh,
            standingCharge: settings.manualStandingChargePencePerDay,
            timestamp: Date()
        )

        return ratesChanged
    }

    // MARK: - Initialization
    @MainActor
    public init(skipCoreDataStorage: Bool = false) {
        DebugLogger.debug(
            "🔄 TariffViewModel init starting on thread: \(Thread.current.description)",
            component: .tariffViewModel)
        self.calculationRepository = TariffCalculationRepository()
        self.skipCoreDataStorage = skipCoreDataStorage
        DebugLogger.debug(
            """
            ✅ TariffViewModel initialized:
            - Skip Core Data: \(skipCoreDataStorage)
            - Thread: \(Thread.current.description)
            - Memory address: \(Unmanaged.passUnretained(self).toOpaque())
            """, component: .tariffViewModel)
    }

    deinit {
        DebugLogger.debug(
            "♻️ TariffViewModel deinit at \(Unmanaged.passUnretained(self).toOpaque())",
            component: .tariffViewModel)
    }

    // MARK: - Cache Management
    private func cacheKey(tariffCode: String, date: Date, intervalType: IntervalType) -> CacheKey {
        let (start, end) = calculateDateRange(for: date, intervalType: intervalType)
        let key = CacheKey(
            tariffCode: tariffCode,
            intervalType: intervalType,
            startTimestamp: start.timeIntervalSince1970,
            endTimestamp: end.timeIntervalSince1970
        )
        DebugLogger.debug(
            "🔑 Generated cache key: \(key.debugDescription)", component: .tariffViewModel)
        return key
    }

    private func cleanupCache() {
        guard calculationCache.count > cacheCleanupThreshold else {
            DebugLogger.debug(
                "⏭️ Skipping cache cleanup - below threshold (\(calculationCache.count) entries)",
                component: .tariffViewModel)
            return
        }

        DebugLogger.debug(
            "🧹 Starting cache cleanup on thread: \(Thread.current.description)",
            component: .tariffViewModel)

        // Move heavy sorting to background thread
        let currentCache = self.calculationCache
        Task.detached(priority: .utility) { [weak self] in
            DebugLogger.debug(
                "🔄 Cache cleanup task started on background thread", component: .tariffViewModel)
            let sortedEntries = currentCache.sorted { $0.value.timestamp > $1.value.timestamp }
            let newCache: [CacheKey: CacheEntry]
            if sortedEntries.count > self?.maxCacheSize ?? 200 {
                newCache = Dictionary(
                    uniqueKeysWithValues:
                        sortedEntries
                        .prefix(self?.maxCacheSize ?? 200)
                        .map { ($0.key, $0.value) }
                )
                DebugLogger.debug(
                    "✂️ Cache trimmed to max size: \(newCache.count) entries",
                    component: .tariffViewModel)
            } else {
                newCache = currentCache
                DebugLogger.debug(
                    "✅ Cache within size limits: \(newCache.count) entries",
                    component: .tariffViewModel)
            }

            // Update cache on main actor
            await MainActor.run { [weak self] in
                DebugLogger.debug("🔄 Updating cache on main thread", component: .tariffViewModel)
                self?.calculationCache = newCache
            }
        }
    }

    public func invalidateCache() {
        DebugLogger.debug("🗑 Invalidating calculation cache", component: .tariffViewModel)
        calculationCache.removeAll()
    }

    // MARK: - Public Methods

    /// Reset the calculation state and invalidate manual plan cache
    @MainActor
    public func resetCalculationState() async {
        DebugLogger.debug(
            "🔄 TariffViewModel starting resetCalculationState", component: .tariffViewModel)
        isCalculating = false
        error = nil
        currentCalculation = nil
        // Invalidate cache for manual plan calculations only
        let oldCount = calculationCache.count
        calculationCache = calculationCache.filter { $0.key.tariffCode != "manualPlan" }
        DebugLogger.debug(
            "🧹 TariffViewModel cache cleaned: \(oldCount) -> \(calculationCache.count) entries",
            component: .tariffViewModel)
        DebugLogger.debug(
            "✅ TariffViewModel resetCalculationState complete", component: .tariffViewModel)
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
        partialEnd: Date? = nil,
        isChangingPlan: Bool = false
    ) async {
        DebugLogger.debug(
            """
            🔄 TariffViewModel starting cost calculation:
            - Date: \(date)
            - Tariff: \(tariffCode)
            - Interval: \(intervalType.rawValue)
            - Has Account Data: \(accountData != nil)
            - Partial Range: \(partialStart?.formatted() ?? "none") to \(partialEnd?.formatted() ?? "none")
            - Is Changing Plan: \(isChangingPlan)
            - Current Thread: \(Thread.current.description)
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

            DebugLogger.debug(
                "📅 TariffViewModel date range computed: \(finalStart) -> \(finalEnd)",
                component: .tariffViewModel)

            // Add guard for invalid date ranges
            guard finalEnd > finalStart else {
                let error = TariffCalculationError.invalidDateRange(
                    message:
                        "Invalid date range: end date (\(finalEnd)) must be after start date (\(finalStart))"
                )
                DebugLogger.debug(
                    "❌ TariffViewModel invalid date range: \(error.localizedDescription)",
                    component: .tariffViewModel)
                throw error
            }

            // 2) Calculate costs over the range
            let calculation = try await computeCostsOverRange(
                startDate: finalStart,
                endDate: finalEnd,
                tariffCode: tariffCode,
                accountData: accountData,
                storeInCoreData: !skipCoreDataStorage && partialStart == nil && partialEnd == nil,
                isChangingPlan: isChangingPlan
            )

            DebugLogger.debug(
                "✅ TariffViewModel calculation complete - setting result",
                component: .tariffViewModel)
            currentCalculation = calculation
        } catch {
            DebugLogger.debug(
                "❌ TariffViewModel calculation error: \(error.localizedDescription)",
                component: .tariffViewModel)
            self.error = error
        }

        DebugLogger.debug(
            "🏁 TariffViewModel finishing calculation - setting isCalculating=false",
            component: .tariffViewModel)
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
        storeInCoreData: Bool,
        isChangingPlan: Bool
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
            // For manual plan, check if rates have changed
            if tariffCode == "manualPlan" && haveManualRatesChanged() {
                DebugLogger.debug(
                    "🔄 Manual rates changed, skipping cache for \(cKey.debugDescription)",
                    component: .tariffViewModel)
            } else {
                DebugLogger.debug(
                    "✅ USING MEMORY CACHE: \(cKey.debugDescription)",
                    component: .tariffViewModel)
                return cached.calculation
            }
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
    public func calculateDateRange(
        for date: Date,
        intervalType: IntervalType,
        billingDay: Int = 1
    ) -> (Date, Date) {
        let calendar = Calendar.current

        var start: Date
        var end: Date

        switch intervalType {
        case .daily:
            // Start is midnight of `date`, end is +1 day
            start = calendar.startOfDay(for: date)
            // end is +1 day (exclusive)
            end = calendar.date(byAdding: .day, value: 1, to: start) ?? date

        case .weekly:
            // Use fixed calendar for weekly calculations to ensure Monday start
            let comps = fixedWeeklyCalendar.dateComponents(
                [.yearForWeekOfYear, .weekOfYear], from: date)
            start = fixedWeeklyCalendar.date(from: comps) ?? date
            // Instead of +7 days, do +6 for the inclusive 7-day display
            // This fixes "20–27 Jan" => "20–26 Jan"
            end = fixedWeeklyCalendar.date(byAdding: .day, value: 6, to: start) ?? date
            // Set to end of day (23:59:59) to include all consumption records
            if let endOfDay = calendar.date(bySettingHour: 23, minute: 59, second: 59, of: end) {
                end = endOfDay
            }

        case .monthly:
            // (unchanged) interpret date as somewhere inside a "billing month" that starts on `billingDay`
            // and ends the day before the next cycle.

            // 1) Extract year, month, and day from the reference
            let dayOfDate = calendar.component(.day, from: date)
            let yearOfDate = calendar.component(.year, from: date)
            let monthOfDate = calendar.component(.month, from: date)

            // 2) Determine the actual "start month" and "start year"
            //    If dayOfDate >= billingDay, the cycle started this month;
            //    else it started last month.
            var cycleMonth = monthOfDate
            var cycleYear = yearOfDate

            if dayOfDate < billingDay {
                // Move one month back
                cycleMonth -= 1
                if cycleMonth < 1 {
                    cycleMonth = 12
                    cycleYear -= 1
                }
            }

            // 3) Build the start date from the user's chosen billingDay
            //    then clamp if that day > number of days in the target month
            let daysInMonth = daysIn(cycleYear, cycleMonth, calendar: calendar)
            let safeDay = min(billingDay, daysInMonth)  // clamp to last valid day
            var startComps = DateComponents(year: cycleYear, month: cycleMonth, day: safeDay)
            start = calendar.date(from: startComps) ?? date

            // 4) End date is exactly one month after `start` day, minus 1 day
            //    We'll do "start + 1 month" then subtract 1 day
            if let plusOneMonth = calendar.date(byAdding: .month, value: 1, to: start) {
                // Get end of day before next month
                end = calendar.date(byAdding: .day, value: -1, to: plusOneMonth) ?? plusOneMonth
                // Set to end of day (23:59:59) to include all consumption records
                if let endOfDay = calendar.date(bySettingHour: 23, minute: 59, second: 59, of: end)
                {
                    end = endOfDay
                }
            } else {
                // fallback if date logic fails
                end = date
            }

        case .quarterly:
            // For billing_day = 1, align with calendar quarters
            // For other billing days, align with billing cycle quarters
            if billingDay == 1 {
                // Find which calendar quarter contains the date
                let monthOfDate = calendar.component(.month, from: date)
                let yearOfDate = calendar.component(.year, from: date)

                // Determine quarter start month (1, 4, 7, or 10)
                let quarterStartMonth = ((monthOfDate - 1) / 3) * 3 + 1

                // Create start date components for quarter start
                var startComps = DateComponents()
                startComps.year = yearOfDate
                startComps.month = quarterStartMonth
                startComps.day = 1
                startComps.hour = 0
                startComps.minute = 0
                startComps.second = 0

                // Get the start date
                start = calendar.date(from: startComps) ?? date

                // End date is exactly three months after start, minus 1 day
                if let plusThreeMonths = calendar.date(byAdding: .month, value: 3, to: start) {
                    end =
                        calendar.date(byAdding: .day, value: -1, to: plusThreeMonths)
                        ?? plusThreeMonths
                    // Set to end of day (23:59:59)
                    if let endOfDay = calendar.date(
                        bySettingHour: 23, minute: 59, second: 59, of: end)
                    {
                        end = endOfDay
                    }
                } else {
                    end = date
                }
            } else {
                // For other billing days, find the start of the billing quarter
                let dayOfDate = calendar.component(.day, from: date)
                let monthOfDate = calendar.component(.month, from: date)
                let yearOfDate = calendar.component(.year, from: date)

                // Determine which quarter this date belongs to based on billing day
                var cycleMonth = monthOfDate
                var cycleYear = yearOfDate

                // If we're before billing day, we're in the previous month's cycle
                if dayOfDate < billingDay {
                    cycleMonth -= 1
                    if cycleMonth < 1 {
                        cycleMonth = 12
                        cycleYear -= 1
                    }
                }

                // Find the quarter start month based on cycleMonth
                // Q1: Jan-Mar (1), Q2: Apr-Jun (4), Q3: Jul-Sep (7), Q4: Oct-Dec (10)
                let quarterStartMonth = ((cycleMonth - 1) / 3) * 3 + 1

                // Create start date components
                var startComps = DateComponents()
                startComps.year = cycleYear
                startComps.month = quarterStartMonth
                startComps.day = billingDay
                startComps.hour = 0
                startComps.minute = 0
                startComps.second = 0

                // Get the start date
                start = calendar.date(from: startComps) ?? date

                // End date is three months after start, minus 1 day
                if let plusThreeMonths = calendar.date(byAdding: .month, value: 3, to: start) {
                    end =
                        calendar.date(byAdding: .day, value: -1, to: plusThreeMonths)
                        ?? plusThreeMonths
                    // Set to end of day (23:59:59)
                    if let endOfDay = calendar.date(
                        bySettingHour: 23, minute: 59, second: 59, of: end)
                    {
                        end = endOfDay
                    }
                } else {
                    end = date
                }
            }
        }

        return (start, end)
    }

    /// Helper to get number of days in a given (year, month)
    private func daysIn(_ year: Int, _ month: Int, calendar: Calendar) -> Int {
        var comps = DateComponents()
        comps.year = year
        comps.month = month
        // If we ask for day=1, then add 1 month minus 1 day, we can see how many days
        comps.day = 1
        guard let firstOfMonth = calendar.date(from: comps),
            let nextMonth = calendar.date(byAdding: .month, value: 1, to: firstOfMonth),
            let lastDayOfMonth = calendar.date(byAdding: .day, value: -1, to: nextMonth)
        else {
            return 30  // fallback
        }
        return calendar.component(.day, from: lastDayOfMonth)
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

// MARK: - Interval Boundary
extension TariffViewModel {
    enum NavigationDirection {
        case backward
        case forward
    }

    struct IntervalBoundary {
        let start: Date
        let end: Date

        func overlapsWithData(minDate: Date?, maxDate: Date?) -> Bool {
            guard let minDate = minDate else { return true }
            // Allow if there's any overlap with the data range
            // i.e., only block if the entire interval is outside the data range
            return !(start < minDate && end < minDate)
        }

        func isAfterData(maxDate: Date?) -> Bool {
            guard let maxDate = maxDate else { return false }
            return start > maxDate
        }
    }

    func getBoundary(for date: Date, intervalType: IntervalType, billingDay: Int = 1)
        -> IntervalBoundary
    {
        let (start, end) = calculateDateRange(
            for: date, intervalType: intervalType, billingDay: billingDay)
        return IntervalBoundary(start: start, end: end)
    }

    /// Returns whether navigation in a direction is allowed
    func canNavigate(
        from date: Date,
        direction: NavigationDirection,
        intervalType: IntervalType,
        minDate: Date?,
        maxDate: Date?,
        billingDay: Int = 1,
        dailyAvailableDates: Set<Date>? = nil
    ) -> Bool {
        // Don't allow navigation while calculating
        if isCalculating { return false }

        // For daily intervals with available dates, check if next date exists
        if intervalType == .daily, let dailySet = dailyAvailableDates {
            // Use nextDate to peek if a valid date exists
            let hasNext =
                nextDate(
                    from: date,
                    forward: direction == .forward,
                    intervalType: intervalType,
                    minDate: minDate,
                    maxDate: maxDate,
                    dailyAvailableDates: dailySet,
                    billingDay: billingDay
                ) != nil
            return hasNext
        }

        // For other intervals, use boundary checking
        let boundary = getBoundary(for: date, intervalType: intervalType, billingDay: billingDay)

        switch direction {
        case .backward:
            return boundary.overlapsWithData(minDate: minDate, maxDate: nil)
        case .forward:
            return !boundary.isAfterData(maxDate: maxDate)
        }
    }
}

// MARK: - Date Navigation & Bounds
extension TariffViewModel {
    /// Returns `true` if `date` is at or before the min boundary (for the given interval type).
    /// If `minDate` is nil, we treat no lower bound.
    public func isDateAtMinimum(
        _ date: Date,
        intervalType: IntervalType,
        minDate: Date?,
        billingDay: Int = 1
    ) -> Bool {
        let boundary = getBoundary(for: date, intervalType: intervalType, billingDay: billingDay)
        return !boundary.overlapsWithData(minDate: minDate, maxDate: nil)
    }

    /// Returns `true` if `date` is at or after the max boundary (for the given interval type).
    /// If `maxDate` is nil, treat no upper bound.
    public func isDateAtMaximum(
        _ date: Date,
        intervalType: IntervalType,
        maxDate: Date?,
        billingDay: Int = 1
    ) -> Bool {
        let boundary = getBoundary(for: date, intervalType: intervalType, billingDay: billingDay)
        return boundary.isAfterData(maxDate: maxDate)
    }

    /// Returns the next valid date for navigation, or nil if at boundary.
    /// For daily intervals with a dailySet, it will find the next available day with data.
    /// For other intervals, it moves by the standard interval step.
    public func nextDate(
        from currentDate: Date,
        forward: Bool,
        intervalType: IntervalType,
        minDate: Date? = nil,
        maxDate: Date? = nil,
        dailyAvailableDates: Set<Date>? = nil,
        billingDay: Int = 1
    ) -> Date? {
        let calendar = Calendar.current

        // If daily and we have a set of valid daily dates with data:
        if intervalType == .daily, let dailySet = dailyAvailableDates, !dailySet.isEmpty {
            // Start from the startOfDay of currentDate
            let startOfCurrentDay = calendar.startOfDay(for: currentDate)

            // Filter dates based on direction and bounds
            let validDates = dailySet.filter { date in
                let startOfDate = calendar.startOfDay(for: date)

                // Check direction
                if forward {
                    guard startOfDate > startOfCurrentDay else { return false }
                } else {
                    guard startOfDate < startOfCurrentDay else { return false }
                }

                // Check bounds
                if let minDate = minDate {
                    let startOfMin = calendar.startOfDay(for: minDate)
                    if startOfDate < startOfMin { return false }
                }
                if let maxDate = maxDate {
                    let startOfMax = calendar.startOfDay(for: maxDate)
                    if startOfDate > startOfMax { return false }
                }

                return true
            }

            // Get the closest date in the requested direction
            if forward {
                return validDates.min()
            } else {
                return validDates.max()
            }
        }

        // Otherwise, we do a simpler approach for weekly/monthly/quarterly
        switch intervalType {
        case .daily:
            // No daily set => normal ±1 day
            guard
                let newDate = calendar.date(
                    byAdding: .day,
                    value: forward ? 1 : -1, to: currentDate)
            else {
                return nil
            }
            return clampDate(
                newDate, minDate: minDate, maxDate: maxDate, intervalType: intervalType,
                billingDay: billingDay)

        case .weekly:
            guard
                let newDate = fixedWeeklyCalendar.date(
                    // still move ±1 "weekOfYear" so the next navigation step lands
                    // on the next ISO week start, which is consistent with the new range fix
                    byAdding: .weekOfYear,
                    value: forward ? 1 : -1, to: currentDate)
            else {
                return nil
            }
            return clampDate(
                newDate, minDate: minDate, maxDate: maxDate, intervalType: intervalType,
                billingDay: billingDay)

        case .monthly:
            // We'll move from the current cycle start date by ±1 billing month
            // 1) Find current cycle range
            let (startOfCycle, _) = self.calculateDateRange(
                for: currentDate,
                intervalType: .monthly,
                billingDay: billingDay
            )

            // 2) Add ±1 month to that startOfCycle
            guard
                let shifted = calendar.date(
                    byAdding: .month, value: forward ? 1 : -1, to: startOfCycle)
            else { return nil }

            // 3) Now calculate the new cycle for `shifted`
            let (newStart, _) = self.calculateDateRange(
                for: shifted,
                intervalType: .monthly,
                billingDay: billingDay
            )

            return clampDate(
                newStart, minDate: minDate, maxDate: maxDate, intervalType: intervalType,
                billingDay: billingDay)

        case .quarterly:
            let (startOfCycle, _) = self.calculateDateRange(
                for: currentDate,
                intervalType: .quarterly,
                billingDay: billingDay
            )
            guard
                let shifted = calendar.date(
                    byAdding: .month, value: forward ? 3 : -3, to: startOfCycle)
            else { return nil }
            let (newStart, _) = self.calculateDateRange(
                for: shifted,
                intervalType: .quarterly,
                billingDay: billingDay
            )
            return clampDate(
                newStart, minDate: minDate, maxDate: maxDate, intervalType: intervalType,
                billingDay: billingDay)
        }
    }

    /// Helper that bounds a date between optional minDate and maxDate.
    private func clampDate(
        _ date: Date,
        minDate: Date?,
        maxDate: Date?,
        intervalType: IntervalType,
        billingDay: Int = 1
    ) -> Date? {
        let boundary = getBoundary(for: date, intervalType: intervalType, billingDay: billingDay)
        if !boundary.overlapsWithData(minDate: minDate, maxDate: nil)
            || boundary.isAfterData(maxDate: maxDate)
        {
            return nil
        }
        return date
    }
}
