import Combine
import CoreData
import OctopusHelperShared
import SwiftUI

struct AllRatesListView: View {
    @ObservedObject var viewModel: RatesViewModel
    @EnvironmentObject var globalSettings: GlobalSettingsManager
    
    @Environment(\.dismiss) var dismiss
    @State private var refreshTrigger = UUID()
    @State private var displayedRatesByDate: [(String, [NSManagedObject])] = []
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

    private static var isInitializing = false

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

    /// Instead of grouping and sorting the entire `viewModel.allRates(for: viewModel.currentAgileCode)`,
    /// this method groups & sorts whichever slice we've loaded from DB.
    private func groupAndSortRates(_ rates: [NSManagedObject]) -> [(String, [NSManagedObject])] {
        print("AllRatesListView[groupAndSortRates]: Grouping and sorting \(rates.count) rates")
        // These rates might come from viewModel.allRates(for: viewModel.currentAgileCode)
        // but we pass the sliced/fetched rates directly as param.
        let sortedRates = rates.sorted { rate1, rate2 in
            guard let date1 = rate1.value(forKey: "valid_from") as? Date, let date2 = rate2.value(forKey: "valid_from") as? Date else {
                return false
            }
            return date1 < date2
        }

        // Group by date string
        var groupedByDate: [String: [NSManagedObject]] = [:]
        for rate in sortedRates {
            if let date = rate.value(forKey: "valid_from") as? Date {
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
                rates.sorted { ($0.value(forKey: "valid_from") as? Date ?? .distantPast) < ($1.value(forKey: "valid_from") as? Date ?? .distantPast) }
            )
        }.sorted { group1, group2 in
            guard let date1 = group1.1.first?.value(forKey: "valid_from") as? Date,
                let date2 = group2.1.first?.value(forKey: "valid_from") as? Date
            else {
                return false
            }
            return date1 < date2
        }

        print("AllRatesListView[groupAndSortRates]: Grouped into \(sortedGroups.count) date groups")
        return sortedGroups
    }

    /// Helper that groups + merges newly fetched rates with existing
    private func addRatesToDisplayed(_ newRates: [NSManagedObject]) {
        let newGroups = groupAndSortRates(newRates)
        // Avoid duplicating date sections
        for group in newGroups {
            if let existingIndex = displayedRatesByDate.firstIndex(where: { $0.0 == group.0 }) {
                // Append any new rates (but typically they'd be the same day, so might skip)
                let existingRates = displayedRatesByDate[existingIndex].1
                let combined = Array(Set(existingRates + group.1))
                let sorted = combined.sorted { ($0.value(forKey: "valid_from") as? Date ?? .distantPast) < ($1.value(forKey: "valid_from") as? Date ?? .distantPast) }
                displayedRatesByDate[existingIndex] = (group.0, sorted)
            } else {
                displayedRatesByDate.append(group)
            }
        }
        // Sort sections by date asc
        displayedRatesByDate.sort {
            guard let d1 = $0.1.first?.value(forKey: "valid_from") as? Date, let d2 = $1.1.first?.value(forKey: "valid_from") as? Date else { return false }
            return d1 < d2
        }
    }

    /// Load the entire day (UTC-based) and store it. Ignores if already loaded.
    private func loadDay(_ day: Date) async {
        let cal = Calendar(identifier: .gregorian)
        let dayStart = cal.startOfDay(for: day)
        if loadedDays.contains(where: { cal.isDate($0, inSameDayAs: dayStart) }) {
            print("AllRatesListView[loadDay]: Already loaded day \(dayStart)")
            return
        }
        
        do {
            // Get rates directly from CoreData for this day
            let dayRates = try await viewModel.fetchRatesForDay(dayStart)
            
            // Filter for current Agile code
            let filteredRates = dayRates.filter { rate in
                (rate.value(forKey: "tariff_code") as? String) == viewModel.currentAgileCode
            }
            
            print("AllRatesListView[loadDay]: Found \(filteredRates.count) rates in CoreData for \(viewModel.currentAgileCode)")
            addRatesToDisplayed(filteredRates)
            loadedDays.append(dayStart)
        } catch {
            print("AllRatesListView[loadDay]: Error loading day from CoreData \(dayStart): \(error)")
        }
    }

