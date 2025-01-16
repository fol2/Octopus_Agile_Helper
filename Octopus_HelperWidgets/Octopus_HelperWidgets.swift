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
import CoreData

// MARK: - Timeline Provider
final class OctopusWidgetProvider: NSObject, AppIntentTimelineProvider {

    // MARK: - Dependencies
    private var repository: RatesRepository {
        get async { await MainActor.run { RatesRepository.shared } }
    }
    private var sharedDefaults: UserDefaults? {
        UserDefaults(suiteName: "group.com.jamesto.octopus-agile-helper")
    }
    private var persistenceController: PersistenceController {
        PersistenceController.shared
    }
    private var productDetailRepository: ProductDetailRepository {
        ProductDetailRepository.shared
    }
    
    private let agileCodeKey = "agile_code_for_widget"
    
    // Add shared settings manager
    private var chartSettings: InteractiveChartSettings {
        if let data = sharedDefaults?.data(forKey: "MyChartSettings"),
           let decoded = try? JSONDecoder().decode(InteractiveChartSettings.self, from: data) {
            return decoded
        }
        return .default
    }
    
    // MARK: - Public Entry Points
    override init() {
        super.init()
    }

    func placeholder(in context: Context) -> SimpleEntry {
        let context = persistenceController.container.viewContext
        let request = NSFetchRequest<NSManagedObject>(entityName: "RateEntity")
        let rates = (try? context.fetch(request)) ?? []
        return SimpleEntry(
            date: .now,
            configuration: ConfigurationAppIntent(),
            rates: rates,
            settings: readSettings(),
            chartSettings: chartSettings,
            agileCode: {
                let stored = sharedDefaults?.string(forKey: agileCodeKey)
                let fallback = fallbackAgileCodeFromProductEntity()
                return stored ?? fallback ?? ""
            }()
        )
    }

    func snapshot(for configuration: ConfigurationAppIntent, in context: Context) async -> SimpleEntry {
        let context = persistenceController.container.viewContext
        let request = NSFetchRequest<NSManagedObject>(entityName: "RateEntity")
        let rates = (try? context.fetch(request)) ?? []
        return SimpleEntry(
            date: .now,
            configuration: configuration,
            rates: rates,
            settings: readSettings(),
            chartSettings: chartSettings,
            agileCode: {
                let stored = sharedDefaults?.string(forKey: agileCodeKey)
                let fallback = fallbackAgileCodeFromProductEntity()
                return stored ?? fallback ?? ""
            }()
        )
    }
    
