//
//  Octopus_HelperWidgets.swift
//  Octopus_HelperWidgets
//
//  Created by James To on 31/12/2024.
//

import AppIntents
import Charts
import CoreData
import OctopusHelperShared
import SwiftUI
import WidgetKit

/// Set to true to enable debug logging in the widget
// fileprivate let isDebugLoggingEnabled = false

/// Helper function for debug logging
// fileprivate func debugLog(_ message: String, function: String = #function) {
//     guard isDebugLoggingEnabled else { return }
//     print("WIDGET DEBUG [\(function)]: \(message)")
// }

// Provide a stable string ID for each NSManagedObject (RateEntity).
extension NSManagedObject {
    /// Returns the existing `id` attribute, or a fallback UUID string if missing.
    var idString: String {
        (value(forKey: "id") as? String)
            ?? {
                // If somehow 'id' was never set, generate a fallback here.
                let generated = UUID().uuidString
                return generated
            }()
    }
}

// MARK: - Timeline Provider
final class OctopusWidgetProvider: NSObject, AppIntentTimelineProvider {

    // MARK: - Dependencies
    private var sharedDefaults: UserDefaults? {
        UserDefaults(suiteName: "group.com.jamesto.octopus-agile-helper")
    }

    // Add shared settings manager
    private var chartSettings: InteractiveChartSettings {
        if let data = sharedDefaults?.data(forKey: "MyChartSettings"),
            let decoded = try? JSONDecoder().decode(InteractiveChartSettings.self, from: data)
        {
            return decoded
        }
        return .default
    }

    // Add cache reference
    private var cache: AgileRateWidgetCache {
        AgileRateWidgetCache.shared
    }

    // MARK: - Public Entry Points
    override init() {
        super.init()

        // Initialize cache with current tariff code
        let userSettings = readSettings()
        DebugLogger.debug(
            "Initializing with tariff code: \(userSettings.agileCode)", component: .widget)
        Task {
            try? await cache.widgetFetchAndCacheRates(tariffCode: userSettings.agileCode)
        }
    }

    func placeholder(in context: Context) -> SimpleEntry {
        DebugLogger.debug("Creating placeholder entry", component: .widget)
        let userSettings = readSettings()

        return SimpleEntry(
            date: .now,
            configuration: ConfigurationAppIntent(),
            rates: [],
            settings: (
                showRatesInPounds: userSettings.showRatesInPounds,
                showRatesWithVAT: userSettings.showRatesWithVAT,
                language: userSettings.language,
                agileCode: userSettings.agileCode
            ),
            chartSettings: chartSettings
        )
    }

    func snapshot(for configuration: ConfigurationAppIntent, in context: Context) async
        -> SimpleEntry
    {
        DebugLogger.debug("Creating snapshot", component: .widget)
        let userSettings = readSettings()

        // Use widgetFetchAndCacheRates to get data (will use cache if sufficient)
        do {
            DebugLogger.debug(
                "Fetching rates for snapshot with tariff: \(userSettings.agileCode)",
                component: .widget)
            let rates = try await cache.widgetFetchAndCacheRates(tariffCode: userSettings.agileCode)
            DebugLogger.debug("Got \(rates.count) rates for snapshot", component: .widget)
            return SimpleEntry(
                date: .now,
                configuration: configuration,
                rates: rates,
                settings: (
                    showRatesInPounds: userSettings.showRatesInPounds,
                    showRatesWithVAT: userSettings.showRatesWithVAT,
                    language: userSettings.language,
                    agileCode: userSettings.agileCode
                ),
                chartSettings: chartSettings
            )
        } catch {
            DebugLogger.debug("Error fetching rates for snapshot: \(error)", component: .widget)
            return SimpleEntry(
                date: .now,
                configuration: configuration,
                rates: [],
                settings: (
                    showRatesInPounds: userSettings.showRatesInPounds,
                    showRatesWithVAT: userSettings.showRatesWithVAT,
                    language: userSettings.language,
                    agileCode: userSettings.agileCode
                ),
                chartSettings: chartSettings
            )
        }
    }

