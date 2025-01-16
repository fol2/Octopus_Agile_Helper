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
//    - Adjust or expand logic as appropriate for your app’s rate/standing-charge rules.
//

import CoreData
import Foundation
import SwiftUI

@MainActor
public final class TariffCalculationRepository: ObservableObject {
    // MARK: - Dependencies
    private let context: NSManagedObjectContext
    
    // MARK: - Initialization
    public init(context: NSManagedObjectContext = PersistenceController.shared.container.viewContext) {
        self.context = context
    }
    
    // MARK: - Public API
    
    /// Fetches a stored TariffCalculationEntity if it matches the exact period & tariffCode & intervalType.
    /// Returns nil if not found.
    public func fetchStoredCalculation(
        tariffCode: String,
        intervalType: String,
        periodStart: Date,
        periodEnd: Date
    ) async throws -> NSManagedObject? {
        try await context.perform {
            let fetchRequest = NSFetchRequest<NSManagedObject>(entityName: "TariffCalculationEntity")
            
            // Example matching logic: exact match for these columns
            fetchRequest.predicate = NSPredicate(
                format: "tariff_code == %@ AND interval_type == %@ AND period_start == %@ AND period_end == %@",
                tariffCode, intervalType, periodStart as CVarArg, periodEnd as CVarArg
            )
            
            fetchRequest.fetchLimit = 1
            let results = try self.context.fetch(fetchRequest)
            return results.first
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
        intervalType: String
    ) async throws -> NSManagedObject {
        
        // 1) Gather all relevant consumption in EConsumAgile
        let consumptionRecords = try await fetchConsumption(start: startDate, end: endDate)
        
        // 2) Gather all rates for the same tariff code
        //    We assume RateEntity has tariff_code + valid_from + valid_to + value_exc_vat + value_including_vat
        let rateEntities = try await fetchRates(tariffCode: tariffCode, start: startDate, end: endDate)
        
        // 3) Gather all standing charges for the same tariff code
        //    Optional step if your product has standing charges in StandingChargeEntity
        let standingCharges = try await fetchStandingCharges(tariffCode: tariffCode, start: startDate, end: endDate)
        
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
        //    In most cases, we'll insert a new row.
        //    If you want to allow updates, fetch existing row first (like fetchStoredCalculation).
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
                let desc = NSEntityDescription.entity(forEntityName: "TariffCalculationEntity", in: self.context)!
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
            let netRateExc = totalKWh > 0.0 ? (totalCostExcVAT - standingExcVAT) / totalKWh : 0.0
            let netRateInc = totalKWh > 0.0 ? (totalCostIncVAT - standingIncVAT) / totalKWh : 0.0
            entity.setValue(netRateExc, forKey: "average_unit_rate_exc_vat")
            entity.setValue(netRateInc, forKey: "average_unit_rate_inc_vat")
            
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
        // 1) Identify active electricity meter agreements.
        //    We assume user has 1 property + 1 electricity meter point for brevity.
        guard let firstProperty = accountData.properties.first,
              let elecMP = firstProperty.electricity_meter_points?.first,
              let agreements = elecMP.agreements else {
            // Return empty if no valid electricity agreements
            return []
        }
        
        // Sort agreements by valid_from
        let sortedAgreements = agreements.sorted { a1, a2 in
            let df = ISO8601DateFormatter()
            let from1 = df.date(from: a1.valid_from ?? "") ?? .distantPast
            let from2 = df.date(from: a2.valid_from ?? "") ?? .distantPast
            return from1 < from2
        }
        
        // 2) For each agreement, compute the partial date range we should handle
        //    e.g. if agreement says valid_from=June 20, but user asked from June 1 => only from June 20 onward
        //    Also if agreement says valid_to=Aug 10, but user asked until Aug 31 => only until Aug 10
        var results: [NSManagedObject] = []
        let dateFormatter = ISO8601DateFormatter()
        
        for agreement in sortedAgreements {
            guard let tf = agreement.tariff_code as String? else { continue }
            
            let rawFrom = agreement.valid_from ?? ""
            let rawTo = agreement.valid_to ?? ""
            let agrFrom = dateFormatter.date(from: rawFrom) ?? .distantPast
            let agrTo   = dateFormatter.date(from: rawTo) ?? .distantFuture
            
            // Clip to user’s requested range
            let effectiveStart = max(agrFrom, startDate)
            let effectiveEnd   = min(agrTo, endDate)
            
            // If no overlap, skip
            if effectiveEnd <= effectiveStart { continue }
            
            // 3) Calculate cost for that partial interval
            let partialCalc = try await self.calculateCostForPeriod(
                tariffCode: tf,
                startDate: effectiveStart,
                endDate: effectiveEnd,
                intervalType: intervalType
            )
            
            results.append(partialCalc)
        }
        
        return results
    }
    
    // MARK: - Private Helpers
    
    /// Fetch half-hour consumption from EConsumAgile, for the specified time window.
    private func fetchConsumption(start: Date, end: Date) async throws -> [NSManagedObject] {
        try await context.perform {
            let request = NSFetchRequest<NSManagedObject>(entityName: "EConsumAgile")
            request.predicate = NSPredicate(
                format: "interval_start >= %@ AND interval_end <= %@",
                start as NSDate, end as NSDate
            )
            request.sortDescriptors = [NSSortDescriptor(key: "interval_start", ascending: true)]
            return try self.context.fetch(request)
        }
    }
    
    /// Fetch rate records from RateEntity for a single tariff_code that intersect the requested date window.
    /// We allow a bit of a looser query because we handle boundary alignment in compute logic.
    private func fetchRates(tariffCode: String, start: Date, end: Date) async throws -> [NSManagedObject] {
        try await context.perform {
            let request = NSFetchRequest<NSManagedObject>(entityName: "RateEntity")
            request.predicate = NSPredicate(
                format: "tariff_code == %@ AND valid_to >= %@ AND valid_from <= %@",
                tariffCode, start as NSDate, end as NSDate
            )
            request.sortDescriptors = [NSSortDescriptor(key: "valid_from", ascending: true)]
            return try self.context.fetch(request)
        }
    }
    
    /// Fetch standing charge records from StandingChargeEntity for the same tariff_code + date window.
    private func fetchStandingCharges(tariffCode: String, start: Date, end: Date) async throws -> [NSManagedObject] {
        try await context.perform {
            let request = NSFetchRequest<NSManagedObject>(entityName: "StandingChargeEntity")
            request.predicate = NSPredicate(format: "tariff_code == %@", tariffCode)
            request.sortDescriptors = [NSSortDescriptor(key: "valid_from", ascending: true)]
            return try self.context.fetch(request)
        }
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
                  let inc = mo.value(forKey: "value_including_vat") as? Double else {
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
                  let inc = mo.value(forKey: "value_including_vat") as? Double else {
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
            if let dayStart = Calendar.current.date(byAdding: .day, value: dayOffset, to: startOfDay(rangeStart)) {
                let dayEnd = endOfDay(dayStart)
                if dayStart > rangeEnd { break }
                if dayEnd < rangeStart { continue }
                
                // Clip day range within user's overall range
                let effectiveDayStart = max(dayStart, rangeStart)
                let effectiveDayEnd   = min(dayEnd, rangeEnd)
                
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
                  let cEnd   = record.value(forKey: "interval_end")   as? Date,
                  let usage  = record.value(forKey: "consumption")    as? Double else {
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
                print("⚠️ No matching rate found for period: \(cStart.formatted()) to \(cEnd.formatted())")
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
         -> (Date, Date, Double, Double)? {
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
         -> (Date, Date, Double, Double)? {
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
        let startOfEnd   = Calendar.current.startOfDay(for: end)
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
        guard let end = Calendar.current.date(bySettingHour: 23, minute: 59, second: 59, of: date) else {
            return date
        }
        return end
    }
}
