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

// MARK: - The Card
struct InteractiveLineChartCardView: View {
    @ObservedObject var viewModel: RatesViewModel
    @StateObject private var localSettings = InteractiveChartSettingsManager()
    @EnvironmentObject var globalSettings: GlobalSettingsManager
    
    /// Flip state
    @State private var isFlipped = false
    
    /// "Now" & timer
    @State private var now = Date()
    private let timer = Timer
        .publish(every: 1, on: .main, in: .common)
        .autoconnect()
    
    /// Chart hover states
    @State private var hoveredTime: Date? = nil
    @State private var hoveredPrice: Double? = nil
    @State private var lastSnappedTime: Date? = nil
    
    // For tooltip positioning
    @State private var tooltipPosition: CGPoint = .zero
    
    // Haptic feedback generator
    private let hapticFeedback = UIImpactFeedbackGenerator(style: .light)
    
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
    
    /// Calculate dynamic bar width based on data points
    private var dynamicBarWidth: Double {
        // Using 65 as our base number for better proportions
        let maxPossibleBars = 65.0
        let currentBars = Double(filteredRates.count)
        
        // Direct proportional calculation:
        // At maxPossibleBars (65) -> width should be 5
        // At fewer bars -> width should scale up proportionally
        let width = (maxPossibleBars / currentBars) * 5.0
        
        // For debugging
        print("Bars: \(currentBars), Width: \(width)")
        
        return width
    }
    
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
            now = Date()
        }
        .rateCardStyle()
    }
}

// MARK: - FRONT SIDE
extension InteractiveLineChartCardView {
    private var frontSide: some View {
        VStack(alignment: .leading, spacing: 12) {
            // Header
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
            
            if viewModel.isLoading {
                ProgressView()
            } else if filteredRates.isEmpty {
                Text("No upcoming rates available")
                    .font(Theme.secondaryFont())
                    .foregroundStyle(Theme.secondaryTextColor)
            } else {
                chartView
                    .frame(height: 220)
                    .padding(.top, 30)
            }
        }
    }
    
    /// Our chart
    private var chartView: some View {
        let (minVal, maxVal) = yRange
        return Chart {
            // 1) Highlight best windows (NOT expanded).
            ForEach(bestTimeRanges, id: \.0) { (start, end) in
                RectangleMark(
                    xStart: .value("Start", start),
                    xEnd:   .value("End", end),
                    yStart: .value("Min", minVal),
                    yEnd:   .value("Max", maxVal)
                )
                .foregroundStyle(Theme.mainColor.opacity(0.2))
            }
            
            // 2) "Now" RuleMark (moved before bars)
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
            
            // 3) Actual bars
            ForEach(filteredRates, id: \.validFrom) { rate in
                if let validFrom = rate.validFrom {
                    BarMark(
                        x: .value("Time", validFrom),
                        y: .value("Price", rate.valueIncludingVAT),
                        width: .fixed(dynamicBarWidth)
                    )
                    .foregroundStyle(
                        rate.valueIncludingVAT < 0 
                            ? Theme.secondaryColor
                            : Theme.mainColor
                    )
                }
            }
        }
        .chartXScale(
            domain: xDomain,
            range: .plotDimension(padding: 0)
        )
        .chartYScale(domain: minVal...maxVal)
        .chartPlotStyle { plotContent in
            plotContent
                .padding(.horizontal, 0)
                .frame(maxWidth: .infinity)
        }
        .chartXAxis {
            AxisMarks(values: strideXticks) { value in
                AxisGridLine()
                AxisValueLabel(anchor: .top) {
                    if let date = value.as(Date.self) {
                        xAxisLabel(for: date)
                            .offset(x: 0, y: 0)
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
                                // Safely unwrap plotFrame
                                guard let plotFrame = proxy.plotFrame else { return }
                                
                                let globalLocation = drag.location
                                let plotRect = geo[plotFrame]
                                
                                // Clamp x position to plot bounds
                                let clampedX = min(max(globalLocation.x, plotRect.minX), plotRect.maxX)
                                
                                // Calculate x position within plot
                                let locationInPlot = CGPoint(
                                    x: clampedX - plotRect.minX,
                                    y: globalLocation.y - plotRect.minY
                                )
                                
                                if let date: Date = proxy.value(atX: locationInPlot.x) {
                                    // Clamp date to the available data range
                                    let clampedDate: Date
                                    if let firstDate = filteredRates.first?.validFrom,
                                       let lastDate = filteredRates.last?.validFrom {
                                        clampedDate = min(max(date, firstDate), lastDate)
                                    } else {
                                        clampedDate = date
                                    }
                                    
                                    // Snap to 30-minute intervals
                                    let snappedDate = snapToHalfHour(clampedDate)
                                    
                                    // Provide haptic feedback when moving to a new interval
                                    if snappedDate != lastSnappedTime {
                                        hapticFeedback.impactOccurred()
                                        lastSnappedTime = snappedDate
                                    }
                                    
                                    hoveredTime = snappedDate
                                    hoveredPrice = findNearestPrice(snappedDate)
                                }
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
                        // Draw the vertical highlight line
                        Rectangle()
                            .fill(Theme.mainColor.opacity(0.3))
                            .frame(width: 2, height: rect.height)
                            .position(x: rect.minX + xPos, y: rect.midY)
                        
                        // Prepare the tooltip text
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
                                // Calculate the maximum x position that keeps tooltip visible
                                let maxX = rect.maxX - width/2
                                let minX = rect.minX + width/2
                                let tooltipX = min(maxX, max(minX, rect.minX + xPos))
                                tooltipPosition = CGPoint(x: tooltipX, y: rect.minY + 20)
                            }
                            .position(tooltipPosition)
                    }
                }
            }
        }
    }
    
    private func isHighlightedTime(_ date: Date) -> Bool {
        return bestTimeRanges.contains { range in
            let calendar = Calendar.current
            let startHour = calendar.component(.hour, from: range.0)
            let startMinute = calendar.component(.minute, from: range.0)
            let endHour = calendar.component(.hour, from: range.1)
            let endMinute = calendar.component(.minute, from: range.1)
            
            let dateHour = calendar.component(.hour, from: date)
            let dateMinute = calendar.component(.minute, from: date)
            
            return (dateHour == startHour && dateMinute == startMinute) ||
                   (dateHour == endHour && dateMinute == endMinute)
        }
    }

    private func xAxisLabel(for date: Date) -> some View {
        // First check if date is within bounds, if not return EmptyView
        guard isDateWithinChartBounds(date) else {
            return Text("").foregroundStyle(.clear)
        }

        let calendar = Calendar.current
        let hour = calendar.component(.hour, from: date)
        let text = formatAxisTime(date)
        
        if hour == 0 {
            // For midnight, show date underneath
            let day = calendar.component(.day, from: date)
            let month = calendar.component(.month, from: date)
            return VStack(spacing: 2) {
                Text(text)
                    .foregroundStyle(
                        isHighlightedTime(date)
                            ? Theme.mainColor
                            : Theme.secondaryTextColor
                    )
                Text(String(format: "%02d/%02d", day, month))
                    .foregroundStyle(Theme.secondaryTextColor)
            }
        } else {
            // For other hours, just show the time
            return Text(text)
                .foregroundStyle(
                    isHighlightedTime(date)
                        ? Theme.mainColor
                        : Theme.secondaryTextColor
                )
        }
    }
    
    private func isDateWithinChartBounds(_ date: Date) -> Bool {
        guard let firstDate = filteredRates.first?.validFrom,
              let lastDate = filteredRates.last?.validFrom else {
            return false
        }
        return date >= firstDate && date <= lastDate
    }
}

