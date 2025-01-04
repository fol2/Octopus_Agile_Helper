import Charts
import Combine
import Foundation
import SwiftUI
import OctopusHelperShared

// MARK: - Tooltip Width Preference Key
private struct TooltipWidthKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = nextValue()
    }
}

// MARK: - Simplified Local Settings
public struct InteractiveChartSettings: Codable {
    public var customAverageHours: Double
    public var maxListCount: Int

    public static let `default` = InteractiveChartSettings(
        customAverageHours: 3.0,
        maxListCount: 10
    )
}

public class InteractiveChartSettingsManager: ObservableObject {
    @Published public var settings: InteractiveChartSettings {
        didSet { saveSettings() }
    }

    private let userDefaultsKey = "MyChartSettings"

    public init() {
        if let data = UserDefaults.standard.data(forKey: userDefaultsKey),
            let decoded = try? JSONDecoder().decode(InteractiveChartSettings.self, from: data)
        {
            self.settings = decoded
        } else {
            self.settings = .default
        }
    }

    private func saveSettings() {
        if let encoded = try? JSONEncoder().encode(settings) {
            UserDefaults.standard.set(encoded, forKey: userDefaultsKey)
        }
    }
}

// MARK: - Main Chart View
public struct InteractiveLineChartCardView: View {
    @ObservedObject var viewModel: RatesViewModel
    @StateObject private var localSettings = InteractiveChartSettingsManager()
    @EnvironmentObject var globalSettings: GlobalSettingsManager

    // Flip state (front/back)
    @State private var isFlipped = false

    // "Now" state
    @State private var now = Date()

    // For app state detection
    @Environment(\.scenePhase) var scenePhase

    // For DRY, we rely on CardRefreshManager
    @ObservedObject private var refreshManager = CardRefreshManager.shared

    // Chart hover states
    @State private var hoveredTime: Date? = nil
    @State private var hoveredPrice: Double? = nil
    @State private var lastSnappedTime: Date? = nil

    // Bar width
    @State private var barWidth: Double = 0
    @State private var lastSnappedMinute: Int?
    @State private var lastPrintedWidth: Double?

    // Tooltip
    @State private var tooltipPosition: CGPoint = .zero

    // Haptic feedback generator
    private let hapticFeedback = UIImpactFeedbackGenerator(style: .light)

    // --- NEW: Final x-axis labels after pixel-based collision ---
    @State private var finalXLabels: [LabelCandidate] = []

