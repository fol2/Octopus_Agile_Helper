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
struct CurrentRateWidget: View {
    let rates: [RateEntity]
    let settings: (postcode: String, showRatesInPounds: Bool, language: String)
    @Environment(\.widgetFamily) var family
    
    var body: some View {
        switch family {
        case .systemSmall:
            systemSmallView
        case .accessoryCircular:
            circularView
        case .accessoryRectangular:
            rectangularView
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
            if let currentRate = findCurrentRate(),
               let minRate = rates.min(by: { $0.valueIncludingVAT < $1.valueIncludingVAT })?.valueIncludingVAT,
               let maxRate = rates.max(by: { $0.valueIncludingVAT < $1.valueIncludingVAT })?.valueIncludingVAT {
                Gauge(value: currentRate.valueIncludingVAT, in: minRate...maxRate) {
                    Image(systemName: "bolt.fill")
                } currentValueLabel: {
                    Text(formatRate(currentRate.valueIncludingVAT))
                        .font(.system(.body, design: .rounded))
                        .minimumScaleFactor(0.5)
                }
                .gaugeStyle(.accessoryCircular)
                .tint(RateColor.getColor(for: currentRate, allRates: rates))
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
                HStack(spacing: 2) {
                    Image(systemName: "chevron.down")
                        .font(.caption)
                        .foregroundColor(Theme.icon)
                    rateView(value: lowestRate.valueIncludingVAT, color: RateColor.getColor(for: lowestRate, allRates: rates), font: Theme.titleFont())
                    Spacer(minLength: 4)
                    Text(formatTime(startTime))
                        .font(.caption2)
                        .foregroundColor(Theme.secondaryTextColor)
                }
            }
            if let (highestRate, startTime) = highestUpcoming() {
                HStack(spacing: 2) {
                    Image(systemName: "chevron.up")
                        .font(.caption)
                        .foregroundColor(Theme.icon)
                    rateView(value: highestRate.valueIncludingVAT, color: RateColor.getColor(for: highestRate, allRates: rates), font: Theme.titleFont())
                    Spacer(minLength: 4)
                    Text(formatTime(startTime))
                        .font(.caption2)
                        .foregroundColor(Theme.secondaryTextColor)
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
    
    private func lowestUpcoming() -> (RateEntity, Date)? {
        let upcoming = rates.filter {
            guard let vFrom = $0.validFrom else { return false }
            return vFrom > Date()
        }
        .sorted { $0.valueIncludingVAT < $1.valueIncludingVAT }
        
        if let item = upcoming.first, let from = item.validFrom {
            return (item, from)
        }
        return nil
    }
    
    private func highestUpcoming() -> (RateEntity, Date)? {
        let upcoming = rates.filter {
            guard let vFrom = $0.validFrom else { return false }
            return vFrom > Date()
        }
        .sorted { $0.valueIncludingVAT > $1.valueIncludingVAT }
        
        if let item = upcoming.first, let from = item.validFrom {
            return (item, from)
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
                .font(font == Theme.mainFont() ? Theme.secondaryFont() : .caption2)
                .foregroundColor(Theme.secondaryTextColor)
                .scaleEffect(font == Theme.mainFont() ? 0.9 : 0.8)
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
            CurrentRateWidget(rates: entry.rates, settings: entry.settings)
                .containerBackground(Theme.mainBackground, for: .widget)
        }
        .configurationDisplayName("Current Rate")
        .description("Display the current electricity rate.")
        .supportedFamilies([
            .systemSmall,
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