    func timeline(for configuration: ConfigurationAppIntent, in context: Context) async -> Timeline<SimpleEntry> {
        do {
            // 1) Update rates from the repository
            let repo = await repository
            
            // 1.5) Read the agile code from shared defaults
            let agileCode: String = {
                let stored = sharedDefaults?.string(forKey: agileCodeKey)
                let fallback = fallbackAgileCodeFromProductEntity()
                return stored ?? fallback ?? "AGILE-FLEX-22-11-25"
            }()
            
            // Get product detail to get link and tariff code
            let details = try await productDetailRepository.loadLocalProductDetail(code: agileCode)
            if let detail = details.first,
               let tCode = detail.value(forKey: "tariff_code") as? String,
               let link = detail.value(forKey: "link_rate") as? String {
                try await repo.fetchAndStoreRates(tariffCode: tCode, url: link)
            }
            
            let rates = try await repo.fetchAllRates()

            // 2) On first install or empty DB => direct fetch
            if rates.isEmpty {
                // If we truly need a fallback approach, either do:
                // rates = try await directFetchAndSave()
                // or just rely on repo.updateRates() logic above. We can comment it out if you no longer want to call direct fetch:
                // rates = try await directFetchAndSave()
                // For now, let's skip or comment:
                // rates = try await directFetchAndSave()
            }

            // Convert [NSManagedObject] -> [RateEntity]
            let typedRates = rates.compactMap { $0 }

            // 2.5) Create a specialized RatesViewModel with the known agile code
            _ = await RatesViewModel(widgetRates: typedRates, productCode: agileCode)

            // 3) Build timeline
            let now = Date()
            let entries = buildTimelineEntries(rates: typedRates, configuration: configuration, now: now, agileCode: agileCode)
            
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
    private func readSettings() -> (postcode: String, showRatesInPounds: Bool, language: String, electricityMPAN: String?, meterSerialNumber: String?) {
        let defaults = sharedDefaults
        if let data = defaults?.data(forKey: "user_settings"),
           let decoded = try? JSONDecoder().decode(GlobalSettings.self, from: data)
        {
            return (
                postcode: decoded.regionInput,
                showRatesInPounds: decoded.showRatesInPounds,
                language: decoded.selectedLanguage.rawValue,
                electricityMPAN: decoded.electricityMPAN,
                meterSerialNumber: decoded.electricityMeterSerialNumber
            )
        }
        // Fallback if "user_settings" is missing
        return (
            postcode: defaults?.string(forKey: "selected_postcode") ?? "",
            showRatesInPounds: defaults?.bool(forKey: "show_rates_in_pounds") ?? false,
            language: defaults?.string(forKey: "selected_language") ?? "en",
            electricityMPAN: defaults?.string(forKey: "electricity_mpan"),
            meterSerialNumber: defaults?.string(forKey: "meter_serial_number")
        )
    }

    /// Directly fetches from API + saves to Core Data for first-time or fallback usage.
    private func directFetchAndSave() async throws -> [NSManagedObject] {
        _ = try await fetchRegionID()
        // If your new code doesn't have `fetchRates(...)`, you may comment out or adapt:
        // let rawRates = try await OctopusAPIClient.shared.fetchRates(regionID: regionID)
        // let ctx = PersistenceController.shared.container.viewContext

        // Convert raw response to NSManagedObject
        // let entities = rawRates.map { r -> NSManagedObject in
        //     let obj = NSEntityDescription.insertNewObject(forEntityName: "RateEntity", into: ctx)
        //     obj.setValue(UUID().uuidString, forKey: "id")
        //     obj.setValue(r.valid_from, forKey: "valid_from")
        //     obj.setValue(r.valid_to, forKey: "valid_to")
        //     obj.setValue(r.value_exc_vat, forKey: "value_excluding_vat")
        //     obj.setValue(r.value_inc_vat, forKey: "value_including_vat")
        //     return obj
        // }
        // if ctx.hasChanges { try ctx.save() }
        // return entities
        return []
    }

    /// Obtain the region ID from user's input (postcode or region code), fallback to "H" if none.
    private func fetchRegionID() async throws -> String {
        let input = readSettings().postcode.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        guard !input.isEmpty else { return "H" }
        
        // If input is a single letter A-P, treat it as a direct region code
        if input.count == 1 && input >= "A" && input <= "P" {
            return input
        }
        
        // Otherwise, treat as postcode and look up region
        return try await (await repository).fetchRegionID(for: input) ?? "H"
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
        let chartSettings = self.chartSettings  // Get the shared chart settings
        
        return refreshSlots.map { date in
            SimpleEntry(
                date: date,
                configuration: configuration,
                rates: rates,
                settings: userSettings,
                chartSettings: chartSettings,  // Pass chart settings to entry
                agileCode: agileCode
            )
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
                settings: userSettings,
                chartSettings: chartSettings,
                agileCode: {
                    let stored = sharedDefaults?.string(forKey: agileCodeKey)
                    let fallback = fallbackAgileCodeFromProductEntity()
                    // If 'stored' is nil, fallback to local DB; if that is also nil => empty
                    return stored ?? fallback ?? ""
                }()
            ),
            SimpleEntry(
                date: retryDate,
                configuration: configuration,
                rates: [],
                settings: userSettings,
                chartSettings: chartSettings,
                agileCode: {
                    let stored = sharedDefaults?.string(forKey: agileCodeKey)
                    let fallback = fallbackAgileCodeFromProductEntity()
                    // If 'stored' is nil, fallback to local DB; if that is also nil => empty
                    return stored ?? fallback ?? ""
                }()
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

// MARK: - Local fallback for "AGILE" product
/// Attempts to find a product in Core Data whose code contains "AGILE"
/// and is not expired (or has no `available_to`) picking the 'latest'.
/// Return nil if none.
extension OctopusWidgetProvider {
    private func fallbackAgileCodeFromProductEntity() -> String? {
        let ctx = persistenceController.container.viewContext
        let request = NSFetchRequest<NSManagedObject>(entityName: "ProductEntity")
        // e.g., code CONTAINS 'AGILE' AND (available_to == nil OR available_to > NOW)
        let now = Date()
        request.predicate = NSPredicate(
            format: "(code CONTAINS[cd] %@) AND (available_to == nil OR available_to > %@)",
            "AGILE", now as NSDate
        )
        request.sortDescriptors = [
            // Sort descending by available_to => "latest" first
            NSSortDescriptor(key: "available_to", ascending: false)
        ]

        do {
            let results = try ctx.fetch(request)
            // Return first code if present
            if let first = results.first,
               let code = first.value(forKey: "code") as? String {
                return code
            }
        } catch {
            print("DEBUG: fallbackAgileCodeFromProductEntity error: \(error)")
        }
        // If none found, return nil
        return nil
    }
}

// MARK: - Timeline Entry
struct SimpleEntry: TimelineEntry {
    let date: Date
    let configuration: ConfigurationAppIntent
    let rates: [NSManagedObject]
    let settings: (postcode: String, showRatesInPounds: Bool, language: String, electricityMPAN: String?, meterSerialNumber: String?)
    let chartSettings: InteractiveChartSettings
    let agileCode: String
}

// MARK: - The Widget UI
/// Displays the current Agile rate, plus highest & lowest upcoming times.
@available(iOS 17.0, *)
struct CurrentRateWidget: View {
    let rates: [NSManagedObject]
    let settings: (postcode: String, showRatesInPounds: Bool, language: String, electricityMPAN: String?, meterSerialNumber: String?)
    let chartSettings: InteractiveChartSettings
    let agileCode: String
    @Environment(\.widgetFamily) var family
    
    // Add computed property for best time ranges
    private var bestTimeRanges: [(Date, Date)] {
        let widgetVM = RatesViewModel(
            widgetRates: rates.compactMap { $0 },
            productCode: agileCode
        )
        let avgRates = widgetVM.getLowestAverages(
            productCode: agileCode,
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
        
        // Filter to only show ranges that overlap with our chart's visible range
        guard let chartStart = filteredRatesForChart.first?.value(forKey: "valid_from") as? Date,
            let chartEnd = filteredRatesForChart.last?.value(forKey: "valid_to") as? Date else {
            return []
        }
        
        return merged.filter { window in
            window.0 <= chartEnd && window.1 >= chartStart
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
        
        // Split rates into past and future
        let validRates = rates.filter { $0.value(forKey: "valid_from") != nil && $0.value(forKey: "valid_to") != nil }
        let pastRates = validRates
            .filter { ($0.value(forKey: "valid_from") as? Date ?? .distantFuture) <= now }
            .sorted { ($0.value(forKey: "valid_from") as? Date ?? .distantPast) > ($1.value(forKey: "valid_from") as? Date ?? .distantPast) } // Latest first
            .prefix(42) // Take up to 42 past rates
        
        let futureRates = validRates
            .filter { ($0.value(forKey: "valid_from") as? Date ?? .distantPast) > now }
            .sorted { ($0.value(forKey: "valid_from") as? Date ?? .distantPast) < ($1.value(forKey: "valid_from") as? Date ?? .distantPast) } // Earliest first
            .prefix(33) // Take up to 33 future rates
        
        // Combine and sort for display
        return (Array(pastRates) + Array(futureRates))
            .sorted { ($0.value(forKey: "valid_from") as? Date ?? .distantPast) < ($1.value(forKey: "valid_from") as? Date ?? .distantPast) }
    }

    /// Y-axis range for chart
    private var chartYRange: (Double, Double) {
        let prices = filteredRatesForChart.map { ($0.value(forKey: "value_including_vat") as? Double) ?? 0 }
        guard !prices.isEmpty else { return (0, 10) }
        let minVal = min(0, (prices.min() ?? 0) - 2)
        let maxVal = (prices.max() ?? 0) + 10
        return (minVal, maxVal)
    }

    private var xDomain: ClosedRange<Date> {
        guard let earliest = filteredRatesForChart.first?.value(forKey: "valid_from") as? Date,
            let lastRate = filteredRatesForChart.last,
            let domainEnd = (lastRate.value(forKey: "valid_to") as? Date) ?? 
                          ((lastRate.value(forKey: "valid_from") as? Date)?.addingTimeInterval(1800))
        else {
            return Date()...(Date().addingTimeInterval(3600))
        }
        return earliest...domainEnd
    }

    private func findCurrentRatePeriod(_ date: Date) -> (start: Date, price: Double)? {
        guard
            let rate = filteredRatesForChart.first(where: { r in
                guard let start = r.value(forKey: "valid_from") as? Date,
                      let end = r.value(forKey: "valid_to") as? Date else { return false }
                return date >= start && date < end
            })
        else {
            return nil
        }
        if let start = rate.value(forKey: "valid_from") as? Date {
            return (start, rate.value(forKey: "value_including_vat") as? Double ?? 0)
        }
        return nil
    }

    /// Get upcoming rates including current rate, sorted by value
    private func getUpcomingRates() -> [NSManagedObject] {
        let now = Date()
        return rates
            .filter { rate in
                guard let _ = rate.value(forKey: "valid_from") as? Date,
                      let validTo = rate.value(forKey: "valid_to") as? Date else { return false }
                return validTo > now
            }
            .sorted { a, b in
                let aValue = (a.value(forKey: "value_including_vat") as? Double) ?? Double.infinity
                let bValue = (b.value(forKey: "value_including_vat") as? Double) ?? Double.infinity
                return aValue < bValue
            }
    }

    private var barWidth: Double {
        let maxPossibleBars = 65.0  // Upper bound
        let currentBars = Double(filteredRatesForChart.count)
        let baseWidthPerBar = 5.0
        let barGapRatio = 0.7  // 70% bar, 30% gap
        let totalChunk = (maxPossibleBars / currentBars) * baseWidthPerBar
        return totalChunk * barGapRatio
    }

    private func formatPrice(_ pence: Double) -> String {
        if settings.showRatesInPounds {
            return String(format: "£%.2f", pence / 100.0)
        } else {
            return String(format: "%.0fp", pence)
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
                let upcomingRates = getUpcomingRates()
                if !upcomingRates.isEmpty {
                    let currentValue = currentRate.value(forKey: "value_including_vat") as? Double ?? 0
                    let minRate = min(currentValue, upcomingRates.first?.value(forKey: "value_including_vat") as? Double ?? currentValue)
                    let maxRate = max(currentValue, upcomingRates.last?.value(forKey: "value_including_vat") as? Double ?? currentValue)
                    
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
                        Text(formatRate(currentRate.value(forKey: "value_including_vat") as? Double ?? 0))
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

    // Inline lock screen widget
    private var inlineView: some View {
        if let currentRate = findCurrentRate() {
            Label {
                Text("\(formatRate(currentRate.value(forKey: "value_including_vat") as? Double ?? 0))/kWh")
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
    /// - Left side: current rate, highest & lowest (same as systemSmall)
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
        let nowX = if let currentPeriod = findCurrentRatePeriod(now) {
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
    private func chartBackgroundLayers(minVal: Double, maxVal: Double, nowX: Date) -> some ChartContent {
        // 0) Best time ranges (behind everything)
        ForEach(bestTimeRanges, id: \.0) { start, end in
            RectangleMark(
                xStart: .value("Start", start),
                xEnd: .value("End", end),
                yStart: .value("Min", minVal - 20),
                yEnd: .value("Max", maxVal + 20)
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
        ForEach(Array(data.enumerated()), id: \.1) { index, rate in
            if let t = rate.value(forKey: "valid_from") as? Date {
                let value = rate.value(forKey: "value_including_vat") as? Double ?? 0
                let baseColor = value < 0 ? Theme.secondaryColor : Theme.mainColor
                let rawProgress = Double(index) / Double(max(1, data.count - 1))
                let isToday = Calendar.current.isDate(t, inSameDayAs: Date())
                
                // Keep first 30% as background color, then gradient over remaining 70%
                let colorProgress = if rawProgress < 0.3 {
                    0.0 // First 30% are pure background
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
                    y: .value("Rate", value),
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
            .opacity(0) // Invisible rule mark just for the annotation
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
}

// MARK: - Subviews for CurrentRateWidget
extension CurrentRateWidget {
    
    private func contentForCurrent(rate: NSManagedObject) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            topLabel(title: "Agile Current", icon: "clock")
            
            // Show large current rate
            rateView(value: rate.value(forKey: "value_including_vat") as? Double ?? 0, color: RateColor.getColor(for: rate, allRates: rates), font: Theme.mainFont())
            
            // "Until HH:mm"
            if let validTo = rate.value(forKey: "valid_to") as? Date {
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
                        value: lowestRate.value(forKey: "value_including_vat") as? Double ?? 0,
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
                        value: highestRate.value(forKey: "value_including_vat") as? Double ?? 0,
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
                  let to = r.value(forKey: "valid_to") as? Date else { return false }
            return (from <= Date() && to > Date())
        }
    }
    
    private func lowestUpcoming() -> (NSManagedObject, Date)? {
        let upcoming = getUpcomingRates()
        
        if let item = upcoming.first,
           let from = item.value(forKey: "valid_from") as? Date {
            return (item, from)
        }
        return nil
    }
    
    private func highestUpcoming() -> (NSManagedObject, Date)? {
        let upcoming = getUpcomingRates()
        
        if let item = upcoming.last,
           let validFrom = item.value(forKey: "valid_from") as? Date {
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
                CurrentRateWidget(
                    rates: entry.rates,
                    settings: entry.settings,
                    chartSettings: entry.chartSettings,
                    agileCode: entry.agileCode
                )
                    .containerBackground(Theme.mainBackground, for: .widget)
            } else {
                CurrentRateWidget(
                    rates: entry.rates,
                    settings: entry.settings,
                    chartSettings: entry.chartSettings,
                    agileCode: entry.agileCode
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
            .accessoryInline
        ])
    }
}

// MARK: - Preview Helpers
extension PersistenceController {
    static var widgetPreview: PersistenceController = {
        PersistenceController.shared
    }()
}

// MARK: - Widget Previews
#Preview(as: .systemSmall) {
    Octopus_HelperWidgets()
} timeline: {
    let context = PersistenceController.shared.container.viewContext
    let request: NSFetchRequest<NSManagedObject> = NSFetchRequest(entityName: "RateEntity")
    let rates: [NSManagedObject] = (try? context.fetch(request)) ?? []
    
    SimpleEntry(
        date: .now,
        configuration: ConfigurationAppIntent(),
        rates: rates,
        settings: (
            postcode: "SW1A 1AA",
            showRatesInPounds: false,
            language: "en",
            electricityMPAN: nil,
            meterSerialNumber: nil
        ),
        chartSettings: .default,
        agileCode: "AGILE-FLEX-22-11-25"
    )
}

#Preview(as: .systemMedium) {
    Octopus_HelperWidgets()
} timeline: {
    let context = PersistenceController.shared.container.viewContext
    let request: NSFetchRequest<NSManagedObject> = NSFetchRequest(entityName: "RateEntity")
    let rates: [NSManagedObject] = (try? context.fetch(request)) ?? []
    
    SimpleEntry(
        date: .now,
        configuration: ConfigurationAppIntent(),
        rates: rates,
        settings: (
            postcode: "SW1A 1AA",
            showRatesInPounds: false,
            language: "en",
            electricityMPAN: nil,
            meterSerialNumber: nil
        ),
        chartSettings: .default,
        agileCode: "AGILE-FLEX-22-11-25"
    )
}

#Preview(as: .accessoryCircular) {
    Octopus_HelperWidgets()
} timeline: {
    let context = PersistenceController.shared.container.viewContext
    let request: NSFetchRequest<NSManagedObject> = NSFetchRequest(entityName: "RateEntity")
    let rates: [NSManagedObject] = (try? context.fetch(request)) ?? []
    
    SimpleEntry(
        date: .now,
        configuration: ConfigurationAppIntent(),
        rates: rates,
        settings: (
            postcode: "SW1A 1AA",
            showRatesInPounds: false,
            language: "en",
            electricityMPAN: nil,
            meterSerialNumber: nil
        ),
        chartSettings: .default,
        agileCode: "AGILE-FLEX-22-11-25"
    )
}

#Preview(as: .accessoryInline) {
    Octopus_HelperWidgets()
} timeline: {
    let context = PersistenceController.shared.container.viewContext
    let request: NSFetchRequest<NSManagedObject> = NSFetchRequest(entityName: "RateEntity")
    let rates: [NSManagedObject] = (try? context.fetch(request)) ?? []
    
    SimpleEntry(
        date: .now,
        configuration: ConfigurationAppIntent(),
        rates: rates,
        settings: (
            postcode: "SW1A 1AA",
            showRatesInPounds: false,
            language: "en",
            electricityMPAN: nil,
            meterSerialNumber: nil
        ),
        chartSettings: .default,
        agileCode: "AGILE-FLEX-22-11-25"
    )
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

struct CurrentRateWidget_Previews: PreviewProvider {
    static var previews: some View {
        CurrentRateWidget(
            rates: [],
            settings: (postcode: "", showRatesInPounds: false, language: "en", electricityMPAN: nil, meterSerialNumber: nil),
            chartSettings: InteractiveChartSettings.default,
            agileCode: "AGILE-24-10-01"
        )
    }
}
