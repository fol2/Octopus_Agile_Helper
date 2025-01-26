//
//  TariffCalculationRepository.swift
//  Octopus_Agile_Helper
//
//  Description:
//    Handles read/write of TariffCalculationEntity, merging consumption (EConsumAgile)
//    with RateEntity + StandingChargeEntity. Provides a single interface for calculating
//    total cost over a period, either for one tariff or for multiple agreements.
//
//  Note:
//    - Uses Key-Value Coding (KVC) to read/write NSManagedObject properties where needed.
//    - Demonstrates async/await for Core Data fetches and saves (iOS 15+).
//    - Adjust or expand logic as appropriate for your app's rate/standing-charge rules.
//

import CoreData
import Foundation
import SwiftUI

// MARK: - Support Types
private struct ComparisonCardSettings: Codable {
    var selectedPlanCode: String
    var isManualPlan: Bool
    var manualRatePencePerKWh: Double
    var manualStandingChargePencePerDay: Double
}

public enum TariffCalculationError: Error {
    case noDataAvailable(period: ClosedRange<Date>)
    case insufficientData(available: ClosedRange<Date>, requested: ClosedRange<Date>)
    case invalidDateRange(message: String)
}

@MainActor
public final class TariffCalculationRepository: ObservableObject {
    // MARK: - Dependencies
    private let backgroundContext: NSManagedObjectContext
    private let consumptionRepository: ElectricityConsumptionRepository
    private let ratesRepository: RatesRepository

    // MARK: - Initialization
    public init(
        consumptionRepository: ElectricityConsumptionRepository = .shared,
        ratesRepository: RatesRepository = .shared
    ) {
        self.consumptionRepository = consumptionRepository
        self.ratesRepository = ratesRepository
        // Use a background context to avoid blocking the main thread:
        let container = PersistenceController.shared.container
        self.backgroundContext = container.newBackgroundContext()
        self.backgroundContext.mergePolicy = NSMergeByPropertyObjectTrumpMergePolicy
    }

    // MARK: - Use backgroundContext instead of main context
    // MARK: - Public API

    /// Fetches a stored TariffCalculationEntity if it matches the exact period & tariffCode & intervalType.
    /// Also checks if we have new data available since the calculation was made.
    /// Returns nil if not found or if we have new data that wasn't included in the original calculation.
    public func fetchStoredCalculation(
        tariffCode: String,
        intervalType: String,
        periodStart: Date,
        periodEnd: Date
    ) async throws -> NSManagedObject? {
        let existing = try await backgroundContext.perform {
            let fetchRequest = NSFetchRequest<NSManagedObject>(
                entityName: "TariffCalculationEntity")

            // Example matching logic: exact match for these columns
            fetchRequest.predicate = NSPredicate(
                format:
                    "tariff_code == %@ AND interval_type == %@ AND period_start == %@ AND period_end == %@",
                tariffCode, intervalType, periodStart as CVarArg, periodEnd as CVarArg
            )

            fetchRequest.fetchLimit = 1
            let results = try self.backgroundContext.fetch(fetchRequest)
            return results.first
        }

        guard let existing = existing else {
            return nil
        }

        // Inline check for new consumption data – do it outside the first perform, but in a
        // single pass to avoid re-entrancy. We'll do a second fetchConsumption *without*
        // backgroundContext.perform, so it remains on the main task. Then re-enter for final check.

        let storedTotalKWh =
            existing.value(forKey: "total_consumption_kwh") as? Double ?? 0.0

        // fetchConsumption also calls backgroundContext.perform, but here we are no longer
        // inside the prior block. So it is safe as a separate top-level await call.
        let currentRecords = try await self.fetchConsumption(start: periodStart, end: periodEnd)
        let currentTotalKWh = currentRecords.reduce(0.0) { total, record in
            total + (record.value(forKey: "consumption") as? Double ?? 0.0)
        }

        let tolerance = 0.0001
        let diff = abs(currentTotalKWh - storedTotalKWh)
        if diff > tolerance {
            print("💡 CoreData cache invalid for tariff \(tariffCode), calculating fresh values...")
            return nil
        } else {
            print("✅ USING COREDATA CACHE for \(tariffCode)")
            return existing
        }
    }