    func timeline(for configuration: ConfigurationAppIntent, in context: Context) async -> Timeline<
        SimpleEntry
    > {
        DebugLogger.debug("Building timeline", component: .widget)
        do {
            let userSettings = readSettings()
            DebugLogger.debug(
                "Fetching rates for timeline with tariff: \(userSettings.agileCode)",
                component: .widget)

            // Use widgetFetchAndCacheRates to get data (will use cache if sufficient)
            let rates = try await cache.widgetFetchAndCacheRates(tariffCode: userSettings.agileCode)
            DebugLogger.debug("Got \(rates.count) rates for timeline", component: .widget)

            // Build timeline entries using the rate data
            let now = Date()
            let entries = buildTimelineEntries(
                rates: rates,
                configuration: configuration,
                now: now,
                agileCode: userSettings.agileCode
            )
            DebugLogger.debug("Built \(entries.count) timeline entries", component: .widget)

            // Refresh at the next half-hour boundary or when settings change
            let nextRefresh = nextHalfHour(from: now)
            DebugLogger.debug("Next refresh at \(nextRefresh.formatted())", component: .widget)

            // Add observer for settings changes
            NotificationCenter.default.addObserver(
                forName: UserDefaults.didChangeNotification,
                object: sharedDefaults,
                queue: .main
            ) { _ in
                WidgetCenter.shared.reloadAllTimelines()
            }

            return Timeline(entries: entries, policy: .after(nextRefresh))
        } catch {
            DebugLogger.debug("Error building timeline: \(error)", component: .widget)
            DebugLogger.debug("Will retry in 15 minutes", component: .widget)
            // For all errors, retry in 15 minutes
            return Timeline(
                entries: [buildErrorEntry(configuration: configuration)],
                policy: .after(Date().addingTimeInterval(15 * 60))
            )
        }
    }

    private func buildErrorEntry(configuration: ConfigurationAppIntent) -> SimpleEntry {
        let userSettings = readSettings()
        return SimpleEntry(
            date: .now,
            configuration: configuration,
            rates: [],
            settings: (
                showRatesInPounds: userSettings.showRatesInPounds,
                showRatesWithVAT: userSettings.showRatesWithVAT,
                language: userSettings.language,
                agileCode: userSettings.agileCode
            ),
            chartSettings: chartSettings
        )
    }

    // MARK: - Private Helpers

    /// Attempts to read global settings from shared container. Fallback to minimal keys if needed.
    private func readSettings() -> (
        showRatesInPounds: Bool, showRatesWithVAT: Bool, language: String, agileCode: String
    ) {
        let defaults = sharedDefaults
        if let data = defaults?.data(forKey: "user_settings"),
            let decoded = try? JSONDecoder().decode(GlobalSettings.self, from: data)
        {
            return (
                showRatesInPounds: decoded.showRatesInPounds,
                showRatesWithVAT: decoded.showRatesWithVAT,
                language: decoded.selectedLanguage.rawValue,
                agileCode: decoded.currentAgileCode
            )
        }

        // Fallback to individual keys
        return (
            showRatesInPounds: defaults?.bool(forKey: "show_rates_in_pounds") ?? false,
            showRatesWithVAT: defaults?.bool(forKey: "show_rates_with_vat") ?? true,
            language: defaults?.string(forKey: "selected_language") ?? "en",
            agileCode: defaults?.string(forKey: "current_agile_code") ?? ""
        )
    }

    /// Build timeline entries from now up to 4 hours ahead in half-hour intervals (+/-2m).
    private func buildTimelineEntries(
        rates: [NSManagedObject],
        configuration: ConfigurationAppIntent,
        now: Date,
        agileCode: String
    ) -> [SimpleEntry] {
        let refreshSlots = computeRefreshSlots(from: now)
        let userSettings = readSettings()

        return refreshSlots.map { date in
            SimpleEntry(
                date: date,
                configuration: configuration,
                rates: rates,
                settings: (
                    showRatesInPounds: userSettings.showRatesInPounds,
                    showRatesWithVAT: userSettings.showRatesWithVAT,
                    language: userSettings.language,
                    agileCode: agileCode
                ),
                chartSettings: chartSettings
            )
        }
    }

