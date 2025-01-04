//
//  Octopus_HelperWidgets.swift
//  Octopus_HelperWidgets
//
//  Created by James To on 31/12/2024.
//

import AppIntents
import OctopusHelperShared
import SwiftUI
import WidgetKit
import Charts

// MARK: - Timeline Provider
final class OctopusWidgetProvider: NSObject, AppIntentTimelineProvider {

    // MARK: - Dependencies
    private var repository: RatesRepository {
        get async { await MainActor.run { RatesRepository.shared } }
    }
    private var sharedDefaults: UserDefaults? {
        UserDefaults(suiteName: "group.com.jamesto.OctopusHelper")
    }
    
    // MARK: - Public Entry Points
    override init() {
        super.init()
    }

    func placeholder(in context: Context) -> SimpleEntry {
        SimpleEntry(date: .now, configuration: ConfigurationAppIntent(), rates: [], settings: readSettings())
    }

    func snapshot(for configuration: ConfigurationAppIntent, in context: Context) async -> SimpleEntry {
        SimpleEntry(date: .now, configuration: configuration, rates: [], settings: readSettings())
    }
    
    func timeline(for configuration: ConfigurationAppIntent, in context: Context) async -> Timeline<SimpleEntry> {
        do {
            // 1) Update rates from the repository
            let repo = await repository
            try await repo.updateRates()
            var rates = try await repo.fetchAllRates()

            // 2) On first install or empty DB => direct fetch
            if rates.isEmpty {
                rates = try await directFetchAndSave()
            }

            // 3) Build timeline
            let now = Date()
            let entries = buildTimelineEntries(rates: rates, configuration: configuration, now: now)
            
            // 4) Force next refresh soon => immediate effect on user exit
            let nextRefresh = Date().addingTimeInterval(1)
            return Timeline(entries: entries, policy: .after(nextRefresh))

        } catch {
            // 5) On error, do a short retry timeline
            return buildErrorTimeline(configuration: configuration)
        }
    }

    // MARK: - Private Helpers

    /// Attempts to read global settings from shared container. Fallback to minimal keys if needed.
    private func readSettings() -> (postcode: String, showRatesInPounds: Bool, language: String) {
        let defaults = sharedDefaults
        if let data = defaults?.data(forKey: "user_settings"),
           let decoded = try? JSONDecoder().decode(GlobalSettings.self, from: data)
        {
            return (
                postcode: decoded.postcode,
                showRatesInPounds: decoded.showRatesInPounds,
                language: decoded.selectedLanguage.rawValue
            )
        }
        // Fallback if "user_settings" is missing
        return (
            postcode: defaults?.string(forKey: "selected_postcode") ?? "",
            showRatesInPounds: defaults?.bool(forKey: "show_rates_in_pounds") ?? false,
            language: defaults?.string(forKey: "selected_language") ?? "en"
        )
    }

    /// Directly fetches from API + saves to Core Data for first-time or fallback usage.
    private func directFetchAndSave() async throws -> [RateEntity] {
        let regionID = try await fetchRegionID()
        let rawRates = try await OctopusAPIClient.shared.fetchRates(regionID: regionID)
        let ctx = PersistenceController.shared.container.viewContext

        // Convert raw response to RateEntity
        let entities = rawRates.map { r -> RateEntity in
            let obj = RateEntity(context: ctx)
            obj.id = UUID().uuidString
            obj.validFrom = r.valid_from
            obj.validTo = r.valid_to
            obj.valueExcludingVAT = r.value_exc_vat
            obj.valueIncludingVAT = r.value_inc_vat
            return obj
        }
        if ctx.hasChanges { try ctx.save() }
        return entities
    }

    /// Obtain the region ID from user’s postcode, fallback to "H" if none.
    private func fetchRegionID() async throws -> String {
        let s = readSettings().postcode.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !s.isEmpty else { return "H" }
        return try await (await repository).fetchRegionID(for: s) ?? "H"
    }

    /// Build timeline entries from now up to 4 hours ahead in half-hour intervals (+/-2m).
    private func buildTimelineEntries(
        rates: [RateEntity],
        configuration: ConfigurationAppIntent,
        now: Date
    ) -> [SimpleEntry] {
        let refreshSlots = computeRefreshSlots(from: now)
        let userSettings = readSettings()
        
        return refreshSlots.map { date in
            SimpleEntry(date: date, configuration: configuration, rates: rates, settings: userSettings)
        }
    }

