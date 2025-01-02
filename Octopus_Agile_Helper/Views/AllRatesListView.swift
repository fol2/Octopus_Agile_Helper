import Combine
import CoreData
import SwiftUI

struct AllRatesListView: View {
    @ObservedObject var viewModel: RatesViewModel
    @Environment(\.dismiss) var dismiss
    @EnvironmentObject var globalSettings: GlobalSettingsManager
    @State private var refreshTrigger = UUID()
    @State private var displayedRatesByDate: [(String, [RateEntity])] = []
    @State private var currentPage = 0
    @State private var hasInitiallyLoaded = false
    @State private var currentRateID: NSManagedObjectID?
    private let pageSize = 48  // 24 hours worth of 30-minute intervals

    // Use the shared manager for periodic refresh
    @ObservedObject private var refreshManager = CardRefreshManager.shared

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

    private func loadInitialData() {
        guard !hasInitiallyLoaded else {
            print("DEBUG: Skipping initial load - already loaded")
            return
        }

        print("DEBUG: Loading initial data")
        let sortedGroups = groupAndSortRates(viewModel.allRates)

        // Store the current rate's ID for scrolling
        currentRateID = viewModel.allRates.first(where: { isRateCurrentlyActive($0) })?.objectID

        // If we have less than one page of data, just load everything
        if sortedGroups.count <= pageSize {
            displayedRatesByDate = sortedGroups
            currentPage = 1
            hasInitiallyLoaded = true
            return
        }

        // Find the group containing the current rate
        if let currentGroupIndex = sortedGroups.firstIndex(where: { _, rates in
            rates.contains { isRateCurrentlyActive($0) }
        }) {
            print("DEBUG: Found current rate in group \(currentGroupIndex)")
            // Calculate the page that would contain the current rate
            let pageOfCurrentRate = currentGroupIndex / pageSize

            // Load the page containing current rate and one page before if possible
            let startPage = max(0, pageOfCurrentRate - 1)
            let startIndex = startPage * pageSize
            let endIndex = min(startIndex + (pageSize * 2), sortedGroups.count)

            displayedRatesByDate = Array(sortedGroups[startIndex..<endIndex])
            currentPage = endIndex / pageSize
            print("DEBUG: Loaded pages \(startPage) to \(currentPage)")
        } else {
            print("DEBUG: No current rate found, loading from start")
            // If no current rate found, load first two pages from the beginning
            let endIndex = min(pageSize * 2, sortedGroups.count)
            displayedRatesByDate = Array(sortedGroups[0..<endIndex])
            currentPage = 2
        }

        hasInitiallyLoaded = true
    }

    private func loadNextPage() {
        print("DEBUG: Loading next page \(currentPage)")
        let sortedGroups = groupAndSortRates(viewModel.allRates)

        let startIndex = currentPage * pageSize
        let endIndex = min(startIndex + pageSize, sortedGroups.count)
        guard startIndex < sortedGroups.count else {
            print("DEBUG: No more pages to load")
            return
        }

        // Check if we already have these items to prevent duplicates
        let newItems = Array(sortedGroups[startIndex..<endIndex])
        let newItemDates = Set(newItems.map { $0.0 })
        let existingDates = Set(displayedRatesByDate.map { $0.0 })

        if newItemDates.isDisjoint(with: existingDates) {
            displayedRatesByDate.append(contentsOf: newItems)
            currentPage += 1
            print("DEBUG: Loaded page \(currentPage-1) with \(newItems.count) groups")
        } else {
            print("DEBUG: Skipping page load - items already exist")
        }
    }

    var body: some View {
        ScrollViewReader { scrollProxy in
            List {
                ForEach(displayedRatesByDate, id: \.0) { dateString, rates in
                    Section {
                        ForEach(rates, id: \.objectID) { rate in
                            RateRowView(
                                rate: rate, viewModel: viewModel, globalSettings: globalSettings
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
                                // If this is one of the last items, load more
                                if rates.last?.objectID == rate.objectID
                                    && dateString == displayedRatesByDate.last?.0
                                {
                                    loadNextPage()
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
                loadInitialData()

                // Scroll to current rate if exists
                if let currentRateID = currentRateID {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                        withAnimation {
                            scrollProxy.scrollTo(currentRateID, anchor: .center)
                            print("DEBUG: Scrolling to current rate")
                        }
                    }
                }
            }
            // Re-render on half-hour
            .onReceive(refreshManager.$halfHourTick) { tickTime in
                guard tickTime != nil else { return }
                Task {
                    await viewModel.refreshRates()
                    loadInitialData()  // Reload the view data
                }
            }
            // Also re-render if app becomes active
            .onReceive(refreshManager.$sceneActiveTick) { _ in
                Task {
                    await viewModel.refreshRates()
                    loadInitialData()  // Reload the view data
                }
            }
        }
        .navigationTitle(LocalizedStringKey("All Rates"))
        .navigationBarTitleDisplayMode(.inline)
        .environment(\.locale, globalSettings.locale)
        .id("all-rates-\(refreshTrigger)")
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
