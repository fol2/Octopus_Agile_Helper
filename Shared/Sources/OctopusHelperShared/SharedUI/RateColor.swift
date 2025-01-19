import SwiftUI
import CoreData

public struct RateColor {
    // MARK: - Colour Definitions
    // Adjust as needed:
    private static let whiteColor       = Color.white
    private static let softerRedColor   = Color(red: 1.0, green: 0.2, blue: 0.2)
    private static let devilPurpleColor = Color(red: 0.9, green: 0.1, blue: 1.0)
    private static let greenColor       = Color(red: 0.1, green: 1.0, blue: 0.3)

    // We no longer rely on fixed thresholds for "medium" and "high" in the old sense.
    // Instead, each day has its own maximum rate, and we apply your new logic:
    //  - Negative -> White -> Green
    //  - Positive up to dayMax:
    //     * First 50% of sorted rates (by ascending value) → White
    //     * Last 50% → gradient from white to "soft red" (up to 50p),
    //       then from 50p to 100p → gradient to devil purple,
    //       above 100p stays devil purple
    //
    // All color calculations happen only among that day's rates.

    /// Returns all rates for a specific day, sorted chronologically
    /// - Parameters:
    ///   - date: The date to get rates for
    ///   - allRates: All available rates from CoreData, pre-filtered for the current Agile code
    /// - Returns: Array of rates for the specified day
    public static func getDayRates(for date: Date, allRates: [NSManagedObject]) -> [NSManagedObject] {
        let calendar = Calendar.current
        let startOfDay = calendar.startOfDay(for: date)
        let endOfDay = calendar.date(byAdding: .day, value: 1, to: startOfDay)!

        return allRates.filter { rate in
            guard let validFrom = rate.value(forKey: "valid_from") as? Date else { return false }
            return validFrom >= startOfDay && validFrom < endOfDay
        }.sorted { 
            let date1 = $0.value(forKey: "valid_from") as? Date ?? .distantPast
            let date2 = $1.value(forKey: "valid_from") as? Date ?? .distantPast
            return date1 < date2
        }
    }

    public static func getColor(for rate: NSManagedObject, allRates: [NSManagedObject]) -> Color {
        guard let currentValidFrom = rate.value(forKey: "valid_from") as? Date else {
            return .white
        }

        // Get all rates for the day
        let dayRates = getDayRates(for: currentValidFrom, allRates: allRates)

        // Handle negative rates
        let currentValue = rate.value(forKey: "value_including_vat") as? Double ?? 0

        // Negative: White -> Green gradient (day-based)
        if currentValue < 0 {
            return computeNegativeGradientColor(
                dayRates: dayRates,
                currentValue: currentValue
            )
        }

        // Positive: new day-based gradient logic
        // 1) Sort all daily (non-negative) rates ascending
        let positiveRates = dayRates
            .compactMap { $0.value(forKey: "value_including_vat") as? Double }
            .filter { $0 >= 0 }
            .sorted()

        guard !positiveRates.isEmpty else {
            // If there's absolutely no non-negative rate, fallback to white
            return whiteColor
        }

        // 2) Identify dayMax for "full color" and handle >100p => always devilPurple
        let dayMax = positiveRates.last ?? 0
        if currentValue > 100 {
            return devilPurpleColor
        }

        // 3) If dayMax <= 50, we treat dayMax as 100% "soft red" boundary
        //    If dayMax is between 50..100, we do partial gradient red → devilPurple
        //    If currentValue > 50 => shift into purple gradient zone
        let isAbove50 = (currentValue > 50)

        // 4) Determine which 'half' the current rate belongs to, by index in sorted array
        let indexInList = positiveRates.firstIndex(where: { $0 >= currentValue }) ?? 0
        let half = positiveRates.count / 2  // integer division

        if indexInList < half {
            // First 50% => White
            return whiteColor
        }
        // Last 50% => gradient from White → Red OR Red → DevilPurple

        // For rates over 50p, we do gradient from red to purple (up to 100p).
        // For rates up to 50p, we do white->red. But we must see how far along we are in dayMax.
        return computePositiveGradientColor(
            currentValue: currentValue,
            dayMax: dayMax,
            isAbove50: isAbove50
        )
    }

    // MARK: - Negative Rates
    private static func computeNegativeGradientColor(dayRates: [NSManagedObject], currentValue: Double) -> Color {
        // We do "White -> Green" using a proportion of how negative it is relative to day's min negative
        let negatives = dayRates.compactMap {
            $0.value(forKey: "value_including_vat") as? Double
        }.filter { $0 < 0 }
        guard let dayMinNeg = negatives.min() else {
            return greenColor
        }
        let ratio = (currentValue - 0.0) / (dayMinNeg - 0.0) // negative / negative => positive ratio
        // clamp ratio to [0..1]
        let clamped = max(0.0, min(abs(ratio), 1.0))

        // White (1,1,1) to greenColor
        return Color(
            red: 1.0 + (0.2 - 1.0) * clamped,  // 1.0 -> 0.2
            green: 1.0 + (0.8 - 1.0) * clamped, // 1.0 -> 0.8
            blue: 1.0 + (0.4 - 1.0) * clamped  // 1.0 -> 0.4
        )
    }

    // MARK: - Positive Rates Gradient
    private static func computePositiveGradientColor(
        currentValue: Double,
        dayMax: Double,
        isAbove50: Bool
    ) -> Color {
        if !isAbove50 {
            // White -> (soft) Red gradient
            // dayMax might be < 50 or >= 50, but if the currentValue <= 50, we ignore purple.
            let ratio = currentValue / 50.0 // up to 50p is 100% "soft red"
            let clamped = max(0.0, min(ratio, 1.0))
            return interpolate(whiteColor, softerRedColor, clamped)
        } else if currentValue <= 100 {
            // We are in the 50..100 range => red -> devilPurple
            // 50p => red, 100p => devilPurple
            let ratio = (currentValue - 50.0) / (100.0 - 50.0)
            let clamped = max(0.0, min(ratio, 1.0))
            // We do a simple interpolation from "softRed" to "devilPurple"
            return interpolate(softerRedColor, devilPurpleColor, clamped)
        } else {
            // Over 100p => devilPurple
            return devilPurpleColor
        }
    }

    // MARK: - Interpolation Helper
    private static func interpolate(_ from: Color, _ to: Color, _ fraction: Double) -> Color {
        let f = CGFloat(max(0.0, min(fraction, 1.0)))
        let uiFrom = UIColor(from)
        let uiTo   = UIColor(to)
        var r1: CGFloat = 0, g1: CGFloat = 0, b1: CGFloat = 0, a1: CGFloat = 0
        var r2: CGFloat = 0, g2: CGFloat = 0, b2: CGFloat = 0, a2: CGFloat = 0
        uiFrom.getRed(&r1, green: &g1, blue: &b1, alpha: &a1)
        uiTo.getRed(&r2, green: &g2, blue: &b2, alpha: &a2)
        return Color(
            red:   Double(r1 + (r2 - r1) * f),
            green: Double(g1 + (g2 - g1) * f),
            blue:  Double(b1 + (b2 - b1) * f),
            opacity: Double(a1 + (a2 - a1) * f)
        )
    }
} 