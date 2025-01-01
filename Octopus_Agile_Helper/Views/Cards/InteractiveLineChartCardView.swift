import SwiftUI
import Charts
import Foundation

// MARK: - Tooltip Width Preference Key
private struct TooltipWidthKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = nextValue()
    }
}

// MARK: - Simplified Local Settings
struct InteractiveChartSettings: Codable {
    var customAverageHours: Double
    var maxListCount: Int
    
    static let `default` = InteractiveChartSettings(
        customAverageHours: 3.0,
        maxListCount: 10
    )
}

class InteractiveChartSettingsManager: ObservableObject {
    @Published var settings: InteractiveChartSettings {
        didSet { saveSettings() }
    }
    
    private let userDefaultsKey = "MyChartSettings"
    
    init() {
        if let data = UserDefaults.standard.data(forKey: userDefaultsKey),
           let decoded = try? JSONDecoder().decode(InteractiveChartSettings.self, from: data) {
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

// MARK: - Main Chart View
struct InteractiveLineChartCardView: View {
    @ObservedObject var viewModel: RatesViewModel
    @StateObject private var localSettings = InteractiveChartSettingsManager()
    @EnvironmentObject var globalSettings: GlobalSettingsManager
    
    // Flip state (front/back)
    @State private var isFlipped = false
    
    // "Now" & timer, set to fire every 60 seconds
    @State private var now = Date()
    // Timer for "Now" annotation updates
    private let timer = Timer
        .publish(every: 1, on: .main, in: .common)
        .autoconnect()
    
    // Timer for content refresh
    private let refreshTimer = Timer
        .publish(every: 1, on: .main, in: .common)
        .autoconnect()
    
    // Chart hover states
    @State private var hoveredTime: Date? = nil
    @State private var hoveredPrice: Double? = nil
    @State private var lastSnappedTime: Date? = nil
    
    // Bar width optimization
    @State private var barWidth: Double = 0
    @State private var lastSnappedMinute: Int?
    @State private var lastPrintedWidth: Double?
    
    // Tooltip
    @State private var tooltipPosition: CGPoint = .zero
    
    // Haptic feedback generator
    private let hapticFeedback = UIImpactFeedbackGenerator(style: .light)
    
    var body: some View {
        ZStack {
            // FRONT side
            frontSide
                .opacity(isFlipped ? 0 : 1)
                .rotation3DEffect(.degrees(isFlipped ? 180 : 0),
                                  axis: (x: 0, y: 1, z: 0),
                                  perspective: 0.8)
            
            // BACK side (settings)
            backSide
                .opacity(isFlipped ? 1 : 0)
                .rotation3DEffect(.degrees(isFlipped ? 0 : -180),
                                  axis: (x: 0, y: 1, z: 0),
                                  perspective: 0.8)
        }
        .onReceive(timer) { _ in
            let calendar = Calendar.current
            let second = calendar.component(.second, from: Date())
            // Only update if we're at second 0
            if second == 0 {
                now = Date()
            }
        }
        .onReceive(refreshTimer) { _ in
            let calendar = Calendar.current
            let date = Date()
            let minute = calendar.component(.minute, from: date)
            let second = calendar.component(.second, from: date)
            
            // Only refresh content at o'clock and half o'clock
            if second == 0 && (minute == 0 || minute == 30) {
                Task {
                    await viewModel.refreshRates()
                }
            }
        }
        .onChange(of: filteredRates) { oldValue, newValue in
            // If the rates change significantly, recalc bar width right away
            recalcBarWidthAndPrintOnce()
        }
        .onAppear {
            // Calculate once initially
            recalcBarWidthAndPrintOnce()
        }
        .rateCardStyle() // Custom view modifier
    }
    
    // MARK: Timer & Bar Width
    private func handleTimerTick() {
        now = Date()
        
        // Check if minute is :00 or :30
        let minute = Calendar.current.component(.minute, from: now)
        let second = Calendar.current.component(.second, from: now)
        
        // Only if we're exactly at second == 0 and minute is 0 or 30:
        if second == 0, (minute == 0 || minute == 30) {
            // Avoid re-triggering if we already did so for the same minute
            if lastSnappedMinute != minute {
                lastSnappedMinute = minute
                recalcBarWidthAndPrintOnce()
            }
        }
    }
    
    /// Recalculate bar width once and print the debug only if it actually changed
    private func recalcBarWidthAndPrintOnce() {
        let newWidth = computeDynamicBarWidth()
        guard newWidth != barWidth else { return }
        
        barWidth = newWidth
        
        // Print debug only if newly changed
        #if DEBUG
        if lastPrintedWidth != newWidth {
            print("Updated bar width: \(newWidth)")
            lastPrintedWidth = newWidth
        }
        #endif
    }
}

// MARK: - Front Side
extension InteractiveLineChartCardView {
    private var frontSide: some View {
        VStack(alignment: .leading, spacing: 12) {
            headerBar
            if viewModel.isLoading {
                ProgressView()
            } else if filteredRates.isEmpty {
                noDataView
            } else {
                chartView
                    .frame(height: 220)
                    .padding(.top, 30)
            }
        }
    }
    
    /// The header bar on the front side
    private var headerBar: some View {
        HStack {
            if let def = CardRegistry.shared.definition(for: .interactiveChart) {
                Image(systemName: def.iconName)
                    .foregroundColor(Theme.icon)
            }
            Text("Interactive Rates")
                .font(Theme.titleFont())
                .foregroundStyle(Theme.mainTextColor)
            Spacer()
            Button {
                withAnimation(.spring()) {
                    isFlipped = true
                }
            } label: {
                Image(systemName: "gearshape.fill")
                    .foregroundStyle(Theme.secondaryTextColor)
            }
        }
    }
    
    /// The "No Data" view
    private var noDataView: some View {
        Text("No upcoming rates available")
            .font(Theme.secondaryFont())
            .foregroundStyle(Theme.secondaryTextColor)
    }
    
    /// The main chart
    private var chartView: some View {
        let (minVal, maxVal) = yRange
        
        return Chart {
            // 1) Highlight best windows (not expanded).
            ForEach(bestTimeRanges, id: \.0) { (start, end) in
                RectangleMark(
                    xStart: .value("Start", start),
                    xEnd:   .value("End", end),
                    yStart: .value("Min", minVal),
                    yEnd:   .value("Max", maxVal)
                )
                .foregroundStyle(Theme.mainColor.opacity(0.2))
            }
            
            // 2) "Now" rule
            if let currentPeriod = findCurrentRatePeriod(now) {
                RuleMark(x: .value("Now", currentPeriod.start))
                    .lineStyle(StrokeStyle(lineWidth: 2))
                    .foregroundStyle(Theme.secondaryColor.opacity(0.7))
                    .annotation(position: .top) {
                        Text("\(formatFullTime(now)) (\(formatPrice(currentPeriod.price, showDecimals: true, forceFullDecimals: true)))")
                            .font(Theme.subFont().weight(.light))
                            .scaleEffect(0.85)
                            .padding(4)
                            .background(Theme.secondaryBackground)
                            .foregroundStyle(Theme.mainTextColor)
                            .cornerRadius(4)
                    }
            }
            
            // 3) Bars
            ForEach(filteredRates, id: \.validFrom) { rate in
                if let validFrom = rate.validFrom {
                    BarMark(
                        x: .value("Time", validFrom),
                        y: .value("Price", rate.valueIncludingVAT),
                        width: .fixed(barWidth)
                    )
                    .cornerRadius(3)
                    .foregroundStyle(
                        rate.valueIncludingVAT < 0
                            ? Theme.secondaryColor
                            : Theme.mainColor
                    )
                }
            }
        }
        .chartXScale(domain: xDomain, range: .plotDimension(padding: 0))
        .chartYScale(domain: minVal...maxVal)
        .chartPlotStyle { plotContent in
            plotContent
                .padding(.horizontal, 0)
                .padding(.leading, 16)
                .frame(maxWidth: .infinity)
        }
        .chartXAxis {
            AxisMarks(values: strideXticks) { value in
                AxisGridLine()
                AxisValueLabel(anchor: .top) {
                    if let date = value.as(Date.self) {
                        xAxisLabel(for: date)
                            .offset(x: 16, y: 0)
                    }
                }
            }
        }
        .chartYAxis {
            AxisMarks(position: .leading) { value in
                if let val = value.as(Double.self) {
                    AxisValueLabel {
                        Text(formatPrice(val))
                            .foregroundStyle(Theme.secondaryTextColor)
                    }
                }
            }
        }
        .chartOverlay { proxy in
            GeometryReader { geo in
                Rectangle()
                    .fill(.clear)
                    .contentShape(Rectangle())
                    .gesture(
                        DragGesture(minimumDistance: 0)
                            .onChanged { drag in
                                handleDragChanged(
                                    drag: drag,
                                    proxy: proxy,
                                    geo: geo
                                )
                            }
                            .onEnded { _ in
                                hoveredTime = nil
                                hoveredPrice = nil
                            }
                    )
                
                // If we have a hovered date/price, show highlight & tooltip
                if let time = hoveredTime, let price = hoveredPrice {
                    if let xPos = proxy.position(forX: time),
                       let plotArea = proxy.plotFrame {
                        let rect = geo[plotArea]
                        drawHoverElements(rect: rect, xPos: xPos, time: time, price: price)
                    }
                }
            }
        }
    }
}

// MARK: - Back Side
extension InteractiveLineChartCardView {
    private var backSide: some View {
        VStack(alignment: .leading, spacing: 6) {
            settingsHeaderBar
            
            VStack(alignment: .leading, spacing: 12) {
                // customAverageHours
                customAverageHoursView
                // maxListCount
                maxListCountView
            }
            .padding(.top, 8)
            
            Spacer()
        }
        .padding(8)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }
    
    /// The header on the back side
    private var settingsHeaderBar: some View {
        HStack {
            if let def = CardRegistry.shared.definition(for: .interactiveChart) {
                Image(systemName: def.iconName)
                    .foregroundStyle(Theme.icon)
            }
            Text("Card Settings")
                .font(Theme.titleFont())
                .foregroundStyle(Theme.mainTextColor)
            Spacer()
            Button {
                withAnimation(.spring()) {
                    isFlipped = false
                }
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .font(Theme.subFont())
                    .foregroundStyle(Theme.secondaryTextColor)
            }
        }
    }
    
    /// Settings UI for customAverageHours
    private var customAverageHoursView: some View {
        HStack(alignment: .top) {
            let hours = localSettings.settings.customAverageHours
            let displayHours = hours.truncatingRemainder(dividingBy: 1) == 0
                ? String(format: "%.0f", hours)
                : String(format: "%.1f", hours)
            
            Text("Custom Average Hours: \(displayHours)")
                .font(Theme.secondaryFont())
                .foregroundStyle(Theme.mainTextColor)
            Spacer()
            Stepper(
                "",
                value: $localSettings.settings.customAverageHours,
                in: 0.5...24,
                step: 0.5
            )
            .labelsHidden()
            .font(Theme.secondaryFont())
            .foregroundStyle(Theme.mainTextColor)
            .tint(Theme.secondaryColor)
            .padding(.horizontal, 6)
            .background(Theme.secondaryBackground)
            .cornerRadius(8)
        }
    }
    
    /// Settings UI for maxListCount
    private var maxListCountView: some View {
        HStack(alignment: .top) {
            Text("Max List Count: \(localSettings.settings.maxListCount)")
                .font(Theme.secondaryFont())
                .foregroundStyle(Theme.mainTextColor)
            Spacer()
            Stepper(
                "",
                value: $localSettings.settings.maxListCount,
                in: 1...50
            )
            .labelsHidden()
            .font(Theme.secondaryFont())
            .foregroundStyle(Theme.mainTextColor)
            .tint(Theme.secondaryColor)
            .padding(.horizontal, 6)
            .background(Theme.secondaryBackground)
            .cornerRadius(8)
        }
    }
}

// MARK: - Chart Interaction Helpers
extension InteractiveLineChartCardView {
    /// Gesture handler for dragging across the chart
    private func handleDragChanged(drag: DragGesture.Value,
                                   proxy: ChartProxy,
                                   geo: GeometryProxy) {
        guard let plotFrame = proxy.plotFrame else { return }
        
        let globalLocation = drag.location
        let plotRect = geo[plotFrame]
        
        // Clamp x position to plot bounds
        let clampedX = min(max(globalLocation.x, plotRect.minX), plotRect.maxX)
        
        // Get location in the plot
        let locationInPlot = CGPoint(
            x: clampedX - plotRect.minX,
            y: globalLocation.y - plotRect.minY
        )
        
        if let rawDate: Date = proxy.value(atX: locationInPlot.x) {
            let clampedDate = clampDateToDataRange(rawDate)
            let snappedDate = snapToHalfHour(clampedDate)
            
            // Provide haptic feedback on each new half-hour snap
            if snappedDate != lastSnappedTime {
                hapticFeedback.impactOccurred()
                lastSnappedTime = snappedDate
            }
            
            hoveredTime = snappedDate
            hoveredPrice = findNearestPrice(snappedDate)
        }
    }
    
    /// Draws the vertical highlight line + tooltip in the overlay
    @ViewBuilder
    private func drawHoverElements(rect: CGRect,
                                   xPos: CGFloat,
                                   time: Date,
                                   price: Double) -> some View {
        // Vertical highlight line
        Rectangle()
            .fill(Theme.mainColor.opacity(0.3))
            .frame(width: 2, height: rect.height)
            .position(x: rect.minX + xPos, y: rect.midY)
        
        // Tooltip
        let timeRange = formatFullTimeRange(time)
        let priceText = formatPrice(price, showDecimals: true)
        
        Text("\(timeRange)\n\(priceText)")
            .font(Theme.subFont())
            .padding(6)
            .background(Theme.secondaryBackground)
            .foregroundStyle(Theme.mainTextColor)
            .cornerRadius(6)
            .fixedSize()
            .overlay {
                GeometryReader { tooltipGeo in
                    Color.clear.preference(
                        key: TooltipWidthKey.self,
                        value: tooltipGeo.size.width
                    )
                }
            }
            .onPreferenceChange(TooltipWidthKey.self) { width in
                // Clamp tooltip horizontally
                let maxX = rect.maxX - width / 2
                let minX = rect.minX + width / 2
                let tooltipX = min(maxX, max(minX, rect.minX + xPos))
                tooltipPosition = CGPoint(x: tooltipX, y: rect.minY + 20)
            }
            .position(tooltipPosition)
    }
}

// MARK: - Data Logic
extension InteractiveLineChartCardView {
    /// Only refresh from 1 hr behind now to next 48 hrs
    private var filteredRates: [RateEntity] {
        let start = now.addingTimeInterval(-3600)
        let end   = now.addingTimeInterval(48 * 3600)
        
        return viewModel.allRates
            .filter { $0.validFrom != nil && $0.validTo != nil }
            .sorted { ($0.validFrom ?? .distantPast) < ($1.validFrom ?? .distantPast) }
            .filter {
                guard let date = $0.validFrom else { return false }
                return (date >= start && date <= end)
            }
    }
    
    /// Y range: clamp min at 0, add 2 pence padding on both ends
    private var yRange: (Double, Double) {
        let prices = filteredRates.map { $0.valueIncludingVAT }
        guard !prices.isEmpty else { return (0, 10) }
        let minVal = min(0, (prices.min() ?? 0) - 2)
        let maxVal = (prices.max() ?? 0) + 2
        return (minVal, maxVal)
    }
    
    /// X domain: from earliest rate to 30 mins after the last
    private var xDomain: ClosedRange<Date> {
        guard let earliest = filteredRates.first?.validFrom,
              let latest = filteredRates.last?.validFrom
        else {
            // Fallback domain of 1 hour
            return now...(now.addingTimeInterval(3600))
        }
        return earliest...(latest.addingTimeInterval(1800))
    }
    
    /// x-axis ticks for specific times
    private var strideXticks: [Date] {
        var ticks = Set<Date>()
        
        // Add start/end times of highlighted areas
        for (start, end) in bestTimeRanges {
            ticks.insert(start)
            ticks.insert(end)
        }
        
        // Add midnight & noon for the displayed range
        let calendar = Calendar.current
        if let firstDate = filteredRates.first?.validFrom,
           let lastDate = filteredRates.last?.validFrom {
            var currentDate = calendar.startOfDay(for: firstDate)
            while currentDate <= lastDate {
                // midnight
                ticks.insert(currentDate)
                
                // noon
                if let noon = calendar.date(bySettingHour: 12, minute: 0, second: 0, of: currentDate) {
                    ticks.insert(noon)
                }
                
                // next day
                currentDate = calendar.date(byAdding: .day, value: 1, to: currentDate) ?? lastDate
            }
        }
        
        let sortedTicks = Array(ticks).sorted()
        return sortedTicks
    }
    
    /// Best time windows from the view model
    private var bestTimeRanges: [(Date, Date)] {
        let windows = viewModel.getLowestAveragesIncludingPastHour(
            hours: localSettings.settings.customAverageHours,
            maxCount: localSettings.settings.maxListCount
        )
        let raw = windows.map { ($0.start, $0.end) }
        return mergeWindows(raw)
    }
    
    /// Merges overlapping time windows (but doesn't expand them to bar boundaries)
    private func mergeWindows(_ input: [(Date, Date)]) -> [(Date, Date)] {
        guard !input.isEmpty else { return [] }
        let sorted = input.sorted { $0.0 < $1.0 }
        
        var merged = [sorted[0]]
        for window in sorted.dropFirst() {
            let lastIndex = merged.count - 1
            if window.0 <= merged[lastIndex].1 {
                merged[lastIndex].1 = max(merged[lastIndex].1, window.1)
            } else {
                merged.append(window)
            }
        }
        return merged
    }
    
    /// Finds the current period for a given date
    private func findCurrentRatePeriod(_ date: Date) -> (start: Date, price: Double)? {
        guard let rate = filteredRates.first(where: { r in
            guard let start = r.validFrom, let end = r.validTo else { return false }
            return date >= start && date < end
        }) else {
            return nil
        }
        if let start = rate.validFrom {
            return (start, rate.valueIncludingVAT)
        }
        return nil
    }
    
    /// Finds the nearest price to a given date
    private func findNearestPrice(_ date: Date) -> Double? {
        filteredRates.min {
            abs(($0.validFrom ?? .distantPast).timeIntervalSince(date)) <
            abs(($1.validFrom ?? .distantPast).timeIntervalSince(date))
        }?.valueIncludingVAT
    }
    
    /// Clamp a raw date to the earliest & latest in our filtered data
    private func clampDateToDataRange(_ date: Date) -> Date {
        guard let firstDate = filteredRates.first?.validFrom,
              let lastDate = filteredRates.last?.validFrom
        else {
            return date
        }
        return min(max(date, firstDate), lastDate)
    }
    
    /// Snap date to 30-minute intervals
    private func snapToHalfHour(_ date: Date) -> Date {
        let calendar = Calendar.current
        let comps = calendar.dateComponents([.year, .month, .day, .hour, .minute], from: date)
        let halfHour = (comps.minute ?? 0) < 30 ? 0 : 30
        let snappedComps = DateComponents(
            year: comps.year,
            month: comps.month,
            day: comps.day,
            hour: comps.hour,
            minute: halfHour
        )
        return calendar.date(from: snappedComps) ?? date
    }
}

// MARK: - Visual & Formatting
extension InteractiveLineChartCardView {
    /// Dynamically calculate bar width (with gap ratio)
    private func computeDynamicBarWidth() -> Double {
        let maxPossibleBars   = 65.0
        let currentBars       = Double(filteredRates.count)
        let baseWidthPerBar   = 5.0
        let barGapRatio       = 0.7  // 70% bar, 30% gap
        let totalChunk        = (maxPossibleBars / currentBars) * baseWidthPerBar
        let barWidth          = totalChunk * barGapRatio
        return barWidth
    }
    
    /// Axis label generator
    private func xAxisLabel(for date: Date) -> some View {
        guard isDateWithinChartBounds(date) else {
            return VStack(spacing: 2) {
                Text("")
                    .foregroundStyle(.clear)
                Text("")
                    .foregroundStyle(.clear)
            }
        }
        let calendar = Calendar.current
        let hour = calendar.component(.hour, from: date)
        let text = formatAxisTime(date)
        
        if hour == 0 {
            // Show date under "00"
            let day = calendar.component(.day, from: date)
            let month = calendar.component(.month, from: date)
            return VStack(spacing: 2) {
                Text(text)
                    .foregroundStyle(highlightColor(for: date))
                Text(String(format: "%02d/%02d", day, month))
                    .foregroundStyle(Theme.secondaryTextColor)
            }
        } else {
            // Normal hour
            return VStack(spacing: 2) {
                Text(text)
                    .foregroundStyle(highlightColor(for: date))
                Text("")
                    .foregroundStyle(.clear)
            }
        }
    }
    
    /// Determines if a date is inside our filtered range
    private func isDateWithinChartBounds(_ date: Date) -> Bool {
        guard let firstDate = filteredRates.first?.validFrom,
              let lastDate  = filteredRates.last?.validFrom else {
            return false
        }
        return date >= firstDate && date <= lastDate
    }
    
    /// Highlights times that match best windows’ boundaries
    private func highlightColor(for date: Date) -> Color {
        isHighlightedTime(date) ? Theme.mainColor : Theme.secondaryTextColor
    }
    
    private func isHighlightedTime(_ date: Date) -> Bool {
        let calendar = Calendar.current
        return bestTimeRanges.contains { range in
            let (startHour, startMinute) = (calendar.component(.hour, from: range.0),
                                            calendar.component(.minute, from: range.0))
            let (endHour, endMinute)     = (calendar.component(.hour, from: range.1),
                                            calendar.component(.minute, from: range.1))
            let (dateHour, dateMinute)   = (calendar.component(.hour, from: date),
                                            calendar.component(.minute, from: date))
            
            let matchesStart = (dateHour == startHour && dateMinute == startMinute)
            let matchesEnd   = (dateHour == endHour && dateMinute == endMinute)
            
            return matchesStart || matchesEnd
        }
    }
    
    /// Price formatting
    private func formatPrice(_ pence: Double,
                             showDecimals: Bool = false,
                             forceFullDecimals: Bool = false) -> String {
        if globalSettings.settings.showRatesInPounds {
            let pounds = pence / 100.0
            return forceFullDecimals
                ? String(format: "£%.4f", pounds)
                : String(format: "£%.2f", pounds)
        } else {
            return String(format: showDecimals ? "%.2fp" : "%.0fp", pence)
        }
    }
    
    private func formatAxisTime(_ date: Date) -> String {
        let calendar = Calendar.current
        let hour = calendar.component(.hour, from: date)
        let minute = calendar.component(.minute, from: date)
        
        if minute == 30 {
            return "\(String(format: "%02d", hour))½"
        } else {
            return String(format: "%02d", hour)
        }
    }
    
    /// Full time with minute
    private func formatFullTime(_ date: Date) -> String {
        let calendar = Calendar.current
        let hour   = calendar.component(.hour, from: date)
        let minute = calendar.component(.minute, from: date)
        return String(format: "%02d:%02d", hour, minute)
    }
    
    /// Full half-hour range (e.g. 09:00-09:30)
    private func formatFullTimeRange(_ date: Date) -> String {
        let calendar = Calendar.current
        let comps = calendar.dateComponents([.year, .month, .day, .hour, .minute], from: date)
        
        let hour     = comps.hour ?? 0
        let minute   = comps.minute ?? 0
        let halfHour = minute < 30 ? 0 : 30
        
        // Start
        let startTime = String(format: "%02d:%02d", hour, halfHour)
        
        // End
        let endHour   = halfHour == 30 ? (hour + 1) % 24 : hour
        let endMinute = halfHour == 0 ? 30 : 0
        let endTime   = String(format: "%02d:%02d", endHour, endMinute)
        
        return "\(startTime)-\(endTime)"
    }
}