    /// If an error occurs, create a short timeline that tries again in 1 second.
    private func buildErrorTimeline(configuration: ConfigurationAppIntent) -> Timeline<SimpleEntry> {
        let now = Date()
        let userSettings = readSettings()
        let retryDate = now.addingTimeInterval(1)

        let entries = [
            SimpleEntry(
                date: now,
                configuration: configuration,
                rates: [],
                settings: userSettings
            ),
            SimpleEntry(
                date: retryDate,
                configuration: configuration,
                rates: [],
                settings: userSettings
            )
        ]
        return Timeline(entries: entries, policy: .after(retryDate))
    }

    /// Compute next half-hour intervals (±2 min) to create timeline entry points.
    private func computeRefreshSlots(from initial: Date) -> [Date] {
        var result = [initial]
        let cal = Calendar.current
        var cursor = initial

        for _ in 0..<8 { // ~4 hours
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
        let comps = Calendar.current.dateComponents([.year, .month, .day, .hour, .minute], from: date)
        guard let hr = comps.hour, let min = comps.minute else { return date.addingTimeInterval(30*60) }
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
    let rates: [RateEntity]
    let settings: (postcode: String, showRatesInPounds: Bool, language: String)
}

// MARK: - The Widget UI
/// Displays the current Agile rate, plus highest & lowest upcoming times.
@available(iOS 17.0, *)
struct CurrentRateWidget: View {
    let rates: [RateEntity]
    let settings: (postcode: String, showRatesInPounds: Bool, language: String)
    @Environment(\.widgetFamily) var family
    
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
                let upcomingRates = getUpcomingRates()
                if !upcomingRates.isEmpty {
                    let currentValue = currentRate.valueIncludingVAT
                    let minRate = min(currentValue, upcomingRates.first?.valueIncludingVAT ?? currentValue)
                    let maxRate = max(currentValue, upcomingRates.last?.valueIncludingVAT ?? currentValue)
                    
                    // Normalize current value to 0-1 range
                    let normalizedValue = (currentValue - minRate) / (maxRate - minRate)
                    
                    Gauge(value: normalizedValue, in: 0...1) {
                        Image(systemName: "bolt.fill")
                    } currentValueLabel: {
                        Text(formatRate(currentValue))
                            .font(.system(.body, design: .rounded))
                            .minimumScaleFactor(0.5)
                    }
                    .gaugeStyle(.accessoryCircular)
                    .tint(RateColor.getColor(for: currentRate, allRates: rates))
                } else {
                    // Fallback if no upcoming rates
                    Gauge(value: 0.5, in: 0...1) {
                        Image(systemName: "bolt.fill")
                    } currentValueLabel: {
                        Text(formatRate(currentRate.valueIncludingVAT))
                            .font(.system(.body, design: .rounded))
                            .minimumScaleFactor(0.5)
                    }
                    .gaugeStyle(.accessoryCircular)
                    .tint(RateColor.getColor(for: currentRate, allRates: rates))
                }
            } else {
                Gauge(value: 0, in: 0...1) {
                    Image(systemName: "bolt.fill")
                } currentValueLabel: {
                    Text("--")
                        .font(.system(.body, design: .rounded))
                }
                .gaugeStyle(.accessoryCircular)
                .tint(.gray)
            }
        }
    }
    
    // Rectangular lock screen widget
    private var rectangularView: some View {
        HStack {
            if let currentRate = findCurrentRate() {
                VStack(alignment: .leading) {
                    Text("Current Rate")
                        .font(.caption2)
                        .foregroundColor(.secondary)
                    HStack(alignment: .firstTextBaseline, spacing: 1) {
                        Text(formatRate(currentRate.valueIncludingVAT))
                            .font(.system(.body, design: .rounded))
                            .foregroundColor(RateColor.getColor(for: currentRate, allRates: rates))
                        Text("/kWh")
                            .font(.caption2)
                            .foregroundColor(.secondary)
                    }
                }
                Spacer()
                if let validTo = currentRate.validTo {
                    Text(formatTime(validTo))
                        .font(.caption2)
                        .foregroundColor(.secondary)
                }
            } else {
                Text("No current rate")
                    .font(.caption)
            }
        }
        .padding(.horizontal, 4)
    }
    
    // Inline lock screen widget
    private var inlineView: some View {
        if let currentRate = findCurrentRate() {
            Label {
                Text("\(formatRate(currentRate.valueIncludingVAT))/kWh")
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
                    .padding(.top, 0)
                    .padding([.leading, .trailing, .bottom], -16)
                    .ignoresSafeArea()
                
                // 2) Left side content (same as systemSmall)
                HStack {
                    if let currentRate = findCurrentRate() {
                        contentForCurrent(rate: currentRate)
                            .frame(width: geometry.size.width * 0.45)
                    } else {
                        noCurrentRateView
                            .frame(width: geometry.size.width * 0.45)
                    }
                    Spacer()
                }
            }
        }
        .background(Theme.mainBackground)
        .id("\(settings.showRatesInPounds)_\(settings.language)")
        .environment(\.locale, Locale(identifier: settings.language))
    }

    /// The mini chart with best-time background + 'now' line
    private var chartView: some View {
        let data = filteredRatesForChart
        let bestRanges = findBestTimeRanges(data: data)
        let nowX = Date()
        let (minVal, maxVal) = chartYRange
        let barWidth = computeDynamicBarWidth(rateCount: data.count)

        return Chart {
            // 1) "Now" vertical line (behind bars)
            RuleMark(x: .value("Now", nowX))
                .foregroundStyle(Theme.secondaryColor.opacity(0.7))
                .lineStyle(StrokeStyle(lineWidth: 2))
                .zIndex(1)

            // 2) best-time background
            ForEach(bestRanges, id: \.0) { (start, end) in
                RectangleMark(
                    xStart: .value("Start", start),
                    xEnd: .value("End", end),
                    yStart: .value("Y1", minVal),
                    yEnd: .value("Y2", maxVal)
                )
                .foregroundStyle(Theme.mainColor.opacity(0.2))
                .zIndex(2)
            }

            // 3) Bars for rates
            ForEach(data, id: \.validFrom) { rate in
                if let t = rate.validFrom {
                    let opacity = computeOpacity(for: t, in: data)
                    BarMark(
                        x: .value("Time", t),
                        y: .value("Rate", rate.valueIncludingVAT),
                        width: .fixed(barWidth)
                    )
                    .cornerRadius(3)
                    .foregroundStyle(
                        rate.valueIncludingVAT < 0 
                            ? Theme.secondaryColor.opacity(opacity)
                            : Theme.mainColor.opacity(opacity)
                    )
                    .zIndex(3)
                }
            }

            // 4) "Now" badge (on top)
            RuleMark(x: .value("Now", nowX))
                .opacity(0) // Invisible rule mark just for the annotation
                .annotation(position: .top) {
                    Text(LocalizedStringKey("NOW"))
                        .font(.system(size: 10).weight(.bold))
                        .foregroundColor(.white)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(
                            Capsule()
                                .fill(Theme.secondaryColor.opacity(0.7))
                                .frame(width: 32)
                        )
                        .offset(y: 45)
                }
                .offset(y: -16)
                .zIndex(4) // Badge always on top
        }
        .chartYScale(domain: minVal...maxVal)
        .chartXAxis {
            AxisMarks(preset: .extended, values: .stride(by: 7200))
        }
        .chartYAxis(.hidden)
        .chartPlotStyle { plotContent in
            plotContent
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .padding(.top, 0)
                .padding([.leading, .trailing, .bottom], -16)
        }
        .padding(0)
    }

    /// Compute opacity for gradient effect (0% for first 20%, then 0% to 100% for remaining)
    private func computeOpacity(for date: Date, in data: [RateEntity]) -> Double {
        guard let firstDate = data.first?.validFrom,
              let lastDate = data.last?.validFrom,
              lastDate > firstDate else {
            return 1.0
        }
        
        let totalDuration = lastDate.timeIntervalSince(firstDate)
        let currentDuration = date.timeIntervalSince(firstDate)
        let progress = currentDuration / totalDuration
        
        // First 20% is completely transparent
        if progress < 0.3 {
            return 0.0
        }
        
        // Remaining 80% goes from 0% to 100%
        return (progress - 0.3) / 0.7 // This maps 0.2->1.0 to 0.0->1.0
    }

    /// Compute dynamic bar width with gaps
    private func computeDynamicBarWidth(rateCount: Int) -> Double {
        let maxPossibleBars = 65.0  // Upper bound, same as InteractiveLineChartCardView
        let currentBars = Double(rateCount)
        let baseWidthPerBar = 5.0
        let barGapRatio = 0.7  // 70% bar, 30% gap
        let totalChunk = (maxPossibleBars / currentBars) * baseWidthPerBar
        return totalChunk * barGapRatio
    }

    /// Filtered rates for chart display (from 00:00 of latest data's previous day)
    private var filteredRatesForChart: [RateEntity] {
        let calendar = Calendar.current
        
        // Find the latest data's date
        let sortedRates = rates
            .filter { $0.validTo != nil }
            .sorted { ($0.validTo ?? .distantPast) > ($1.validTo ?? .distantPast) }
        
        guard let latestDate = sortedRates.first?.validTo else {
            return []
        }
        
        // Get start of yesterday relative to the latest date
        let yesterday = calendar.date(byAdding: .day, value: -1, to: latestDate) ?? latestDate
        let start = calendar.startOfDay(for: yesterday)
        
        return rates
            .filter { $0.validFrom != nil && $0.validTo != nil }
            .sorted { ($0.validFrom ?? .distantPast) < ($1.validFrom ?? .distantPast) }
            .filter {
                guard let date = $0.validFrom else { return false }
                return date >= start
            }
    }

    /// Y-axis range for chart
    private var chartYRange: (Double, Double) {
        let prices = filteredRatesForChart.map { $0.valueIncludingVAT }
        guard !prices.isEmpty else { return (0, 10) }
        let minVal = min(0, (prices.min() ?? 0) - 2)
        let maxVal = (prices.max() ?? 0) + 2
        return (minVal, maxVal)
    }

    /// Example subview for each rate row in left column
    private func rateRow(label: String, icon: String, value: Double, color: Color) -> some View {
        HStack(spacing: 4) {
            Image(systemName: icon).font(.caption2).foregroundColor(.secondary)
            Text(label).font(.caption2).foregroundColor(.secondary)
            Spacer()
            Text(formatRate(value))
                .font(.caption2)
                .foregroundColor(color)
        }
    }

    /// Find best time ranges (lowest average windows) in the next 24 hours
    private func findBestTimeRanges(data: [RateEntity]) -> [(Date, Date)] {
        let now = Date()
        let future = now.addingTimeInterval(24 * 3600)
        let upcomingRates = data.filter { rate in
            guard let from = rate.validFrom, let _ = rate.validTo else { return false }
            return from >= now && from < future
        }
        
        // Simple algorithm: Find 2-hour windows with lowest average
        var bestRanges: [(Date, Date)] = []
        let windowSize = 2 * 3600.0 // 2 hours
        
        for i in stride(from: 0, to: upcomingRates.count - 3, by: 1) {
            let windowRates = Array(upcomingRates[i..<min(i + 4, upcomingRates.count)])
            let avgRate = windowRates.reduce(0.0) { $0 + $1.valueIncludingVAT } / Double(windowRates.count)
            
            if avgRate < 20.0, // Threshold for "good" rate
               let firstRate = windowRates.first,
               let start = firstRate.validFrom {
                let end = start.addingTimeInterval(windowSize)
                bestRanges.append((start, end))
            }
        }
        
        return bestRanges
    }
}

