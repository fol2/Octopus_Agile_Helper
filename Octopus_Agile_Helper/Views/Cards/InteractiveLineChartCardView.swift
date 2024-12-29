import SwiftUI
import Charts
import Foundation
import CoreData
import UIKit

// MARK: - Preference Keys
private struct SizePreferenceKey: PreferenceKey {
    static var defaultValue: CGSize? = nil
    static func reduce(value: inout CGSize?, nextValue: () -> CGSize?) {
        value = nextValue() ?? value
    }
}

private struct PositionPreferenceKey: PreferenceKey {
    static var defaultValue: CGPoint? = nil
    static func reduce(value: inout CGPoint?, nextValue: () -> CGPoint?) {
        value = nextValue() ?? value
    }
}

// MARK: - Local Settings
private struct AverageCardLocalSettings: Codable {
    var customAverageHours: Double
    var maxListCount: Int
    
    static let `default` = AverageCardLocalSettings(customAverageHours: 3.0, maxListCount: 10)
}

private class AverageCardLocalSettingsManager: ObservableObject {
    @Published var settings: AverageCardLocalSettings {
        didSet { saveSettings() }
    }
    
    private let userDefaultsKey = "AverageCardSettings"
    
    init() {
        if let data = UserDefaults.standard.data(forKey: userDefaultsKey),
           let decoded = try? JSONDecoder().decode(AverageCardLocalSettings.self, from: data) {
            self.settings = decoded
        } else {
            self.settings = .default
        }
    }
    
    func saveSettings() {
        if let encoded = try? JSONEncoder().encode(settings) {
            UserDefaults.standard.set(encoded, forKey: userDefaultsKey)
        }
    }
}

// MARK: - Settings Sheet
private struct AverageCardSettingsSheet: View {
    @ObservedObject var localSettings: AverageCardLocalSettingsManager
    @Environment(\.dismiss) var dismiss
    @EnvironmentObject var globalSettings: GlobalSettingsManager
    @State private var refreshTrigger = false

    var body: some View {
        NavigationView {
            Form {
                Section(header: Text("Card Settings")) {
                    Stepper(
                        "Custom Average Hours: \(String(format: "%.1f", localSettings.settings.customAverageHours))",
                        value: $localSettings.settings.customAverageHours,
                        in: 1...24,
                        step: 0.5
                    )
                    Stepper(
                        "Max List Count: \(localSettings.settings.maxListCount)",
                        value: $localSettings.settings.maxListCount,
                        in: 1...50
                    )
                }
            }
            .navigationTitle("Average Upcoming Rates")
            .toolbar {
                ToolbarItem(placement: .automatic) {
                    Button("Done") { dismiss() }
                }
            }
        }
        .environment(\.locale, globalSettings.locale)
        .id("settings-sheet-\(refreshTrigger)")
        .onChange(of: globalSettings.locale) { _, _ in
            refreshTrigger.toggle()
        }
    }
}

// MARK: - Interactive Line Chart Card

struct InteractiveLineChartCardView: View {
    @ObservedObject var viewModel: RatesViewModel
    @EnvironmentObject var globalSettings: GlobalSettingsManager
    @Environment(\.colorScheme) var colorScheme
    
    // Refresh triggers
    @State private var refreshTrigger = false
    
    // 'now' updated every minute
    @State private var now: Date = Date()
    let timer = Timer.publish(every: 60, on: .main, in: .common).autoconnect()
    @State private var forcedRefresh = false
    
    // Hover/tapping states
    @State private var hoveredPrice: Double? = nil
    @State private var hoveredTime: Date? = nil
    @State private var labelPosition: CGPoint = .zero
    
    // Local settings
    @StateObject private var localSettings = AverageCardLocalSettingsManager()
    @State private var showingLocalSettings = false
    
    // MARK: - Data
    
    /// We'll read from `viewModel.allRates`
    /// Then filter to 1 hour behind 'now' + 24 hours ahead
    private var filteredRates: [RateEntity] {
        let earliestWanted = now.addingTimeInterval(-3600) // 1 hour behind
        let latestWanted   = now.addingTimeInterval(24 * 3600) // 24h ahead
        
        return viewModel.allRates
            .filter { $0.validFrom != nil }
            .sorted { ($0.validFrom ?? .distantPast) < ($1.validFrom ?? .distantPast) }
            .filter {
                guard let date = $0.validFrom else { return false }
                return date >= earliestWanted && date <= latestWanted
            }
    }
    
