import Combine
import CoreData
import SwiftUI

public struct AccountTariffCardView: View {
    // MARK: - Dependencies
    @ObservedObject var viewModel: RatesViewModel
    @EnvironmentObject var globalSettings: GlobalSettingsManager
    @StateObject private var tariffVM = TariffViewModel()
    @ObservedObject var consumptionVM: ConsumptionViewModel

    // MARK: - State
    @State private var selectedInterval: IntervalType
    @State private var currentDate: Date
    @State private var showingDetails = false
    @State private var refreshTrigger = false
    @State private var minAllowedDate: Date?
    @State private var maxAllowedDate: Date?

    // MARK: - Types
    enum IntervalType: String, CaseIterable {
        case daily = "DAILY"
        case weekly = "WEEKLY"
        case monthly = "MONTHLY"

        var displayName: String {
            rawValue.capitalized
        }

        var viewModelInterval: TariffViewModel.IntervalType {
            switch self {
            case .daily: return .daily
            case .weekly: return .weekly
            case .monthly: return .monthly
            }
        }

        static func from(string: String) -> IntervalType {
            IntervalType(rawValue: string) ?? .daily
        }
    }

    // MARK: - Initialization
    public init(viewModel: RatesViewModel, consumptionVM: ConsumptionViewModel) {
        self.viewModel = viewModel
        self.consumptionVM = consumptionVM
        // Initialize state properties with default values
        // They will be updated in onAppear with the actual values from globalSettings
        _selectedInterval = State(initialValue: .daily)
        _currentDate = State(initialValue: Date())
    }

    private func initializeFromSettings() {
        // Update interval and date from settings
        selectedInterval = IntervalType.from(string: globalSettings.settings.selectedTariffInterval)
        currentDate =
            globalSettings.settings.lastViewedTariffDates[
                globalSettings.settings.selectedTariffInterval] ?? Date()
    }

    // MARK: - Computed Properties
    private var isAtMinDate: Bool {
        guard let minDate = minAllowedDate else { return false }
        let calendar = Calendar.current

        switch selectedInterval {
        case .daily:
            return calendar.isDate(currentDate, inSameDayAs: minDate)
        case .weekly:
            let currentWeekStart = calendar.date(
                from: calendar.dateComponents([.yearForWeekOfYear, .weekOfYear], from: currentDate))!
            let minWeekStart = calendar.date(
                from: calendar.dateComponents([.yearForWeekOfYear, .weekOfYear], from: minDate))!
            return currentWeekStart <= minWeekStart
        case .monthly:
            let currentMonthStart = calendar.date(
                from: calendar.dateComponents([.year, .month], from: currentDate))!
            let minMonthStart = calendar.date(
                from: calendar.dateComponents([.year, .month], from: minDate))!
            return currentMonthStart <= minMonthStart
        }
    }

    private var isAtMaxDate: Bool {
        guard let maxDate = maxAllowedDate else { return false }
        let calendar = Calendar.current

        switch selectedInterval {
        case .daily:
            return calendar.isDate(currentDate, inSameDayAs: maxDate)
        case .weekly:
            let currentWeekStart = calendar.date(
                from: calendar.dateComponents([.yearForWeekOfYear, .weekOfYear], from: currentDate))!
            let maxWeekStart = calendar.date(
                from: calendar.dateComponents([.yearForWeekOfYear, .weekOfYear], from: maxDate))!
            return currentWeekStart >= maxWeekStart
        case .monthly:
            let currentMonthStart = calendar.date(
                from: calendar.dateComponents([.year, .month], from: currentDate))!
            let maxMonthStart = calendar.date(
                from: calendar.dateComponents([.year, .month], from: maxDate))!
            return currentMonthStart >= maxMonthStart
        }
    }

    private var dateRange: (start: Date, end: Date) {
        let calendar = Calendar.current
        let startOfDay = calendar.startOfDay(for: currentDate)

        switch selectedInterval {
        case .daily:
            let endDate = calendar.date(byAdding: .day, value: 1, to: startOfDay)!
            return (start: startOfDay, end: endDate)

        case .weekly:
            let weekStart = calendar.date(
                from: calendar.dateComponents([.yearForWeekOfYear, .weekOfYear], from: startOfDay))!
            let weekEnd = calendar.date(byAdding: .weekOfYear, value: 1, to: weekStart)!
            return (start: weekStart, end: weekEnd)

        case .monthly:
            let monthStart =
                calendar.date(from: calendar.dateComponents([.year, .month], from: startOfDay))!
            let monthEnd = calendar.date(byAdding: .month, value: 1, to: monthStart)!
            return (start: monthStart, end: monthEnd)
        }
    }

