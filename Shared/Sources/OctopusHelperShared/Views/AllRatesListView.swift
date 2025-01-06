import Combine
import CoreData
import OctopusHelperShared
import SwiftUI

struct AllRatesListView: View {
    @ObservedObject var viewModel: RatesViewModel
    @EnvironmentObject var globalSettings: GlobalSettingsManager
    
    @Environment(\.dismiss) var dismiss
    @State private var refreshTrigger = UUID()
    @State private var displayedRatesByDate: [(String, [RateEntity])] = []
    @State private var hasInitiallyLoaded = false
    @State private var currentRateID: NSManagedObjectID?
    @State private var shouldScrollToCurrentRate = false
    @State private var isScrolling = false
    @State private var hasCompletedInitialScroll = false
    private let pageSize = 48  // 24 hours worth of 30-minute intervals
    
    // Track loaded days and current day
    @State private var loadedDays: [Date] = []
    @State private var currentDay: Date = Date()
    
    @ObservedObject private var refreshManager = CardRefreshManager.shared
    @State private var forceReRenderToggle = false
    @State private var lastSceneActiveTime: Date = Date.distantPast

    private var dateFormatter: DateFormatter {
        let formatter = DateFormatter()
        if globalSettings.locale.language.languageCode?.identifier == "zh" {
            formatter.dateFormat = "MM月dd日"
        } else {
            formatter.dateFormat = "d MMM"  // UK format
        }
        formatter.locale = globalSettings.locale
        return formatter
    }

    /// Instead of grouping and sorting the entire `viewModel.allRates`,
    /// this method groups & sorts whichever slice we've loaded from DB.
    private func groupAndSortRates(_ rates: [RateEntity]) -> [(String, [RateEntity])] {
        print("DEBUG: Grouping and sorting \(rates.count) rates")
        // First, sort all rates by date
        let sortedRates = rates.sorted { rate1, rate2 in
            guard let date1 = rate1.validFrom, let date2 = rate2.validFrom else {
                return false
            }
            return date1 < date2
        }

        // Group by date string
        var groupedByDate: [String: [RateEntity]] = [:]
        for rate in sortedRates {
            if let date = rate.validFrom {
                let dateString = dateFormatter.string(from: date)
                if groupedByDate[dateString] == nil {
                    groupedByDate[dateString] = []
                }
                groupedByDate[dateString]?.append(rate)
            }
        }

        // Convert to array and sort by first rate's date in each group
        let sortedGroups = groupedByDate.map { (dateString, rates) in
            (
                dateString,
                rates.sorted { ($0.validFrom ?? .distantPast) < ($1.validFrom ?? .distantPast) }
            )
        }.sorted { group1, group2 in
            guard let date1 = group1.1.first?.validFrom,
                let date2 = group2.1.first?.validFrom
            else {
                return false
            }
            return date1 < date2
        }

        print("DEBUG: Grouped into \(sortedGroups.count) date groups")
        return sortedGroups
    }

    /// Helper that groups + merges newly fetched rates with existing
    private func addRatesToDisplayed(_ newRates: [RateEntity]) {
        let newGroups = groupAndSortRates(newRates)
        // Avoid duplicating date sections
        for group in newGroups {
            if let existingIndex = displayedRatesByDate.firstIndex(where: { $0.0 == group.0 }) {
                // Append any new rates (but typically they'd be the same day, so might skip)
                let existingRates = displayedRatesByDate[existingIndex].1
                let combined = Array(Set(existingRates + group.1))
                let sorted = combined.sorted { ($0.validFrom ?? .distantPast) < ($1.validFrom ?? .distantPast) }
                displayedRatesByDate[existingIndex] = (group.0, sorted)
            } else {
                displayedRatesByDate.append(group)
            }
        }
        // Sort sections by date asc
        displayedRatesByDate.sort {
            guard let d1 = $0.1.first?.validFrom, let d2 = $1.1.first?.validFrom else { return false }
            return d1 < d2
        }
    }

    /// Load the entire day (UTC-based) and store it. Ignores if already loaded.
    private func loadDay(_ day: Date) async {
        let cal = Calendar(identifier: .gregorian)
        let dayStart = cal.startOfDay(for: day)
        if loadedDays.contains(where: { cal.isDate($0, inSameDayAs: dayStart) }) {
            print("DEBUG: Already loaded day \(dayStart)")
            return
        }
        do {
            print("DEBUG: Fetching day = \(dayStart)")
            let newRates = try await viewModel.repository.fetchRatesForDay(dayStart)
            addRatesToDisplayed(newRates)
            loadedDays.append(dayStart)
        } catch {
            print("DEBUG: Error loading day \(dayStart): \(error)")
        }
    }