    private func loadInitialData() async {
        guard !hasInitiallyLoaded else {
            print("AllRatesListView[loadInitialData]: Skipping initial load - already loaded")
            return
        }
        
        // Add static initialization guard
        guard !Self.isInitializing else {
            print("AllRatesListView[loadInitialData]: Another instance is already initializing")
            return
        }
        
        Self.isInitializing = true
        defer { Self.isInitializing = false }
        
        // Set this first to prevent race conditions
        await MainActor.run {
            hasInitiallyLoaded = true
        }
        
        print("AllRatesListView[loadInitialData]: Loading initial data")
        currentDay = Date()

        // Check if product code is empty to avoid redundant calls
        if viewModel.currentAgileCode.isEmpty {
            print("AllRatesListView[loadInitialData]: currentAgileCode is empty; skipping loadInitialData")
            return
        }

        print("AllRatesListView[loadInitialData]: Using Agile code: \(viewModel.currentAgileCode)")
        
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
            if case .failure(let error) = yesterdayResult { print("AllRatesListView[loadInitialData]: Yesterday load failed: \(error)") }
            if case .failure(let error) = todayResult { print("AllRatesListView[loadInitialData]: Today load failed: \(error)") }
            if case .failure(let error) = tomorrowResult { print("AllRatesListView[loadInitialData]: Tomorrow load failed: \(error)") }
            
            print("AllRatesListView[loadInitialData]: Initial days load complete")
            
            // Find and set current rate
            if let currentRate = displayedRatesByDate
                .flatMap({ $0.1 })
                .first(where: { isRateCurrentlyActive($0) }) {
                print("AllRatesListView[loadInitialData]: Found current rate: \(currentRate.objectID)")
                currentRateID = currentRate.objectID
                
                try await Task.sleep(nanoseconds: 100_000_000)
                await MainActor.run {
                    shouldScrollToCurrentRate = true
                }
            } else {
                print("AllRatesListView[loadInitialData]: No current rate found")
            }
        } catch {
            print("AllRatesListView[loadInitialData]: Error in initial load: \(error)")
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
            print("AllRatesListView[scrollToCurrentRate]: No current rate ID to scroll to")
            return
        }
        
        guard !isScrolling else {
            print("AllRatesListView[scrollToCurrentRate]: Scroll already in progress")
            return
        }
        
        print("AllRatesListView[scrollToCurrentRate]: Attempting to scroll to rate: \(id)")
        
        // Set scrolling state
        await MainActor.run {
            isScrolling = true
        }
        
        // Ensure we're on the main thread for UI updates
        await MainActor.run {
            withAnimation(.easeInOut(duration: 0.5)) {
                proxy.scrollTo(id, anchor: .center)
                print("AllRatesListView[scrollToCurrentRate]: Executed scroll command")
            }
        }
        
        // Wait for scroll animation to complete
        try? await Task.sleep(nanoseconds: 800_000_000) // 0.8 seconds for animation + extra time
        
        print("AllRatesListView[scrollToCurrentRate]: Scroll animation completed")
        