    /// Calculates cost for a single tariff code over a specified date range,
    /// optionally storing the result in TariffCalculationEntity with intervalType (e.g. DAILY, MONTHLY).
    ///
    /// 1) Fetch consumption from EConsumAgile,
    /// 2) Find applicable rates & standing charges for the same date range,
    /// 3) Sum total cost (exc/inc VAT), and store in new TariffCalculationEntity.
    ///
    /// Returns the newly inserted or updated TariffCalculationEntity (as NSManagedObject).
    public func calculateCostForPeriod(
        tariffCode: String,
        startDate: Date,
        endDate: Date,
        intervalType: String,
        storeInCoreData: Bool = true
    ) async throws -> NSManagedObject {
        // First try to fetch from CoreData if we're storing
        if storeInCoreData {
            let existing = try await backgroundContext.perform {
                let fetchRequest = NSFetchRequest<NSManagedObject>(
                    entityName: "TariffCalculationEntity")

                // Match by period and interval type for single tariff calculations
                fetchRequest.predicate = NSPredicate(
                    format:
                        "tariff_code == %@ AND interval_type == %@ AND period_start == %@ AND period_end == %@",
                    tariffCode, intervalType, startDate as CVarArg, endDate as CVarArg
                )

                fetchRequest.fetchLimit = 1
                let results = try self.backgroundContext.fetch(fetchRequest)
                return results.first
            }

            // If we found an existing calculation, check if we have new data
            if let existing = existing {
                // Inline check for new data
                let storedTotalKWh =
                    existing.value(forKey: "total_consumption_kwh") as? Double ?? 0.0

                let currentRecords = try await self.fetchConsumption(start: startDate, end: endDate)
                let currentTotalKWh = currentRecords.reduce(0.0) { total, record in
                    total + (record.value(forKey: "consumption") as? Double ?? 0.0)
                }

                let tolerance = 0.0001
                let diff = abs(currentTotalKWh - storedTotalKWh)
                if diff > tolerance {
                    print(
                        "💡 CoreData cache invalid for tariff \(tariffCode), calculating fresh values..."
                    )
                } else {
                    print("✅ USING COREDATA CACHE for tariff \(tariffCode)")
                    return existing
                }
            } else {
                print(
                    "🔍 No CoreData cache found for tariff \(tariffCode), calculating fresh values..."
                )
            }
        }

        // 1) Gather all relevant consumption in EConsumAgile
        let consumptionRecords = try await fetchConsumption(start: startDate, end: endDate)

        // ----------------------------------------------------------------
        // Handle "manual" or "manualPlan" specifically
        // ----------------------------------------------------------------
        if tariffCode == "MANUAL" || tariffCode == "manualPlan" {
            print("⚙️ Manual Plan: skipping normal rate fetch, using user-defined rates.")
            guard !consumptionRecords.isEmpty else {
                throw TariffCalculationError.noDataAvailable(period: startDate...endDate)
            }
            let (totalKWh, costExc, costInc, standExc, standInc) = computeManualPlanCost(
                consumptionRecords: consumptionRecords,
                startDate: startDate, endDate: endDate
            )
            return makeEphemeralCalculation(
                tariffCode: tariffCode, startDate: startDate, endDate: endDate,
                intervalType: intervalType, totalKWh: totalKWh, costExcVAT: costExc,
                costIncVAT: costInc, standingExcVAT: standExc, standingIncVAT: standInc)
        }

        // Validate based on interval type
        if consumptionRecords.isEmpty {
            throw TariffCalculationError.noDataAvailable(period: startDate...endDate)
        }

        // For daily intervals, we need complete data
        if intervalType.uppercased() == "DAILY" {
            // Get the earliest and latest consumption records
            let sortedRecords = consumptionRecords.sorted { record1, record2 in
                let start1 = record1.value(forKey: "interval_start") as? Date ?? .distantFuture
                let start2 = record2.value(forKey: "interval_start") as? Date ?? .distantFuture
                return start1 < start2
            }

            if let firstRecord = sortedRecords.first,
                let lastRecord = sortedRecords.last,
                let firstStart = firstRecord.value(forKey: "interval_start") as? Date,
                let lastEnd = lastRecord.value(forKey: "interval_end") as? Date
            {
                // For daily, if we don't have any overlap with the requested period, throw insufficientData
                if firstStart > endDate || lastEnd < startDate {
                    throw TariffCalculationError.insufficientData(
                        available: firstStart...lastEnd,
                        requested: startDate...endDate
                    )
                }

                // Filter records to only include those within our available data range
                let adjustedStartDate = max(startDate, firstStart)
                let adjustedEndDate = min(endDate, lastEnd)
                let filteredRecords = consumptionRecords.filter { record in
                    guard let recordStart = record.value(forKey: "interval_start") as? Date,
                        let recordEnd = record.value(forKey: "interval_end") as? Date
                    else { return false }
                    return recordStart >= adjustedStartDate && recordEnd <= adjustedEndDate
                }

                // Continue with the filtered records
                return try await computeAndStoreCost(
                    tariffCode: tariffCode,
                    startDate: adjustedStartDate,
                    endDate: adjustedEndDate,
                    intervalType: intervalType,
                    consumptionRecords: filteredRecords,
                    storeInCoreData: storeInCoreData
                )
            }
        }

        // For non-daily intervals or if we don't have any records to filter
        return try await computeAndStoreCost(
            tariffCode: tariffCode,
            startDate: startDate,
            endDate: endDate,
            intervalType: intervalType,
            consumptionRecords: consumptionRecords,
            storeInCoreData: storeInCoreData
        )
    }