    /// Compute next half-hour intervals (±2 min) to create timeline entry points.
    private func computeRefreshSlots(from initial: Date) -> [Date] {
        var result = [initial]
        let cal = Calendar.current
        var cursor = initial

        for _ in 0..<8 {  // ~4 hours
            cursor = nextHalfHour(from: cursor)
            // 2 min before
            if let prev2 = cal.date(byAdding: .minute, value: -2, to: cursor) {
                result.append(prev2)
            }
            // exact half-hour
            result.append(cursor)
            // 2 min after
            if let plus2 = cal.date(byAdding: .minute, value: 2, to: cursor) {
                result.append(plus2)
            }
        }
        return result.sorted()
    }

    /// Helper to snap the next half-hour boundary from a given date.
    private func nextHalfHour(from date: Date) -> Date {
        let comps = Calendar.current.dateComponents(
            [.year, .month, .day, .hour, .minute], from: date)
        guard let hr = comps.hour, let min = comps.minute else {
            return date.addingTimeInterval(30 * 60)
        }
        let nextMin = min >= 30 ? 0 : 30
        var targetComps = DateComponents(
            year: comps.year, month: comps.month, day: comps.day,
            hour: nextMin == 0 ? hr + 1 : hr, minute: nextMin
        )
        targetComps.second = 0
        return Calendar.current.date(from: targetComps) ?? date.addingTimeInterval(30 * 60)
    }
}

// MARK: - Timeline Entry
struct SimpleEntry: TimelineEntry {
    let date: Date
    let configuration: ConfigurationAppIntent
    let rates: [NSManagedObject]
    let settings:
        (showRatesInPounds: Bool, showRatesWithVAT: Bool, language: String, agileCode: String)
    let chartSettings: InteractiveChartSettings
}

// MARK: - The Widget UI
/// Displays the current Agile rate, plus highest & lowest upcoming times.
@available(iOS 17.0, *)
struct CurrentRateWidget: View {
    let rates: [NSManagedObject]
    let settings:
        (showRatesInPounds: Bool, showRatesWithVAT: Bool, language: String, agileCode: String)
    let chartSettings: InteractiveChartSettings

    @Environment(\.widgetFamily) var family

    // Add computed property for best time ranges
    private var bestTimeRanges: [(Date, Date)] {
        let widgetVM = RatesViewModel(
            widgetRates: rates.compactMap { $0 },
            productCode: settings.agileCode
        )
        let avgRates = widgetVM.getLowestAverages(
            productCode: settings.agileCode,
            hours: chartSettings.customAverageHours,
            maxCount: chartSettings.maxListCount
        )
        let windows = avgRates.map { rate in
            AveragedRateWindow(
                average: rate.average,
                start: rate.start,
                end: rate.end
            )
        }
        let raw = windows.map { ($0.start, $0.end) }
        let merged = mergeWindows(raw)

        // Filter and clip ranges to chart's visible range
        guard let chartStart = filteredRatesForChart.first?.value(forKey: "valid_from") as? Date,
            let chartEnd = filteredRatesForChart.last?.value(forKey: "valid_to") as? Date
        else {
            return []
        }

        return merged.compactMap { window -> (Date, Date)? in
            // Skip windows completely outside chart range
            guard window.0 <= chartEnd && window.1 >= chartStart else {
                return nil
            }

            // Clip window to chart range
            let clippedStart = max(window.0, chartStart)
            let clippedEnd = min(window.1, chartEnd)

            return (clippedStart, clippedEnd)
        }
    }

    /// The "best" time windows adjusted for rendering (with epsilon shift)
    private var bestTimeRangesRender: [(Date, Date)] {
        bestTimeRanges.map { (s, e) -> (Date, Date) in
            let adjustedStart = isExactlyOnHalfHour(s) ? s.addingTimeInterval(-900) : s
            let adjustedEnd = isExactlyOnHalfHour(e) ? e.addingTimeInterval(-900) : e
            return (adjustedStart, adjustedEnd)
        }
    }

    /// Helper to check if a date is exactly on a half hour
    private func isExactlyOnHalfHour(_ date: Date) -> Bool {
        let calendar = Calendar.current
        let comps = calendar.dateComponents([.minute, .second, .nanosecond], from: date)
        let minute = comps.minute ?? 0
        return (minute == 0 || minute == 30) && (comps.second ?? 0) == 0
            && (comps.nanosecond ?? 0) == 0
    }

