import SwiftUI
import CoreData

public struct RateColor {
    // Fixed rate thresholds in pence
    private static let mediumRateThreshold = 50.0  // 50p
    private static let highRateThreshold = 100.0   // £1
    
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
            print("DEBUG: RateColor - No valid_from date found")
            return .white
        }

        // Get all rates for the day
        let dayRates = getDayRates(for: currentValidFrom, allRates: allRates)
        print("DEBUG: RateColor - Found \(dayRates.count) rates for the day")

        // Handle negative rates
        let currentValue = rate.value(forKey: "value_including_vat") as? Double ?? 0
        print("DEBUG: RateColor - Current rate value: \(currentValue)")
        
        if currentValue < 0 {
            let negativeRates = dayRates.filter { 
                ($0.value(forKey: "value_including_vat") as? Double ?? 0) < 0 
            }
            print("DEBUG: RateColor - Found \(negativeRates.count) negative rates")
            
            if let mostNegative = negativeRates.min(by: {
                ($0.value(forKey: "value_including_vat") as? Double ?? 0) < ($1.value(forKey: "value_including_vat") as? Double ?? 0)
            }) {
                // Calculate percentage based on how close to 0 the rate is, but keep minimum 20% intensity
                let mostNegativeValue = mostNegative.value(forKey: "value_including_vat") as? Double ?? 0
                let rawPercentage = abs(currentValue / mostNegativeValue)
                let percentage = 0.5 + (rawPercentage * 0.5)  // This ensures we keep at least 50% of the color
                print("DEBUG: RateColor - Negative rate color percentage: \(percentage)")
                
                // Base green color (RGB: 0.2, 0.8, 0.4)
                return Color(
                    red: 1.0 - (0.8 * percentage),  // Interpolate from 1.0 to 0.2
                    green: 1.0 - (0.2 * percentage),  // Interpolate from 1.0 to 0.8
                    blue: 1.0 - (0.6 * percentage)  // Interpolate from 1.0 to 0.4
                )
            }
            return Color(red: 0.2, green: 0.8, blue: 0.4)
        }

        // Find the day's rate statistics for rates below 50p
        let sortedRates = dayRates.map { $0.value(forKey: "value_including_vat") as? Double ?? 0 }
            .filter { $0 <= mediumRateThreshold }
            .sorted()
        
        // For rates above 100p, return devil purple
        if currentValue > highRateThreshold {
            print("DEBUG: RateColor - Rate above 100p, using devil purple")
            return Color(red: 0.5, green: 0.0, blue: 0.8)  // Devil purple
        }
        
        // For rates between 50p and 100p, interpolate between red and devil purple
        if currentValue > mediumRateThreshold {
            let percentage = (currentValue - mediumRateThreshold) / (highRateThreshold - mediumRateThreshold)
            print("DEBUG: RateColor - Rate between 50p-100p, percentage: \(percentage)")
            
            // Interpolate from red (1.0, 0.0, 0.0) to devil purple (0.5, 0.0, 0.8)
            return Color(
                red: 1.0 - (0.5 * percentage),  // 1.0 → 0.5
                green: 0.0,                     // Stay at 0
                blue: 0.8 * percentage          // 0.0 → 0.8
            )
        }

        // For rates below or equal to 50p, use original white to red gradient
        guard !sortedRates.isEmpty else { 
            print("DEBUG: RateColor - No sorted rates found")
            return .white 
        }

        let medianRate = sortedRates[sortedRates.count / 2]
        print("DEBUG: RateColor - Median rate for <=50p: \(medianRate)")

        // Only color rates above the median
        if currentValue >= medianRate {
            // Calculate how "high" the rate is compared to the range between median and 50p
            let percentage = (currentValue - medianRate) / (mediumRateThreshold - medianRate)
            print("DEBUG: RateColor - Above median color percentage: \(percentage)")
            
            // White to red gradient
            return Color(
                red: 1.0,  // Full red
                green: 1.0 - percentage,  // Fade from white to no green
                blue: 1.0 - percentage   // Fade from white to no blue
            )
        }
        
        print("DEBUG: RateColor - Below median, returning white")
        // Return white for rates below median
        return .white
    }
} 