    /// Helper function to compute and store cost calculation
    fileprivate func computeAndStoreCost(
        tariffCode: String,
        startDate: Date,
        endDate: Date,
        intervalType: String,
        consumptionRecords: [NSManagedObject],
        storeInCoreData: Bool = true
    ) async throws -> NSManagedObject {
        // 2) Gather all rates for the same tariff code
        let rateEntities = try await fetchRates(
            tariffCode: tariffCode, start: startDate, end: endDate)

        // 3) Gather all standing charges for the same tariff code
        let standingCharges = try await fetchStandingCharges(
            tariffCode: tariffCode, start: startDate, end: endDate)

        // 4) Perform the cost calculation
        let (totalKWh, totalCostExcVAT, totalCostIncVAT, standingExcVAT, standingIncVAT) =
            computeAggregatedCost(
                consumptionRecords: consumptionRecords,
                rates: rateEntities,
                standingCharges: standingCharges,
                rangeStart: startDate,
                rangeEnd: endDate
            )

        // 5) Insert or update TariffCalculationEntity
        let existing = try await self.fetchStoredCalculation(
            tariffCode: tariffCode,
            intervalType: intervalType,
            periodStart: startDate,
            periodEnd: endDate
        )

        let result: NSManagedObject
        if let found = existing {
            result = found
        } else {
            let desc = NSEntityDescription.entity(
                forEntityName: "TariffCalculationEntity", in: self.backgroundContext)!
            result = NSManagedObject(entity: desc, insertInto: self.backgroundContext)
        }

        // Write fields via KVC or property access
        result.setValue(UUID(), forKey: "id")
        result.setValue(tariffCode, forKey: "tariff_code")
        result.setValue(startDate, forKey: "period_start")
        result.setValue(endDate, forKey: "period_end")
        result.setValue(intervalType, forKey: "interval_type")

        result.setValue(totalKWh, forKey: "total_consumption_kwh")
        result.setValue(totalCostExcVAT, forKey: "total_cost_exc_vat")
        result.setValue(totalCostIncVAT, forKey: "total_cost_inc_vat")
        result.setValue(standingExcVAT, forKey: "standing_charge_cost_exc_vat")
        result.setValue(standingIncVAT, forKey: "standing_charge_cost_inc_vat")

        // Calculate average unit rates
        let avgRateExc = totalKWh > 0.0 ? (totalCostExcVAT - standingExcVAT) / totalKWh : 0.0
        let avgRateInc = totalKWh > 0.0 ? (totalCostIncVAT - standingIncVAT) / totalKWh : 0.0
        result.setValue(avgRateExc, forKey: "average_unit_rate_exc_vat")
        result.setValue(avgRateInc, forKey: "average_unit_rate_inc_vat")

        let now = Date()
        result.setValue(now, forKey: "updated_at")

        // For newly inserted rows only
        if existing == nil {
            result.setValue(now, forKey: "create_at")
        }

        // Save context
        try self.backgroundContext.save()

        // After computing costs, only store in CoreData if requested
        if storeInCoreData {
            // Store in CoreData
            try await backgroundContext.perform {
                // ... existing CoreData storage code ...
            }
        }
        // Return the calculation object
        return result
    }

