import SwiftUI
import CoreData

struct AllRatesListView: View {
    @ObservedObject var viewModel: RatesViewModel
    @Environment(\.dismiss) var dismiss
    @EnvironmentObject var globalSettings: GlobalSettingsManager
    @State private var refreshTrigger = UUID()
    @State private var displayedRatesByDate: [(String, [RateEntity])] = []
    @State private var currentPage = 0
    @State private var hasInitiallyLoaded = false
    private let pageSize = 48 // 24 hours worth of 30-minute intervals
    
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
            (dateString, rates.sorted { ($0.validFrom ?? .distantPast) < ($1.validFrom ?? .distantPast) })
        }.sorted { group1, group2 in
            guard let date1 = group1.1.first?.validFrom,
                  let date2 = group2.1.first?.validFrom else {
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
        
        // Find the group containing the current rate
        if let currentGroupIndex = sortedGroups.firstIndex(where: { _, rates in
            rates.contains { isRateCurrentlyActive($0) }
        }) {
            print("DEBUG: Found current rate in group \(currentGroupIndex)")
            // Calculate the page that would contain the current rate
            currentPage = max(0, (currentGroupIndex / pageSize) - 1) // One page before current if possible
            let startIndex = currentPage * pageSize
            let endIndex = min(startIndex + (pageSize * 2), sortedGroups.count) // Load two pages initially
            displayedRatesByDate = Array(sortedGroups[startIndex..<endIndex])
            currentPage = endIndex / pageSize
            print("DEBUG: Loaded pages \(startIndex/pageSize) to \(currentPage)")
        } else {
            print("DEBUG: No current rate found, loading from start")
            // If no current rate found, start from the beginning
            let endIndex = min(pageSize, sortedGroups.count)
            displayedRatesByDate = Array(sortedGroups[0..<endIndex])
            currentPage = 1
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
                            RateRowView(rate: rate, viewModel: viewModel, globalSettings: globalSettings)
                                .id(rate.objectID)
                                .listRowBackground(isRateCurrentlyActive(rate) ? Theme.accent.opacity(0.1) : Theme.secondaryBackground)
                                .onAppear {
                                    // If this is one of the last items, load more
                                    if rates.last?.objectID == rate.objectID &&
                                       dateString == displayedRatesByDate.last?.0 {
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
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                    if let currentRate = viewModel.allRates.first(where: { isRateCurrentlyActive($0) }) {
                        print("DEBUG: Scrolling to current rate")
                        withAnimation {
                            scrollProxy.scrollTo(currentRate.objectID, anchor: .center)
                        }
                    }
                }
            }
        }
        .navigationTitle(LocalizedStringKey("All Rates"))
        .navigationBarTitleDisplayMode(.inline)
        .environment(\.locale, globalSettings.locale)
        .id("all-rates-\(refreshTrigger)")
        .onChange(of: globalSettings.locale) { oldValue, newValue in
            print("DEBUG: Locale changed from \(oldValue.identifier) to \(newValue.identifier)")
            refreshTrigger = UUID() // Just refresh the view instead of reloading data
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
    
    var body: some View {
        HStack(spacing: 8) {
            Text("\(viewModel.formatTime(rate.validFrom ?? Date())) - \(viewModel.formatTime(rate.validTo ?? Date()))")
                .font(Theme.subFont())
                .foregroundStyle(Theme.secondaryTextColor)
                .frame(minWidth: 110, alignment: .leading)
            
            let parts = viewModel.formatRate(
                rate.valueIncludingVAT,
                showRatesInPounds: globalSettings.settings.showRatesInPounds
            ).split(separator: " ")
            HStack(alignment: .firstTextBaseline, spacing: 2) {
                Text(parts[0])  // Now includes currency symbol
                    .font(Theme.mainFont2())
                    .foregroundStyle(Theme.mainTextColor)
                Text(parts[1])  // Just "/kWh"
                    .font(Theme.subFont())
                    .foregroundStyle(Theme.secondaryTextColor)
            }
            .frame(minWidth: 80, alignment: .trailing)
            
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