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
        self._selectedInterval = State(initialValue: .daily)
        self._currentDate = State(initialValue: Date())
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
            // Header
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
                // No account message
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
                        mainContentView
                    }
                case .failure:
                    errorView
                }
            }
        }
        .rateCardStyle()
        .environment(\.locale, globalSettings.locale)
        .onAppear(perform: handleOnAppear)
        .onChange(of: globalSettings.settings.accountData) { oldValue, newValue in
            guard oldValue != newValue else { return }
            print("🔄 AccountTariffCardView: Detected new accountData, forcing consumption reload.")
            Task {
                await consumptionVM.refreshDataFromAPI(force: true)
                updateAllowedDateRangeAndRecalculate()
            }
        }
        .onChange(of: globalSettings.locale) { _, _ in
            refreshTrigger.toggle()
        }
        .onChange(of: consumptionVM.fetchState) { oldVal, newVal in
            if newVal == .loading && consumptionVM.consumptionRecords.isEmpty {
                DispatchQueue.main.asyncAfter(wallDeadline: .now() + 8) { [weak consumptionVM] in
                    guard let consumptionVM else { return }
                    if consumptionVM.fetchState == .loading
                        && consumptionVM.consumptionRecords.isEmpty
                    {
                        Task { @MainActor in
                            await consumptionVM.loadData()
                        }
                    }
                }
            }
        }
        .onChange(of: consumptionVM.minInterval) { _, _ in
            updateAllowedDateRangeAndRecalculate()
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

    // MARK: - Main content body splitted
    @ViewBuilder
    private var mainContentView: some View {
        VStack(spacing: 0) {
            // (A) Date Navigation Sub-View
            AccountTariffDateNavView(
                currentDate: $currentDate,
                selectedInterval: $selectedInterval,
                minAllowedDate: minAllowedDate,
                maxAllowedDate: maxAllowedDate,
                tariffVM: tariffVM,
                consumptionVM: consumptionVM,
                onDateChanged: {
                    savePreferences()
                    calculateCostsIfPossible()
                },
                globalSettings: globalSettings
            )
            // (B) Main Card Content Sub-View
            AccountTariffMainContentView(
                tariffVM: tariffVM,
                selectedInterval: $selectedInterval,
                currentDate: $currentDate,
                globalSettings: globalSettings,
                onIntervalChanged: { interval in
                    selectedInterval = interval
                    if let savedDate = globalSettings.settings
                        .lastViewedTariffDates[interval.rawValue]
                    {
                        currentDate = savedDate
                    }
                    updateAllowedDateRange()
                    savePreferences()
                    calculateCostsIfPossible()
                }
            )
        }
    }

    // MARK: - Private Helpers
    private func handleOnAppear() {
        Task {
            initializeFromSettings()
            updateAllowedDateRange()
            calculateCostsIfPossible()
        }
    }

    private func updateAllowedDateRangeAndRecalculate() {
        updateAllowedDateRange()
        calculateCostsIfPossible()
    }

    private func calculateCostsIfPossible() {
        guard let accountData = accountResponse else { return }
        Task {
            await tariffVM.calculateCosts(
                for: currentDate,
                tariffCode: "savedAccount",
                intervalType: selectedInterval.viewModelInterval,
                accountData: accountData
            )
        }
    }

    private func initializeFromSettings() {
        selectedInterval = IntervalType.from(string: globalSettings.settings.selectedTariffInterval)
        currentDate =
            globalSettings.settings
            .lastViewedTariffDates[globalSettings.settings.selectedTariffInterval] ?? Date()
    }

    private var accountResponse: OctopusAccountResponse? {
        guard
            let accountData = globalSettings.settings.accountData,
            let decoded = try? JSONDecoder().decode(OctopusAccountResponse.self, from: accountData)
        else {
            return nil
        }
        return decoded
    }

    private func savePreferences() {
        globalSettings.settings.selectedTariffInterval = selectedInterval.rawValue
        globalSettings.settings.lastViewedTariffDates[selectedInterval.rawValue] = currentDate
    }

    private func updateAllowedDateRange() {
        let calendar = Calendar.current
        let now = Date()
        let startOfToday = calendar.startOfDay(for: now)
        let latestDailyDate = calendar.date(byAdding: .day, value: -1, to: startOfToday)!

        switch selectedInterval {
        case .daily:
            maxAllowedDate = latestDailyDate
        case .weekly:
            let latestWeekStart = calendar.date(
                from: calendar.dateComponents(
                    [.yearForWeekOfYear, .weekOfYear], from: latestDailyDate))!
            maxAllowedDate = latestWeekStart
        case .monthly:
            maxAllowedDate = calendar.date(
                from: calendar.dateComponents([.year, .month], from: latestDailyDate))
        }

        minAllowedDate = consumptionVM.minInterval

        if let mx = maxAllowedDate, currentDate > mx {
            currentDate = mx
        }
        if let mn = minAllowedDate, currentDate < mn {
            currentDate = mn
        }
    }
}