    private func loadInitialData() async {
        guard !hasInitiallyLoaded else {
            print("DEBUG: Skipping initial load - already loaded")
            return
        }
        
        hasInitiallyLoaded = true
        print("DEBUG: Loading initial data")
        currentDay = Date()
        
        do {
            let calendar = Calendar.current
            let yesterday = calendar.date(byAdding: .day, value: -1, to: currentDay)!
            let tomorrow = calendar.date(byAdding: .day, value: 1, to: currentDay)!
            
            // Load all three days concurrently
            async let yesterdayLoad = loadDayWithError(yesterday)
            async let todayLoad = loadDayWithError(currentDay)
            async let tomorrowLoad = loadDayWithError(tomorrow)
            
            // Collect results
            let (yesterdayResult, todayResult, tomorrowResult) = await (yesterdayLoad, todayLoad, tomorrowLoad)
            
            // Log results
            if case .failure(let error) = yesterdayResult { print("DEBUG: Yesterday load failed: \(error)") }
            if case .failure(let error) = todayResult { print("DEBUG: Today load failed: \(error)") }
            if case .failure(let error) = tomorrowResult { print("DEBUG: Tomorrow load failed: \(error)") }
            
            print("DEBUG: Initial days load complete")
            
            // Find and set current rate
            if let currentRate = displayedRatesByDate
                .flatMap({ $0.1 })
                .first(where: { isRateCurrentlyActive($0) }) {
                print("DEBUG: Found current rate: \(currentRate.objectID)")
                currentRateID = currentRate.objectID
                
                try await Task.sleep(nanoseconds: 100_000_000)
                await MainActor.run {
                    shouldScrollToCurrentRate = true
                }
            } else {
                print("DEBUG: No current rate found")
            }
        } catch {
            print("DEBUG: Error in initial load: \(error)")
        }
    }

    // Add this helper function
    private func loadDayWithError(_ date: Date) async -> Result<Void, Error> {
        do {
            try await loadDay(date)
            return .success(())
        } catch {
            return .failure(error)
        }
    }

    private func scrollToCurrentRate(proxy: ScrollViewProxy) async {
        guard let id = currentRateID else {
            print("DEBUG: No current rate ID to scroll to")
            return
        }
        
        guard !isScrolling else {
            print("DEBUG: Scroll already in progress")
            return
        }
        
        print("DEBUG: Attempting to scroll to rate: \(id)")
        
        // Set scrolling state
        await MainActor.run {
            isScrolling = true
        }
        
        // Ensure we're on the main thread for UI updates
        await MainActor.run {
            withAnimation(.easeInOut(duration: 0.5)) {
                proxy.scrollTo(id, anchor: .center)
                print("DEBUG: Executed scroll command")
            }
        }
        
        // Wait for scroll animation to complete
        try? await Task.sleep(nanoseconds: 800_000_000) // 0.8 seconds for animation + extra time
        
        print("DEBUG: Scroll animation completed")
        
        // Reset scroll state and mark initial scroll as complete
        await MainActor.run {
            isScrolling = false
            shouldScrollToCurrentRate = false
            hasCompletedInitialScroll = true
            print("DEBUG: Initial scroll marked as complete")
        }
    }

    private func loadNextDayIfNeeded(_ rate: RateEntity) {
        if let validTo = rate.validTo,
           let nextDay = Calendar.current.date(byAdding: .day, value: 1, to: currentDay),
           !loadedDays.contains(where: { Calendar.current.isDate($0, inSameDayAs: nextDay) })
        {
            print("DEBUG: Loading next day on-demand")
            Task {
                await loadDay(nextDay)
            }
        }
    }

    private func loadPreviousDayIfNeeded(_ rate: RateEntity) {
        // Only load previous day if initial scroll to current rate is complete
        guard hasCompletedInitialScroll else {
            print("DEBUG: Skipping previous day load - waiting for initial scroll to complete")
            return
        }
        
        if let validFrom = rate.validFrom,
           let prevDay = Calendar.current.date(byAdding: .day, value: -1, to: currentDay),
           !loadedDays.contains(where: { Calendar.current.isDate($0, inSameDayAs: prevDay) })
        {
            print("DEBUG: Loading previous day on-demand")
            Task {
                await loadDay(prevDay)
            }
        }
    }

