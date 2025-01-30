import Foundation

/// A centralized utility for handling all date and time formatting operations across the app.
/// Provides consistent formatting with support for:
/// - Multiple locales (30+ languages including English, Chinese, Arabic, etc.)
/// - Time formatting (time-only, with date, ranges)
/// - Date formatting (short, medium, long formats)
/// - Weekday formatting (full and abbreviated)
/// - Interval-based formatting (daily, weekly, monthly, quarterly)
/// - Billing cycle specific date calculations
/// All formats respect the user's locale settings and handle special cases for different languages
///
/// Supported Languages and Special Cases:
/// 1. Western Languages (Left-to-Right):
///    - English (en): "31 Dec", "31 December 2024"
///    - Spanish (es): "31 dic", "31 de diciembre de 2024"
///    - French (fr): "31 déc", "31 décembre 2024"
///    - German (de): "31. Dez", "31. Dezember 2024"
///    - Italian (it): "31 dic", "31 dicembre 2024"
///    - Portuguese (pt-PT): "31 dez", "31 de dezembro de 2024"
///    - Dutch (nl): "31 dec", "31 december 2024"
///    - Polish (pl): "31 gru", "31 grudnia 2024"
///    - Russian (ru): "31 дек", "31 декабря 2024"
///    - Turkish (tr): "31 Ara", "31 Aralık 2024"
///    - Czech (cs): "31. pro", "31. prosince 2024"
///    - Danish (da): "31. dec", "31. december 2024"
///    - Finnish (fi): "31. joulu", "31. joulukuuta 2024"
///    - Greek (el): "31 Δεκ", "31 Δεκεμβρίου 2024"
///    - Hungarian (hu): "dec. 31.", "2024. december 31."
///    - Croatian (hr): "31. pro", "31. prosinca 2024"
///    - Norwegian (nb): "31. des", "31. desember 2024"
///    - Romanian (ro): "31 dec", "31 decembrie 2024"
///    - Slovak (sk): "31. dec", "31. decembra 2024"
///    - Slovenian (sl): "31. dec", "31. december 2024"
///    - Swedish (sv): "31 dec", "31 december 2024"
///    - Ukrainian (uk): "31 груд", "31 грудня 2024"
///    - Indonesian (id): "31 Des", "31 Desember 2024"
///    - Malay (ms): "31 Dis", "31 Disember 2024"
///    - Vietnamese (vi): "31 thg 12", "31 tháng 12 năm 2024"
///
/// Time Format Standard:
/// - All times are in 24-hour format
/// - Time only: "14:30"
/// - Time range same day: "14:30 - 15:30"
/// - Time range cross day: "22:00 - 02:00" (next day)
///
/// 2. Right-to-Left Languages:
///    - Arabic (ar): "٣١ ديسمبر", "٣١ ديسمبر ٢٠٢٤"
///    - Hebrew (he): "31 בדצמ׳", "31 בדצמבר 2024"
///
/// 3. East Asian Languages:
///    - Chinese Traditional (zh-Hant): "12月31日", "2024年12月31日"
///    - Chinese Simplified (zh-Hans): "12月31日", "2024年12月31日"
///    - Japanese (ja): "12月31日", "2024年12月31日"
///    - Korean (ko): "12월 31일", "2024년 12월 31일"
///    - Thai (th): "31 ธ.ค.", "31 ธันวาคม 2567"
///
/// 4. Other Scripts:
///    - Hindi (hi): "31 दिस॰", "31 दिसंबर 2024"
///
/// Weekday Format Examples:
/// 1. Western Languages:
///    - English: "Monday" / "Mon"
///    - German: "Montag" / "Mo"
///    - French: "lundi" / "lun."
/// 2. East Asian:
///    - Chinese: "星期一" / "周一"
///    - Japanese: "月曜日" / "月"
///    - Korean: "월요일" / "월"
/// 3. RTL Languages:
///    - Arabic: "الاثنين" / "اثنين"
///    - Hebrew: "יום שני" / "ב׳"
///
/// TODO Implementation List:
/// 1. Core Formatting:
///    - [✓] Implement basic DateFormatter cache system
///
/// 2. Time Formatting (24-hour):
///    - [✓] Implement time-only formatting (HH:mm)
///    - [✓] Add time range formatting (same day)
///    - [✓] Handle cross-day time ranges
///    - [✓] Add date context when needed
///    - [✓] Implement time range formatting
///    - [✓] Handle cross-day time ranges
///
/// 3. Date Formatting:
///    - [ ] Implement short date style with locale-specific separators
///    - [ ] Handle medium date style with abbreviated month names
///    - [ ] Implement long date style with full month names
///    - [ ] Add year formatting based on context
///    - [ ] Handle special date particles (de, の, 年, etc.)
///
/// 4. Weekday Formatting:
///    - [ ] Add full weekday name formatting
///    - [ ] Implement abbreviated weekday names
///    - [ ] Handle locale-specific abbreviation rules
///    - [ ] Support standalone vs contextual forms
///
/// 5. Interval Formatting:
///    - [ ] Implement daily interval formatting
///    - [ ] Add weekly interval with locale-specific first day
///    - [ ] Handle monthly intervals with billing day
///    - [ ] Implement quarterly intervals with billing day
///    - [ ] Add custom interval support
///
/// 6. Special Cases:
///    - [ ] Handle right-to-left text formatting
///    - [ ] Implement East Asian date formatting
///    - [ ] Handle Arabic number formatting
///    - [ ] Support Hindi date formatting
///
/// 7. Testing:
///    - [ ] Create test cases for each language
///    - [ ] Verify date/time separators
///    - [ ] Test time range formatting
///    - [ ] Verify right-to-left formatting
///    - [ ] Test cross-year scenarios
///    - [ ] Verify weekday formatting
public class DateFormatting {
    // MARK: - Singleton