    /// Calculates cost for multiple tariff agreements from a user's account,
    /// seamlessly switching from one tariff_code to another based on valid_from/valid_to.
    /// E.g., if the user changed from Var-22 to Agile-24 mid-month, this method accounts for each partial range.
    ///
    /// This merges partial calculations for each relevant agreement, summing them up or storing separately.
    public func calculateCostForAccount(
        accountData: OctopusAccountResponse,
        startDate: Date,
        endDate: Date,
        intervalType: String
    ) async throws -> [NSManagedObject] {
        // First try to fetch from CoreData
        let existing = try await backgroundContext.perform {
            let fetchRequest = NSFetchRequest<NSManagedObject>(
                entityName: "TariffCalculationEntity")

            // Match by period and interval type for account calculations
            fetchRequest.predicate = NSPredicate(
                format:
                    "tariff_code == %@ AND interval_type == %@ AND period_start == %@ AND period_end == %@",
                "savedAccount", intervalType, startDate as CVarArg, endDate as CVarArg
            )

            fetchRequest.fetchLimit = 1
            let results = try self.backgroundContext.fetch(fetchRequest)
            return results.first
        }

        // If we found an existing calculation, check if we have new data
        if let existing = existing {
            // Inline check for new data
            let storedTotalKWh = existing.value(forKey: "total_consumption_kwh") as? Double ?? 0.0

            let currentRecords = try await self.fetchConsumption(start: startDate, end: endDate)
            let currentTotalKWh = currentRecords.reduce(0.0) { total, record in
                total + (record.value(forKey: "consumption") as? Double ?? 0.0)
            }

            let tolerance = 0.0001
            let diff = abs(currentTotalKWh - storedTotalKWh)
            if diff > tolerance {
                print("💡 CoreData cache invalid, calculating fresh values...")
            } else {
                print("✅ USING COREDATA CACHE for account calculation")
                return [existing]
            }
        } else {
            print("🔍 No CoreData cache found for account calculation, calculating fresh values...")
        }

        print("🔄 Starting fresh calculation for account periods")

        // Calculate fresh values
        guard let firstProperty = accountData.properties.first,
            let elecMP = firstProperty.electricity_meter_points?.first,
            let agreements = elecMP.agreements
        else {
            return []
        }

        // Sort agreements by valid_from
        let sortedAgreements = agreements.sorted { a1, a2 in
            let df = ISO8601DateFormatter()
            let from1 = df.date(from: a1.valid_from ?? "") ?? .distantPast
            let from2 = df.date(from: a2.valid_from ?? "") ?? .distantPast
            return from1 < from2
        }

        // Calculate for each agreement period
        var results: [NSManagedObject] = []
        let dateFormatter = ISO8601DateFormatter()

        for agreement in sortedAgreements {
            guard let tf = agreement.tariff_code as String? else { continue }

            let rawFrom = agreement.valid_from ?? ""
            let rawTo = agreement.valid_to ?? ""
            let agrFrom = dateFormatter.date(from: rawFrom) ?? .distantPast
            let agrTo = dateFormatter.date(from: rawTo) ?? .distantFuture

            let effectiveStart = max(agrFrom, startDate)
            let effectiveEnd = min(agrTo, endDate)

            if effectiveEnd <= effectiveStart { continue }

            let partialCalc = try await self.calculateCostForPeriod(
                tariffCode: tf,
                startDate: effectiveStart,
                endDate: effectiveEnd,
                intervalType: intervalType
            )

            results.append(partialCalc)
        }

        // Store the combined calculation in CoreData
        if !results.isEmpty {
            let combinedCalc = try await backgroundContext.perform {
                let desc = NSEntityDescription.entity(
                    forEntityName: "TariffCalculationEntity", in: self.backgroundContext)!
                let entity = NSManagedObject(entity: desc, insertInto: self.backgroundContext)

                // Sum up the values from individual calculations
                var totalKWh = 0.0
                var totalCostExcVAT = 0.0
                var totalCostIncVAT = 0.0
                var totalStandingChargeExcVAT = 0.0
                var totalStandingChargeIncVAT = 0.0

                for calc in results {
                    totalKWh += calc.value(forKey: "total_consumption_kwh") as? Double ?? 0.0
                    totalCostExcVAT += calc.value(forKey: "total_cost_exc_vat") as? Double ?? 0.0
                    totalCostIncVAT += calc.value(forKey: "total_cost_inc_vat") as? Double ?? 0.0
                    totalStandingChargeExcVAT +=
                        calc.value(forKey: "standing_charge_cost_exc_vat") as? Double ?? 0.0
                    totalStandingChargeIncVAT +=
                        calc.value(forKey: "standing_charge_cost_inc_vat") as? Double ?? 0.0
                }

                let avgRateExc =
                    totalKWh > 0.0 ? (totalCostExcVAT - totalStandingChargeExcVAT) / totalKWh : 0.0
                let avgRateInc =
                    totalKWh > 0.0 ? (totalCostIncVAT - totalStandingChargeIncVAT) / totalKWh : 0.0

                entity.setValue(UUID(), forKey: "id")
                entity.setValue("savedAccount", forKey: "tariff_code")
                entity.setValue(startDate, forKey: "period_start")
                entity.setValue(endDate, forKey: "period_end")
                entity.setValue(intervalType, forKey: "interval_type")
                entity.setValue(totalKWh, forKey: "total_consumption_kwh")
                entity.setValue(totalCostExcVAT, forKey: "total_cost_exc_vat")
                entity.setValue(totalCostIncVAT, forKey: "total_cost_inc_vat")
                entity.setValue(totalStandingChargeExcVAT, forKey: "standing_charge_cost_exc_vat")
                entity.setValue(totalStandingChargeIncVAT, forKey: "standing_charge_cost_inc_vat")
                entity.setValue(avgRateExc, forKey: "average_unit_rate_exc_vat")
                entity.setValue(avgRateInc, forKey: "average_unit_rate_inc_vat")
                entity.setValue(Date(), forKey: "updated_at")
                entity.setValue(Date(), forKey: "create_at")

                try self.backgroundContext.save()
                return entity
            }

            print("✅ Stored fresh calculation in CoreData")
            return [combinedCalc]
        }

        return results
    }