    /// Basic min/max price with small buffer
    private var chartPriceRange: (min: Double, max: Double) {
        let values = filteredRates.map(\.valueIncludingVAT)
        guard !values.isEmpty else { return (0, 50) }
        
        let rawMin = values.min() ?? 0
        let rawMax = values.max() ?? 0
        let minVal = (rawMin < 0) ? (rawMin - 2) : max(0, rawMin - 2)
        let maxVal = rawMax + 2
        return (minVal, maxVal)
    }
    
    /// Merged best time windows to highlight
    private var bestTimeRanges: [(Date, Date)] {
        let bestWindows = viewModel.getLowestAverages(
            hours: localSettings.settings.customAverageHours,
            maxCount: localSettings.settings.maxListCount
        )
        let rawWindows = bestWindows.map { ($0.start, $0.end) }
        return mergeTimeWindows(rawWindows)
    }
    
    private func mergeTimeWindows(_ windows: [(Date, Date)]) -> [(Date, Date)] {
        guard !windows.isEmpty else { return [] }
        let sorted = windows.sorted { $0.0 < $1.0 }
        var merged = [sorted[0]]
        
        for w in sorted.dropFirst() {
            if w.0 <= merged.last!.1 {
                merged[merged.count - 1].1 = max(merged.last!.1, w.1)
            } else {
                merged.append(w)
            }
        }
        return merged
    }
    
    /// Times to show on the x-axis (start/end of each best window).
    /// Make sure to include the domain upper bound so the far-right label doesn't vanish.
    private var highlightTickDates: [Date] {
        var dates = bestTimeRanges.flatMap { [$0.0, $0.1] }
        
        // Make sure we include the domain’s upper bound
        let upperBound = domainRange.upperBound
        if let last = dates.last, upperBound > last {
            dates.append(upperBound)
        } else if dates.isEmpty {
            // If we have no ranges at all, at least add the domain end so the axis can show up
            dates.append(upperBound)
        }
        
        return dates.sorted()
    }
    
    /// Actual domain for the x-axis
    private var domainRange: ClosedRange<Date> {
        guard let earliestData = filteredRates.first?.validFrom,
              let latestData = filteredRates.last?.validFrom
        else {
            // fallback if no data
            let fallbackEnd = now.addingTimeInterval(3600)
            return now...fallbackEnd
        }
        // Add a small padding to ensure the last point is fully visible
        return earliestData...(latestData.addingTimeInterval(300))
    }
    
    /// Find nearest price at a given date
    private func findNearestPrice(_ date: Date) -> Double? {
        guard !filteredRates.isEmpty else { return nil }
        return filteredRates.min {
            abs(($0.validFrom ?? .distantPast).timeIntervalSince(date)) <
            abs(($1.validFrom ?? .distantPast).timeIntervalSince(date))
        }?.valueIncludingVAT
    }
    
    // MARK: - Formatting
    
    /// Short price label, e.g. "20p", "20.5p", or "£1.2"
    private func shortLabelPrice(_ price: Double) -> String {
        if globalSettings.settings.showRatesInPounds {
            let pounds = price / 100.0
            if floor(pounds) == pounds {
                return String(format: "£%.0f", pounds)
            } else {
                return String(format: "£%.1f", pounds)
            }
        } else {
            if floor(price) == price {
                return String(format: "%.0fp", price)
            } else {
                return String(format: "%.1fp", price)
            }
        }
    }
    
    /// For less text on x-axis: e.g. "2am", "3pm"
    private func shortTime(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = globalSettings.locale
        formatter.dateFormat = "ha"  // "2am", "3pm"
        return formatter.string(from: date).lowercased()
    }
    
    /// For detailed time range display: e.g. "1:00-1:30"
    private func detailedTimeRange(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = globalSettings.locale
        formatter.dateFormat = "H:mm"
        let (start, end) = halfHourRange(for: date)
        return "\(formatter.string(from: start))-\(formatter.string(from: end))"
    }
    