    /// Shared instance for date formatting operations
    public static let shared = DateFormatting()

    // MARK: - Private Properties

    /// Calendar instance for date calculations
    /// Used for determining day boundaries, intervals, and billing cycles
    private let calendar: Calendar

    /// Thread-safe cache for date formatters
    /// Using NSCache for automatic memory management and thread safety
    private let formatterCache: NSCache<NSString, DateFormatter>

    /// Lock for thread-safe access to formatters
    private let lock = NSLock()

    // MARK: - Initialization

    private init() {
        self.calendar = Calendar.current
        self.formatterCache = NSCache<NSString, DateFormatter>()
        self.formatterCache.countLimit = 50  // Limit cache to 50 formatters
        self.formatterCache.totalCostLimit = 5 * 1024 * 1024  // 5MB limit
    }

    // MARK: - Public Interface

    // TODO: We will implement the following functionalities:
    // 1. Basic date/time formatting
    // 2. Locale-specific formatting
    // 3. Date range formatting
    // 4. Interval-based formatting (daily, weekly, monthly, quarterly)
    // 5. Billing cycle specific formatting
    // 6. Custom format patterns

    // MARK: - Private Helpers

    /// Generates a cache key for formatter configurations
    /// - Parameters:
    ///   - locale: The locale for formatting
    ///   - dateStyle: The date formatting style
    ///   - timeStyle: The time formatting style
    ///   - format: Custom format string if any
    /// - Returns: A unique cache key for this formatter configuration
    private func cacheKey(
        locale: Locale?,
        dateStyle: DateFormatter.Style = .none,
        timeStyle: DateFormatter.Style = .none,
        format: String? = nil
    ) -> NSString {
        let localeId = locale?.identifier ?? Locale.current.identifier
        let components = [
            localeId,
            String(dateStyle.rawValue),
            String(timeStyle.rawValue),
            format ?? "",
        ]
        return components.joined(separator: "_") as NSString
    }

    /// Gets a cached formatter or creates a new one if not exists
    /// - Parameters:
    ///   - key: Cache key for the formatter
    ///   - configuration: Configuration closure for new formatters
    /// - Returns: Configured DateFormatter instance
    private func getCachedFormatter(withKey key: NSString, configuration: (DateFormatter) -> Void)
        -> DateFormatter
    {
        // Try to get from cache first
        if let cached = formatterCache.object(forKey: key) {
            return cached
        }

        // Create new formatter with lock
        lock.lock()
        defer { lock.unlock() }

        // Double-check after acquiring lock
        if let cached = formatterCache.object(forKey: key) {
            return cached
        }

        // Create and configure new formatter
        let formatter = DateFormatter()
        configuration(formatter)
        formatterCache.setObject(formatter, forKey: key)
        return formatter
    }

    /// Clears the formatter cache
    /// Called when receiving memory warning or when cache gets too large
    private func clearFormatterCache() {
        formatterCache.removeAllObjects()
    }

    // MARK: - Example Usage Methods