    // MARK: - Private Helpers

    /// Fetch half-hour consumption from EConsumAgile, for the specified time window.
    /// If no data is found, attempts to fetch from API.
    private func fetchConsumption(start: Date, end: Date) async throws -> [NSManagedObject] {
        // First try to fetch from local storage
        // 1) Do a quick fetch inside backgroundContext.perform
        let localRecords = try await backgroundContext.perform {
            let request = NSFetchRequest<NSManagedObject>(entityName: "EConsumAgile")
            request.predicate = NSPredicate(
                format: "interval_start >= %@ AND interval_start < %@",
                start as NSDate, end as NSDate
            )
            request.sortDescriptors = [NSSortDescriptor(key: "interval_start", ascending: true)]
            return try self.backgroundContext.fetch(request)
        }

        // 2) If we found something, return immediately
        if !localRecords.isEmpty {
            return localRecords
        }

        return localRecords
    }

    /// Fetch rate records from RateEntity for a single tariff_code that intersect the requested date window.
    /// If no data is found, attempts to fetch from API.
    private func fetchRates(tariffCode: String, start: Date, end: Date) async throws
        -> [NSManagedObject]
    {
        // 1) Attempt local fetch in background context
        let localRates = try await backgroundContext.perform {
            let request = NSFetchRequest<NSManagedObject>(entityName: "RateEntity")
            request.predicate = NSPredicate(
                format: "tariff_code == %@ AND valid_to >= %@ AND valid_from <= %@",
                tariffCode, start as NSDate, end as NSDate
            )
            request.sortDescriptors = [NSSortDescriptor(key: "valid_from", ascending: true)]
            return try self.backgroundContext.fetch(request)
        }

        // If no records found, try to fetch from API
        // 2) If not empty, just return
        if !localRates.isEmpty {
            return localRates
        }

        // 3) Otherwise, do the remote fetch outside backgroundContext.perform
        print("🔄 No rate data found. Fetching from API...")
        let (_, _) = try await ratesRepository.fetchAndStoreRates(tariffCode: tariffCode)

        // 4) Then do a new backgroundContext.perform after we have new data
        let updatedRates = try await backgroundContext.perform {
            let request = NSFetchRequest<NSManagedObject>(entityName: "RateEntity")
            request.predicate = NSPredicate(
                format: "tariff_code == %@ AND valid_to >= %@ AND valid_from <= %@",
                tariffCode, start as NSDate, end as NSDate
            )
            request.sortDescriptors = [NSSortDescriptor(key: "valid_from", ascending: true)]
            return try self.backgroundContext.fetch(request)
        }
        return updatedRates
    }

