import OctopusHelperShared
import SwiftUI

struct RateCardStyle: ViewModifier {
    @Environment(\.colorScheme) var colorScheme

    func body(content: Content) -> some View {
        content
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            .background(Theme.secondaryBackground)
            .cornerRadius(12)
            .padding(.bottom, 12)
            .padding(.horizontal, 8)
    }
}

struct InfoCardStyle: ViewModifier {
    @Environment(\.colorScheme) var colorScheme

    func body(content: Content) -> some View {
        content
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            .background(Theme.secondaryBackground)
            .cornerRadius(12)
    }
}

extension View {
    func rateCardStyle() -> some View {
        modifier(RateCardStyle())
    }

    func infoCardStyle() -> some View {
        modifier(InfoCardStyle())
    }
}

// MARK: - Shared Time Formatting
extension View {
    /// Formats a time range with localization support.
    /// - Parameters:
    ///   - from: Start date
    ///   - to: End date
    ///   - locale: The locale to use for formatting
    /// - Returns: A formatted string representing the time range
    func formatTimeRange(_ from: Date?, _ to: Date?, locale: Locale) -> String {
        guard let from = from, let to = to else { return "" }

        let now = Date()
        let calendar = Calendar.current

        let fromDay = calendar.startOfDay(for: from)
        let toDay = calendar.startOfDay(for: to)
        let nowDay = calendar.startOfDay(for: now)

        let timeFormatter = DateFormatter()
        timeFormatter.dateFormat = "HH:mm"
        timeFormatter.locale = locale

        let dateFormatter = DateFormatter()
        if locale.language.languageCode?.identifier == "zh" {
            dateFormatter.dateFormat = "M月d日"
        } else {
            dateFormatter.dateFormat = "d MMM"  // UK format
        }
        dateFormatter.locale = locale

        // same day
        if calendar.isDate(fromDay, inSameDayAs: toDay) {
            if calendar.isDate(fromDay, inSameDayAs: nowDay) {
                return "\(timeFormatter.string(from: from))-\(timeFormatter.string(from: to))"
            } else {
                return
                    "\(dateFormatter.string(from: from)) \(timeFormatter.string(from: from))-\(timeFormatter.string(from: to))"
            }
        } else {
            // different days
            if calendar.isDate(fromDay, inSameDayAs: nowDay) {
                // If start is today, only show date for the end
                return
                    "\(timeFormatter.string(from: from))-\(dateFormatter.string(from: to)) \(timeFormatter.string(from: to))"
            } else {
                // Show both dates
                return
                    "\(dateFormatter.string(from: from)) \(timeFormatter.string(from: from))-\(dateFormatter.string(from: to)) \(timeFormatter.string(from: to))"
            }
        }
    }
}