    /// Gets a formatter configured for the specified style and locale
    /// - Parameters:
    ///   - dateStyle: The date style to use
    ///   - timeStyle: The time style to use
    ///   - locale: Optional locale (defaults to current)
    /// - Returns: Configured DateFormatter
    private func getStyledFormatter(
        dateStyle: DateFormatter.Style,
        timeStyle: DateFormatter.Style,
        locale: Locale? = nil
    ) -> DateFormatter {
        let key = cacheKey(locale: locale, dateStyle: dateStyle, timeStyle: timeStyle)
        return getCachedFormatter(withKey: key) { formatter in
            formatter.dateStyle = dateStyle
            formatter.timeStyle = timeStyle
            formatter.locale = locale ?? Locale.current
        }
    }

    /// Gets a formatter configured with a custom format string
    /// - Parameters:
    ///   - format: The format string to use
    ///   - locale: Optional locale (defaults to current)
    /// - Returns: Configured DateFormatter
    private func getCustomFormatter(format: String, locale: Locale? = nil) -> DateFormatter {
        let key = cacheKey(locale: locale, format: format)
        return getCachedFormatter(withKey: key) { formatter in
            formatter.dateFormat = format
            formatter.locale = locale ?? Locale.current
        }
    }
}

// MARK: - Format Styles

extension DateFormatting {
    /// Defines the style of date format
    public enum DateStyle {
        case short  // UK: "31/12", US: "12/31", CN: "12-31"
        case medium  // UK/US: "31 Dec", CN: "12月31日"
        case long  // UK/US: "31 December 2024", CN: "2024年12月31日"
        case custom(String)  // Custom format pattern (using DateFormatter patterns)
    }

    /// Defines the style of time format
    public enum TimeStyle {
        case timeOnly  // "14:30"
        case timeWithDate  // UK: "31 Dec 14:30", CN: "12月31日 14:30"
        case timeRange  // "14:30 - 15:30"
        case timeRangeWithDate  // UK: "31 Dec 14:30 - 15:30", CN: "12月31日 14:30 - 15:30"
        case timeRangeCrossDay  // UK: "22:00 - 31 Dec 02:00", CN: "22:00 - 12月31日 02:00"
    }

    /// Defines the style of weekday format
    public enum WeekdayStyle {
        case full  // "Monday", "星期一", "Montag"
        case abbreviated  // "Mon", "周一", "Mo"
        case standalone  // For languages that have different forms when the weekday is used alone
    }
}

// MARK: - Interval Type

extension DateFormatting {
    /// Defines the type of interval for date range formatting
    /// Used for billing cycles and consumption analysis
    public enum IntervalType {
        case daily  // Single day: "24 Jan 2025"
        case weekly  // Week range: "20 Jan - 26 Jan 2025" or "31 Dec 2024 - 5 Jan 2025"
        case monthly  // Month range based on billing day
        case quarterly  // Quarter range based on billing day
        case custom(Calendar.Component)  // Custom calendar component based range
    }
}

// MARK: - Public Interface

extension DateFormatting {
    // MARK: - Time Formatting

    /// Formats a single time point with optional date context
    /// - Parameters:
    ///   - date: The date/time to format
    ///   - referenceDate: Date used to determine if the time is "today" (defaults to current date)
    ///   - locale: Target locale for formatting (defaults to system locale)
    /// - Returns: Formatted time string in the locale's preferred format
    public func formatTime(_ date: Date, referenceDate: Date? = nil, locale: Locale? = nil)
        -> String
    {
        let reference = referenceDate ?? Date()

        if isToday(date, relativeTo: reference) {
            return formatTimeOnly(date, locale: locale)
        } else {
            return formatDateWithTime(date, locale: locale)
        }
    }

    /// Formats a time range with smart date context
    /// - Parameters:
    ///   - from: Start date/time
    ///   - to: End date/time
    ///   - referenceDate: Date used to determine if the range is "today" (defaults to current date)
    ///   - locale: Target locale for formatting (defaults to system locale)
    /// - Returns: Formatted time range string with appropriate date context
    public func formatTimeRange(
        from: Date, to: Date,
        referenceDate: Date? = nil,
        locale: Locale? = nil
    ) -> String {
        let reference = referenceDate ?? Date()

        if areSameDay(from, to) {
            if isToday(from, relativeTo: reference) {
                return
                    "\(formatTimeOnly(from, locale: locale)) - \(formatTimeOnly(to, locale: locale))"
            } else {
                return
                    "\(formatDateOnly(from, locale: locale)) \(formatTimeOnly(from, locale: locale)) - \(formatTimeOnly(to, locale: locale))"
            }
        } else {
            if isToday(from, relativeTo: reference) {
                return
                    "\(formatTimeOnly(from, locale: locale)) - \(formatDateWithTime(to, locale: locale))"
            } else if isToday(to, relativeTo: reference) {
                return
                    "\(formatDateWithTime(from, locale: locale)) - \(formatDateWithTime(to, locale: locale))"
            } else {
                return
                    "\(formatDateWithTime(from, locale: locale)) - \(formatDateWithTime(to, locale: locale))"
            }
        }
    }