        // Reset scroll state and mark initial scroll as complete
        await MainActor.run {
            isScrolling = false
            shouldScrollToCurrentRate = false
            hasCompletedInitialScroll = true
            print("AllRatesListView[scrollToCurrentRate]: Initial scroll marked as complete")
        }
    }

    private func loadNextDayIfNeeded(_ rate: NSManagedObject) {
        if let validTo = rate.value(forKey: "valid_to") as? Date,
           let nextDay = Calendar.current.date(byAdding: .day, value: 1, to: currentDay),
           !loadedDays.contains(where: { Calendar.current.isDate($0, inSameDayAs: nextDay) })
        {
            print("AllRatesListView[loadNextDayIfNeeded]: Loading next day on-demand")
            Task {
                await loadDay(nextDay)
            }
        }
    }

    private func loadPreviousDayIfNeeded(_ rate: NSManagedObject) {
        // Only load previous day if initial scroll to current rate is complete
        guard hasCompletedInitialScroll else {
            print("AllRatesListView[loadPreviousDayIfNeeded]: Skipping previous day load - waiting for initial scroll to complete")
            return
        }
        
        if let validFrom = rate.value(forKey: "valid_from") as? Date,
           let prevDay = Calendar.current.date(byAdding: .day, value: -1, to: currentDay),
           !loadedDays.contains(where: { Calendar.current.isDate($0, inSameDayAs: prevDay) })
        {
            print("AllRatesListView[loadPreviousDayIfNeeded]: Loading previous day on-demand")
            Task {
                await loadDay(prevDay)
            }
        }
    }

    var body: some View {
        ScrollViewReader { scrollProxy in
            VStack(spacing: 0) {
                if viewModel.isLoading(for: viewModel.currentAgileCode)
                    && displayedRatesByDate.isEmpty {
                    ProgressView("Fetching Rates...")
                        .font(Theme.subFont())
                }

                if !viewModel.currentAgileCode.isEmpty {
                    Text(viewModel.currentAgileCode)
                        .font(Theme.subFont())
                        .foregroundStyle(Theme.secondaryTextColor)
                        .padding(.vertical, 8)
                        .frame(maxWidth: .infinity)
                        .background(Theme.mainBackground)
                }
                
                // Call our extracted property here
                ratesListView
                    .onAppear {
                        print("AllRatesListView[body]: View appeared")
                        Task {
                            await loadInitialData()
                        }
                    }
                    .onReceive(refreshManager.$halfHourTick) { tickTime in
                        guard tickTime != nil else { return }
                        forceReRenderToggle.toggle()
                    }
                    .onReceive(refreshManager.$sceneActiveTick) { _ in
                        guard !Self.isInitializing else { return }
                        print("AllRatesListView[body]: Scene became active")
                        forceReRenderToggle.toggle()
                    }
                    .onChange(of: shouldScrollToCurrentRate) { _, shouldScroll in
                        if shouldScroll {
                            Task {
                                await scrollToCurrentRate(proxy: scrollProxy)
                            }
                        }
                    }
                    .onDisappear {
                        print("AllRatesListView[body]: View disappeared")
                        // Reset state for next presentation
                        hasInitiallyLoaded = false
                        hasCompletedInitialScroll = false
                        displayedRatesByDate = []
                        loadedDays = []
                        Self.isInitializing = false  // Reset static flag
                    }
            }
            .navigationTitle(LocalizedStringKey("All Rates"))
            .navigationBarTitleDisplayMode(.inline)
            .environment(\.locale, globalSettings.locale)
            .id(dynamicViewID)
            .onChange(of: globalSettings.locale) { oldValue, newValue in
                print("AllRatesListView[body]: Locale changed from \(oldValue.identifier) to \(newValue.identifier)")
                refreshTrigger = UUID()
            }
        }
    }

    private func isRateCurrentlyActive(_ rate: NSManagedObject) -> Bool {
        return rate.isCurrentlyActive()
    }
}

private extension AllRatesListView {
    var dynamicViewID: String {
        "all-rates-\(refreshTrigger)-\(forceReRenderToggle ? 1 : 0)"
    }
}

private extension AllRatesListView {
    
