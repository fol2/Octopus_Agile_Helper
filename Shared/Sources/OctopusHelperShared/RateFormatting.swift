import Foundation

public struct RateFormatting {
    public static func formatRate(_ value: Double, showRatesInPounds: Bool = false) -> String {
        if showRatesInPounds {
            // Convert pence to pounds: 100 pence = £1
            let poundsValue = value / 100.0
            return String(format: "£%.4f /kWh", poundsValue)
        } else {
            return String(format: "%.2fp /kWh", value)
        }
    }
    
    public static func formatTime(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateStyle = .none
        formatter.timeStyle = .short
        return formatter.string(from: date)
    }
    
    public static func formatTimeRange(_ start: Date?, _ end: Date?) -> String {
        guard let start = start, let end = end else { return "" }
        return "\(formatTime(start)) - \(formatTime(end))"
    }
} 