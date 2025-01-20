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

public enum TariffCalculationError: Error {
    case noDataAvailable(period: ClosedRange<Date>)
    case insufficientData(available: ClosedRange<Date>, requested: ClosedRange<Date>)
}

@MainActor
public final class TariffCalculationRepository: ObservableObject {
    // MARK: - Dependencies
    private let context: NSManagedObjectContext
    private let consumptionRepository: ElectricityConsumptionRepository
    private let ratesRepository: RatesRepository

    // MARK: - Initialization
    public init(
        context: NSManagedObjectContext = PersistenceController.shared.container.viewContext,
        consumptionRepository: ElectricityConsumptionRepository = .shared,
        ratesRepository: RatesRepository = .shared
    ) {
        self.context = context
        self.consumptionRepository = consumptionRepository
        self.ratesRepository = ratesRepository
    }

    // MARK: - Public API

    /// Checks if we have new consumption data available since the calculation was last updated
    private func hasNewDataAvailable(
        existingCalculation: NSManagedObject,
        start: Date,
        end: Date
    ) async throws -> Bool {
        // Get the stored total consumption from the calculation
        let storedTotalKWh =
            existingCalculation.value(forKey: "total_consumption_kwh") as? Double ?? 0.0
        let storedUpdateTime =
            existingCalculation.value(forKey: "updated_at") as? Date ?? .distantPast

        // Fetch current consumption records for the period
        let currentRecords = try await fetchConsumption(start: start, end: end)

        // Calculate current total consumption
        let currentTotalKWh = currentRecords.reduce(0.0) { total, record in
            total + (record.value(forKey: "consumption") as? Double ?? 0.0)
        }

        // Compare total consumption with a small tolerance for floating point differences
        let tolerance = 0.0001
        let consumptionDifference = abs(currentTotalKWh - storedTotalKWh)

        print(
            """
            🔍 VALIDATING CACHED DATA:
            - Period: \(start.formatted()) to \(end.formatted())
            - Last updated: \(storedUpdateTime.formatted())
            - Stored consumption: \(String(format: "%.4f", storedTotalKWh))kWh
            - Current consumption: \(String(format: "%.4f", currentTotalKWh))kWh
            - Difference: \(String(format: "%.4f", consumptionDifference))kWh
            - Tolerance: \(tolerance)kWh
            """)

        if consumptionDifference > tolerance {
            print(
                "❌ CACHE INVALID: Consumption difference (\(String(format: "%.4f", consumptionDifference))kWh) exceeds tolerance (\(tolerance)kWh)"
            )
            return true
        }

        print("✅ CACHE VALID: Using stored calculation")
        return false
    }