// MARK: - BACK SIDE
extension InteractiveLineChartCardView {
    private var backSide: some View {
        VStack(alignment: .leading, spacing: 6) {
            // Header
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
            
            // Body
            VStack(alignment: .leading, spacing: 12) {
                // customAverageHours
                HStack(alignment: .top) {
                    Text("Custom Average Hours: \(localSettings.settings.customAverageHours.truncatingRemainder(dividingBy: 1) == 0 ? String(format: "%.0f", localSettings.settings.customAverageHours) : String(format: "%.1f", localSettings.settings.customAverageHours))")
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
                
                // maxListCount
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
            .padding(.top, 8)
            
            Spacer()
        }
        .padding(8)
        // Force content to top
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }
}

// MARK: - Data Logic
extension InteractiveLineChartCardView {
    /// Filter from 1 hr behind now -> next 48 hours
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
    
    /// Y range: clamp min at 0
    private var yRange: (Double, Double) {
        let prices = filteredRates.map { $0.valueIncludingVAT }
        guard !prices.isEmpty else { return (0, 10) }
        let minVal = min(0, (prices.min() ?? 0) - 2)  // Allow negative values and add padding
        let maxVal = (prices.max() ?? 0) + 2
        return (minVal, maxVal)
    }
    
    /// X domain: from earliest validFrom in filteredRates to a bit after the last
    private var xDomain: ClosedRange<Date> {
        guard let earliest = filteredRates.first?.validFrom,
              let latest    = filteredRates.last?.validFrom
        else {
            // fallback
            return now...(now.addingTimeInterval(3600))
        }
        // pad latest by 30 min
        return earliest...(latest.addingTimeInterval(1800))
    }
    
    /// Ticks for specific times we want to show
    private var strideXticks: [Date] {
        var ticks = Set<Date>()
        
        // Add start and end times of highlighted areas
        for (start, end) in bestTimeRanges {
            ticks.insert(start)
            ticks.insert(end)
        }
        
        // Add midnight and noon for the current day
        let calendar = Calendar.current
        if let firstDate = filteredRates.first?.validFrom,
           let lastDate = filteredRates.last?.validFrom {
            // Get all days between first and last date
            var currentDate = calendar.startOfDay(for: firstDate)
            while currentDate <= lastDate {
                // Add midnight
                ticks.insert(currentDate)
                
                // Add noon
                if let noon = calendar.date(bySettingHour: 12, minute: 0, second: 0, of: currentDate) {
                    ticks.insert(noon)
                }
                
                // Move to next day
                currentDate = calendar.date(byAdding: .day, value: 1, to: currentDate) ?? lastDate
            }
        }
        
        // Convert to array and sort
        return Array(ticks).sorted()
    }
    
    /// Find the nearest price for a given time
    private func findNearestPrice(_ date: Date) -> Double? {
        filteredRates.min {
            abs(($0.validFrom ?? .distantPast).timeIntervalSince(date)) <
            abs(($1.validFrom ?? .distantPast).timeIntervalSince(date))
        }?.valueIncludingVAT
    }
    
    /// Best time windows from the ViewModel (merged, but not expanded)
    private var bestTimeRanges: [(Date, Date)] {
        // 1) get the raw windows
        let windows = viewModel.getLowestAveragesIncludingPastHour(
            hours: localSettings.settings.customAverageHours,
            maxCount: localSettings.settings.maxListCount
        )
        // 2) flatten into (start, end)
        let raw = windows.map { ($0.start, $0.end) }
        // 3) merge any overlapping windows
        return mergeWindows(raw)
    }
    
    /// Merge overlapping windows but do NOT expand to bar boundaries
    private func mergeWindows(_ input: [(Date, Date)]) -> [(Date, Date)] {
        if input.isEmpty { return [] }
        let sorted = input.sorted { $0.0 < $1.0 }
        var merged: [(Date, Date)] = [sorted[0]]
        
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
    
    /// Find the current price for now
    private func findCurrentPrice(_ date: Date) -> Double? {
        return filteredRates.first { rate in
            guard let start = rate.validFrom, let end = rate.validTo else { return false }
            return date >= start && date < end
        }?.valueIncludingVAT
    }
    
    /// Find the current rate period
    private func findCurrentRatePeriod(_ date: Date) -> (start: Date, price: Double)? {
        if let rate = filteredRates.first(where: { rate in
            guard let start = rate.validFrom, let end = rate.validTo else { return false }
            return date >= start && date < end
        }) {
            return rate.validFrom.map { ($0, rate.valueIncludingVAT) }
        }
        return nil
    }
}

// MARK: - Formatting
extension InteractiveLineChartCardView {
    private func formatPrice(_ pence: Double, showDecimals: Bool = false, forceFullDecimals: Bool = false) -> String {
        if globalSettings.settings.showRatesInPounds {
            let pounds = pence / 100.0
            return forceFullDecimals ? String(format: "£%.4f", pounds) : String(format: "£%.2f", pounds)
        } else {
            return String(format: showDecimals ? "%.2fp" : "%.0fp", pence)
        }
    }
    
    private var timeFormatter: DateFormatter {
        let f = DateFormatter()
        f.dateFormat = "HH:mm"
        return f
    }
    
    private func formatHalfHourRange(_ date: Date) -> String {
        let calendar = Calendar.current
        let comps = calendar.dateComponents([.year, .month, .day, .hour, .minute], from: date)
        
        let hour = comps.hour ?? 0
        let minute = comps.minute ?? 0
        let halfHour = minute < 30 ? 0 : 30
        
        // Format start time
        let startTime = String(format: "%02d", hour) + (halfHour == 30 ? "½" : "")
        
        // Format end time (next half hour)
        let endHour = halfHour == 30 ? (hour + 1) % 24 : hour
        let endTime = String(format: "%02d", endHour) + (halfHour == 0 ? "½" : "")
        
        return "\(startTime)-\(endTime)"
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
    
    private func formatFullTime(_ date: Date) -> String {
        let calendar = Calendar.current
        let hour = calendar.component(.hour, from: date)
        let minute = calendar.component(.minute, from: date)
        return String(format: "%02d:%02d", hour, minute)
    }
    
    private func formatFullTimeRange(_ date: Date) -> String {
        let calendar = Calendar.current
        let comps = calendar.dateComponents([.year, .month, .day, .hour, .minute], from: date)
        
        let hour = comps.hour ?? 0
        let minute = comps.minute ?? 0
        let halfHour = minute < 30 ? 0 : 30
        
        // Format start time
        let startTime = String(format: "%02d:%02d", hour, halfHour)
        
        // Format end time (next half hour)
        let endHour = halfHour == 30 ? (hour + 1) % 24 : hour
        let endMinute = halfHour == 0 ? 30 : 0
        let endTime = String(format: "%02d:%02d", endHour, endMinute)
        
        return "\(startTime)-\(endTime)"
    }
}