// MARK: - Subviews for CurrentRateWidget
extension CurrentRateWidget {
    
    private func contentForCurrent(rate: RateEntity) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            topLabel(title: "Agile Current", icon: "clock.fill")
            
            // Show large current rate
            rateView(value: rate.valueIncludingVAT, color: RateColor.getColor(for: rate, allRates: rates), font: Theme.mainFont())
            
            // "Until HH:mm"
            if let validTo = rate.validTo {
                Text("Until \(formatTime(validTo))")
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
            topLabel(title: "Agile Current", icon: "clock.fill")
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
                        value: lowestRate.valueIncludingVAT,
                        color: RateColor.getColor(for: lowestRate, allRates: rates),
                        font: family == .systemSmall ? Theme.titleFont() : Theme.mainFont()
                    )
                    Spacer(minLength: 0)
                    Text(formatTime(startTime))
                        .font(.caption2)
                        .foregroundColor(Theme.mainTextColor)
                }
            }
            if let (highestRate, startTime) = highestUpcoming() {
                HStack(alignment: .firstTextBaseline, spacing: 2) {
                    Image(systemName: "chevron.up")
                        .font(.caption)
                        .foregroundColor(Theme.icon)
                    rateView(
                        value: highestRate.valueIncludingVAT,
                        color: RateColor.getColor(for: highestRate, allRates: rates),
                        font: family == .systemSmall ? Theme.titleFont() : Theme.mainFont()
                    )
                    Spacer(minLength: 0)
                    Text(formatTime(startTime))
                        .font(.caption2)
                        .foregroundColor(Theme.mainTextColor)
                }
            }
        }
    }
    
    private func topLabel(title: String, icon: String) -> some View {
        HStack {
            Image(systemName: icon)
                .foregroundColor(Theme.icon)
                .font(Theme.subFont())
            Text(title)
                .font(Theme.subFont())
                .foregroundColor(Theme.secondaryTextColor)
        }
    }
}