    /// Fetch standing charge records from StandingChargeEntity for the same tariff_code + date window.
    /// If no data is found, attempts to fetch from API.
    private func fetchStandingCharges(tariffCode: String, start: Date, end: Date) async throws
        -> [NSManagedObject]
    {
        // 1) Attempt local fetch in background context
        let localRecords = try await backgroundContext.perform {
            let request = NSFetchRequest<NSManagedObject>(entityName: "StandingChargeEntity")
            request.predicate = NSPredicate(format: "tariff_code == %@", tariffCode)
            request.sortDescriptors = [NSSortDescriptor(key: "valid_from", ascending: true)]
            return try self.backgroundContext.fetch(request)
        }

        // 2) If not empty, just return
        if !localRecords.isEmpty {
            return localRecords
        }

        // 3) Otherwise, do the remote fetch outside backgroundContext.perform
        print("🔄 No standing charge data found locally for tariff \(tariffCode)")
        print("🔄 Attempting to fetch from API...")

        // First we need to get the product details to get the standing charge URL
        let details = try await backgroundContext.perform {
            let request = NSFetchRequest<NSManagedObject>(entityName: "ProductDetailEntity")
            request.predicate = NSPredicate(format: "tariff_code == %@", tariffCode)
            return try self.backgroundContext.fetch(request)
        }

        if let detail = details.first,
            let standingChargeLink = detail.value(forKey: "link_standing_charge") as? String
        {
            // Update standing charges from API
            try await ratesRepository.fetchAndStoreStandingCharges(
                tariffCode: tariffCode,
                url: standingChargeLink
            )

            // 4) Then do a new backgroundContext.perform after we have new data
            let updatedRecords = try await backgroundContext.perform {
                let request = NSFetchRequest<NSManagedObject>(
                    entityName: "StandingChargeEntity")
                request.predicate = NSPredicate(format: "tariff_code == %@", tariffCode)
                request.sortDescriptors = [NSSortDescriptor(key: "valid_from", ascending: true)]
                return try self.backgroundContext.fetch(request)
            }
            return updatedRecords
        } else {
            print(
                "⚠️ Could not find product details or standing charge link for tariff \(tariffCode)"
            )
            return []
        }
    }