    // Add helper function for merging windows
    private func mergeWindows(_ input: [(Date, Date)]) -> [(Date, Date)] {
        guard !input.isEmpty else { return [] }
        let sorted = input.sorted { $0.0 < $1.0 }
        var result = [(Date, Date)]()
        var current = sorted[0]

        for window in sorted.dropFirst() {
            if window.0 <= current.1 {
                // Overlapping or adjacent windows - merge them
                current.1 = max(current.1, window.1)
            } else {
                // Gap between windows - add the current one and start a new one
                result.append(current)
                current = window
            }
        }
        result.append(current)
        return result
    }

    // Add missing computed properties and functions
    private var filteredRatesForChart: [NSManagedObject] {
        let now = Date()
        let sortedRates = rates.sorted {
            ($0.value(forKey: "valid_from") as? Date ?? .distantPast)
                < ($1.value(forKey: "valid_from") as? Date ?? .distantPast)
        }

        // Split into past and future
        let pastRates =
            sortedRates
            .filter { ($0.value(forKey: "valid_from") as? Date ?? .distantFuture) <= now }
            .suffix(42)  // Take last 42 past rates (21 hours)

        let futureRates =
            sortedRates
            .filter { ($0.value(forKey: "valid_from") as? Date ?? .distantPast) > now }
            .prefix(33)  // Take first 33 future rates (16.5 hours)

        // Combine and maintain sort
        return Array(pastRates) + Array(futureRates)
    }

    /// Y-axis range for chart
    private var chartYRange: (Double, Double) {
        let prices = filteredRatesForChart.map(getRateValue)
        guard !prices.isEmpty else { return (0, 10) }
        let minVal = min(0, (prices.min() ?? 0) - 2)
        let maxVal = (prices.max() ?? 0) + 2
        return (minVal, maxVal)
    }

    private var xDomain: ClosedRange<Date> {
        guard let earliest = filteredRatesForChart.first?.value(forKey: "valid_from") as? Date,
            let lastRate = filteredRatesForChart.last,
            let domainEnd = (lastRate.value(forKey: "valid_to") as? Date)
                ?? ((lastRate.value(forKey: "valid_from") as? Date)?.addingTimeInterval(1800))
        else {
            return Date()...(Date().addingTimeInterval(3600))
        }
        return earliest...domainEnd
    }

    private func findCurrentRatePeriod(_ date: Date) -> (start: Date, price: Double)? {
        guard
            let rate = filteredRatesForChart.first(where: { r in
                guard let start = r.value(forKey: "valid_from") as? Date,
                    let end = r.value(forKey: "valid_to") as? Date
                else { return false }
                return date >= start && date < end
            })
        else {
            return nil
        }
        if let start = rate.value(forKey: "valid_from") as? Date {
            return (start, getRateValue(rate))
        }
        return nil
    }

    private var barWidth: Double {
        let maxPossibleBars = 65.0  // Upper bound
        let currentBars = Double(filteredRatesForChart.count)
        let baseWidthPerBar = 5.0
        let barGapRatio = 0.7  // 70% bar, 30% gap
        let totalChunk = (maxPossibleBars / currentBars) * baseWidthPerBar
        return totalChunk * barGapRatio
    }

    private func formatRate(_ raw: Double) -> String {
        if settings.showRatesInPounds {
            // Format with 2 decimals for pounds
            let formatted = String(format: "£%.3f", raw / 100.0)
            return "\(formatted)/kWh"
        } else {
            // Use the standard RateFormatting for pence
            return RateFormatting.formatRate(
                raw,
                showRatesInPounds: settings.showRatesInPounds,
                showRatesWithVAT: settings.showRatesWithVAT
            )
        }
    }

    var body: some View {
        switch family {
        case .systemSmall:
            systemSmallView
        case .systemMedium:
            systemMediumView
        case .accessoryCircular:
            circularView
        case .accessoryInline:
            inlineView
        default:
            systemSmallView
        }
    }