    private func halfHourRange(for date: Date) -> (Date, Date) {
        let cal = Calendar.current
        var comps = cal.dateComponents([.year, .month, .day, .hour, .minute], from: date)
        if var minute = comps.minute {
            minute = (minute / 30) * 30
            comps.minute = minute
        }
        let start = cal.date(from: comps) ?? date
        let end = start.addingTimeInterval(1800)
        return (start, end)
    }
    
    /// The label for the dashed "Now" line
    private var timePriceLabel: String {
        let df = DateFormatter()
        df.locale = globalSettings.locale
        df.dateFormat = "HH:mm"
        let t = df.string(from: now)
        
        if let p = findNearestPrice(now) {
            return "\(t) (\(shortLabelPrice(p)))"
        } else {
            return "\(t)"
        }
    }
    
    // MARK: - Subview
    private var chartView: some View {
        let (minY, maxY) = chartPriceRange
        
        return Chart {
            // Highlighted windows
            ForEach(bestTimeRanges, id: \.0) { (start, end) in
                RectangleMark(
                    xStart: .value("Start", start),
                    xEnd:   .value("End", end),
                    yStart: .value("MinY", minY),
                    yEnd:   .value("MaxY", maxY)
                )
                .foregroundStyle(
                    .linearGradient(
                        Gradient(colors: [
                            .blue.opacity(0.08),
                            .blue.opacity(0.25)
                        ]),
                        startPoint: .top,
                        endPoint: .bottom
                    )
                )
                // Place it behind the main line
                .zIndex(-2)
            }
            
            // Rate line
            ForEach(filteredRates, id: \.validFrom) { rate in
                if let validFrom = rate.validFrom {
                    LineMark(
                        x: .value("Time", validFrom),
                        y: .value("Price", rate.valueIncludingVAT)
                    )
                    .lineStyle(.init(lineWidth: 2))
                    .foregroundStyle(
                        rate.valueIncludingVAT < 0
                        ? .red.opacity(0.8)
                        : .blue.opacity(0.9)
                    )
                }
            }
            
            // "Now" rule
            RuleMark(x: .value("NowLine", now))
                // Slightly thicker line with no dash
                .lineStyle(StrokeStyle(lineWidth: 1.5, dash: [4,2]))
                // Vertical green gradient
                .foregroundStyle(.green.opacity(0.8))
                .annotation(position: .top, alignment: .center) {
                    Text(timePriceLabel)
                        // Force a new identity each time 'now' changes
                        .id("now-\(now.timeIntervalSince1970)")
                        .transition(.opacity)
                        .font(.system(size: 14, weight: .medium))
                        .foregroundColor(.white)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(
                            RoundedRectangle(cornerRadius: 6)
                                .fill(Color.black.opacity(0.65))
                        )
                        .offset(x: 40, y: 16)
                }
        }
        // Give the chart a bit more breathing room
        .frame(minHeight: 200, maxHeight: 240)
        // Domain from earliest to latest data, plus some padding
        .chartXScale(domain: domainRange, range: .plotDimension(padding: 0))
        // Use highlightTickDates for x-axis
        .chartXAxis {
            AxisMarks(values: highlightTickDates) { value in
                AxisGridLine()
                    .foregroundStyle(Color.secondary.opacity(0.2))
                AxisValueLabel {
                    if let date = value.as(Date.self) {
                        Text(shortTime(date))
                            .font(.system(size: 12))
                    }
                }
                // Hide axis ticks
                AxisTick(centered: false, length: 0)
            }
        }
        .chartYScale(domain: minY...maxY)
        .chartYAxis {
            AxisMarks(position: .leading) { value in
                if let dbl = value.as(Double.self) {
                    AxisValueLabel(centered: true) {
                        Text(shortLabelPrice(dbl))
                            .font(.system(size: 12))
                    }
                    // Use very light lines or none
                    AxisGridLine()
                        .foregroundStyle(Color.secondary.opacity(0.2))
                    // Hide ticks
                    AxisTick(centered: false, length: 0)
                }
            }
        }
        // Overlay for tap gesture + circle + label
        .chartOverlay { proxy in
            GeometryReader { geo in
                Rectangle()
                    .fill(.clear)
                    .contentShape(Rectangle())
                    .gesture(
                        DragGesture(minimumDistance: 0)
                            .onChanged { value in
                                let loc = value.location
                                if let date: Date = proxy.value(atX: loc.x) {
                                    let snappedDate = min(max(date, domainRange.lowerBound),
                                                          domainRange.upperBound)
                                    hoveredTime = snappedDate
                                    hoveredPrice = findNearestPrice(snappedDate)
                                }
                            }
                            .onEnded { _ in
                                hoveredTime = nil
                                hoveredPrice = nil
                            }
                    )
                
                if let time = hoveredTime, let price = hoveredPrice {
                    if
                        let xPos = proxy.position(forX: time),
                        let yPos = proxy.position(forY: price),
                        let plotFrame = proxy.plotFrame
                    {
                        let plotRect = geo[plotFrame]
                        
                        // Dot on the chart
                        Circle()
                            .fill(.blue)
                            .frame(width: 8, height: 8)
                            .position(
                                x: plotRect.minX + xPos,
                                y: plotRect.minY + yPos
                            )
                        
                        // Label pinned near the top
                        let label = "\(detailedTimeRange(time))\n\(shortLabelPrice(price))"
                        
                        Text(label)
                            .font(.callout)
                            .padding(6)
                            .foregroundColor(.white)
                            .background(Color.black.opacity(0.75))
                            .cornerRadius(6)
                            .fixedSize()
                            .background(
                                GeometryReader { labelGeo in
                                    Color.clear.preference(
                                        key: SizePreferenceKey.self,
                                        value: labelGeo.size
                                    )
                                }
                            )
                            .onPreferenceChange(SizePreferenceKey.self) { size in
                                if let labelWidth = size?.width {
                                    let maxX = plotRect.maxX - labelWidth/2 - 8
                                    let minX = plotRect.minX + labelWidth/2 + 8
                                    let constrainedX = min(maxX, max(minX, plotRect.minX + xPos))
                                    DispatchQueue.main.async {
                                        withAnimation(.interactiveSpring()) {
                                            self.labelPosition = CGPoint(
                                                x: constrainedX,
                                                y: plotRect.minY + 20
                                            )
                                        }
                                    }
                                }
                            }
                            .position(labelPosition)
                    }
                }
            }
        }
    }
    