    private var accountResponse: OctopusAccountResponse? {
        guard let accountData = globalSettings.settings.accountData,
            let decoded = try? JSONDecoder().decode(OctopusAccountResponse.self, from: accountData)
        else {
            return nil
        }
        return decoded
    }

    private func iconName(for interval: IntervalType) -> String {
        switch interval {
        case .daily: return "calendar.day.timeline.left"
        case .weekly: return "calendar.badge.clock"
        case .monthly: return "calendar"
        }
    }

    // MARK: - Methods
    private func savePreferences() {
        // Save current interval and date
        globalSettings.settings.selectedTariffInterval = selectedInterval.rawValue
        globalSettings.settings.lastViewedTariffDates[selectedInterval.rawValue] = currentDate
    }

    private func updateAllowedDateRange() {
        let calendar = Calendar.current
        let now = Date()
        let startOfToday = calendar.startOfDay(for: now)

        // First determine the latest date we have data for (using daily reference)
        let latestDailyDate = calendar.date(byAdding: .day, value: -1, to: startOfToday)!

        // Set max date based on interval
        switch selectedInterval {
        case .daily:
            maxAllowedDate = latestDailyDate
        case .weekly:
            // Get the start of the week for our latest daily date
            let latestWeekStart = calendar.date(
                from: calendar.dateComponents(
                    [.yearForWeekOfYear, .weekOfYear], from: latestDailyDate))!
            maxAllowedDate = latestWeekStart
        case .monthly:
            maxAllowedDate = calendar.date(
                from: calendar.dateComponents([.year, .month], from: latestDailyDate))
        }

        // Set min date from consumption data
        minAllowedDate = consumptionVM.minInterval

        // Ensure current date is within bounds
        if let maxDate = maxAllowedDate, currentDate > maxDate {
            currentDate = maxDate
            savePreferences()
        }
        if let minDate = minAllowedDate, currentDate < minDate {
            currentDate = minDate
            savePreferences()
        }
    }

    private func loadConsumptionIfNeeded() async {
        if consumptionVM.consumptionRecords.isEmpty {
            await consumptionVM.loadData()
            updateAllowedDateRange()
        }
    }

    /// For daily intervals, returns the next valid date that has actual consumption data
    /// (based on `consumptionVM.consumptionRecords`). If none found (or goes out of [minDate, maxDate]),
    /// returns `nil`.
    private func nextDailyDateWithData(from date: Date, forward: Bool) -> Date? {
        // Check if we have valid min/max dates
        guard let minDate = minAllowedDate,
            let maxDate = maxAllowedDate
        else {
            // If we have no valid min/max date, we cannot safely navigate
            return nil
        }

        // Gather all available start-of-day dates from consumptionRecords
        // so that if a day has no records, we won't let the user navigate to it.
        let dailySet: Set<Date> = {
            let calendar = Calendar.current
            return Set(
                consumptionVM.consumptionRecords.compactMap { record in
                    guard let intervalStart = record.value(forKey: "interval_start") as? Date else {
                        return nil
                    }
                    // If the record is outside min/max, ignore it.
                    // This way we don't accidentally loop forever if there's no valid range.
                    guard intervalStart >= minDate && intervalStart <= maxDate else { return nil }

                    // Normalise to start of day
                    return calendar.startOfDay(for: intervalStart)
                }
            )
        }()

        guard !dailySet.isEmpty else {
            // If there's no daily record at all, we can't navigate forward/backward.
            // Returning nil ensures we don't enter the while loop below.
            // This prevents infinite looping when forward/backward is tapped.
            return nil
        }

        let calendar = Calendar.current
        // Start from the *current* day boundary
        var candidate = calendar.startOfDay(for: date)

        while true {
            // Step by 1 day forward or backward
            guard
                let nextDay = calendar.date(byAdding: .day, value: forward ? 1 : -1, to: candidate)
            else {
                return nil
            }
            candidate = calendar.startOfDay(for: nextDay)

            // Bounds-check against minAllowedDate/maxAllowedDate
            if candidate < calendar.startOfDay(for: minDate) {
                return nil
            }
            if candidate > calendar.startOfDay(for: maxDate) {
                return nil
            }

            // If the candidate day is in the set of days we have data for, we can navigate to it
            if dailySet.contains(candidate) {
                return candidate
            }
        }
    }