    /// Fetches a stored TariffCalculationEntity if it matches the exact period & tariffCode & intervalType.
    /// Also checks if we have new data available since the calculation was made.
    /// Returns nil if not found or if we have new data that wasn't included in the original calculation.
    public func fetchStoredCalculation(
        tariffCode: String,
        intervalType: String,
        periodStart: Date,
        periodEnd: Date
    ) async throws -> NSManagedObject? {
        let existing = try await context.perform {
            let fetchRequest = NSFetchRequest<NSManagedObject>(
                entityName: "TariffCalculationEntity")

            // Example matching logic: exact match for these columns
            fetchRequest.predicate = NSPredicate(
                format:
                    "tariff_code == %@ AND interval_type == %@ AND period_start == %@ AND period_end == %@",
                tariffCode, intervalType, periodStart as CVarArg, periodEnd as CVarArg
            )

            fetchRequest.fetchLimit = 1
            let results = try self.context.fetch(fetchRequest)
            return results.first
        }

        // If we found an existing calculation, check if we have new data
        if let existing = existing {
            if try await hasNewDataAvailable(
                existingCalculation: existing,
                start: periodStart,
                end: periodEnd
            ) {
                // We have new data, don't use the existing calculation
                return nil
            }
            return existing
        }

        return nil
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
        intervalType: String
    ) async throws -> NSManagedObject {
        // 1) Gather all relevant consumption in EConsumAgile
        let consumptionRecords = try await fetchConsumption(start: startDate, end: endDate)

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
                    consumptionRecords: filteredRecords
                )
            }
        }

        // For non-daily intervals or if we don't have any records to filter
        return try await computeAndStoreCost(
            tariffCode: tariffCode,
            startDate: startDate,
            endDate: endDate,
            intervalType: intervalType,
            consumptionRecords: consumptionRecords
        )
    }

    /// Helper function to compute and store cost calculation
    private func computeAndStoreCost(
        tariffCode: String,
        startDate: Date,
        endDate: Date,
        intervalType: String,
        consumptionRecords: [NSManagedObject]
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
        let existing = try await fetchStoredCalculation(
            tariffCode: tariffCode,
            intervalType: intervalType,
            periodStart: startDate,
            periodEnd: endDate
        )

        return try await context.perform {
            let entity: NSManagedObject
            if let found = existing {
                entity = found
            } else {
                let desc = NSEntityDescription.entity(
                    forEntityName: "TariffCalculationEntity", in: self.context)!
                entity = NSManagedObject(entity: desc, insertInto: self.context)
            }

            // Write fields via KVC or property access
            entity.setValue(UUID(), forKey: "id")
            entity.setValue(tariffCode, forKey: "tariff_code")
            entity.setValue(startDate, forKey: "period_start")
            entity.setValue(endDate, forKey: "period_end")
            entity.setValue(intervalType, forKey: "interval_type")

            entity.setValue(totalKWh, forKey: "total_consumption_kwh")
            entity.setValue(totalCostExcVAT, forKey: "total_cost_exc_vat")
            entity.setValue(totalCostIncVAT, forKey: "total_cost_inc_vat")
            entity.setValue(standingExcVAT, forKey: "standing_charge_cost_exc_vat")
            entity.setValue(standingIncVAT, forKey: "standing_charge_cost_inc_vat")

            // Calculate average unit rates
            let avgRateExc = totalKWh > 0.0 ? (totalCostExcVAT - standingExcVAT) / totalKWh : 0.0
            let avgRateInc = totalKWh > 0.0 ? (totalCostIncVAT - standingIncVAT) / totalKWh : 0.0
            entity.setValue(avgRateExc, forKey: "average_unit_rate_exc_vat")
            entity.setValue(avgRateInc, forKey: "average_unit_rate_inc_vat")

            let now = Date()
            entity.setValue(now, forKey: "updated_at")

            // For newly inserted rows only
            if existing == nil {
                entity.setValue(now, forKey: "create_at")
            }

            // Save context
            try self.context.save()
            return entity
        }
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
        let existing = try await context.perform {
            let fetchRequest = NSFetchRequest<NSManagedObject>(
                entityName: "TariffCalculationEntity")

            // Match by period and interval type for account calculations
            fetchRequest.predicate = NSPredicate(
                format:
                    "tariff_code == %@ AND interval_type == %@ AND period_start == %@ AND period_end == %@",
                "savedAccount", intervalType, startDate as CVarArg, endDate as CVarArg
            )

            fetchRequest.fetchLimit = 1
            let results = try self.context.fetch(fetchRequest)
            return results.first
        }

        // If we found an existing calculation, check if we have new data
        if let existing = existing {
            if try await hasNewDataAvailable(
                existingCalculation: existing,
                start: startDate,
                end: endDate
            ) {
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
            let combinedCalc = try await context.perform {
                let desc = NSEntityDescription.entity(
                    forEntityName: "TariffCalculationEntity", in: self.context)!
                let entity = NSManagedObject(entity: desc, insertInto: self.context)

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

                try self.context.save()
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
        let records = try await context.perform {
            let request = NSFetchRequest<NSManagedObject>(entityName: "EConsumAgile")
            request.predicate = NSPredicate(
                format: "interval_start >= %@ AND interval_end <= %@",
                start as NSDate, end as NSDate
            )
            request.sortDescriptors = [NSSortDescriptor(key: "interval_start", ascending: true)]
            return try self.context.fetch(request)
        }

        // If no records found, try to fetch from API
        if records.isEmpty {
            print(
                "🔄 No consumption data found locally for period \(start.formatted()) to \(end.formatted())"
            )
            print("🔄 Attempting to fetch from API...")

            // Update consumption data from API
            try await consumptionRepository.updateConsumptionData()

            // Try fetching again after API update
            return try await context.perform {
                let request = NSFetchRequest<NSManagedObject>(entityName: "EConsumAgile")
                request.predicate = NSPredicate(
                    format: "interval_start >= %@ AND interval_end <= %@",
                    start as NSDate, end as NSDate
                )
                request.sortDescriptors = [NSSortDescriptor(key: "interval_start", ascending: true)]
                return try self.context.fetch(request)
            }
        }

        return records
    }

    /// Fetch rate records from RateEntity for a single tariff_code that intersect the requested date window.
    /// If no data is found, attempts to fetch from API.
    private func fetchRates(tariffCode: String, start: Date, end: Date) async throws
        -> [NSManagedObject]
    {
        // First try to fetch from local storage
        let records = try await context.perform {
            let request = NSFetchRequest<NSManagedObject>(entityName: "RateEntity")
            request.predicate = NSPredicate(
                format: "tariff_code == %@ AND valid_to >= %@ AND valid_from <= %@",
                tariffCode, start as NSDate, end as NSDate
            )
            request.sortDescriptors = [NSSortDescriptor(key: "valid_from", ascending: true)]
            return try self.context.fetch(request)
        }

        // If no records found, try to fetch from API
        if records.isEmpty {
            print(
                "🔄 No rate data found locally for period \(start.formatted()) to \(end.formatted())"
            )
            print("🔄 Attempting to fetch from API...")

            // Update rates data from API
            let (_, _) = try await ratesRepository.fetchAndStoreRates(tariffCode: tariffCode)

            // Try fetching again after API update
            return try await context.perform {
                let request = NSFetchRequest<NSManagedObject>(entityName: "RateEntity")
                request.predicate = NSPredicate(
                    format: "tariff_code == %@ AND valid_to >= %@ AND valid_from <= %@",
                    tariffCode, start as NSDate, end as NSDate
                )
                request.sortDescriptors = [NSSortDescriptor(key: "valid_from", ascending: true)]
                return try self.context.fetch(request)
            }
        }

        return records
    }

    /// Fetch standing charge records from StandingChargeEntity for the same tariff_code + date window.
    /// If no data is found, attempts to fetch from API.
    private func fetchStandingCharges(tariffCode: String, start: Date, end: Date) async throws
        -> [NSManagedObject]
    {
        // First try to fetch from local storage
        let records = try await context.perform {
            let request = NSFetchRequest<NSManagedObject>(entityName: "StandingChargeEntity")
            request.predicate = NSPredicate(format: "tariff_code == %@", tariffCode)
            request.sortDescriptors = [NSSortDescriptor(key: "valid_from", ascending: true)]
            return try self.context.fetch(request)
        }

        // If no records found, try to fetch from API
        if records.isEmpty {
            print("🔄 No standing charge data found locally for tariff \(tariffCode)")
            print("🔄 Attempting to fetch from API...")

            // First we need to get the product details to get the standing charge URL
            let details = try await context.perform {
                let request = NSFetchRequest<NSManagedObject>(entityName: "ProductDetailEntity")
                request.predicate = NSPredicate(format: "tariff_code == %@", tariffCode)
                return try self.context.fetch(request)
            }

            if let detail = details.first,
                let standingChargeLink = detail.value(forKey: "link_standing_charge") as? String
            {
                // Update standing charges from API
                try await ratesRepository.fetchAndStoreStandingCharges(
                    tariffCode: tariffCode,
                    url: standingChargeLink
                )

                // Try fetching again after API update
                return try await context.perform {
                    let request = NSFetchRequest<NSManagedObject>(
                        entityName: "StandingChargeEntity")
                    request.predicate = NSPredicate(format: "tariff_code == %@", tariffCode)
                    request.sortDescriptors = [NSSortDescriptor(key: "valid_from", ascending: true)]
                    return try self.context.fetch(request)
                }
            } else {
                print(
                    "⚠️ Could not find product details or standing charge link for tariff \(tariffCode)"
                )
            }
        }

        return records
    }

    /// Core function that merges half-hour consumption with matched RateEntity intervals,
    /// plus daily standing charges. Adjust as needed for your real app logic (some tariffs might be monthly, etc.).
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

        // Convert RateEntity NSManagedObject list to a simpler structure
        // We'll store them as an array of (start, end, costExc, costInc)
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
        .sorted { $0.0 < $1.0 }  // Sort by valid_from ascending
        print("📊 Parsed \(sortedRates.count) valid rates")

        // Convert StandingChargeEntity to a structure
        let sortedStanding = standingCharges.compactMap { mo -> (Date, Date, Double, Double)? in
            guard let vf = mo.value(forKey: "valid_from") as? Date,
                let exc = mo.value(forKey: "value_excluding_vat") as? Double,
                let inc = mo.value(forKey: "value_including_vat") as? Double
            else {
                return nil
            }
            // Use valid_to if present, otherwise use distant future
            let vt = (mo.value(forKey: "valid_to") as? Date) ?? Date.distantFuture
            return (vf, vt, exc, inc)
        }
        .sorted { $0.0 < $1.0 }  // Sort by valid_from ascending
        print("📊 Parsed \(sortedStanding.count) valid standing charges")
        if let first = sortedStanding.first {
            print("  Example standing charge:")
            print("  - Valid from: \(first.0.formatted())")
            print("  - Valid to: \(first.1.formatted())")
            print("  - Exc VAT: \(first.2)p")
            print("  - Inc VAT: \(first.3)p")
        }

        var totalKWh = 0.0
        var totalCostExc = 0.0
        var totalCostInc = 0.0

        // Summation of daily standing charges (optional approach)
        // If your tariff has daily standing charges, for each day in [rangeStart, rangeEnd],
        // we find the correct standing charge record. Then sum it.
        // Here we do a simplified approach: each day from rangeStart..rangeEnd => add the matched standing charge.
        let daysBetween = daysBetweenDates(rangeStart, rangeEnd)
        print("📅 Calculating standing charges for \(daysBetween) days")

        var totalStandingExc = 0.0
        var totalStandingInc = 0.0
        var daysWithCharges = 0

        for dayOffset in 0..<daysBetween {
            if let dayStart = Calendar.current.date(
                byAdding: .day, value: dayOffset, to: startOfDay(rangeStart))
            {
                let dayEnd = endOfDay(dayStart)
                if dayStart > rangeEnd { break }
                if dayEnd < rangeStart { continue }

                // Clip day range within user's overall range
                let effectiveDayStart = max(dayStart, rangeStart)
                let effectiveDayEnd = min(dayEnd, rangeEnd)

                // Find which standing charge record is valid for this day
                if let matchingSC = findStandingCharge(for: effectiveDayStart, in: sortedStanding) {
                    totalStandingExc += matchingSC.2
                    totalStandingInc += matchingSC.3
                    daysWithCharges += 1
                }
            }
        }

        print("💰 Standing charge totals:")
        print("  - Days with charges: \(daysWithCharges) out of \(daysBetween)")
        print("  - Total exc VAT: \(totalStandingExc)p")
        print("  - Total inc VAT: \(totalStandingInc)p")

        // Now handle the half-hour consumption
        var consumptionPeriods = 0
        for record in consumptionRecords {
            // KVC read
            guard let cStart = record.value(forKey: "interval_start") as? Date,
                let cEnd = record.value(forKey: "interval_end") as? Date,
                let usage = record.value(forKey: "consumption") as? Double
            else {
                continue
            }
            // We'll take the "end" as the point in time that determines which rate is applicable
            let pivotDate = cEnd

            // Find a matching rate
            if let (rateFrom, rateTo, exc, inc) = findRate(for: pivotDate, in: sortedRates) {
                // Add cost
                totalKWh += usage
                totalCostExc += usage * exc
                totalCostInc += usage * inc
                consumptionPeriods += 1
            } else {
                // If no matching rate found, skip or log a warning
                print(
                    "⚠️ No matching rate found for period: \(cStart.formatted()) to \(cEnd.formatted())"
                )
            }
        }

        print("⚡️ Consumption totals:")
        print("  - Periods with rates: \(consumptionPeriods) out of \(consumptionRecords.count)")
        print("  - Total kWh: \(totalKWh)")
        print("  - Cost exc VAT: \(totalCostExc)p")
        print("  - Cost inc VAT: \(totalCostInc)p")

        let finalCostExc = totalCostExc + totalStandingExc
        let finalCostInc = totalCostInc + totalStandingInc

        print("🏁 Final totals:")
        print("  - Total cost exc VAT: \(finalCostExc)p")
        print("  - Total cost inc VAT: \(finalCostInc)p")

        return (totalKWh, finalCostExc, finalCostInc, totalStandingExc, totalStandingInc)
    }

    /// Helper to find which rate record covers a given instant (usually the consumption interval_end).
    private func findRate(for date: Date, in sortedRates: [(Date, Date, Double, Double)])
        -> (Date, Date, Double, Double)?
    {
        // Typical logic: pick the rate whose valid_from <= date < valid_to
        for (start, end, exc, inc) in sortedRates {
            if start <= date && date < end {
                return (start, end, exc, inc)
            }
        }
        return nil
    }

    /// Helper to find which standing charge record is valid for the start of a day
    /// (or any instant that you prefer).
    private func findStandingCharge(for date: Date, in sortedSC: [(Date, Date, Double, Double)])
        -> (Date, Date, Double, Double)?
    {
        for (start, end, exc, inc) in sortedSC {
            if start <= date && date < end {
                return (start, end, exc, inc)
            }
        }
        return nil
    }

    /// Count the number of day boundaries between two dates (inclusive).
    /// e.g. from 2025-01-01 to 2025-01-03 => 3 days
    private func daysBetweenDates(_ start: Date, _ end: Date) -> Int {
        let startOfStart = Calendar.current.startOfDay(for: start)
        let startOfEnd = Calendar.current.startOfDay(for: end)
        let diff = Calendar.current.dateComponents([.day], from: startOfStart, to: startOfEnd)
        // Add 1 to include the last partial day
        return max(0, (diff.day ?? 0) + 1)
    }

    /// For day-level iteration, get the day start
    private func startOfDay(_ date: Date) -> Date {
        return Calendar.current.startOfDay(for: date)
    }

    /// For day-level iteration, get day end
    private func endOfDay(_ date: Date) -> Date {
        guard let end = Calendar.current.date(bySettingHour: 23, minute: 59, second: 59, of: date)
        else {
            return date
        }
        return end
    }
}
