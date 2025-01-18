//
//  TariffComparisonEngine.swift
//  Octopus_Agile_Helper
//
//  Description:
//    Provides standalone logic to merge half-hourly consumption with multi-interval rates
//    and daily standing charges, returning final usage and cost totals.
//
//    This file is a pure “engine” that can be called from TariffCalculationRepository
//    or other modules. It doesn’t perform Core Data fetches; it expects already-fetched
//    consumption/rate/standing-charge records (NSManagedObject arrays or lightweight
//    plain structs) and returns aggregated results.
//
//    Adjust or expand as your app logic requires.
//
//  Example Usage:
//    let engine = TariffComparisonEngine()
//    let result = engine.computeAggregatedCost(
//        consumptionRecords: consumptionArray,
//        rates: rateArray,
//        standingCharges: standingChargeArray,
//        rangeStart: userStart,
//        rangeEnd: userEnd
//    )
//

import Foundation
import CoreData
import SwiftUI

public struct TariffComparisonResult {
    /// Total consumption (kWh) over the requested period.
    public let totalConsumptionKWh: Double
    
    /// Total cost excluding VAT, including standing charges.
    public let totalCostExcVAT: Double
    
    /// Total cost including VAT, including standing charges.
    public let totalCostIncVAT: Double
    
    /// The sum of standing-charge cost exc VAT for the entire period.
    public let standingChargeExcVAT: Double
    
    /// The sum of standing-charge cost inc VAT for the entire period.
    public let standingChargeIncVAT: Double
}

/// A dedicated comparison engine that aligns half-hour consumption with multi-interval rates
/// and optional daily standing charges. Returns aggregated usage and cost data.
public final class TariffComparisonEngine: ObservableObject {
    
    public init() {}
    
    // MARK: - Public Primary Method
    
    /// Merges half-hour consumption with the correct rates (exc/inc VAT),
    /// plus daily standing charges, for a given date range.
    ///
    /// - Parameters:
    ///   - consumptionRecords: Array of NSManagedObject from `EConsumAgile`,
    ///        each with `interval_start (Date), interval_end (Date), consumption (Double)`.
    ///   - rates: Array of NSManagedObject from `RateEntity`,
    ///        each with `valid_from (Date), valid_to (Date), value_excluding_vat (Double), value_including_vat (Double)`.
    ///   - standingCharges: Array of NSManagedObject from `StandingChargeEntity`,
    ///        each with `valid_from (Date), valid_to (Date), value_excluding_vat (Double), value_including_vat (Double)`.
    ///   - rangeStart: The start of the overall period we’re calculating.
    ///   - rangeEnd: The end of the overall period we’re calculating.
    ///
    /// - Returns: A TariffComparisonResult struct with total usage, total cost (exc/inc VAT), etc.
    public func computeAggregatedCost(
        consumptionRecords: [NSManagedObject],
        rates: [NSManagedObject],
        standingCharges: [NSManagedObject],
        rangeStart: Date,
        rangeEnd: Date
    ) -> TariffComparisonResult {
        
        // 1) Convert input data into simpler arrays or domain models
        let sortedRates = parseRates(rates)
        let sortedStanding = parseStandingCharges(standingCharges)
        
        // 2) Summation variables
        var totalKWh = 0.0
        var totalCostExc = 0.0
        var totalCostInc = 0.0
        
        // 3) Compute total standing charges for daily intervals
        let (daysBetween, totalStandingExc, totalStandingInc) =
            computeDailyStandingCharges(
                sortedStanding: sortedStanding,
                overallStart: rangeStart,
                overallEnd: rangeEnd
            )
        
        // 4) Sum consumption cost
        for record in consumptionRecords {
            guard let cStart = record.value(forKey: "interval_start") as? Date,
                  let cEnd   = record.value(forKey: "interval_end")   as? Date,
                  let usage  = record.value(forKey: "consumption")    as? Double else {
                continue
            }
            // Typically, the "cEnd" (or average of cStart..cEnd) determines which rate applies
            let pivot = cEnd
            if let matchedRate = findRate(for: pivot, in: sortedRates) {
                totalKWh += usage
                totalCostExc += usage * matchedRate.2
                totalCostInc += usage * matchedRate.3
            }
        }
        
        // 5) Add daily standing charges
        let finalExc = totalCostExc + totalStandingExc
        let finalInc = totalCostInc + totalStandingInc
        
        return TariffComparisonResult(
            totalConsumptionKWh: totalKWh,
            totalCostExcVAT: finalExc,
            totalCostIncVAT: finalInc,
            standingChargeExcVAT: totalStandingExc,
            standingChargeIncVAT: totalStandingInc
        )
    }
    
    // MARK: - Parsing Input Data
    