    // Original system small widget layout
    private var systemSmallView: some View {
        ZStack {
            Theme.mainBackground.ignoresSafeArea()

            if let currentRate = findCurrentRate() {
                contentForCurrent(rate: currentRate)
            } else {
                noCurrentRateView
            }
        }
        .id("\(settings.showRatesInPounds)_\(settings.language)")
        .environment(\.locale, Locale(identifier: settings.language))
    }

    // Circular lock screen widget
    private var circularView: some View {
        Group {
            if let currentRate = findCurrentRate() {
                let widgetVM = RatesViewModel(
                    widgetRates: rates.compactMap { $0 }, productCode: settings.agileCode)
                let currentValue = getRateValue(currentRate)
                let lowestRate = widgetVM.lowestUpcomingRate(productCode: settings.agileCode)
                let lowestValue = lowestRate != nil ? getRateValue(lowestRate!) : currentValue
                let highestRate = widgetVM.highestUpcomingRate(productCode: settings.agileCode)
                let highestValue = highestRate != nil ? getRateValue(highestRate!) : currentValue

                // Normalize current value to 0-1 range
                let minRate = min(currentValue, lowestValue)
                let maxRate = max(currentValue, highestValue)
                let normalizedValue = (currentValue - minRate) / (maxRate - minRate)

                Gauge(value: normalizedValue, in: 0...1) {
                    Image(systemName: "bolt.fill")
                } currentValueLabel: {
                    // Format without /kWh and fewer decimals for circular view
                    Text(
                        settings.showRatesInPounds
                            ? String(format: "£%.3f", currentValue / 100.0)
                            : String(format: "%.2fp", currentValue)
                    )
                    .font(Theme.mainFont())
                    .foregroundColor(RateColor.getColor(for: currentRate, allRates: rates))
                }
                .gaugeStyle(.accessoryCircular)
                .tint(RateColor.getColor(for: currentRate, allRates: rates))
            } else {
                Gauge(value: 0, in: 0...1) {
                    Image(systemName: "bolt.fill")
                } currentValueLabel: {
                    Text("--")
                        .font(Theme.mainFont())
                }
                .gaugeStyle(.accessoryCircular)
                .tint(.gray)
            }
        }
    }

    // Inline lock screen widget
    private var inlineView: some View {
        if let currentRate = findCurrentRate() {
            Label {
                Text("\(formatRate(getRateValue(currentRate)))")
            } icon: {
                Image(systemName: "bolt.fill")
            }
        } else {
            Label {
                Text("No current rate")
            } icon: {
                Image(systemName: "bolt.fill")
            }
        }
    }

    // MARK: - System Medium View
    /// A medium widget layout:
    /// - Left side: current rate, highest, lowest (same as systemSmall)
    /// - Right side: a mini chart with best-time background + "now" vertical line
    @ViewBuilder
    private var systemMediumView: some View {
        GeometryReader { geometry in
            ZStack {
                // 1) Background chart spanning full width
                chartView
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .padding(.top, 8)
                    .padding(.leading, 0)
                    .padding(.trailing, 1)
                    .padding(.bottom, -1)
                    .ignoresSafeArea()

                // 2) Left side content (same as systemSmall)
                HStack {
                    if let currentRate = findCurrentRate() {
                        contentForCurrent(rate: currentRate)
                            .frame(width: geometry.size.width * 0.48)
                    } else {
                        noCurrentRateView
                            .frame(width: geometry.size.width * 0.48)
                    }
                    Spacer()
                }
            }
        }
        .background(Theme.mainBackground)
        .id("\(settings.showRatesInPounds)_\(settings.language)")
        .environment(\.locale, Locale(identifier: settings.language))
    }

    /// Helper to snap time to nearest half hour
    private func snapToHalfHour(_ date: Date) -> Date {
        let calendar = Calendar.current
        let components = calendar.dateComponents([.year, .month, .day, .hour, .minute], from: date)
        let minute = components.minute ?? 0
        let snappedMinute = minute >= 30 ? 30 : 0

        var newComponents = DateComponents()
        newComponents.year = components.year
        newComponents.month = components.month
        newComponents.day = components.day
        newComponents.hour = components.hour
        newComponents.minute = snappedMinute
        newComponents.second = 0

        return calendar.date(from: newComponents) ?? date
    }