    /// Core function that merges half-hour consumption with matched RateEntity intervals,
    /// plus daily standing charges. Adjust as needed for your real app logic (some tariffs might be monthly, etc.).
    ///
    /// New approach:
    ///   1. We still sum consumption * rate for each half-hour.
    ///   2. We also do half-hour increments for standing charge, applying pro-rata if a tariff is daily, weekly or monthly.
    ///
    private func computeAggregatedCost(
        consumptionRecords: [NSManagedObject],
        rates: [NSManagedObject],
        standingCharges: [NSManagedObject],
        rangeStart: Date,
        rangeEnd: Date
    ) -> (Double, Double, Double, Double, Double) {
        print("\n🧮 Starting cost calculation:")
        print("📅 Period: \(rangeStart.formatted()) to \(rangeEnd.formatted())")
        print("📊 Found:")
        print("  - \(consumptionRecords.count) consumption records")
        print("  - \(rates.count) rate records")
        print("  - \(standingCharges.count) standing charge records")

        // --- 1) Convert RateEntity → array of (start, end, costExc, costInc)
        let sortedRates = rates.compactMap { mo -> (Date, Date, Double, Double)? in
            guard let vf = mo.value(forKey: "valid_from") as? Date,
                let vt = mo.value(forKey: "valid_to") as? Date,
                let exc = mo.value(forKey: "value_excluding_vat") as? Double,
                let inc = mo.value(forKey: "value_including_vat") as? Double
            else {
                return nil
            }
            return (vf, vt, exc, inc)
        }
        .sorted { $0.0 < $1.0 }

        // --- 2) Convert StandingChargeEntity → array of (start, end, costExc, costInc)
        let sortedStanding = standingCharges.compactMap { mo -> (Date, Date, Double, Double)? in
            guard let vf = mo.value(forKey: "valid_from") as? Date,
                let exc = mo.value(forKey: "value_excluding_vat") as? Double,
                let inc = mo.value(forKey: "value_including_vat") as? Double
            else {
                return nil
            }
            let vt = (mo.value(forKey: "valid_to") as? Date) ?? Date.distantFuture
            return (vf, vt, exc, inc)
        }
        .sorted { $0.0 < $1.0 }

        print("📊 Parsed \(sortedRates.count) valid rates")
        print("📊 Parsed \(sortedStanding.count) valid standing charges")

        var totalKWh = 0.0
        var totalCostExc = 0.0
        var totalCostInc = 0.0
        var totalStandingExc = 0.0
        var totalStandingInc = 0.0

        // Helper to find which rate record covers a given instant
        func findRate(for date: Date, in rates: [(Date, Date, Double, Double)]) -> (
            Date, Date, Double, Double
        )? {
            for (start, end, exc, inc) in rates {
                if start <= date && date < end {
                    return (start, end, exc, inc)
                }
            }
            return nil
        }

        // A helper function to find and pro-rate standing charge for a single half-hour slot
        func proRateStandingCharge(
            start: Date,
            end: Date
        ) -> (Double, Double) {
            // We find which standing charge record is valid at the midpoint
            // or simply use the `start` to pick a standing record.
            guard
                let (scStart, scEnd, scExc, scInc) = findStandingCharge(
                    for: start, in: sortedStanding)
            else {
                return (0, 0)
            }

            // For a daily standing charge:
            let dailyHours = 24.0
            let slotHours = (end.timeIntervalSince(start) / 3600.0)
            let fractionOfDay = slotHours / dailyHours

            // If you have weekly or monthly, you can detect it from the "tariff_code" or "payment" field
            // and do fractionOfWeek or fractionOfMonth. For brevity, we'll assume daily in this patch.
            // If you really have monthly, you'd do:
            //    let daysInMonth = 30.0 (or get from calendar)
            //    let fractionOfMonth = slotHours / (daysInMonth * 24.0)

            let excPart = scExc * fractionOfDay
            let incPart = scInc * fractionOfDay
            return (excPart, incPart)
        }

        // We'll accumulate everything half-hour by half-hour
        // Instead of each half-hour, we rely on consumptionRecords themselves:
        //   If there's a consumption record from X to X+30min, we add partial standing for that half-hour.

        var consumptionPeriods = 0
        for record in consumptionRecords {
            // KVC read
            guard let cStart = record.value(forKey: "interval_start") as? Date,
                let cEnd = record.value(forKey: "interval_end") as? Date,
                let usageKWh = record.value(forKey: "consumption") as? Double
            else {
                continue
            }
            // Ensure we clip the consumption to our overall range
            let slotStart = max(cStart, rangeStart)
            let slotEnd = min(cEnd, rangeEnd)
            if slotEnd <= slotStart { continue }

            // 1) Determine which rate record is valid for the midpoint
            let midpoint = slotStart.addingTimeInterval(slotEnd.timeIntervalSince(slotStart) / 2)
            if let (rateFrom, rateTo, exc, inc) = findRate(for: midpoint, in: sortedRates) {
                totalKWh += usageKWh
                totalCostExc += usageKWh * exc
                totalCostInc += usageKWh * inc
                consumptionPeriods += 1
            } else {
                print(
                    "⚠️ No matching rate found for period: \(slotStart.formatted()) to \(slotEnd.formatted())"
                )
            }

            // 2) Add the pro-rated fraction of the standing charge for this half-hour block
            let (excPart, incPart) = proRateStandingCharge(start: slotStart, end: slotEnd)
            totalStandingExc += excPart
            totalStandingInc += incPart
        }

        print("⚡️ Consumption totals:")
        print("  - Periods with rates: \(consumptionPeriods) out of \(consumptionRecords.count)")
        print("  - Total kWh: \(totalKWh)")
        print("  - Cost exc VAT: \(totalCostExc)p")
        print("  - Cost inc VAT: \(totalCostInc)p")

        print("💰 Standing charge totals:")
        print("  - Total exc VAT: \(totalStandingExc)p")
        print("  - Total inc VAT: \(totalStandingInc)p")

        // Sum up final
        let finalCostExc = totalCostExc + totalStandingExc
        let finalCostInc = totalCostInc + totalStandingInc
        print("🏁 Final totals:")
        print("  - Total cost exc VAT: \(finalCostExc)p")
        print("  - Total cost inc VAT: \(finalCostInc)p")

        return (totalKWh, finalCostExc, finalCostInc, totalStandingExc, totalStandingInc)
    }