// MARK: - Computations & Formatters
extension CurrentRateWidget {
    private func findCurrentRate() -> RateEntity? {
        rates.first { r in
            guard let from = r.validFrom, let to = r.validTo else { return false }
            return (from <= Date() && to > Date())
        }
    }
    
    /// Get upcoming rates including current rate, sorted by value
    private func getUpcomingRates() -> [RateEntity] {
        let now = Date()
        return rates
            .filter { rate in
                guard let from = rate.validFrom, let to = rate.validTo else { return false }
                // Include if it overlaps with now or is in the future
                return (from <= now && to > now) || from > now
            }
            .sorted { $0.valueIncludingVAT < $1.valueIncludingVAT }
    }
    
    private func lowestUpcoming() -> (RateEntity, Date)? {
        let upcoming = getUpcomingRates()
        
        if let item = upcoming.first, let from = item.validFrom {
            return (item, from)
        }
        return nil
    }
    
    private func highestUpcoming() -> (RateEntity, Date)? {
        let upcoming = getUpcomingRates()
        
        if let item = upcoming.last, let validFrom = item.validFrom {
            return (item, validFrom)
        }
        return nil
    }
    
    private func rateView(value: Double, color: Color, font: Font) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 0) {
            Text(formatRate(value))
                .font(font)
                .foregroundColor(color)
                .lineLimit(1)
                .minimumScaleFactor(0.5)
            Text("/kWh")
                .font(.caption2)
                .foregroundColor(Theme.secondaryTextColor)
                .scaleEffect(0.8)
        }
    }
    
    private func formatRate(_ raw: Double) -> String {
        if settings.showRatesInPounds {
            return String(format: "£%.3f", raw / 100.0)
        } else {
            return String(format: "%.2fp", raw)
        }
    }
    
    private func formatTime(_ date: Date) -> String {
        let df = DateFormatter()
        df.dateFormat = "HH:mm"
        return df.string(from: date)
    }
}