    /// The mini chart with best-time background + 'now' line
    private var chartView: some View {
        let data = filteredRatesForChart
        let now = Date()
        // Snap nowX to the current period's start time
        let nowX =
            if let currentPeriod = findCurrentRatePeriod(now) {
                currentPeriod.start
            } else {
                snapToHalfHour(now)
            }
        let (minVal, maxVal) = chartYRange
        let barWidth = computeDynamicBarWidth(rateCount: data.count)

        return Chart {
            chartBackgroundLayers(minVal: minVal, maxVal: maxVal, nowX: nowX)
            chartBars(data: data, barWidth: barWidth)
            chartNowBadge(nowX: nowX)
        }
        .chartYScale(domain: minVal...maxVal)
        .chartXAxis {
            AxisMarks(preset: .extended, values: .stride(by: 7200))
        }
        .chartYAxis(.hidden)
        .chartPlotStyle { plotContent in
            plotContent
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .padding(.top, -16)
                .padding(.leading, -16)
                .padding(.trailing, -16)
                .padding(.bottom, -16)
        }
        .padding(0)
    }

    @ChartContentBuilder
    private func chartBackgroundLayers(minVal: Double, maxVal: Double, nowX: Date)
        -> some ChartContent
    {
        // 0) Best time ranges (behind everything)
        ForEach(bestTimeRangesRender, id: \.0) { window in
            RectangleMark(
                xStart: .value("Window Start", window.0),
                xEnd: .value("Window End", window.1),
                yStart: .value("Min", minVal - 50),
                yEnd: .value("Max", maxVal + 50)
            )
            .foregroundStyle(Theme.mainColor.opacity(0.2))
        }

        // 1) "Now" vertical line (behind bars)
        RuleMark(
            x: .value("Now", nowX),
            yStart: .value("Start", minVal - 20),
            yEnd: .value("End", maxVal + 20)
        )
        .foregroundStyle(Theme.secondaryColor)
        .lineStyle(StrokeStyle(lineWidth: 2))

        // 2) Zero baseline (for negative values)
        RuleMark(y: .value("Zero", 0))
            .foregroundStyle(Theme.secondaryTextColor.opacity(0.3))
            .lineStyle(StrokeStyle(lineWidth: 1))
    }

    @ChartContentBuilder
    private func chartBars(data: [NSManagedObject], barWidth: Double) -> some ChartContent {
        ForEach(
            Array(data.enumerated()),
            id: \.element.idString
        ) { index, rate in

            if let t = rate.value(forKey: "valid_from") as? Date {
                let baseColor = getRateValue(rate) < 0 ? Theme.secondaryColor : Theme.mainColor
                let rawProgress = Double(index) / Double(max(1, data.count - 1))
                let isToday = Calendar.current.isDate(t, inSameDayAs: Date())

                // Keep first 30% as background color, then gradient over remaining 70%
                let colorProgress =
                    if rawProgress < 0.3 {
                        0.0  // First 30% are pure background
                    } else {
                        // Map 0.3->1.0 range to 0.0->1.0
                        (rawProgress - 0.3) / 0.7
                    }

                // Fixed opacity based on whether it's today or not
                let barOpacity = isToday ? 1.2 : 1.0

                // Blend between background and base color based on progress
                let blendedColor = Color.interpolate(
                    from: Theme.mainBackground,
                    to: baseColor,
                    progress: colorProgress
                )

                BarMark(
                    x: .value("Time", t),
                    y: .value("Rate", getRateValue(rate)),
                    width: .fixed(barWidth)
                )
                .cornerRadius(3)
                .foregroundStyle(blendedColor.opacity(barOpacity))
            }
        }
    }

    @ChartContentBuilder
    private func chartNowBadge(nowX: Date) -> some ChartContent {
        RuleMark(x: .value("Now", nowX))
            .opacity(0)  // Invisible rule mark just for the annotation
            .annotation(position: .top) {
                Text(LocalizedStringKey("NOW"))
                    .font(.system(size: 10).weight(.bold))
                    .foregroundColor(.white)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(
                        Capsule()
                            .fill(Theme.secondaryColor)
                            .frame(width: 32)
                    )
                    .offset(y: 45)
            }
            .offset(y: -16)
    }

