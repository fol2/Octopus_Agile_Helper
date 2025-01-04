import Foundation

public struct ClockModel {
    /// Convert a time to the appropriate clock asset name
    public static func iconName(for date: Date = Date()) -> String {
        let calendar = Calendar.current
        let hour = calendar.component(.hour, from: date)
        let minute = calendar.component(.minute, from: date)
        
        // If minutes > 45, roll over to next hour
        if minute > 45 {
            if let nextHour = calendar.date(byAdding: .hour, value: 1, to: date) {
                return iconName(for: nextHour)
            }
        }
        
        // Convert 24h to 12h format
        let clockHour = hour % 12
        
        // Round minutes to nearest 30
        // 0-15 -> 0
        // 16-45 -> 5 (representing 30 minutes)
        let clockMinute = minute <= 15 ? "0" : "5"
        
        return "clock.\(clockHour).\(clockMinute)"
    }
} 