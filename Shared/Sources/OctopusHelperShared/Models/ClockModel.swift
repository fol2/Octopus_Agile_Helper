import Foundation

public struct ClockModel {
    /// Convert a time to the appropriate clock asset name
    public static func iconName(for date: Date = Date()) -> String {
        let calendar = Calendar.current
        let hour = calendar.component(.hour, from: date)
        let minute = calendar.component(.minute, from: date)
        
        // Convert 24h to 12h format
        let clockHour = hour % 12
        
        // For minutes 0-29 -> 0, 30-59 -> 5
        let clockMinute = minute < 30 ? "0" : "5"
        
        return "clock.\(clockHour).\(clockMinute)"
    }
} 