import SwiftUI
import CoreData

public struct RateColor {
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
        if currentValue < 0 {
            let negativeRates = dayRates.filter { 
                ($0.value(forKey: "value_including_vat") as? Double ?? 0) < 0 
            }
            if let mostNegative = negativeRates.min(by: {
                ($0.value(forKey: "value_including_vat") as? Double ?? 0) < ($1.value(forKey: "value_including_vat") as? Double ?? 0)
            }) {
                // Calculate percentage based on how close to 0 the rate is, but keep minimum 20% intensity
                let mostNegativeValue = mostNegative.value(forKey: "value_including_vat") as? Double ?? 0
                let rawPercentage = abs(currentValue / mostNegativeValue)
                let percentage = 0.5 + (rawPercentage * 0.5)  // This ensures we keep at least 50% of the color
                // Base green color (RGB: 0.2, 0.8, 0.4)
                return Color(
                    red: 1.0 - (0.8 * percentage),  // Interpolate from 1.0 to 0.2
                    green: 1.0 - (0.2 * percentage),  // Interpolate from 1.0 to 0.8
                    blue: 1.0 - (0.6 * percentage)  // Interpolate from 1.0 to 0.4
                )
            }
            return Color(red: 0.2, green: 0.8, blue: 0.4)
        }

        // Find the day's rate statistics
        let sortedRates = dayRates.map { $0.value(forKey: "value_including_vat") as? Double ?? 0 }.sorted()
        guard !sortedRates.isEmpty else { return .white }

        let medianRate = sortedRates[sortedRates.count / 2]
        let maxRate = sortedRates.last ?? 0

        // Only color rates above the median
        if currentValue >= medianRate {
            // Calculate how "high" the rate is compared to the range between median and max
            let percentage = (currentValue - medianRate) / (maxRate - medianRate)
            
            // Interpolate between yellow and red based on percentage
            return Color(
                red: 1.0,  // Full red
                green: 1.0 - (0.8 * percentage),  // Fade from full yellow to slight yellow
                blue: 0.0   // No blue
            )
        }
        
        // Return white for rates below median
        return .white
    }
} 