    /// Compute dynamic bar width with gaps
    private func computeDynamicBarWidth(rateCount: Int) -> Double {
        let maxPossibleBars = 70.0  // Upper bound, same as InteractiveLineChartCardView
        let currentBars = Double(rateCount)
        let baseWidthPerBar = 5.0
        let barGapRatio = 0.8  // 70% bar, 30% gap
        let totalChunk = (maxPossibleBars / currentBars) * baseWidthPerBar
        return totalChunk * barGapRatio
    }
}

// MARK: - Subviews for CurrentRateWidget
extension CurrentRateWidget {

    private func contentForCurrent(rate: NSManagedObject) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            topLabel(title: "Agile Current", icon: "clock")

            // Show large current rate
            rateView(
                value: getRateValue(rate), color: RateColor.getColor(for: rate, allRates: rates),
                font: Theme.mainFont())

            // "Until HH:mm"
            if let valid_to = rate.value(forKey: "valid_to") as? Date {
                Text("Until \(formatTime(valid_to))")
                    .font(.caption2)
                    .foregroundColor(Theme.secondaryTextColor)
            }

            Spacer(minLength: 8)
            upcomingRatesView
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
    }

    private var noCurrentRateView: some View {
        VStack(alignment: .leading, spacing: 4) {
            topLabel(title: "Agile Current", icon: "clock")
            Text("No current rate")
                .font(Theme.mainFont2())
                .foregroundColor(Theme.mainTextColor)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
    }

    /// Build the small "lowest" & "highest" row
    private var upcomingRatesView: some View {
        VStack(alignment: .leading, spacing: 2) {
            if let (lowestRate, startTime) = lowestUpcoming() {
                HStack(alignment: .firstTextBaseline, spacing: 2) {
                    Image(systemName: "chevron.down")
                        .font(.caption)
                        .foregroundColor(Theme.icon)
                    rateView(
                        value: getRateValue(lowestRate),
                        color: RateColor.getColor(for: lowestRate, allRates: rates),
                        font: family == .systemSmall ? Theme.titleFont() : Theme.mainFont()
                    )
                    Spacer(minLength: 0)
                    HStack(spacing: 0) {
                        Text(formatTime(startTime))
                            .font(.caption2)
                        if !Calendar.current.isDate(startTime, inSameDayAs: Date()) {
                            Text("N")
                                .font(.system(size: 8))
                                .baselineOffset(2)
                        }
                    }
                    .foregroundColor(Theme.mainTextColor)
                }
            }
            if let (highestRate, startTime) = highestUpcoming() {
                HStack(alignment: .firstTextBaseline, spacing: 2) {
                    Image(systemName: "chevron.up")
                        .font(.caption)
                        .foregroundColor(Theme.icon)
                    rateView(
                        value: getRateValue(highestRate),
                        color: RateColor.getColor(for: highestRate, allRates: rates),
                        font: family == .systemSmall ? Theme.titleFont() : Theme.mainFont()
                    )
                    Spacer(minLength: 0)
                    HStack(spacing: 0) {
                        Text(formatTime(startTime))
                            .font(.caption2)
                        if !Calendar.current.isDate(startTime, inSameDayAs: Date()) {
                            Text("N")
                                .font(.system(size: 8))
                                .baselineOffset(2)
                        }
                    }
                    .foregroundColor(Theme.mainTextColor)
                }
            }
        }
    }

    private func topLabel(title: String, icon: String) -> some View {
        HStack {
            if icon == "clock" {
                // Use our custom clock icon with current time
                let currentTime = Date()
                Image(ClockModel.iconName(for: currentTime))
                    .renderingMode(.template)
                    .resizable()
                    .scaledToFit()
                    .frame(width: 20, height: 20)
                    .foregroundColor(Theme.icon)
            } else {
                Image(systemName: icon)
                    .foregroundColor(Theme.icon)
                    .font(Theme.subFont())
            }
            Text(title)
                .font(Theme.subFont())
                .foregroundColor(Theme.secondaryTextColor)
        }
    }
}