    /// Converts RateEntity NSManagedObject rows into an array of (start, end, valueExc, valueInc).
    /// Sorts by valid_from ascending.
    private func parseRates(_ rates: [NSManagedObject])
        -> [(validFrom: Date, validTo: Date, valueExc: Double, valueInc: Double)]
    {
        rates.compactMap { mo -> (Date, Date, Double, Double)? in
            guard let vf  = mo.value(forKey: "valid_from") as? Date,
                  let vt  = mo.value(forKey: "valid_to")   as? Date,
                  let exc = mo.value(forKey: "value_excluding_vat") as? Double,
                  let inc = mo.value(forKey: "value_including_vat") as? Double else {
                return nil
            }
            return (vf, vt, exc, inc)
        }
        .sorted { $0.validFrom < $1.validFrom }
    }
    
    /// Converts StandingChargeEntity NSManagedObject rows into an array of (start, end, valueExc, valueInc).
    /// Sorts by valid_from ascending.
    private func parseStandingCharges(_ scList: [NSManagedObject])
        -> [(validFrom: Date, validTo: Date, valueExc: Double, valueInc: Double)]
    {
        scList.compactMap { mo -> (Date, Date, Double, Double)? in
            guard let vf  = mo.value(forKey: "valid_from") as? Date,
                  let vt  = mo.value(forKey: "valid_to")   as? Date,
                  let exc = mo.value(forKey: "value_excluding_vat") as? Double,
                  let inc = mo.value(forKey: "value_including_vat") as? Double else {
                return nil
            }
            return (vf, vt, exc, inc)
        }
        .sorted { $0.validFrom < $1.validFrom }
    }
    
    // MARK: - Daily Standing Charges Logic
    
    /// Iterates from overallStart..overallEnd by day, and for each day checks which
    /// standing charge record is valid. Returns (daysBetween, totalSCExc, totalSCInc).
    private func computeDailyStandingCharges(
        sortedStanding: [(validFrom: Date, validTo: Date, valueExc: Double, valueInc: Double)],
        overallStart: Date,
        overallEnd: Date
    ) -> (Int, Double, Double) {
        
        let dayCount = daysBetweenDates(overallStart, overallEnd)
        var totalExc = 0.0
        var totalInc = 0.0
        
        for offset in 0..<dayCount {
            guard let dayStart = Calendar.current.date(byAdding: .day, value: offset, to: startOfDay(overallStart)) else {
                continue
            }
            let dayEnd = endOfDay(dayStart)
            if dayStart > overallEnd { break }
            if dayEnd < overallStart { continue }
            
            // We consider the day start to find a matching record
            if let (vf, vt, scExc, scInc) = findStandingCharge(for: dayStart, in: sortedStanding) {
                totalExc += scExc
                totalInc += scInc
            }
        }
        
        return (dayCount, totalExc, totalInc)
    }
    
    // MARK: - Rate & Standing Charge Finders
    
    /// Returns the single rate record whose validFrom <= pivot < validTo, if any.
    private func findRate(
        for pivot: Date,
        in sortedRates: [(validFrom: Date, validTo: Date, valueExc: Double, valueInc: Double)]
    ) -> (Date, Date, Double, Double)? {
        
        // We do a simple linear search. If performance is a concern, consider a binary search approach.
        for (vf, vt, exc, inc) in sortedRates {
            if vf <= pivot && pivot < vt {
                return (vf, vt, exc, inc)
            }
        }
        return nil
    }
    
    /// Returns the single standing charge record whose validFrom <= dayStart < validTo, if any.
    private func findStandingCharge(
        for dayStart: Date,
        in sortedSC: [(validFrom: Date, validTo: Date, valueExc: Double, valueInc: Double)]
    ) -> (Date, Date, Double, Double)? {
        
        for (vf, vt, exc, inc) in sortedSC {
            if vf <= dayStart && dayStart < vt {
                return (vf, vt, exc, inc)
            }
        }
        return nil
    }
    
    // MARK: - Date Helpers
    
    /// Returns the number of daily steps (inclusive) between two dates.
    /// E.g. from 2025-01-01 to 2025-01-03 => 3 days
    private func daysBetweenDates(_ start: Date, _ end: Date) -> Int {
        let startOfStart = Calendar.current.startOfDay(for: start)
        let startOfEnd   = Calendar.current.startOfDay(for: end)
        let diff = Calendar.current.dateComponents([.day], from: startOfStart, to: startOfEnd)
        // +1 to include the partial last day
        return max(0, (diff.day ?? 0) + 1)
    }
    
    private func startOfDay(_ date: Date) -> Date {
        Calendar.current.startOfDay(for: date)
    }
    
    private func endOfDay(_ date: Date) -> Date {
        guard let eod = Calendar.current.date(bySettingHour: 23, minute: 59, second: 59, of: date) else {
            return date
        }
        return eod
    }
}