    // MARK: - Body
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            // Header
            HStack {
                Image(systemName: "chart.xyaxis.line")
                    .foregroundColor(.blue)
                Text("Interactive Rate Chart")
                    .font(.headline)
                Spacer()
                Button {
                    showingLocalSettings.toggle()
                } label: {
                    Image(systemName: "gearshape.fill")
                        .font(.footnote)
                        .foregroundColor(.secondary.opacity(0.7))
                }
                .padding(.trailing, 4)
            }
            
            if viewModel.isLoading {
                ProgressView()
            } else if filteredRates.isEmpty {
                Text("No upcoming rates available")
                    .foregroundColor(.secondary)
            } else {
                chartView
            }
        }
        .sheet(isPresented: $showingLocalSettings) {
            AverageCardSettingsSheet(localSettings: localSettings)
                .environment(\.locale, globalSettings.locale)
        }
        // If you have a custom style, apply it here
        .rateCardStyle()
        .environment(\.locale, globalSettings.locale)
        .id("interactive-chart-\(refreshTrigger)")
        // Refresh if locale changes
        .onChange(of: globalSettings.locale) { _, _ in
            refreshTrigger.toggle()
        }
        // Update 'now' every minute
        .onReceive(timer) { _ in
            // Debug: confirm the timer is actually firing on the device
            print("Timer fired at \(Date())")
            
            // 1) Force the chart to re-calculate by toggling a boolean
            forcedRefresh.toggle()
            
            // 2) Update 'now' with a small animation
            withAnimation(.easeIn(duration: 0.3)) {
                now = Date()  // triggers a new timePriceLabel
            }
        }
        // Force entire chart to refresh whenever forcedRefresh changes
        .id("chart-\(forcedRefresh)")
    }
}