// MARK: - Computations & Formatters
extension CurrentRateWidget {
    private func findCurrentRate() -> NSManagedObject? {
        rates.first { r in
            guard let from = r.value(forKey: "valid_from") as? Date,
                let to = r.value(forKey: "valid_to") as? Date
            else { return false }
            return (from <= Date() && to > Date())
        }
    }

    private func lowestUpcoming() -> (NSManagedObject, Date)? {
        let widgetVM = RatesViewModel(
            widgetRates: rates.compactMap { $0 }, productCode: settings.agileCode)
        if let item = widgetVM.lowestUpcomingRate(productCode: settings.agileCode),
            let from = item.value(forKey: "valid_from") as? Date
        {
            return (item, from)
        }
        return nil
    }

    private func highestUpcoming() -> (NSManagedObject, Date)? {
        let widgetVM = RatesViewModel(
            widgetRates: rates.compactMap { $0 }, productCode: settings.agileCode)
        if let item = widgetVM.highestUpcomingRate(productCode: settings.agileCode),
            let valid_from = item.value(forKey: "valid_from") as? Date
        {
            return (item, valid_from)
        }
        return nil
    }

    private func getRateValue(_ rate: NSManagedObject) -> Double {
        if settings.showRatesWithVAT {
            return rate.value(forKey: "value_including_vat") as? Double ?? 0
        } else {
            return rate.value(forKey: "value_excluding_vat") as? Double ?? 0
        }
    }

    private func rateView(value: Double, color: Color, font: Font) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 0) {
            let parts = formatRate(value).split(separator: "/")
            if parts.count > 0 {
                Text(String(parts[0]))
                    .font(font)
                    .foregroundColor(color)
                    .lineLimit(1)
                    .minimumScaleFactor(0.5)

                if parts.count > 1 {
                    Text("/\(parts[1])")
                        .font(.caption2)
                        .foregroundColor(Theme.secondaryTextColor)
                        .scaleEffect(0.8)
                }
            }
        }
    }

    private func formatTime(_ date: Date) -> String {
        let df = DateFormatter()
        df.dateFormat = "HH:mm"
        return df.string(from: date)
    }
}

// MARK: - Widget Definition
struct Octopus_HelperWidgets: Widget {
    let kind = "Octopus_HelperWidgets"

    var body: some WidgetConfiguration {
        AppIntentConfiguration(
            kind: kind,
            intent: ConfigurationAppIntent.self,
            provider: OctopusWidgetProvider()
        ) { entry in
            if #available(iOS 17.0, *) {
                CurrentRateWidget(
                    rates: entry.rates,
                    settings: entry.settings,
                    chartSettings: entry.chartSettings
                )
                .containerBackground(Theme.mainBackground, for: .widget)
            } else {
                CurrentRateWidget(
                    rates: entry.rates,
                    settings: entry.settings,
                    chartSettings: entry.chartSettings
                )
                .padding()
                .background(Theme.mainBackground)
            }
        }
        .configurationDisplayName("Octomiser")
        .description("Display the current Octopus Agile rate.")
        .supportedFamilies([
            .systemSmall,
            .systemMedium,
            .accessoryCircular,
            .accessoryInline,
        ])
    }
}

extension Color {
    static func interpolate(from: Color, to: Color, progress: Double) -> Color {
        let uiColor1 = UIColor(from)
        let uiColor2 = UIColor(to)

        var red1: CGFloat = 0
        var green1: CGFloat = 0
        var blue1: CGFloat = 0
        var alpha1: CGFloat = 0
        uiColor1.getRed(&red1, green: &green1, blue: &blue1, alpha: &alpha1)

        var red2: CGFloat = 0
        var green2: CGFloat = 0
        var blue2: CGFloat = 0
        var alpha2: CGFloat = 0
        uiColor2.getRed(&red2, green: &green2, blue: &blue2, alpha: &alpha2)

        let clampedProgress = min(1, max(0, progress))

        let red = red1 + (red2 - red1) * clampedProgress
        let green = green1 + (green2 - green1) * clampedProgress
        let blue = blue1 + (blue2 - blue1) * clampedProgress

        return Color(uiColor: UIColor(red: red, green: green, blue: blue, alpha: 1.0))
    }
}

struct AveragedRateWindow {
    let average: Double
    let start: Date
    let end: Date
}
