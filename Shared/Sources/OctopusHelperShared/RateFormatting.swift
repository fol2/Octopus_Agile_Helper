import Foundation

public struct RateFormatting {
    public static func formatRate(_ value: Double, showRatesInPounds: Bool = false, showRatesWithVAT: Bool = true) -> String {
        // Determine which value to use based on VAT preference
        let rateValue = value
        
        if showRatesInPounds {
            // Convert pence to pounds: 100 pence = £1
            let poundsValue = rateValue / 100.0
            return String(format: "£%.4f /kWh", poundsValue)
        } else {
            return String(format: "%.2fp /kWh", rateValue)
        }
    }
    
    public static func formatRate(excVAT: Double, incVAT: Double, showRatesInPounds: Bool = false, showRatesWithVAT: Bool = true) -> String {
        // Choose the appropriate value based on VAT preference
        let rateValue = showRatesWithVAT ? incVAT : excVAT
        
        if showRatesInPounds {
            // Convert pence to pounds: 100 pence = £1
            let poundsValue = rateValue / 100.0
            return String(format: "£%.4f /kWh", poundsValue)
        } else {
            return String(format: "%.2fp /kWh", rateValue)
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