    // This sub-view or computed property holds the big List block
    var ratesListView: some View {
        List {
            ForEach(displayedRatesByDate, id: \.0) { dateString, rates in
                Section {
                    ForEach(rates, id: \.objectID) { rate in
                        RateRowView(
                            rate: rate,
                            viewModel: viewModel,
                            globalSettings: globalSettings,
                            lastSceneActiveTime: lastSceneActiveTime,
                            dayRates: rates
                        )
                        .id(rate.objectID)
                        .listRowBackground(
                            Group {
                                if isRateCurrentlyActive(rate) {
                                    Theme.accent.opacity(0.1)
                                } else if rate.value(forKey: "value_including_vat") as? Double ?? 0 < 0 {
                                    Color(red: 0.2, green: 0.8, blue: 0.4).opacity(0.15)
                                } else {
                                    Theme.secondaryBackground
                                }
                            }
                        )
                        .onAppear {
                            let allRates = viewModel.allRates(for: viewModel.currentAgileCode)
                            
                            // Load next/prev days
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
    }
}

// Extract row view to prevent unnecessary redraws
private struct RateRowView: View {
    let rate: NSManagedObject
    let viewModel: RatesViewModel
    let globalSettings: GlobalSettingsManager
    let lastSceneActiveTime: Date
    let dayRates: [NSManagedObject]

    private func getDayRates(for date: Date, productCode: String) -> [NSManagedObject] {
        return RateColor.getDayRates(for: date, allRates: dayRates)
    }

    private func getTrend() -> (trend: TrendType, opacity: Double) {
        guard let currentValidFrom = rate.value(forKey: "valid_from") as? Date else {
            return (.noChange, 0)
        }

        let dayRates = getDayRates(for: currentValidFrom, productCode: viewModel.currentAgileCode)

        // Find the previous rate (either from same day or previous day)
        guard let currentIndex = dayRates.firstIndex(where: { $0.value(forKey: "valid_from") as? Date == currentValidFrom })
        else {
            return (.noChange, 0)
        }

        let previousRate: NSManagedObject?
        if currentIndex > 0 {
            // Not the first rate of the day, use previous rate from same day
            previousRate = dayRates[currentIndex - 1]
        } else {
            // First rate of the day, get last rate from previous day
            let previousDayRates = getDayRates(for: Calendar.current.date(byAdding: .day, value: -1, to: currentValidFrom)!, productCode: viewModel.currentAgileCode)
            previousRate = previousDayRates.last
        }

        guard let previousRate = previousRate else {
            return (.noChange, 0)
        }

        let currentValue = rate.value(forKey: "value_including_vat") as? Double ?? 0
        let previousValue = previousRate.value(forKey: "value_including_vat") as? Double ?? 0

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

    private func calculateMaxDayChange(rates: [NSManagedObject]) -> Double {
        guard rates.count > 1 else { return 0 }

        var maxChange = 0.0
        for i in 0..<(rates.count - 1) {
            let rate1 = rates[i]
            let rate2 = rates[i + 1]
            let value1 = rate1.value(forKey: "value_including_vat") as? Double ?? 0
            let value2 = rate2.value(forKey: "value_including_vat") as? Double ?? 0
            
            // Avoid division by zero
            guard abs(value1) > 0 else { continue }
            
            let change = abs((value2 - value1) / abs(value1)) * 100
            maxChange = max(maxChange, change)
        }
        return maxChange
    }

    private func calculateOpacity(currentChange: Double, maxChange: Double) -> Double {
        guard maxChange > 0 else { return 0.3 }
        return min(1.0, max(0.3, abs(currentChange) / maxChange))
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
                "\(viewModel.formatTime(rate.value(forKey: "valid_from") as? Date ?? Date())) - \(viewModel.formatTime(rate.value(forKey: "valid_to") as? Date ?? Date()))"
            )
            .font(Theme.subFont())
            .foregroundStyle(Theme.secondaryTextColor)
            .frame(minWidth: 110, alignment: .leading)

            let parts = viewModel.formatRate(
                rate.value(forKey: "value_including_vat") as? Double ?? 0,
                showRatesInPounds: globalSettings.settings.showRatesInPounds
            )
            .split(separator: " ")

            HStack(alignment: .firstTextBaseline, spacing: 0) {
                HStack(alignment: .firstTextBaseline, spacing: 2) {
                    Text(parts[0])  // Rate value
                        .font(Theme.mainFont2())
                        .foregroundColor(RateColor.getColor(for: rate, allRates: dayRates))

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
            print("AllRatesListView[RateRowView]: lastSceneActiveTime changed => re-checking NOW badge")
        }
    }

    private func isRateCurrentlyActive(_ rate: NSManagedObject) -> Bool {
        return rate.isCurrentlyActive()
    }
}

private extension NSManagedObject {
    func isCurrentlyActive() -> Bool {
        let now = Date()
        guard let start = self.value(forKey: "valid_from") as? Date,
              let end = self.value(forKey: "valid_to") as? Date else {
            return false
        }
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