// MARK: - Sub-view: Date Navigation
private struct AccountTariffDateNavView: View {
    @Binding var currentDate: Date
    @Binding var selectedInterval: AccountTariffCardView.IntervalType
    let minAllowedDate: Date?
    let maxAllowedDate: Date?
    @ObservedObject var tariffVM: TariffViewModel
    @ObservedObject var consumptionVM: ConsumptionViewModel
    let onDateChanged: () -> Void
    @ObservedObject var globalSettings: GlobalSettingsManager

    var body: some View {
        HStack(spacing: 0) {
            // Left
            HStack {
                let atMin = tariffVM.isDateAtMinimum(
                    currentDate,
                    intervalType: selectedInterval.viewModelInterval,
                    minDate: minAllowedDate
                )
                if !atMin && !tariffVM.isCalculating {
                    Button {
                        moveDate(forward: false)
                    } label: {
                        Image(systemName: "chevron.left")
                            .imageScale(.large)
                            .foregroundColor(Theme.mainColor)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.borderless)
                }
            }
            .frame(width: 44)

            Spacer(minLength: 0)

            // Center
            HStack {
                Spacer()
                Text(dateRangeText())
                    .font(Theme.secondaryFont())
                    .foregroundColor(Theme.mainTextColor)
                    .overlay(alignment: .bottom) {
                        if tariffVM.isCalculating {
                            ProgressView()
                                .progressViewStyle(CircularProgressViewStyle())
                                .scaleEffect(0.7)
                                .offset(y: 14)
                        }
                    }
                Spacer()
            }
            .frame(height: 44)

            Spacer(minLength: 0)

            // Right
            HStack {
                let atMax = tariffVM.isDateAtMaximum(
                    currentDate,
                    intervalType: selectedInterval.viewModelInterval,
                    maxDate: maxAllowedDate
                )
                if !atMax && !tariffVM.isCalculating {
                    // For daily, check if we have a next daily date with data
                    if selectedInterval != .daily
                        || nextDailyAvailableDateExists(forward: true)
                    {
                        Button {
                            moveDate(forward: true)
                        } label: {
                            Image(systemName: "chevron.right")
                                .imageScale(.large)
                                .foregroundColor(Theme.mainColor)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.borderless)
                    }
                }
            }
            .frame(width: 44)
        }
        .padding(.vertical, 4)
    }

    // Attempt to step the date (via TariffViewModel)
    private func moveDate(forward: Bool) {
        // Build daily set for consumption if needed
        var dailySet: Set<Date>? = nil
        if selectedInterval == .daily {
            let minD = minAllowedDate ?? Date.distantPast
            let maxD = maxAllowedDate ?? Date.distantFuture
            let calendar = Calendar.current
            dailySet = Set(
                consumptionVM.consumptionRecords.compactMap { record in
                    guard let start = record.value(forKey: "interval_start") as? Date else {
                        return nil
                    }
                    if start < minD || start > maxD { return nil }
                    return calendar.startOfDay(for: start)
                }
            )
        }

        if let newDate = tariffVM.nextDate(
            from: currentDate,
            forward: forward,
            intervalType: selectedInterval.viewModelInterval,
            minDate: minAllowedDate,
            maxDate: maxAllowedDate,
            dailyAvailableDates: dailySet
        ) {
            currentDate = newDate
            onDateChanged()
        }
    }

    private func nextDailyAvailableDateExists(forward: Bool) -> Bool {
        // If we have a valid next daily date, return true
        // This is basically a "peek" version of moveDate
        let result = tariffVM.nextDate(
            from: currentDate,
            forward: forward,
            intervalType: selectedInterval.viewModelInterval,
            minDate: minAllowedDate,
            maxDate: maxAllowedDate,
            dailyAvailableDates: buildDailySet()
        )
        return (result != nil)
    }