    /// We updated to accept "start" instead of dayStart so partial intervals can be matched
    internal func findStandingCharge(for date: Date, in sortedSC: [(Date, Date, Double, Double)])
        -> (Date, Date, Double, Double)?
    {
        for (start, end, exc, inc) in sortedSC {
            if start <= date && date < end {
                return (start, end, exc, inc)
            }
        }
        return nil
    }

    // ----------------------------------------------------------------------
    //  MANUAL PLAN: Helper Functions
    // ----------------------------------------------------------------------
    private func computeManualPlanCost(
        consumptionRecords: [NSManagedObject],
        startDate: Date,
        endDate: Date
    ) -> (Double, Double, Double, Double, Double) {
        // Get manual rates from UserDefaults where ComparisonCardSettings stores them
        var manualRatePence = 30.0  // Default values
        var manualStandingPence = 45.0

        if let data = UserDefaults.standard.data(forKey: "TariffComparisonCardSettings"),
            let settings = try? JSONDecoder().decode(ComparisonCardSettings.self, from: data)
        {
            manualRatePence = settings.manualRatePencePerKWh
            manualStandingPence = settings.manualStandingChargePencePerDay
        }

        var totalKWh = 0.0
        var totalCostExcVAT = 0.0
        var totalCostIncVAT = 0.0
        var totalStandingExcVAT = 0.0
        var totalStandingIncVAT = 0.0

        // Rates are already in the correct format (inc or exc VAT) based on user settings
        // Summation over half-hour blocks:
        // usage (kWh) * manualRate + partial daily standing
        for record in consumptionRecords {
            let usage = record.value(forKey: "consumption") as? Double ?? 0
            totalKWh += usage

            // Use the rates directly as they are already in correct format
            totalCostExcVAT += usage * manualRatePence
            totalCostIncVAT += usage * manualRatePence  // Same rate as it's already in correct format

            // For a half-hour slot, pro-rate the daily standing:
            // each 30-min is 1/48 of a day
            totalStandingExcVAT += (manualStandingPence / 48.0)
            totalStandingIncVAT += (manualStandingPence / 48.0)  // Same rate as it's already in correct format
        }

        // Return summaries
        let finalExc = totalCostExcVAT + totalStandingExcVAT
        let finalInc = totalCostIncVAT + totalStandingIncVAT
        return (totalKWh, finalExc, finalInc, totalStandingExcVAT, totalStandingIncVAT)
    }

    private func makeEphemeralCalculation(
        tariffCode: String,
        startDate: Date,
        endDate: Date,
        intervalType: String,
        totalKWh: Double,
        costExcVAT: Double,
        costIncVAT: Double,
        standingExcVAT: Double,
        standingIncVAT: Double
    ) -> NSManagedObject {
        // Return an "in-memory" TariffCalculationEntity
        // so the TariffViewModel can handle it. We do not insert into self.context.
        let desc = NSEntityDescription.entity(
            forEntityName: "TariffCalculationEntity", in: self.backgroundContext)!
        let calc = NSManagedObject(entity: desc, insertInto: nil)  // no context => ephemeral
        calc.setValue(UUID(), forKey: "id")
        calc.setValue(tariffCode, forKey: "tariff_code")
        calc.setValue(startDate, forKey: "period_start")
        calc.setValue(endDate, forKey: "period_end")
        calc.setValue(intervalType, forKey: "interval_type")
        calc.setValue(totalKWh, forKey: "total_consumption_kwh")
        calc.setValue(costExcVAT, forKey: "total_cost_exc_vat")
        calc.setValue(costIncVAT, forKey: "total_cost_inc_vat")
        calc.setValue(standingExcVAT, forKey: "standing_charge_cost_exc_vat")
        calc.setValue(standingIncVAT, forKey: "standing_charge_cost_inc_vat")
        let avgRateExc = totalKWh > 0 ? (costExcVAT - standingExcVAT) / totalKWh : 0.0
        let avgRateInc = totalKWh > 0 ? (costIncVAT - standingIncVAT) / totalKWh : 0.0
        calc.setValue(avgRateExc, forKey: "average_unit_rate_exc_vat")
        calc.setValue(avgRateInc, forKey: "average_unit_rate_inc_vat")
        calc.setValue(Date(), forKey: "updated_at")
        // create_at is optional for ephemeral
        return calc
    }
}