    private func navigateDate(forward: Bool) {
        let calendar = Calendar.current
        var newDate: Date?

        switch selectedInterval {
        case .daily:
            // Instead of blindly stepping ±1 day, we jump to the next day for which
            // consumption data actually exists.
            newDate = nextDailyDateWithData(from: currentDate, forward: forward)

        case .weekly:
            newDate = calendar.date(byAdding: .weekOfYear, value: forward ? 1 : -1, to: currentDate)

        case .monthly:
            newDate = calendar.date(byAdding: .month, value: forward ? 1 : -1, to: currentDate)
        }

        // If newDate is `nil`, that means:
        //  - We either fell out of [minDate, maxDate], or
        //  - We have no consumption data for the next day
        guard let newDate = newDate else {
            return
        }

        // Final safety check, though we already do min/max checks in daily mode
        // but let's be safe for weekly/monthly steps:
        if let minDate = minAllowedDate, newDate < minDate {
            return
        }
        if let maxDate = maxAllowedDate, newDate > maxDate {
            return
        }

        // If the new date is valid and within range, accept it
        currentDate = newDate
        savePreferences()
        calculateCosts()
    }

    private func calculateCosts() {
        if let accountData = accountResponse {
            Task {
                await tariffVM.calculateCosts(
                    for: currentDate,
                    tariffCode: "savedAccount",
                    intervalType: selectedInterval.viewModelInterval,
                    accountData: accountData
                )
            }
        }
    }

    private func formatDateRange() -> String {
        let dateRange = self.dateRange
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .none
        formatter.locale = globalSettings.locale

        switch selectedInterval {
        case .daily:
            return formatter.string(from: dateRange.start)
        case .weekly:
            let weekEnd = Calendar.current.date(byAdding: .day, value: 6, to: dateRange.start)!
            return "\(formatter.string(from: dateRange.start)) - \(formatter.string(from: weekEnd))"
        case .monthly:
            formatter.dateFormat = "LLLL yyyy"  // e.g. "July 2025"
            return formatter.string(from: dateRange.start)
        }
    }

    // MARK: - Loading Views
    private var initiatingView: some View {
        VStack(spacing: 8) {
            ProgressView()
                .scaleEffect(1.2)
            Text("Initiating Account Tariff...")
                .font(Theme.subFont())
                .foregroundColor(Theme.secondaryTextColor)
            Text("Fetching your consumption data")
                .font(Theme.secondaryFont())
                .foregroundColor(Theme.secondaryTextColor.opacity(0.7))
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 24)
    }

    private var loadingView: some View {
        VStack(spacing: 8) {
            ProgressView()
                .scaleEffect(1.2)
            Text("Loading consumption data...")
                .font(Theme.subFont())
                .foregroundColor(Theme.secondaryTextColor)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 24)
    }