// MARK: - Widget Definition
// @main
struct Octopus_HelperWidgets: Widget {
    let kind = "Octopus_HelperWidgets"
    
    var body: some WidgetConfiguration {
        AppIntentConfiguration(
            kind: kind,
            intent: ConfigurationAppIntent.self,
            provider: OctopusWidgetProvider()
        ) { entry in
            if #available(iOS 17.0, *) {
                CurrentRateWidget(rates: entry.rates, settings: entry.settings)
                    .containerBackground(Theme.mainBackground, for: .widget)
            } else {
                CurrentRateWidget(rates: entry.rates, settings: entry.settings)
                    .padding()
                    .background(Theme.mainBackground)
            }
        }
        .configurationDisplayName("Current Rate")
        .description("Display the current electricity rate.")
        .supportedFamilies([
            .systemSmall,
            .systemMedium,
            .accessoryCircular,
            .accessoryInline
        ])
    }
}

// MARK: - Preview
#Preview(as: .systemSmall) {
    Octopus_HelperWidgets()
} timeline: {
    let context = PersistenceController.preview.container.viewContext
    
    // One "no data" entry
    let emptyEntry = SimpleEntry(
        date: .now,
        configuration: ConfigurationAppIntent(),
        rates: [],
        settings: ("", false, "en")
    )

    // One "has data" entry
    let sampleRate = RateEntity(context: context)
    sampleRate.id = UUID().uuidString
    sampleRate.validFrom = Date()
    sampleRate.validTo = Date().addingTimeInterval(1800)
    sampleRate.valueExcludingVAT = 15.0
    sampleRate.valueIncludingVAT = 18.0

    let hasDataEntry = SimpleEntry(
        date: .now,
        configuration: ConfigurationAppIntent(),
        rates: [sampleRate],
        settings: ("", false, "en")
    )

    return [emptyEntry, hasDataEntry]
}
