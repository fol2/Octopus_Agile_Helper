import SwiftUI

struct RateColor {
    static func getDayRates(for date: Date, allRates: [RateEntity]) -> [RateEntity] {
        let calendar = Calendar.current
        let startOfDay = calendar.startOfDay(for: date)
        let endOfDay = calendar.date(byAdding: .day, value: 1, to: startOfDay)!
        
        return allRates.filter { rate in
            guard let validFrom = rate.validFrom else { return false }
            return validFrom >= startOfDay && validFrom < endOfDay
        }.sorted { ($0.validFrom ?? .distantPast) < ($1.validFrom ?? .distantPast) }
    }
    
    static func getColor(for rate: RateEntity, allRates: [RateEntity]) -> Color {
        guard let currentValidFrom = rate.validFrom else {
            return .white
        }
        
        // Get all rates for the day
        let dayRates = getDayRates(for: currentValidFrom, allRates: allRates)
        
        // Handle negative rates
        if rate.valueIncludingVAT < 0 {
            if let mostNegative = dayRates.filter({ $0.valueIncludingVAT < 0 }).min(by: { $0.valueIncludingVAT < $1.valueIncludingVAT }) {
                let percentage = abs(rate.valueIncludingVAT / mostNegative.valueIncludingVAT)
                return Color(red: 0.2, green: 0.8, blue: 0.4).opacity(0.4 + (percentage * 0.6))
            }
            return Color(red: 0.2, green: 0.8, blue: 0.4)
        }
        
        // Find the day's rate statistics
        let sortedRates = dayRates.map { $0.valueIncludingVAT }.sorted()
        guard !sortedRates.isEmpty else { return .white }
        
        let medianRate = sortedRates[sortedRates.count / 2]
        let maxRate = sortedRates.last ?? 0
        
        let currentValue = rate.valueIncludingVAT
        
        // Only color rates above the median
        if currentValue >= medianRate {
            // Calculate how far above median this rate is
            let percentage = (currentValue - medianRate) / (maxRate - medianRate)
            
            // Base color for the softer red (RGB: 255, 69, 58)
            let baseRed = 1.0
            let baseGreen = 0.2
            let baseBlue = 0.2
            
            // For the highest rate, use the base red color at full intensity
            if currentValue == maxRate {
                return Color(red: baseRed, green: baseGreen, blue: baseBlue)
            }
            
            // For other high rates, interpolate from white to the base red color
            let intensity = 0.2 + (percentage * 0.5)
            return Color(
                red: 1.0,
                green: 1.0 - ((1.0 - baseGreen) * intensity),
                blue: 1.0 - ((1.0 - baseBlue) * intensity)
            )
        }
        
        // Lower half rates stay white
        return .white
    }
} 