    private var errorView: some View {
        VStack(spacing: 8) {
            Image(systemName: "exclamationmark.triangle")
                .font(.title)
                .foregroundColor(Theme.secondaryTextColor)
            if let error = consumptionVM.error {
                Text("Error: \(error.localizedDescription)")
                    .font(Theme.subFont())
                    .foregroundColor(Theme.secondaryTextColor)
                    .multilineTextAlignment(.center)
            } else {
                Text("An error occurred while loading data")
                    .font(Theme.subFont())
                    .foregroundColor(Theme.secondaryTextColor)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 24)
    }

    // MARK: - Body
    public var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            // Header with improved layout
            HStack {
                if let def = CardRegistry.shared.definition(for: .accountTariff) {
                    Image(systemName: def.iconName)
                        .foregroundColor(Theme.icon)
                    Text(LocalizedStringKey(def.displayNameKey))
                        .font(Theme.titleFont())
                        .foregroundColor(Theme.secondaryTextColor)

                    Spacer()
                    Button(action: {
                        showingDetails = true
                    }) {
                        Image(systemName: "chevron.right.circle.fill")
                            .foregroundColor(Theme.secondaryTextColor)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.bottom, 2)

            if accountResponse == nil {
                // No account message with improved styling
                VStack(spacing: 8) {
                    Image(systemName: "exclamationmark.circle.fill")
                        .foregroundColor(Theme.icon)
                        .font(.system(size: 32))

                    Text("Please configure your Octopus account in settings to view tariff costs")
                        .font(Theme.subFont())
                        .foregroundColor(Theme.secondaryTextColor)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 24)
            } else {
                switch consumptionVM.fetchState {
                case .idle:
                    if consumptionVM.consumptionRecords.isEmpty {
                        // If we have tried to fetch once but still no records,
                        // show partial or a "No data yet" placeholder, rather than infinite spinner
                        if consumptionVM.error != nil {
                            errorView
                        } else {
                            initiatingView
                        }
                    } else {
                        mainContentView
                    }
                case .partial:
                    mainContentView
                case .success:
                    mainContentView
                case .loading:
                    if consumptionVM.consumptionRecords.isEmpty {
                        loadingView
                    } else {
                        // We do have some records => treat it like partial success
                        mainContentView
                    }
                case .failure:
                    errorView
                }
            }
        }
        .rateCardStyle()
        .environment(\.locale, globalSettings.locale)
        .onAppear {
            Task {
                initializeFromSettings()
                updateAllowedDateRange()
                calculateCosts()
            }
        }
        .onChange(of: globalSettings.settings.accountData) { oldValue, newValue in
            guard oldValue != newValue else { return }

            print("🔄 AccountTariffCardView: Detected new accountData, forcing consumption reload.")
            Task {
                // Force a complete refresh from the API when account changes
                await consumptionVM.refreshDataFromAPI(force: true)
                updateAllowedDateRange()
                calculateCosts()
            }
        }
        .onChange(of: globalSettings.locale) { _, _ in
            // Force a re-render if user changes language
            refreshTrigger.toggle()
        }
        .onChange(of: consumptionVM.fetchState) { oldVal, newVal in
            // If we remain at .loading for too long with no data, try loading again
            if newVal == .loading && consumptionVM.consumptionRecords.isEmpty {
                DispatchQueue.main.asyncAfter(wallDeadline: .now() + 8) { [weak consumptionVM] in
                    guard let consumptionVM else { return }
                    if consumptionVM.fetchState == .loading
                        && consumptionVM.consumptionRecords.isEmpty
                    {
                        // Instead of manually setting state, trigger a new load which has proper state management
                        Task { @MainActor in
                            await consumptionVM.loadData()
                        }
                    }
                }
            }
        }
        .onChange(of: consumptionVM.minInterval) { _, _ in
            updateAllowedDateRange()
        }
        .id("account-tariff-\(refreshTrigger)")
        .sheet(isPresented: $showingDetails) {
            NavigationView {
                AccountTariffDetailView(
                    tariffVM: TariffViewModel(),
                    initialInterval: selectedInterval,
                    initialDate: currentDate
                )
            }
            .environmentObject(globalSettings)
        }
    }

    // MARK: - Main Content View
    private var mainContentView: some View {
        VStack(spacing: 0) {
            // Date Navigation with improved layout - full width
            HStack(spacing: 0) {
                // Left navigation area - fixed width
                HStack {
                    if !isAtMinDate && !tariffVM.isCalculating {
                        Button(action: { navigateDate(forward: false) }) {
                            Image(systemName: "chevron.left")
                                .imageScale(.large)
                                .foregroundColor(Theme.mainColor)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.borderless)
                    }
                }
                .frame(width: 44, alignment: .center)
                .id("left-nav-\(isAtMinDate)-\(tariffVM.isCalculating)")

                Spacer(minLength: 0)

                // Center content - using HStack for better vertical alignment
                HStack {
                    Spacer()
                    Text(formatDateRange())
                        .font(Theme.secondaryFont())
                        .foregroundColor(Theme.mainTextColor)
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)
                        .overlay(alignment: .bottom) {
                            if tariffVM.isCalculating {
                                ProgressView()
                                    .progressViewStyle(CircularProgressViewStyle())
                                    .scaleEffect(0.7)
                                    .offset(y: 14)  // Position below the text
                            }
                        }
                    Spacer()
                }
                .frame(maxWidth: .infinity)
                .frame(height: 44)

                Spacer(minLength: 0)

                // Right navigation area - fixed width
                HStack {
                    if !isAtMaxDate && !tariffVM.isCalculating {
                        // For daily mode, check if we can navigate to the next day
                        if selectedInterval != .daily
                            || nextDailyDateWithData(from: currentDate, forward: true) != nil
                        {
                            Button(action: { navigateDate(forward: true) }) {
                                Image(systemName: "chevron.right")
                                    .imageScale(.large)
                                    .foregroundColor(Theme.mainColor)
                                    .contentShape(Rectangle())
                            }
                            .buttonStyle(.borderless)
                        }
                    }
                }
                .frame(width: 44, alignment: .center)
                .id("right-nav-\(isAtMaxDate)-\(tariffVM.isCalculating)")
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 4)

            // Content and Interval Switcher
            HStack(alignment: .bottom, spacing: 8) {
                // Results Display with improved layout
                if let calculation = tariffVM.currentCalculation {
                    VStack(alignment: .leading, spacing: 8) {
                        // Total Cost with improved hierarchy and standard charge info
                        VStack(alignment: .leading, spacing: 2) {
                            let cost =
                                globalSettings.settings.showRatesWithVAT
                                ? calculation.costIncVAT : calculation.costExcVAT
                            Text("£\(String(format: "%.2f", cost/100))")
                                .font(Theme.mainFont())
                                .foregroundColor(Theme.mainTextColor)

                            let standardCharge =
                                globalSettings.settings.showRatesWithVAT
                                ? calculation.standingChargeIncVAT
                                : calculation.standingChargeExcVAT
                            Text(
                                "£\(String(format: "%.2f", standardCharge/100)) standing charge"
                            )
                            .font(Theme.subFont())
                            .foregroundColor(Theme.secondaryTextColor)
                        }
                        .padding(.vertical, 2)

                        // Usage and Average Rate with improved layout
                        VStack(alignment: .leading, spacing: 4) {
                            HStack(spacing: 8) {
                                Image(systemName: "bolt.fill")
                                    .foregroundColor(Theme.icon)
                                    .imageScale(.small)
                                Text(
                                    "Total Usage: \(String(format: "%.1f kWh", calculation.totalKWh))"
                                )
                                .font(Theme.secondaryFont())
                                .foregroundColor(Theme.secondaryTextColor)
                            }

                            HStack(spacing: 8) {
                                Image(systemName: "chart.line.uptrend.xyaxis")
                                    .foregroundColor(Theme.icon)
                                    .imageScale(.small)
                                let avgRate =
                                    globalSettings.settings.showRatesWithVAT
                                    ? calculation.averageUnitRateIncVAT
                                    : calculation.averageUnitRateExcVAT
                                Text("Average Rate: \(String(format: "%.2f p/kWh", avgRate))")
                                    .font(Theme.secondaryFont())
                                    .foregroundColor(Theme.secondaryTextColor)
                            }
                        }
                    }
                    Spacer(minLength: 0)
                }

                // Right side interval picker
                VStack(spacing: 6) {
                    ForEach(IntervalType.allCases, id: \.self) { interval in
                        Button(action: {
                            withAnimation {
                                selectedInterval = interval
                                // Restore last viewed date for this interval if available
                                if let savedDate = globalSettings.settings
                                    .lastViewedTariffDates[interval.rawValue]
                                {
                                    currentDate = savedDate
                                }
                                updateAllowedDateRange()
                                savePreferences()
                                calculateCosts()
                            }
                        }) {
                            HStack {
                                // Left side with icon
                                Image(systemName: iconName(for: interval))
                                    .imageScale(.small)
                                    .frame(width: 24, alignment: .leading)

                                Spacer(minLength: 16)  // Fixed space between icon and text

                                // Right side with text
                                Text(interval.displayName)
                                    .font(.callout)
                                    .frame(alignment: .trailing)
                            }
                            .font(Theme.subFont())
                            .foregroundColor(
                                selectedInterval == interval
                                    ? Theme.mainTextColor : Theme.secondaryTextColor
                            )
                            .frame(height: 32)
                            .frame(width: 110, alignment: .leading)
                            .padding(.horizontal, 8)
                            .background(
                                RoundedRectangle(cornerRadius: 6)
                                    .fill(
                                        selectedInterval == interval
                                            ? Theme.mainColor.opacity(0.2) : Color.clear)
                            )
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .trailing)
            .padding(.bottom, 6)
        }
    }
}

// MARK: - Detail View
struct AccountTariffDetailView: View {
    // MARK: - Dependencies
    @ObservedObject var tariffVM: TariffViewModel
    let initialInterval: AccountTariffCardView.IntervalType
    let initialDate: Date
    @EnvironmentObject var globalSettings: GlobalSettingsManager
    @Environment(\.dismiss) var dismiss

    // MARK: - State
    @State private var selectedInterval: AccountTariffCardView.IntervalType
    @State private var currentDate: Date
    @State private var displayedRatesByDate: [(String, TariffViewModel.TariffCalculation)] = []
    @State private var hasInitiallyLoaded = false
    @State private var loadedDays: [Date] = []
    @State private var refreshTrigger = UUID()
    @State private var forceReRenderToggle = false

    // Add initializer
    init(
        tariffVM: TariffViewModel, initialInterval: AccountTariffCardView.IntervalType,
        initialDate: Date
    ) {
        self.tariffVM = tariffVM
        self.initialInterval = initialInterval
        self.initialDate = initialDate
        // Initialize state with initial values
        _selectedInterval = State(initialValue: initialInterval)
        _currentDate = State(initialValue: initialDate)
    }

    private let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "d MMMM yyyy"  // UK format: e.g. "15 January 2024"
        return formatter
    }()

    private let monthFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "MMMM yyyy"  // UK format: e.g. "January 2024"
        return formatter
    }()

    private var dynamicViewID: String {
        "account-tariff-detail-\(refreshTrigger)-\(forceReRenderToggle ? 1 : 0)-\(selectedInterval.rawValue)"
    }

    private func iconName(for interval: AccountTariffCardView.IntervalType) -> String {
        switch interval {
        case .daily: return "calendar.day.timeline.left"
        case .weekly: return "calendar.badge.clock"
        case .monthly: return "calendar"
        }
    }

    // MARK: - Loading Methods
    private func loadInitialData() async {
        // Each interval fetch is done in date-descending order for daily/weekly/monthly.
        // We'll do two-phase fetching:
        //  1) Phase 1: Load a small subset of intervals (e.g. 5 days/weeks/months).
        //  2) Phase 2: Background fetch the rest, appending them in descending order once done.

        guard !hasInitiallyLoaded else { return }

        // Clear displayed data only once here when we start loading
        await MainActor.run {
            displayedRatesByDate = []
            loadedDays = []
            hasInitiallyLoaded = true
        }

        let calendar = Calendar.current
        let now = Date()
        let startOfToday = calendar.startOfDay(for: now)

        switch selectedInterval {
        case .daily:
            var daysToLoad: [Date] = []
            // We'll store everything in descending order:
            daysToLoad.append(startOfToday)  // newest first
            for dayOffset in 1...30 {
                if let d = calendar.date(byAdding: .day, value: -dayOffset, to: startOfToday) {
                    daysToLoad.append(d)
                }
            }
            // PHASE 1: Take the first 5 days only (or fewer if less available).
            let phase1Count = min(daysToLoad.count, 5)
            let phase1Dates = Array(daysToLoad.prefix(phase1Count))

            // Load only the newest 5 days first
            await loadDates(phase1Dates, interval: .daily)
            // Then fetch the REST in a background task
            await fetchRemainingDays(Array(daysToLoad.dropFirst(phase1Count)), interval: .daily)

        case .weekly:
            var weeksToLoad: [Date] = []
            let currentWeekStart = calendar.date(
                from: calendar.dateComponents([.yearForWeekOfYear, .weekOfYear], from: now))!
            weeksToLoad.append(currentWeekStart)

            for weekOffset in 1...12 {
                if let date = calendar.date(
                    byAdding: .weekOfYear, value: -weekOffset, to: startOfToday)
                {
                    let weekStart = calendar.date(
                        from: calendar.dateComponents(
                            [.yearForWeekOfYear, .weekOfYear], from: date))!
                    weeksToLoad.append(weekStart)
                }
            }

            let phase1Count = min(weeksToLoad.count, 3)
            let phase1Weeks = Array(weeksToLoad.prefix(phase1Count))
            await loadDates(phase1Weeks, interval: .weekly)
            await fetchRemainingDays(Array(weeksToLoad.dropFirst(phase1Count)), interval: .weekly)

        case .monthly:
            var monthsToLoad: [Date] = []
            let currentMonthStart = calendar.date(
                from: calendar.dateComponents([.year, .month], from: now))!
            monthsToLoad.append(currentMonthStart)

            for monthOffset in 1...6 {
                if let date = calendar.date(byAdding: .month, value: -monthOffset, to: startOfToday)
                {
                    let monthStart = calendar.date(
                        from: calendar.dateComponents([.year, .month], from: date))!
                    monthsToLoad.append(monthStart)
                }
            }
            let phase1Count = min(monthsToLoad.count, 2)
            let phase1Months = Array(monthsToLoad.prefix(phase1Count))
            await loadDates(phase1Months, interval: .monthly)
            await fetchRemainingDays(Array(monthsToLoad.dropFirst(phase1Count)), interval: .monthly)
        }
    }

    /// Background fetch: loads the remaining intervals after the user sees partial results.
    private func fetchRemainingDays(
        _ remaining: [Date], interval: AccountTariffCardView.IntervalType
    ) async {
        guard !remaining.isEmpty else { return }
        // This can run in the background so user sees partial results quickly.
        await loadDates(remaining, interval: interval)
    }

    /// Instead of rewriting loadDates, we keep it the same. We just call it in two stages.
    /// The rest of your loadDates(...) remains unchanged, but now it's effectively "two-phase."
    ///
    /// IMPORTANT: Because we call loadDates for the second chunk in the background,
    /// the user sees partial results (Phase 1) and then sees the older entries appended.
    /// We'll maintain the order so that the newest intervals remain at the top
    /// of displayedRatesByDate, with older appended at the bottom.

    private func loadDates(_ dates: [Date], interval: AccountTariffCardView.IntervalType) async {
        // Remove the data clearing since it's now done in loadInitialData
        // This allows accumulation of data from both phases

        // Load dates sequentially in descending order (they're already sorted)
        for date in dates {
            await loadPeriod(date, interval: interval)
        }

        // No need to sort as data is already in descending order
    }

    private func loadPeriod(_ date: Date, interval: AccountTariffCardView.IntervalType) async {
        let calendar = Calendar.current
        let periodStart = calendar.startOfDay(for: date)  // daily/weekly/monthly pivot
        if loadedDays.contains(where: { calendar.isDate($0, inSameDayAs: periodStart) }) {
            return  // skip duplicates
        }

        if let accountData = globalSettings.settings.accountData,
            let decoded = try? JSONDecoder().decode(OctopusAccountResponse.self, from: accountData)
        {
            await tariffVM.calculateCosts(
                for: periodStart,
                tariffCode: "savedAccount",
                intervalType: interval.viewModelInterval,
                accountData: decoded
            )

            if let calculation = tariffVM.currentCalculation {
                await MainActor.run {
                    let dateString: String
                    switch interval {
                    case .daily:
                        dateString = dateFormatter.string(from: periodStart)
                    case .weekly:
                        let weekEnd = calendar.date(byAdding: .day, value: 6, to: periodStart)!
                        dateString =
                            "\(dateFormatter.string(from: periodStart)) - \(dateFormatter.string(from: weekEnd))"
                    case .monthly:
                        dateString = monthFormatter.string(from: periodStart)
                    }

                    if let existingIndex = displayedRatesByDate.firstIndex(where: {
                        $0.0 == dateString
                    }) {
                        displayedRatesByDate[existingIndex] = (dateString, calculation)
                    } else {
                        displayedRatesByDate.append((dateString, calculation))
                    }
                    loadedDays.append(periodStart)
                }
            }
        }
    }

    // MARK: - View Body
    var body: some View {
        VStack(spacing: 0) {
            // Header with centered title and close button
            ZStack {
                Text("Account Tariff Details")
                    .font(Theme.titleFont())
                    .foregroundColor(Theme.mainTextColor)

                HStack {
                    Spacer()
                    Button {
                        dismiss()
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundColor(Theme.secondaryTextColor.opacity(0.9))
                            .imageScale(.large)
                    }
                }
            }
            .padding(.horizontal)
            .padding(.vertical, 8)
            .background(Theme.mainBackground)

            Divider()
                .padding(.horizontal)
                .padding(.top, 12)
                .padding(.bottom, 4)

            // Interval Picker
            HStack(spacing: 16) {
                ForEach(AccountTariffCardView.IntervalType.allCases, id: \.self) { interval in
                    Button(action: {
                        withAnimation {
                            selectedInterval = interval
                            Task {
                                hasInitiallyLoaded = false
                                await loadInitialData()
                            }
                        }
                    }) {
                        HStack {
                            Image(systemName: iconName(for: interval))
                                .imageScale(.small)
                            Text(interval.displayName)
                                .font(Theme.subFont())
                        }
                        .foregroundColor(
                            selectedInterval == interval
                                ? Theme.mainTextColor : Theme.secondaryTextColor
                        )
                        .padding(.horizontal, 12)
                        .padding(.vertical, 6)
                        .background(
                            RoundedRectangle(cornerRadius: 8)
                                .fill(
                                    selectedInterval == interval
                                        ? Theme.mainColor.opacity(0.2) : Color.clear)
                        )
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal)
            .padding(.vertical, 8)
            .background(Theme.mainBackground)

            if displayedRatesByDate.isEmpty {
                ProgressView("Loading rates...")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ratesListView
            }
        }
        .background(Theme.mainBackground)
        .onAppear {
            Task {
                await loadInitialData()
            }
        }
    }

    // MARK: - Subviews
    private var ratesListView: some View {
        ScrollViewReader { proxy in
            List {
                ForEach(displayedRatesByDate, id: \.0) { dateString, calculation in
                    Section {
                        DailyStatsView(calculation: calculation)
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
                // Scroll to the most recent date
                if let firstDate = displayedRatesByDate.first?.0 {
                    withAnimation {
                        proxy.scrollTo(firstDate, anchor: .top)
                    }
                }
            }
        }
    }
}

// MARK: - Helper Views
private struct DailyCostView: View {
    let calculation: TariffViewModel.TariffCalculation
    @EnvironmentObject var globalSettings: GlobalSettingsManager

    var body: some View {
        HStack {
            Text("Total Cost")
                .font(Theme.titleFont())
            Spacer()
            let cost =
                globalSettings.settings.showRatesWithVAT
                ? calculation.costIncVAT : calculation.costExcVAT
            Text("£\(String(format: "%.2f", cost/100))")
                .font(Theme.mainFont())
                .foregroundColor(Theme.mainTextColor)
        }
    }
}

private struct ConsumptionStatsView: View {
    let calculation: TariffViewModel.TariffCalculation

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                Image(systemName: "bolt.fill")
                    .foregroundColor(Theme.icon)
                Text("\(String(format: "%.1f", calculation.totalKWh)) kWh")
                    .font(Theme.secondaryFont())
            }
            Text("Consumption")
                .font(Theme.captionFont())
                .foregroundColor(Theme.secondaryTextColor)
        }
    }
}

private struct AverageRateView: View {
    let calculation: TariffViewModel.TariffCalculation
    @EnvironmentObject var globalSettings: GlobalSettingsManager

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                Image(systemName: "chart.line.uptrend.xyaxis")
                    .foregroundColor(Theme.icon)
                let avgRate =
                    globalSettings.settings.showRatesWithVAT
                    ? calculation.averageUnitRateIncVAT : calculation.averageUnitRateExcVAT
                Text("\(String(format: "%.1f", avgRate))p/kWh")
                    .font(Theme.secondaryFont())
            }
            Text("Average Rate")
                .font(Theme.captionFont())
                .foregroundColor(Theme.secondaryTextColor)
        }
    }
}

private struct StandingChargeView: View {
    let calculation: TariffViewModel.TariffCalculation
    @EnvironmentObject var globalSettings: GlobalSettingsManager

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                Image(systemName: "clock.fill")
                    .foregroundColor(Theme.icon)
                let charge =
                    globalSettings.settings.showRatesWithVAT
                    ? calculation.standingChargeIncVAT : calculation.standingChargeExcVAT
                Text("£\(String(format: "%.2f", charge/100))")
                    .font(Theme.secondaryFont())
            }
            Text("Standing Charge")
                .font(Theme.captionFont())
                .foregroundColor(Theme.secondaryTextColor)
        }
    }
}

private struct DailyStatsView: View {
    let calculation: TariffViewModel.TariffCalculation

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            DailyCostView(calculation: calculation)

            Divider()

            HStack(spacing: 16) {
                ConsumptionStatsView(calculation: calculation)
                AverageRateView(calculation: calculation)
                StandingChargeView(calculation: calculation)
            }
        }
        .padding(.vertical, 8)
    }
}