    var body: some View {
        ScrollViewReader { scrollProxy in
            List {
                ForEach(displayedRatesByDate, id: \.0) { dateString, rates in
                    Section {
                        ForEach(rates, id: \.objectID) { rate in
                            RateRowView(
                                rate: rate, 
                                viewModel: viewModel, 
                                globalSettings: globalSettings,
                                lastSceneActiveTime: lastSceneActiveTime
                            )
                            .id(rate.objectID)
                            .listRowBackground(
                                Group {
                                    if isRateCurrentlyActive(rate) {
                                        Theme.accent.opacity(0.1)
                                    } else if rate.valueIncludingVAT < 0 {
                                        Color(red: 0.0, green: 0.6, blue: 0.3).opacity(0.15)
                                    } else {
                                        Theme.secondaryBackground
                                    }
                                }
                            )
                            .onAppear {
                                // 3) Load next/prev days as needed
                                if rate.objectID == rates.last?.objectID {
                                    loadNextDayIfNeeded(rate)
                                }
                                if rate.objectID == rates.first?.objectID {
                                    loadPreviousDayIfNeeded(rate)
                                }
                            }
                        }
                    } header: {
                        Text(dateString)
                            .font(Theme.titleFont())
                            .foregroundStyle(Theme.mainTextColor)
                            .listRowInsets(EdgeInsets())
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.vertical, 8)
                            .background(Theme.mainBackground)
                    }
                }
            }
            .listStyle(.plain)
            .background(Theme.mainBackground)
            .onAppear {
                print("DEBUG: View appeared")
                // Only start loading if we haven't loaded yet
                if !hasInitiallyLoaded {
                    Task {
                        await loadInitialData()
                    }
                }
            }
            // Force re-render whenever half-hour ticks => "NOW" badge updates
            .onReceive(refreshManager.$halfHourTick) { tickTime in
                guard tickTime != nil else { return }
                forceReRenderToggle.toggle()
            }
            // Also force re-render whenever app becomes active
            .onReceive(refreshManager.$sceneActiveTick) { _ in
                print("DEBUG: Scene became active, updating lastSceneActiveTime")
                lastSceneActiveTime = Date()
                forceReRenderToggle.toggle()
            }
            .onChange(of: shouldScrollToCurrentRate) { _, shouldScroll in
                if shouldScroll {
                    print("DEBUG: Scroll trigger activated")
                    Task {
                        await scrollToCurrentRate(proxy: scrollProxy)
                    }
                }
            }
            // Re-render on half-hour
            .onReceive(refreshManager.$halfHourTick) { tickTime in
                guard tickTime != nil else { return }
                Task {
                    await viewModel.refreshRates()
                    await loadInitialData()
                }
            }
            // Also re-render if app becomes active
            .onReceive(refreshManager.$sceneActiveTick) { _ in
                Task {
                    await viewModel.refreshRates()
                    await loadInitialData()
                }
            }
        }
        .navigationTitle(LocalizedStringKey("All Rates"))
        .navigationBarTitleDisplayMode(.inline)
        .environment(\.locale, globalSettings.locale)
        .id("all-rates-\(refreshTrigger)-\(forceReRenderToggle ? 1 : 0)")
        .onChange(of: globalSettings.locale) { oldValue, newValue in
            print("DEBUG: Locale changed from \(oldValue.identifier) to \(newValue.identifier)")
            refreshTrigger = UUID()  // Just refresh the view instead of reloading data
        }
    }

    private func isRateCurrentlyActive(_ rate: RateEntity) -> Bool {
        let now = Date()
        guard let start = rate.validFrom, let end = rate.validTo else { return false }
        return start <= now && end > now
    }
}

// Extract row view to prevent unnecessary redraws
private struct RateRowView: View {
    let rate: RateEntity
    let viewModel: RatesViewModel
    let globalSettings: GlobalSettingsManager
    let lastSceneActiveTime: Date  // New property

    private func getDayRates(for date: Date) -> [RateEntity] {
        let calendar = Calendar.current
        let startOfDay = calendar.startOfDay(for: date)
        let endOfDay = calendar.date(byAdding: .day, value: 1, to: startOfDay)!

        return viewModel.allRates.filter { rate in
            guard let validFrom = rate.validFrom else { return false }
            return validFrom >= startOfDay && validFrom < endOfDay
        }.sorted { ($0.validFrom ?? .distantPast) < ($1.validFrom ?? .distantPast) }
    }

    private func calculateMaxDayChange(rates: [RateEntity]) -> Double {
        guard rates.count > 1 else { return 0 }

        var maxChange = 0.0
        for i in 0..<(rates.count - 1) {
            let rate1 = rates[i]
            let rate2 = rates[i + 1]
            let change =
                abs(
                    (rate2.valueIncludingVAT - rate1.valueIncludingVAT)
                        / abs(rate1.valueIncludingVAT)) * 100
            maxChange = max(maxChange, change)
        }
        return maxChange
    }

    private func calculateOpacity(currentChange: Double, maxChange: Double) -> Double {
        guard maxChange > 0 else { return 0.3 }
        return min(1.0, max(0.3, abs(currentChange) / maxChange))
    }