    // MARK: - Private Time Formatting Helpers

    /// Formats time only in 24-hour format (HH:mm)
    private func formatTimeOnly(_ date: Date, locale: Locale? = nil) -> String {
        let key = cacheKey(locale: locale, format: "HH:mm")
        return getCachedFormatter(withKey: key) { formatter in
            formatter.dateFormat = "HH:mm"
            formatter.locale = locale ?? Locale.current
        }.string(from: date)
    }

    /// Formats date only in short format (d MMM)
    private func formatDateOnly(_ date: Date, locale: Locale? = nil) -> String {
        let key = cacheKey(locale: locale, format: "d MMM")
        return getCachedFormatter(withKey: key) { formatter in
            formatter.dateFormat = "d MMM"
            formatter.locale = locale ?? Locale.current
        }.string(from: date)
    }

    /// Formats date with time (d MMM HH:mm)
    private func formatDateWithTime(_ date: Date, locale: Locale? = nil) -> String {
        let key = cacheKey(locale: locale, format: "d MMM HH:mm")
        return getCachedFormatter(withKey: key) { formatter in
            formatter.dateFormat = "d MMM HH:mm"
            formatter.locale = locale ?? Locale.current
        }.string(from: date)
    }

    /// Checks if two dates are in the same day
    private func areSameDay(_ date1: Date, _ date2: Date) -> Bool {
        return calendar.isDate(date1, inSameDayAs: date2)
    }

    /// Checks if a date is today relative to a reference date
    private func isToday(_ date: Date, relativeTo reference: Date) -> Bool {
        return calendar.isDate(date, inSameDayAs: reference)
    }

    // MARK: - Date Formatting

    /// Formats a date (without time) in various styles
    /// - Parameters:
    ///   - date: The date to format
    ///   - style: The date style (short, medium, long, custom)
    ///   - locale: Target locale for formatting (defaults to system locale)
    /// - Returns: Formatted date string in the locale's preferred format
    public func formatDate(_ date: Date, style: DateStyle, locale: Locale? = nil) -> String {
        // TODO: Implementation
        return ""
    }

    // MARK: - Interval Formatting

    /// Formats a date interval based on billing cycles
    /// - Parameters:
    ///   - date: Reference date within the desired interval
    ///   - type: The interval type (daily, weekly, monthly, quarterly, custom)
    ///   - billingDay: The billing cycle start day (1-28)
    ///   - locale: Target locale for formatting (defaults to system locale)
    /// - Returns: Formatted interval string showing the full period
    public func formatInterval(
        _ date: Date, type: IntervalType, billingDay: Int = 1, locale: Locale? = nil
    ) -> String {
        // TODO: Implementation
        return ""
    }

    /// Formats a custom date range
    /// - Parameters:
    ///   - from: Start date
    ///   - to: End date
    ///   - style: The date style for formatting components
    ///   - locale: Target locale for formatting (defaults to system locale)
    /// - Returns: Formatted date range string (handles same year and cross-year cases)
    public func formatDateRange(from: Date, to: Date, style: DateStyle, locale: Locale? = nil)
        -> String
    {
        // TODO: Implementation
        return ""
    }

    // MARK: - Weekday Formatting

    /// Formats a weekday name based on the given date
    /// - Parameters:
    ///   - date: The date to extract weekday from
    ///   - style: The weekday style (full, abbreviated, standalone)
    ///   - locale: Target locale for formatting (defaults to system locale)
    /// - Returns: Formatted weekday name in the locale's preferred format
    public func formatWeekday(_ date: Date, style: WeekdayStyle, locale: Locale? = nil) -> String {
        // TODO: Implementation
        return ""
    }

    /// Gets the localized name of a weekday (1 = Sunday, 7 = Saturday)
    /// - Parameters:
    ///   - weekday: The weekday number (1-7)
    ///   - style: The weekday style (full, abbreviated, standalone)
    ///   - locale: Target locale for formatting (defaults to system locale)
    /// - Returns: Formatted weekday name in the locale's preferred format
    public func weekdayName(_ weekday: Int, style: WeekdayStyle, locale: Locale? = nil) -> String {
        // TODO: Implementation
        return ""
    }
}