    private func buildDailySet() -> Set<Date>? {
        guard selectedInterval == .daily else { return nil }
        let minD = minAllowedDate ?? Date.distantPast
        let maxD = maxAllowedDate ?? Date.distantFuture
        let calendar = Calendar.current
        let set: Set<Date> = Set(
            consumptionVM.consumptionRecords.compactMap { record in
                guard let start = record.value(forKey: "interval_start") as? Date else {
                    return nil
                }
                if start < minD || start > maxD { return nil }
                return calendar.startOfDay(for: start)
            }
        )
        return set.isEmpty ? nil : set
    }

    private func dateRangeText() -> String {
        let (start, end) = tariffVM.calculateDateRange(
            for: currentDate,
            intervalType: selectedInterval.viewModelInterval
        )
        let formatter = DateFormatter()
        formatter.locale = globalSettings.locale
        switch selectedInterval {
        case .daily:
            formatter.dateStyle = .medium
            return formatter.string(from: start)
        case .weekly:
            formatter.dateStyle = .medium
            let endDate = Calendar.current.date(byAdding: .day, value: 6, to: start) ?? end
            let s1 = formatter.string(from: start)
            let s2 = formatter.string(from: endDate)
            return "\(s1) - \(s2)"
        case .monthly:
            formatter.dateFormat = "LLLL yyyy"
            return formatter.string(from: start)
        }
    }
}

// MARK: - Sub-view: Main Content
private struct AccountTariffMainContentView: View {
    @ObservedObject var tariffVM: TariffViewModel
    @Binding var selectedInterval: AccountTariffCardView.IntervalType
    @Binding var currentDate: Date
    @ObservedObject var globalSettings: GlobalSettingsManager
    let onIntervalChanged: (AccountTariffCardView.IntervalType) -> Void

    var body: some View {
        HStack(alignment: .bottom, spacing: 8) {
            // Display currentCalculation if available
            if let calculation = tariffVM.currentCalculation {
                TariffCalculationSummaryView(
                    calculation: calculation,
                    showVAT: globalSettings.settings.showRatesWithVAT
                )
                Spacer(minLength: 0)
            }
            // Interval Picker
            VStack(spacing: 6) {
                ForEach(AccountTariffCardView.IntervalType.allCases, id: \.self) { interval in
                    Button {
                        withAnimation { onIntervalChanged(interval) }
                    } label: {
                        HStack {
                            Image(systemName: iconName(for: interval))
                                .imageScale(.small)
                                .frame(width: 24, alignment: .leading)
                            Spacer(minLength: 16)
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
        .padding(.bottom, 6)
    }

    private func iconName(for interval: AccountTariffCardView.IntervalType) -> String {
        switch interval {
        case .daily: return "calendar.day.timeline.left"
        case .weekly: return "calendar.badge.clock"
        case .monthly: return "calendar"
        }
    }
}

// Displays the cost summary, usage, average rate, etc.
private struct TariffCalculationSummaryView: View {
    let calculation: TariffViewModel.TariffCalculation
    let showVAT: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            // Total cost & standing charge
            VStack(alignment: .leading, spacing: 2) {
                let cost = showVAT ? calculation.costIncVAT : calculation.costExcVAT
                Text("£\(String(format: "%.2f", cost / 100.0))")
                    .font(Theme.mainFont())
                    .foregroundColor(Theme.mainTextColor)

                let standingCharge =
                    showVAT
                    ? calculation.standingChargeIncVAT
                    : calculation.standingChargeExcVAT
                Text("£\(String(format: "%.2f", standingCharge / 100.0)) standing charge")
                    .font(Theme.subFont())
                    .foregroundColor(Theme.secondaryTextColor)
            }

            // Usage & Average Rate
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 8) {
                    Image(systemName: "bolt.fill")
                        .foregroundColor(Theme.icon)
                        .imageScale(.small)
                    Text("Total Usage: \(String(format: "%.1f kWh", calculation.totalKWh))")
                        .font(Theme.secondaryFont())
                        .foregroundColor(Theme.secondaryTextColor)
                }
                HStack(spacing: 8) {
                    Image(systemName: "chart.line.uptrend.xyaxis")
                        .foregroundColor(Theme.icon)
                        .imageScale(.small)
                    let avgRate =
                        showVAT
                        ? calculation.averageUnitRateIncVAT
                        : calculation.averageUnitRateExcVAT
                    Text("Average Rate: \(String(format: "%.2f p/kWh", avgRate))")
                        .font(Theme.secondaryFont())
                        .foregroundColor(Theme.secondaryTextColor)
                }
            }
        }
        .padding(.vertical, 2)
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