    public var body: some View {
        ZStack {
            // FRONT side
            frontSide
                .opacity(isFlipped ? 0 : 1)
                .rotation3DEffect(
                    .degrees(isFlipped ? 180 : 0),
                    axis: (x: 0, y: 1, z: 0),
                    perspective: 0.8)

            // BACK side (settings)
            backSide
                .opacity(isFlipped ? 1 : 0)
                .rotation3DEffect(
                    .degrees(isFlipped ? 0 : -180),
                    axis: (x: 0, y: 1, z: 0),
                    perspective: 0.8)
        }
        // Instead of local timer, we use CardRefreshManager
        .onReceive(refreshManager.$minuteTick) { tickTime in
            guard let t = tickTime else { return }
            self.now = t
            handleMinuteTick()
        }
        .onReceive(refreshManager.$halfHourTick) { tickTime in
            guard tickTime != nil else { return }
            recalcBarWidthAndPrintOnce()
        }
        .onReceive(refreshManager.$sceneActiveTick) { _ in
            now = Date()
            Task {
                await viewModel.refreshRates()
            }
        }
        .onChange(of: filteredRates, initial: true) { oldValue, newValue in
            recalcBarWidthAndPrintOnce()
        }
        .onAppear {
            now = Date()
            recalcBarWidthAndPrintOnce()
        }
        .rateCardStyle()
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

    private var headerBar: some View {
        HStack {
            if let def = CardRegistry.shared.definition(for: .interactiveChart) {
                Image(systemName: def.iconName)
                    .foregroundColor(Theme.icon)
                Text(LocalizedStringKey(def.displayNameKey))
                    .font(Theme.titleFont())
                    .foregroundStyle(Theme.secondaryTextColor)
            }
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

    private var noDataView: some View {
        Text("No upcoming rates available")
            .font(Theme.secondaryFont())
            .foregroundStyle(Theme.secondaryTextColor)
    }

    /// The main chart
    private var chartView: some View {
        let (minVal, maxVal) = yRange

        return Chart {
            // 1) Highlight best windows - using rendering times with epsilon shift
            ForEach(bestTimeRangesRender, id: \.0) { (start, end) in
                RectangleMark(
                    xStart: .value("Start", start),
                    xEnd: .value("End", end),
                    yStart: .value("Min", minVal),
                    yEnd: .value("Max", maxVal)
                )
                .foregroundStyle(Theme.mainColor.opacity(0.2))
            }

            // 2) "Now" rule
            if let currentPeriod = findCurrentRatePeriod(now) {
                RuleMark(x: .value("Now", currentPeriod.start))
                    .lineStyle(StrokeStyle(lineWidth: 2))
                    .foregroundStyle(Theme.secondaryColor.opacity(0.7))
                    .annotation(position: .top) {
                        Text(
                            "\(formatFullTime(now)) (\(formatPrice(currentPeriod.price, showDecimals: true, forceFullDecimals: true)))"
                        )
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
            AxisMarks(values: finalXLabels.map(\.domainDate)) { value in
                // AxisGridLine()
                AxisValueLabel(anchor: .top) {
                    if let domainVal = value.as(Date.self) {
                        // find the matching candidate
                        if let candidate = finalXLabels.first(where: { $0.domainDate == domainVal })
                        {
                            let displayDate = candidate.labelDate
                            let prio = candidate.priority
                            xAxisLabel(for: displayDate, priority: prio)
                                .offset(x: 16, y: 0)
                        }
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
        // We already have a chartOverlay for gesture detection;
        // we'll *also* use it to compute finalXLabels.
        .chartOverlay { proxy in
            GeometryReader { geo in
                Rectangle()
                    .fill(.clear)
                    .contentShape(Rectangle())
                    .gesture(
                        DragGesture(minimumDistance: 0)
                            .onChanged { drag in
                                handleDragChanged(drag: drag, proxy: proxy, geo: geo)
                            }
                            .onEnded { _ in
                                hoveredTime = nil
                                hoveredPrice = nil
                            }
                    )

                if let time = hoveredTime, let price = hoveredPrice {
                    if let xPos = proxy.position(forX: time),
                        let plotArea = proxy.plotFrame
                    {
                        let rect = geo[plotArea]
                        drawHoverElements(rect: rect, xPos: xPos, time: time, price: price)
                    }
                }
            }
            .onAppear {
                computeFinalXAxisLabels(proxy: proxy)
            }
            .onChange(of: filteredRates, initial: true) { oldValue, newValue in
                computeFinalXAxisLabels(proxy: proxy)
            }
            .onChange(of: isFlipped, initial: true) { oldValue, newValue in
                computeFinalXAxisLabels(proxy: proxy)
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

    private var settingsHeaderBar: some View {
        HStack {
            if let def = CardRegistry.shared.definition(for: .interactiveChart) {
                Image(systemName: def.iconName)
                    .foregroundStyle(Theme.icon)
            }
            Text("Card Settings")
                .font(Theme.titleFont())
                .foregroundStyle(Theme.secondaryTextColor)
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

    private var customAverageHoursView: some View {
        HStack(alignment: .top) {
            let hours = localSettings.settings.customAverageHours
            let displayHours =
                hours.truncatingRemainder(dividingBy: 1) == 0
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
    private func handleDragChanged(
        drag: DragGesture.Value,
        proxy: ChartProxy,
        geo: GeometryProxy
    ) {
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

    @ViewBuilder
    private func drawHoverElements(
        rect: CGRect,
        xPos: CGFloat,
        time: Date,
        price: Double
    ) -> some View {
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
    private var filteredRates: [RateEntity] {
        // from now-1hr to now+48hrs
        let start = now.addingTimeInterval(-3600)
        let end = now.addingTimeInterval(48 * 3600)

        return viewModel.allRates
            .filter { $0.validFrom != nil && $0.validTo != nil }
            .sorted { ($0.validFrom ?? .distantPast) < ($1.validFrom ?? .distantPast) }
            .filter {
                guard let date = $0.validFrom else { return false }
                return (date >= start && date <= end)
            }
    }

    private var yRange: (Double, Double) {
        let prices = filteredRates.map { $0.valueIncludingVAT }
        guard !prices.isEmpty else { return (0, 10) }
        let minVal = min(0, (prices.min() ?? 0) - 2)
        let maxVal = (prices.max() ?? 0) + 2
        return (minVal, maxVal)
    }

    private var xDomain: ClosedRange<Date> {
        guard let earliest = filteredRates.first?.validFrom,
            let lastRate = filteredRates.last
        else {
            return now...(now.addingTimeInterval(3600))
        }
        // Base domain end on the last rate's 'validTo'
        let domainEnd = lastRate.validTo ?? lastRate.validFrom!.addingTimeInterval(1800)
        return earliest...domainEnd
    }

    /// The "best" time windows from the VM, merged, raw version for labels
    private var bestTimeRangesRaw: [(Date, Date)] {
        let windows = viewModel.getLowestAveragesIncludingPastHour(
            hours: localSettings.settings.customAverageHours,
            maxCount: localSettings.settings.maxListCount
        )
        let raw = windows.map { ($0.start, $0.end) }
        return mergeWindows(raw)
    }

    /// The "best" time windows adjusted for rendering (with epsilon shift)
    private var bestTimeRangesRender: [(Date, Date)] {
        bestTimeRangesRaw.map { (s, e) -> (Date, Date) in
            let adjustedStart = isExactlyOnHalfHour(s) ? s.addingTimeInterval(-900) : s
            let adjustedEnd = isExactlyOnHalfHour(e) ? e.addingTimeInterval(-900) : e
            return (adjustedStart, adjustedEnd)
        }
    }

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

    private func findCurrentRatePeriod(_ date: Date) -> (start: Date, price: Double)? {
        guard
            let rate = filteredRates.first(where: { r in
                guard let start = r.validFrom, let end = r.validTo else { return false }
                return date >= start && date < end
            })
        else {
            return nil
        }
        if let start = rate.validFrom {
            return (start, rate.valueIncludingVAT)
        }
        return nil
    }

    private func findNearestPrice(_ date: Date) -> Double? {
        filteredRates.min {
            abs(($0.validFrom ?? .distantPast).timeIntervalSince(date))
                < abs(($1.validFrom ?? .distantPast).timeIntervalSince(date))
        }?.valueIncludingVAT
    }

    private func clampDateToDataRange(_ date: Date) -> Date {
        guard let firstDate = filteredRates.first?.validFrom,
            let lastDate = filteredRates.last?.validFrom
        else {
            return date
        }
        return min(max(date, firstDate), lastDate)
    }

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
    /// Each label candidate holds a date + priority
    struct LabelCandidate: Identifiable, Hashable {
        /// The actual domain coordinate used for chart anchoring
        let domainDate: Date

        /// The date/time you want to SHOW in text
        let labelDate: Date

        let priority: Int

        var id: String {
            // So that each candidate is unique
            "\(domainDate.timeIntervalSince1970)_\(labelDate.timeIntervalSince1970)_\(priority)"
        }
    }

    /// Priority rules:
    ///  1 -> Best-time start
    ///  2 -> Best-time end
    ///  3 -> Midnight/noon
    private func priorityOfDate(_ date: Date) -> Int {
        // Are we exactly on a best-time start or end?
        for (start, end) in bestTimeRangesRaw {
            if abs(date.timeIntervalSince(start)) < 1 {
                return 1
            } else if abs(date.timeIntervalSince(end)) < 1 {
                return 2
            }
        }
        // Check if it's midnight/noon (within a minute for safety?)
        let cal = Calendar.current
        let hour = cal.component(.hour, from: date)
        let minute = cal.component(.minute, from: date)
        if (hour == 0 && minute == 0) || (hour == 12 && minute == 0) {
            return 3
        }
        return 3
    }

    /// Builds candidate dates from:
    ///  best-time start (1),
    ///  best-time end (2),
    ///  midnight/noon (3) within xDomain
    private func buildLabelCandidates() -> [LabelCandidate] {
        // For "end" windows:
        let ends = bestTimeRangesRaw.map { (start, end) -> LabelCandidate in
            if isExactlyOnHalfHour(end) {
                // domain coordinate => on the hour (end - 30 min)
                // label text => original half-hour
                let shifted = end.addingTimeInterval(-1800)
                return LabelCandidate(
                    domainDate: shifted,
                    labelDate: end,
                    priority: 2
                )
            } else {
                return LabelCandidate(
                    domainDate: end,
                    labelDate: end,
                    priority: 2
                )
            }
        }

        // Similarly for starts:
        let starts = bestTimeRangesRaw.map { (start, _) -> LabelCandidate in
            // Usually we keep the same domainDate and labelDate for starts
            LabelCandidate(domainDate: start, labelDate: start, priority: 1)
        }

        // midnight/noon:
        let midNoons = generateMidnightNoonTicks().map {
            LabelCandidate(domainDate: $0, labelDate: $0, priority: 3)
        }

        let all = starts + ends + midNoons
        let unique = Array(Set(all))
        let sorted = unique.sorted { $0.domainDate < $1.domainDate }
        return sorted
    }

    /// Generate midnight/noon within domain
    private func generateMidnightNoonTicks() -> [Date] {
        let cal = Calendar.current
        let range = xDomain
        var result = [Date]()

        // If domain is trivial, skip
        guard range.lowerBound < range.upperBound else { return [] }

        // Move day by day
        var dayStart = cal.startOfDay(for: range.lowerBound)
        while dayStart <= range.upperBound {
            // midnight
            if dayStart >= range.lowerBound && dayStart <= range.upperBound {
                result.append(dayStart)
            }

            // noon
            if let noon = cal.date(bySettingHour: 12, minute: 0, second: 0, of: dayStart),
                noon >= range.lowerBound && noon <= range.upperBound
            {
                result.append(noon)
            }

            // next day
            if let nextDay = cal.date(byAdding: .day, value: 1, to: dayStart) {
                dayStart = nextDay
            } else {
                break
            }
        }
        return result
    }

    /// The core pixel-based collision logic:
    /// - Sort all candidates
    /// - For each candidate, measure xPos
    /// - If it's too close to the last accepted label, pick by priority
    private func computeFinalXAxisLabels(proxy: ChartProxy) {
        guard proxy.plotFrame != nil else { return }

        let candidates = buildLabelCandidates()
        var accepted = [LabelCandidate]()

        let pixelGap: CGFloat = 20

        for cand in candidates {
            guard let xPos = proxy.position(forX: cand.domainDate) else { continue }
            if let last = accepted.last,
                let lastXPos = proxy.position(forX: last.domainDate)
            {
                let dist = abs(xPos - lastXPos)
                if dist < pixelGap {
                    // If lower number => higher priority
                    // so if cand.priority < last.priority => replace
                    if cand.priority < last.priority {
                        accepted.removeLast()
                        accepted.append(cand)
                    }
                    // else skip
                } else {
                    accepted.append(cand)
                }
            } else {
                accepted.append(cand)
            }
        }

        finalXLabels = accepted
    }

    /// A small helper to generate textual label, highlighting if needed
    private func xAxisLabel(for date: Date, priority: Int) -> some View {
        VStack(spacing: 2) {
            // If midnight exactly => show "00" and below day/month
            // If noon => "12"
            // If best-time => highlight or normal
            let cal = Calendar.current
            let hour = cal.component(.hour, from: date)
            let minute = cal.component(.minute, from: date)

            // hour label
            let hourLabel: String = {
                if minute == 30 {
                    return String(format: "%02d½", hour)
                } else {
                    return String(format: "%02d", hour)
                }
            }()

            // date label if midnight
            if hour == 0 && minute == 0 {
                let day = cal.component(.day, from: date)
                let month = cal.component(.month, from: date)
                Text(hourLabel)
                    .foregroundStyle(highlightColor(for: priority))
                Text(String(format: "%02d/%02d", day, month))
                    .foregroundStyle(Theme.secondaryTextColor)
            } else {
                Text(hourLabel)
                    .foregroundStyle(highlightColor(for: priority))
                // no second line or empty
                Text("").foregroundStyle(.clear)
            }
        }
    }

    private func highlightColor(for priority: Int) -> Color {
        switch priority {
        case 1: return Theme.mainColor  // best-time start
        case 2: return Theme.mainColor  // best-time end
        case 3: return Theme.secondaryTextColor
        default: return Theme.secondaryTextColor
        }
    }

    /// Price formatting
    private func formatPrice(
        _ pence: Double,
        showDecimals: Bool = false,
        forceFullDecimals: Bool = false
    ) -> String {
        if globalSettings.settings.showRatesInPounds {
            let pounds = pence / 100.0
            return forceFullDecimals
                ? String(format: "£%.4f", pounds)
                : String(format: "£%.2f", pounds)
        } else {
            return String(format: showDecimals ? "%.2fp" : "%.0fp", pence)
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

        let startTime = String(format: "%02d:%02d", hour, halfHour)

        let endHour = halfHour == 30 ? (hour + 1) % 24 : hour
        let endMinute = halfHour == 0 ? 30 : 0
        let endTime = String(format: "%02d:%02d", endHour, endMinute)

        return "\(startTime)-\(endTime)"
    }

    private func isExactlyOnHalfHour(_ date: Date) -> Bool {
        let calendar = Calendar.current
        let comps = calendar.dateComponents([.minute, .second, .nanosecond], from: date)
        let minute = comps.minute ?? 0
        return (minute == 0 || minute == 30) && (comps.second ?? 0) == 0
            && (comps.nanosecond ?? 0) == 0
    }
}

// MARK: - Timer & Bar Width
extension InteractiveLineChartCardView {
    private func handleMinuteTick() {
        let cal = Calendar.current
        let minute = cal.component(.minute, from: now)

        if minute == 0 || minute == 30, lastSnappedMinute != minute {
            lastSnappedMinute = minute
            recalcBarWidthAndPrintOnce()
        }
    }

    private func recalcBarWidthAndPrintOnce() {
        let newWidth = computeDynamicBarWidth()
        guard newWidth != barWidth else { return }

        barWidth = newWidth

        #if DEBUG
            if lastPrintedWidth != newWidth {
                print("Updated bar width: \(newWidth)")
                lastPrintedWidth = newWidth
            }
        #endif
    }

    private func computeDynamicBarWidth() -> Double {
        let maxPossibleBars = 65.0  // just a safe upper bound
        let currentBars = Double(filteredRates.count)
        let baseWidthPerBar = 5.0
        let barGapRatio = 0.7  // 70% bar, 30% gap
        let totalChunk = (maxPossibleBars / currentBars) * baseWidthPerBar
        return totalChunk * barGapRatio
    }
}
