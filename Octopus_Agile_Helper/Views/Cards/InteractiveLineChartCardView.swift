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
    
    static let `default` = AverageCardLocalSettings(
        customAverageHours: 3.0,
        maxListCount: 10
    )
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

// MARK: - Interactive Bar Chart Card (Flip-Card Style)
struct InteractiveLineChartCardView: View {
    @ObservedObject var viewModel: RatesViewModel
    
    // Theme / environment
    @EnvironmentObject var globalSettings: GlobalSettingsManager
    @Environment(\.colorScheme) var colorScheme
    
    // For local settings
    @StateObject private var localSettings = AverageCardLocalSettingsManager()
    
    // Flip state for front/back
    @State private var flipped = false
    
    // Timer for “now” line re-render
    @State private var now: Date = Date()
    let timer = Timer.publish(every: 60, on: .main, in: .common).autoconnect()
    
    // Additional triggers
    @State private var forcedRefresh = false
    @State private var refreshTrigger = false
    
    // Chart hover/tap states
    @State private var hoveredPrice: Double? = nil
    @State private var hoveredTime: Date? = nil
    @State private var labelPosition: CGPoint = .zero
    
    // MARK: - Body
    var body: some View {
        ZStack {
            // FRONT side: bar chart
            frontSide
                .opacity(flipped ? 0 : 1)
                .rotation3DEffect(.degrees(flipped ? 180 : 0),
                                  axis: (x: 0, y: 1, z: 0),
                                  perspective: 0.8)
            
            // BACK side: settings
            backSide
                .opacity(flipped ? 1 : 0)
                .rotation3DEffect(.degrees(flipped ? 0 : -180),
                                  axis: (x: 0, y: 1, z: 0),
                                  perspective: 0.8)
        }
        .rateCardStyle()
        .environment(\.locale, globalSettings.locale)
        .onChange(of: globalSettings.locale) { _, _ in
            refreshTrigger.toggle()
        }
        .id("interactive-chart-\(refreshTrigger)")
    }
    
    // MARK: - Front Side (the bar chart)
    private var frontSide: some View {
        VStack(alignment: .leading, spacing: 12) {
            // Header row
            HStack {
                // Use iconName from registry for .interactiveChart
                if let def = CardRegistry.shared.definition(for: .interactiveChart) {
                    Image(systemName: def.iconName)
                        .foregroundColor(Theme.icon)
                } else {
                    Image(systemName: "chart.xyaxis.line")
                        .foregroundColor(Theme.icon)
                }
                
                Text("Interactive Rate Chart")
                    .font(Theme.titleFont())
                    .foregroundColor(Theme.secondaryTextColor)
                Spacer()
                Button {
                    withAnimation(.spring()) {
                        flipped = true
                    }
                } label: {
                    Image(systemName: "gearshape.fill")
                        .font(Theme.subFont())
                        .foregroundColor(Theme.secondaryTextColor)
                }
            }
            
            if viewModel.isLoading {
                ProgressView()
            } else if filteredRates.isEmpty {
                Text("No upcoming rates available")
                    .foregroundColor(Theme.secondaryTextColor)
            } else {
                chartView
            }
        }
        // Update ‘now’ every minute
        .onReceive(timer) { _ in
            print("Timer fired at \(Date())")
            forcedRefresh.toggle()
            withAnimation(.easeIn(duration: 0.3)) {
                now = Date()
            }
        }
        // Re-render chart
        .id("chart-\(forcedRefresh)")
    }
    
    // MARK: - Back Side (the card settings)
    private var backSide: some View {
        VStack(alignment: .leading, spacing: 12) {
            // Header row
            HStack {
                if let def = CardRegistry.shared.definition(for: .interactiveChart) {
                    Image(systemName: def.iconName)
                        .foregroundColor(Theme.icon)
                } else {
                    Image(systemName: "chart.xyaxis.line")
                        .foregroundColor(Theme.icon)
                }
                
                Text("Card Settings")
                    .font(Theme.titleFont())
                    .foregroundColor(Theme.secondaryTextColor)
                
                Spacer()
                // Flip back
                Button {
                    withAnimation(.spring()) {
                        flipped = false
                    }
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(Theme.subFont())
                        .foregroundColor(Theme.secondaryTextColor)
                }
            }
            
            // Stepper controls
            HStack(alignment: .top) {
                Text("Custom Hours: \(String(format: "%.1f", localSettings.settings.customAverageHours))")
                    .font(Theme.secondaryFont())
                    .foregroundColor(Theme.mainTextColor)
                
                Spacer()
                Stepper(
                    "",
                    value: $localSettings.settings.customAverageHours,
                    in: 1...24,
                    step: 0.5
                )
                .labelsHidden()
                .font(Theme.secondaryFont())
                .foregroundColor(Theme.mainTextColor)
                .tint(Theme.secondaryColor)
                .padding(.horizontal, 6)
                .background(Theme.secondaryBackground)
                .cornerRadius(8)
            }
            
            HStack(alignment: .top) {
                Text("Max List Count: \(localSettings.settings.maxListCount)")
                    .font(Theme.secondaryFont())
                    .foregroundColor(Theme.mainTextColor)
                
                Spacer()
                Stepper(
                    "",
                    value: $localSettings.settings.maxListCount,
                    in: 1...50
                )
                .labelsHidden()
                .font(Theme.secondaryFont())
                .foregroundColor(Theme.mainTextColor)
                .tint(Theme.secondaryColor)
                .padding(.horizontal, 6)
                .background(Theme.secondaryBackground)
                .cornerRadius(8)
            }
        }
        .padding(8)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }
    