    private func getLastRateOfPreviousDay(from date: Date) -> RateEntity? {
        let calendar = Calendar.current
        let startOfDay = calendar.startOfDay(for: date)
        let startOfPreviousDay = calendar.date(byAdding: .day, value: -1, to: startOfDay)!

        let previousDayRates = viewModel.allRates.filter { rate in
            guard let validFrom = rate.validFrom else { return false }
            return validFrom >= startOfPreviousDay && validFrom < startOfDay
        }.sorted { ($0.validFrom ?? .distantPast) < ($1.validFrom ?? .distantPast) }

        return previousDayRates.last
    }

    private func getTrend() -> (trend: TrendType, opacity: Double) {
        guard let currentValidFrom = rate.validFrom else {
            return (.noChange, 0)
        }

        let dayRates = getDayRates(for: currentValidFrom)

        // Find the previous rate (either from same day or previous day)
        guard let currentIndex = dayRates.firstIndex(where: { $0.validFrom == currentValidFrom })
        else {
            return (.noChange, 0)
        }

        let previousRate: RateEntity?
        if currentIndex > 0 {
            // Not the first rate of the day, use previous rate from same day
            previousRate = dayRates[currentIndex - 1]
        } else {
            // First rate of the day, get last rate from previous day
            previousRate = getLastRateOfPreviousDay(from: currentValidFrom)
        }

        guard let previousRate = previousRate else {
            return (.noChange, 0)
        }

        let currentValue = rate.valueIncludingVAT
        let previousValue = previousRate.valueIncludingVAT

        // Calculate percentage change using absolute value in denominator
        let percentageChange = ((currentValue - previousValue) / abs(previousValue)) * 100

        // If there's no change
        if abs(percentageChange) < 0.01 {
            return (.noChange, 1.0)
        }

        // Calculate opacity based on the relative size of the change
        let maxDayChange = calculateMaxDayChange(rates: dayRates)
        let opacity = calculateOpacity(currentChange: percentageChange, maxChange: maxDayChange)

        return (percentageChange > 0 ? .up : .down, opacity)
    }

    private func getRateColor() -> Color {
        return RateColor.getColor(for: rate, allRates: viewModel.allRates)
    }

    private enum TrendType {
        case up, down, noChange

        var iconName: String {
            switch self {
            case .up: return "arrow.up.circle.fill"
            case .down: return "arrow.down.circle.fill"
            case .noChange: return "circle.fill"
            }
        }

        var color: Color {
            switch self {
            case .up: return .red.opacity(0.8)
            case .down: return Color(red: 0.2, green: 0.8, blue: 0.4)  // Match the rate color
            case .noChange: return .gray.opacity(0.5)
            }
        }
    }

    var body: some View {
        HStack(spacing: 8) {
            Text(
                "\(viewModel.formatTime(rate.validFrom ?? Date())) - \(viewModel.formatTime(rate.validTo ?? Date()))"
            )
            .font(Theme.subFont())
            .foregroundStyle(Theme.secondaryTextColor)
            .frame(minWidth: 110, alignment: .leading)

            let parts = viewModel.formatRate(
                rate.valueIncludingVAT,
                showRatesInPounds: globalSettings.settings.showRatesInPounds
            ).split(separator: " ")

            HStack(alignment: .firstTextBaseline, spacing: 0) {
                HStack(alignment: .firstTextBaseline, spacing: 2) {
                    Text(parts[0])  // Rate value
                        .font(Theme.mainFont2())
                        .foregroundStyle(getRateColor())

                    Text(parts[1])  // "/kWh"
                        .font(Theme.subFont())
                        .foregroundStyle(Theme.secondaryTextColor)
                }
                .frame(width: 140, alignment: .trailing)

                let trend = getTrend()
                Image(systemName: trend.trend.iconName)
                    .foregroundStyle(trend.trend.color.opacity(trend.opacity))
                    .font(Theme.subFont())
                    .imageScale(.medium)
                    .padding(.leading, 8)
                    .frame(width: 24)
            }

            Spacer()

            if isRateCurrentlyActive(rate) {
                Text("NOW")
                    .font(Theme.subFont())
                    .fontWeight(.bold)
                    .foregroundColor(.white)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Capsule().fill(Theme.secondaryColor))
            }
        }
        .padding(.vertical, 4)
        .lineLimit(1)
        .onChange(of: lastSceneActiveTime) { _, _ in
            print("DEBUG: lastSceneActiveTime changed => re-checking NOW badge")
        }
    }

    private func isRateCurrentlyActive(_ rate: RateEntity) -> Bool {
        let now = Date()
        guard let start = rate.validFrom, let end = rate.validTo else { return false }
        return start <= now && end > now
    }
}

#Preview {
    let globalTimer = GlobalTimer()
    let viewModel = RatesViewModel(globalTimer: globalTimer)
    NavigationView {
        AllRatesListView(viewModel: viewModel)
            .environmentObject(GlobalSettingsManager())
    }
}