    // MARK: - Chart Logic

    /// We'll read from `viewModel.allRates` then filter to 1 hour behind 'now' + 24h ahead
    private var filteredRates: [RateEntity] {
        let earliestWanted = now.addingTimeInterval(-3600)
        let latestWanted   = now.addingTimeInterval(24 * 3600)
        
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
        
        let rawMax = values.max() ?? 0
        let minVal = 0.0
        let maxVal = rawMax + 2.0
        return (minVal, maxVal)
    }
    
    /// Domain for x-axis
    private var domainRange: ClosedRange<Date> {
        guard let earliestData = filteredRates.first?.validFrom,
              let latestData = filteredRates.last?.validFrom
        else {
            // fallback if no data
            let fallbackEnd = now.addingTimeInterval(3600)
            return now...fallbackEnd
        }
        return earliestData...(latestData.addingTimeInterval(300))
    }
    
    /// Merge best time windows
    private var bestTimeRanges: [(Date, Date)] {
        let bestWindows = viewModel.getLowestAverages(
            hours: localSettings.settings.customAverageHours,
            maxCount: localSettings.settings.maxListCount
        )
        let raw = bestWindows.map { ($0.start, $0.end) }
        return mergeTimeWindows(raw)
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

    /// If user taps, find nearest price
    private func findNearestPrice(_ date: Date) -> Double? {
        guard !filteredRates.isEmpty else { return nil }
        return filteredRates.min {
            abs(($0.validFrom ?? .distantPast).timeIntervalSince(date)) <
            abs(($1.validFrom ?? .distantPast).timeIntervalSince(date))
        }?.valueIncludingVAT
    }

    // MARK: - Ticks for X Axis
    private var xAxisTickDates: [Date] {
        let cal = Calendar.current
        // The day containing domainRange.lowerBound
        let startOfFirstDay = cal.startOfDay(for: domainRange.lowerBound)
        // The day containing domainRange.upperBound, plus 1 day
        let endOfLastDay = cal.date(byAdding: .day, value: 1,
                                    to: cal.startOfDay(for: domainRange.upperBound))
            ?? domainRange.upperBound
        
        var ticks: [Date] = []
        var currentDay = startOfFirstDay
        
        // Step day by day until we pass endOfLastDay
        while currentDay <= endOfLastDay {
            for hour in [0, 6, 12, 18, 23] {
                if let tickDate = cal.date(bySettingHour: hour, minute: 0, second: 0, of: currentDay) {
                    // Only add if it's within domainRange
                    if tickDate >= domainRange.lowerBound && tickDate <= domainRange.upperBound {
                        ticks.append(tickDate)
                    }
                }
            }
            // Move currentDay to the next day
            if let nextDay = cal.date(byAdding: .day, value: 1, to: currentDay) {
                currentDay = nextDay
            } else {
                break
            }
        }
        
        return ticks.sorted()
    }
    
    // MARK: - “Now” label
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
    
    // MARK: - Helpers
    private func shortTime(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = globalSettings.locale
        formatter.dateFormat = "ha"
        return formatter.string(from: date).lowercased()
    }
    
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
        return (start, start.addingTimeInterval(1800))
    }
    
    // MARK: - The Bar Chart Itself
    private var chartView: some View {
        let (minY, maxY) = chartPriceRange
        
        return Chart {
            // Highlight windows
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
                            Theme.mainColor.opacity(0.12),
                            Theme.mainColor.opacity(0.25)
                        ]),
                        startPoint: .top,
                        endPoint: .bottom
                    )
                )
                .zIndex(-2)
            }
            
            // The main bars
            ForEach(filteredRates, id: \.validFrom) { rate in
                if let validFrom = rate.validFrom {
                    BarMark(
                        x: .value("Time", validFrom),
                        y: .value("Price", rate.valueIncludingVAT)
                    )
                    .foregroundStyle(Theme.mainColor)
                    .cornerRadius(3)
                }
            }
            
            // “Now” rule
            RuleMark(x: .value("NowLine", now))
                .lineStyle(StrokeStyle(lineWidth: 1.5, dash: [4,2]))
                .foregroundStyle(.green.opacity(0.8))
                .annotation(position: .top, alignment: .center) {
                    Text(timePriceLabel)
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
                        .offset(x: 40, y: 0)
                }
        }
        .frame(minHeight: 220, maxHeight: 240)
        .chartPlotStyle { content in
            content.padding(.top, 20)
            content.padding(.bottom, 8)
        }
        .chartXScale(domain: domainRange, range: .plotDimension(padding: 0))
        
        // Custom X-axis with ticks at hours [0,6,12,18,23]
        .chartXAxis {
            AxisMarks(values: xAxisTickDates) { value in
                AxisGridLine()
                    .foregroundStyle(Color.secondary.opacity(0.2))
                AxisValueLabel {
                    if let date = value.as(Date.self) {
                        let hour = Calendar.current.component(.hour, from: date)
                        Text(String(format: "%02d", hour))
                            .font(.system(size: 12))
                    }
                }
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
                    AxisGridLine()
                        .foregroundStyle(Color.secondary.opacity(0.2))
                    AxisTick(centered: false, length: 0)
                }
            }
        }
        
        // Tap overlay
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
                        let plotFrame = proxy.plotFrame
                    {
                        let plotRect = geo[plotFrame]
                        
                        // Highlight bar
                        Rectangle()
                            .fill(Theme.mainColor.opacity(0.4))
                            .frame(width: 4)
                            .position(x: plotRect.minX + xPos, y: plotRect.midY)
                            .frame(height: plotRect.height)
                        
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
}
