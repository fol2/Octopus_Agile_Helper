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
    @State private var accountResponse: OctopusAccountResponse?

    // MARK: - Types
    enum IntervalType: String, CaseIterable {
        case daily = "DAILY"
        case weekly = "WEEKLY"
        case monthly = "MONTHLY"

        var displayName: String {
            switch self {
            case .daily: "Daily"
            case .weekly: "Weekly"
            case .monthly: "Monthly"
            }
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
        .task {
            decodeAccountData()
        }
        .onChange(of: globalSettings.settings.accountData) { oldValue, newValue in
            guard oldValue != newValue else { return }
            print("🔄 AccountTariffCardView: Detected new accountData, forcing consumption reload.")
            decodeAccountData()
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
                    consumptionVM: consumptionVM,
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

        // Restore partial coverage so we can see incomplete intervals
        let (stdStart, stdEnd) = tariffVM.calculateDateRange(
            for: currentDate,
            intervalType: selectedInterval.viewModelInterval,
            billingDay: globalSettings.settings.billingDay
        )

        // If the consumption doesn't extend that far, we do partial coverage up to maxInterval
        let lastKnown = consumptionVM.maxInterval ?? Date()
        let partialEnd = min(stdEnd, lastKnown)

        // Always compute partial coverage, even if partialEnd < now
        // (This ensures we can see e.g. 20 Jan - 23 Jan if data ended on the 23rd)
        Task {
            await tariffVM.calculateCosts(
                for: currentDate,
                tariffCode: "savedAccount",
                intervalType: selectedInterval.viewModelInterval,
                accountData: accountData,
                partialStart: stdStart,
                partialEnd: partialEnd
            )
        }
    }

    private func initializeFromSettings() {
        selectedInterval = IntervalType.from(string: globalSettings.settings.selectedTariffInterval)
        currentDate =
            globalSettings.settings
            .lastViewedTariffDates[globalSettings.settings.selectedTariffInterval] ?? Date()
    }

    private func savePreferences() {
        globalSettings.settings.selectedTariffInterval = selectedInterval.rawValue
        globalSettings.settings.lastViewedTariffDates[selectedInterval.rawValue] = currentDate
    }

    private func updateAllowedDateRange() {
        let calendar = Calendar.current
        let today = Date()
        let startOfToday = calendar.startOfDay(for: today)

        // Set minAllowedDate from consumption data
        minAllowedDate = consumptionVM.minInterval

        // Get the boundary for current date's interval
        let currentBoundary = tariffVM.getBoundary(
            for: today,
            intervalType: selectedInterval.viewModelInterval,
            billingDay: globalSettings.settings.billingDay
        )

        // For all intervals, use maxInterval from consumption data
        let rawMax = consumptionVM.maxInterval ?? startOfToday

        switch selectedInterval {
        case .daily:
            // For daily view, we use yesterday as the maximum allowed date
            // This ensures we only show complete days
            maxAllowedDate = calendar.date(byAdding: .day, value: -1, to: startOfToday)

        case .weekly:
            // Find the end of the last complete week
            let weekday = calendar.component(.weekday, from: today)
            let daysToSubtract = weekday == 1 ? 7 : weekday - 1  // If Sunday, subtract 7, else weekday - 1
            let lastCompleteWeekEnd =
                calendar.date(byAdding: .day, value: -daysToSubtract, to: startOfToday) ?? today

            // Check if consumption data extends into current partial week
            let currentWeekStart = calendar.date(
                byAdding: .day, value: -daysToSubtract + 1, to: lastCompleteWeekEnd)!
            let hasPartialWeekData =
                (consumptionVM.maxInterval ?? .distantFuture) > currentWeekStart

            // Modified max date calculation
            maxAllowedDate =
                hasPartialWeekData
                ? min(rawMax, consumptionVM.maxInterval ?? .distantFuture)
                : min(rawMax, lastCompleteWeekEnd)

        case .monthly:
            // For monthly view, find the end of the last complete month
            let lastDayOfPreviousMonth =
                calendar.date(from: calendar.dateComponents([.year, .month], from: today)) ?? today
            maxAllowedDate = min(rawMax, lastDayOfPreviousMonth)
        }

        // Only clamp against maxAllowedDate to prevent going beyond allowed range
        if let mx = maxAllowedDate {
            let dateToCheck = tariffVM.getBoundary(
                for: currentDate,
                intervalType: selectedInterval.viewModelInterval,
                billingDay: globalSettings.settings.billingDay
            )
            // If current date's interval starts after max allowed date, clamp it
            if dateToCheck.start > mx {
                currentDate = mx
            }
        }

        // We do NOT clamp against minAllowedDate anymore to allow partial earliest intervals
        // This is preserved from the original implementation
    }

    // MARK: - Account Data Decoding
    private func decodeAccountData() {
        guard let accountData = globalSettings.settings.accountData else {
            accountResponse = nil
            return
        }

        // Decode in background
        DispatchQueue.global(qos: .userInitiated).async {
            let decoded = try? JSONDecoder().decode(OctopusAccountResponse.self, from: accountData)
            DispatchQueue.main.async {
                self.accountResponse = decoded
            }
        }
    }

    private func buildDailySet() -> Set<Date>? {
        guard selectedInterval == .daily else { return nil }
        guard let minD = minAllowedDate,
            let maxD = maxAllowedDate
        else { return nil }

        // Use the new ConsumptionViewModel method to get available dates
        let dates = consumptionVM.getAvailableDates(in: minD...maxD)
        return dates.isEmpty ? nil : dates
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

    // Add computed properties for current boundaries
    private var currentBoundary: TariffViewModel.IntervalBoundary {
        tariffVM.getBoundary(
            for: currentDate,
            intervalType: selectedInterval.viewModelInterval,
            billingDay: globalSettings.settings.billingDay
        )
    }

    private var previousBoundary: TariffViewModel.IntervalBoundary? {
        guard let prevDate = getPreviousDate() else { return nil }
        return tariffVM.getBoundary(
            for: prevDate,
            intervalType: selectedInterval.viewModelInterval,
            billingDay: globalSettings.settings.billingDay
        )
    }

    private var nextBoundary: TariffViewModel.IntervalBoundary? {
        guard let nextDate = getNextDate() else { return nil }
        return tariffVM.getBoundary(
            for: nextDate,
            intervalType: selectedInterval.viewModelInterval,
            billingDay: globalSettings.settings.billingDay
        )
    }

    var body: some View {
        HStack(spacing: 0) {
            // Left
            HStack {
                let canGoBack = canNavigateBackward()
                if canGoBack {
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
            .frame(width: 64)

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
            HStack(spacing: 0) {
                let canGoForward = canNavigateForward()
                // New jump to max button
                if let maxDate = maxAllowedDate,
                    currentDate < maxDate && !tariffVM.isCalculating && canGoForward
                {
                    Button {
                        if selectedInterval == .daily {
                            // For daily intervals, find the latest available day from consumption data
                            if let dailySet = buildDailySet(),
                                let latestAvailable = dailySet.max()
                            {
                                currentDate = latestAvailable
                                onDateChanged()
                            }
                        } else {
                            // For other intervals, use maxDate
                            currentDate = maxDate
                            onDateChanged()
                        }
                    } label: {
                        Image(systemName: "chevron.right.to.line")
                            .imageScale(.large)
                            .foregroundColor(Theme.mainColor)
                            .contentShape(Rectangle())
                    }
                    .disabled(tariffVM.isCalculating)
                    .frame(width: 24)
                    .padding(.trailing, 8)
                } else {
                    Color.clear
                        .frame(width: 24)
                        .padding(.trailing, 8)
                }

                // Existing forward button
                if canGoForward {
                    Button {
                        moveDate(forward: true)
                    } label: {
                        Image(systemName: "chevron.right")
                            .imageScale(.large)
                            .foregroundColor(Theme.mainColor)
                            .contentShape(Rectangle())
                    }
                    .frame(width: 24)
                } else {
                    Color.clear
                        .frame(width: 24)
                }
            }
            .frame(width: 56)
            .contentShape(Rectangle())
        }
        .padding(.vertical, 4)
    }

    // MARK: - Navigation Logic
    private func canNavigateBackward() -> Bool {
        // Don't allow navigation while calculating
        if tariffVM.isCalculating { return false }

        // For daily intervals with available dates, check if previous date exists
        if selectedInterval == .daily {
            if let dailySet = buildDailySet() {
                return getPreviousDate() != nil
            }
        }

        // For other intervals, use boundary checking
        guard let prevBoundary = previousBoundary else { return false }
        return prevBoundary.overlapsWithData(minDate: minAllowedDate, maxDate: maxAllowedDate)
    }

    private func canNavigateForward() -> Bool {
        // Don't allow navigation while calculating
        if tariffVM.isCalculating { return false }

        // For daily intervals with available dates, check if next date exists
        if selectedInterval == .daily {
            if let dailySet = buildDailySet() {
                return getNextDate() != nil
            }
        }

        // For other intervals, use boundary checking
        guard let nextBoundary = nextBoundary else { return false }
        return !nextBoundary.isAfterData(maxDate: maxAllowedDate)
    }

    private func getPreviousDate() -> Date? {
        let calendar = Calendar.current

        switch selectedInterval {
        case .daily:
            if let dailySet = buildDailySet() {
                return findPreviousAvailableDay(from: currentDate, in: dailySet)
            } else {
                return calendar.date(byAdding: .day, value: -1, to: currentDate)
            }

        case .weekly:
            return calendar.date(byAdding: .weekOfYear, value: -1, to: currentDate)

        case .monthly:
            return calendar.date(byAdding: .month, value: -1, to: currentDate)
        }
    }

    private func getNextDate() -> Date? {
        let calendar = Calendar.current

        switch selectedInterval {
        case .daily:
            if let dailySet = buildDailySet() {
                return findNextAvailableDay(from: currentDate, in: dailySet)
            } else {
                return calendar.date(byAdding: .day, value: 1, to: currentDate)
            }

        case .weekly:
            return calendar.date(byAdding: .weekOfYear, value: 1, to: currentDate)

        case .monthly:
            return calendar.date(byAdding: .month, value: 1, to: currentDate)
        }
    }

    private func findPreviousAvailableDay(from date: Date, in dailySet: Set<Date>) -> Date? {
        let calendar = Calendar.current
        var candidate = calendar.startOfDay(for: date)

        while true {
            guard let prevDay = calendar.date(byAdding: .day, value: -1, to: candidate) else {
                return nil
            }
            candidate = calendar.startOfDay(for: prevDay)

            // Bounds check
            if let minDate = minAllowedDate, candidate < calendar.startOfDay(for: minDate) {
                return nil
            }

            // If the candidate is in the set, we found our previous valid day
            if dailySet.contains(candidate) {
                return candidate
            }
        }
    }

    private func findNextAvailableDay(from date: Date, in dailySet: Set<Date>) -> Date? {
        let calendar = Calendar.current
        var candidate = calendar.startOfDay(for: date)

        while true {
            guard let nextDay = calendar.date(byAdding: .day, value: 1, to: candidate) else {
                return nil
            }
            candidate = calendar.startOfDay(for: nextDay)

            // Bounds check
            if let maxDate = maxAllowedDate, candidate > calendar.startOfDay(for: maxDate) {
                return nil
            }

            // If the candidate is in the set, we found our next valid day
            if dailySet.contains(candidate) {
                return candidate
            }
        }
    }

    private func moveDate(forward: Bool) {
        if let newDate = forward ? getNextDate() : getPreviousDate() {
            currentDate = newDate
            onDateChanged()
        }
    }

    private func buildDailySet() -> Set<Date>? {
        guard selectedInterval == .daily else { return nil }
        guard let minD = minAllowedDate,
            let maxD = maxAllowedDate
        else { return nil }

        // Use the new ConsumptionViewModel method to get available dates
        let dates = consumptionVM.getAvailableDates(in: minD...maxD)
        return dates.isEmpty ? nil : dates
    }

    private func dateRangeText() -> String {
        let (start, end) = tariffVM.calculateDateRange(
            for: currentDate,
            intervalType: selectedInterval.viewModelInterval,
            billingDay: globalSettings.settings.billingDay
        )

        // 2. Use a Calendar matching the chosen locale
        var cal = Calendar.current
        cal.locale = globalSettings.locale

        // 3. Create date formatters:
        // (A) day+month only, e.g. "20 Jan" (English), "1月20日" (Chinese)
        let dayMonthFormatter = DateFormatter()
        dayMonthFormatter.locale = globalSettings.locale
        dayMonthFormatter.setLocalizedDateFormatFromTemplate("MMMd")

        // (B) day+month+year, e.g. "20 Jan 2025" (English), "2025年1月20日" (Chinese)
        let dayMonthYearFormatter = DateFormatter()
        dayMonthYearFormatter.locale = globalSettings.locale
        dayMonthYearFormatter.setLocalizedDateFormatFromTemplate("yMMMd")

        // (C) year-only in a localised style, e.g. "2025" (English), "2025年" (Chinese)
        let yearOnlyFormatter = DateFormatter()
        yearOnlyFormatter.locale = globalSettings.locale
        // "y" = show year with locale rules, e.g. "2025年" in zh-Hant
        yearOnlyFormatter.setLocalizedDateFormatFromTemplate("y")

        // 4. Determine if both dates are in the same year
        let startYear = cal.component(.year, from: start)
        let endYear = cal.component(.year, from: end)

        switch selectedInterval {
        case .daily:
            // Single day => just show day+month+year
            return dayMonthYearFormatter.string(from: start)

        case .weekly, .monthly:
            // Multi-day range
            if startYear == endYear {
                // ---- SAME-YEAR RANGE ----
                // We'll localise the day+month for each date, and localise the year separately

                // e.g. "20 Jan" in English, "1月20日" in Chinese
                let startNoYear = dayMonthFormatter.string(from: start)
                let endNoYear = dayMonthFormatter.string(from: end)

                // Generate a date for (startYear)-01-01 so we can localise the year via yearOnlyFormatter
                var comps = DateComponents()
                comps.year = startYear
                comps.month = 1
                comps.day = 1
                let january1 = cal.date(from: comps) ?? start

                let yearString = yearOnlyFormatter.string(from: january1)
                // e.g. "2025" in English, "2025年" in Chinese

                let pattern = forcedLocalizedString(
                    key: "SAME_YEAR_RANGE", locale: globalSettings.locale)
                //  - en: "%1$@ - %2$@ %3$@" → "20 Jan - 26 Jan 2025"
                //  - zh: "%3$@%1$@ - %2$@"   → "2025年1月20日 - 1月26日"

                return String(format: pattern, startNoYear, endNoYear, yearString)
            } else {
                // ---- CROSS-YEAR RANGE ----
                // Show day+month+year for both
                let startWithYear = dayMonthYearFormatter.string(from: start)
                let endWithYear = dayMonthYearFormatter.string(from: end)

                let pattern = forcedLocalizedString(
                    key: "CROSS_YEAR_RANGE", locale: globalSettings.locale)
                //  - en: "%1$@ - %2$@" → "30 Dec 2024 - 5 Jan 2025"
                //  - zh: "%1$@ - %2$@" → "2024年12月30日 - 2025年1月5日"

                return String(format: pattern, startWithYear, endWithYear)
            }
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
            // Display calculation or placeholder based on state
            if tariffVM.isCalculating {
                TariffCalculationPlaceholderView()
            } else if let calculation = tariffVM.currentCalculation {
                TariffCalculationSummaryView(
                    calculation: calculation,
                    showVAT: globalSettings.settings.showRatesWithVAT
                )
            } else {
                TariffCalculationPlaceholderView()
            }

            Spacer(minLength: 0)

            // Interval Picker
            VStack(spacing: 6) {
                ForEach(AccountTariffCardView.IntervalType.allCases, id: \.self) { interval in
                    Button {
                        withAnimation { onIntervalChanged(interval) }
                    } label: {
                        HStack {
                            Image(systemName: iconName(for: interval))
                                .imageScale(.small)
                                .frame(alignment: .leading)
                            Spacer()
                            Text(
                                forcedLocalizedString(
                                    key: interval.displayName, locale: globalSettings.locale)
                            )
                            .font(.callout)
                            .frame(alignment: .trailing)
                        }
                        .font(Theme.subFont())
                        .foregroundColor(
                            selectedInterval == interval
                                ? Theme.mainTextColor : Theme.secondaryTextColor
                        )
                        .frame(height: 32)
                        .frame(width: 100, alignment: .leading)
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
            .frame(maxWidth: .infinity, alignment: .leading)

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
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.vertical, 2)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

// Add a new placeholder view
private struct TariffCalculationPlaceholderView: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            // Cost placeholder
            VStack(alignment: .leading, spacing: 2) {
                Text("£0.00")
                    .font(Theme.mainFont())
                    .foregroundColor(Theme.mainTextColor.opacity(0.3))
                Text("£0.00 standing charge")
                    .font(Theme.subFont())
                    .foregroundColor(Theme.secondaryTextColor.opacity(0.3))
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            // Usage & Rate placeholder
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 8) {
                    Image(systemName: "bolt.fill")
                        .foregroundColor(Theme.icon.opacity(0.3))
                        .imageScale(.small)
                    Text("Total Usage: 0.0 kWh")
                        .font(Theme.secondaryFont())
                        .foregroundColor(Theme.secondaryTextColor.opacity(0.3))
                }
                HStack(spacing: 8) {
                    Image(systemName: "chart.line.uptrend.xyaxis")
                        .foregroundColor(Theme.icon.opacity(0.3))
                        .imageScale(.small)
                    Text("Average Rate: 0.00 p/kWh")
                        .font(Theme.secondaryFont())
                        .foregroundColor(Theme.secondaryTextColor.opacity(0.3))
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.vertical, 2)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

// MARK: - Detail View
struct AccountTariffDetailView: View {
    // MARK: - Dependencies
    @ObservedObject var tariffVM: TariffViewModel
    @ObservedObject var consumptionVM: ConsumptionViewModel
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
        tariffVM: TariffViewModel,
        consumptionVM: ConsumptionViewModel,
        initialInterval: AccountTariffCardView.IntervalType,
        initialDate: Date
    ) {
        self.tariffVM = tariffVM
        self.consumptionVM = consumptionVM
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
            // For weekly, we want to include the current week even if partial
            let (currentWeekStart, _) = tariffVM.calculateDateRange(
                for: now,
                intervalType: .weekly,
                billingDay: globalSettings.settings.billingDay
            )
            weeksToLoad.append(currentWeekStart)

            for weekOffset in 1...12 {
                if let date = calendar.date(
                    byAdding: .weekOfYear, value: -weekOffset, to: currentWeekStart)
                {
                    weeksToLoad.append(date)
                }
            }

            let phase1Count = min(weeksToLoad.count, 3)
            let phase1Weeks = Array(weeksToLoad.prefix(phase1Count))
            await loadDates(phase1Weeks, interval: .weekly)
            await fetchRemainingDays(Array(weeksToLoad.dropFirst(phase1Count)), interval: .weekly)

        case .monthly:
            var monthsToLoad: [Date] = []
            // For monthly, we want to include the current billing cycle even if partial
            let (currentMonthStart, _) = tariffVM.calculateDateRange(
                for: now,
                intervalType: .monthly,
                billingDay: globalSettings.settings.billingDay
            )
            monthsToLoad.append(currentMonthStart)

            for monthOffset in 1...6 {
                if let date = calendar.date(
                    byAdding: .month, value: -monthOffset, to: currentMonthStart)
                {
                    monthsToLoad.append(date)
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

        // For display, we want the nominal range (not the partial coverage).
        // So let's fetch the nominal start/end from TariffViewModel:
        let (nominalStart, nominalEnd) = tariffVM.calculateDateRange(
            for: periodStart,
            intervalType: interval.viewModelInterval,
            billingDay: globalSettings.settings.billingDay
        )

        if let accountData = globalSettings.settings.accountData,
            let decoded = try? JSONDecoder().decode(OctopusAccountResponse.self, from: accountData)
        {
            // Get the standard interval range
            let (stdStart, stdEnd) = tariffVM.calculateDateRange(
                for: periodStart,
                intervalType: interval.viewModelInterval,
                billingDay: globalSettings.settings.billingDay
            )

            // If the consumption doesn't extend that far, we do partial coverage up to maxInterval
            let lastKnown = consumptionVM.maxInterval ?? Date()
            let partialEnd = min(stdEnd, lastKnown)

            // Skip if no overlap with consumption data
            if partialEnd <= stdStart { return }

            await tariffVM.calculateCosts(
                for: periodStart,
                tariffCode: "savedAccount",
                intervalType: interval.viewModelInterval,
                accountData: decoded,
                partialStart: stdStart,
                partialEnd: partialEnd
            )

            // For the row label, always use the nominal cycle
            if tariffVM.currentCalculation != nil {
                let dateString = shortRangeLabel(
                    for: nominalStart,
                    to: nominalEnd,
                    interval
                )
                await MainActor.run {
                    if let existingIndex = displayedRatesByDate.firstIndex(where: {
                        $0.0 == dateString
                    }) {
                        displayedRatesByDate[existingIndex] = (
                            dateString, tariffVM.currentCalculation!
                        )
                    } else {
                        displayedRatesByDate.append((dateString, tariffVM.currentCalculation!))
                    }
                    loadedDays.append(periodStart)
                }
            }
        }
    }

    /// Build short UK-styled label for intervals, matching the main view format
    private func shortRangeLabel(
        for start: Date,
        to end: Date,
        _ interval: AccountTariffCardView.IntervalType
    ) -> String {
        // 1. Use a Calendar matching the chosen locale
        var cal = Calendar.current
        cal.locale = globalSettings.locale

        // 2. Create date formatters:
        // (A) day+month only, e.g. "20 Jan" (English), "1月20日" (Chinese)
        let dayMonthFormatter = DateFormatter()
        dayMonthFormatter.locale = globalSettings.locale
        dayMonthFormatter.setLocalizedDateFormatFromTemplate("MMMd")

        // (B) day+month+year, e.g. "20 Jan 2025" (English), "2025年1月20日" (Chinese)
        let dayMonthYearFormatter = DateFormatter()
        dayMonthYearFormatter.locale = globalSettings.locale
        dayMonthYearFormatter.setLocalizedDateFormatFromTemplate("yMMMd")

        // (C) year-only in a localised style, e.g. "2025" (English), "2025年" (Chinese)
        let yearOnlyFormatter = DateFormatter()
        yearOnlyFormatter.locale = globalSettings.locale
        yearOnlyFormatter.setLocalizedDateFormatFromTemplate("y")

        // 3. Determine if both dates are in the same year
        let startYear = cal.component(.year, from: start)
        let endYear = cal.component(.year, from: end)

        switch interval {
        case .daily:
            // Single day => just show day+month+year
            return dayMonthYearFormatter.string(from: start)

        case .weekly, .monthly:
            if startYear == endYear {
                // ---- SAME-YEAR RANGE ----
                // We'll localise the day+month for each date, and localise the year separately
                let startNoYear = dayMonthFormatter.string(from: start)
                let endNoYear = dayMonthFormatter.string(from: end)

                // Generate a date for (startYear)-01-01 so we can localise the year via yearOnlyFormatter
                var comps = DateComponents()
                comps.year = startYear
                comps.month = 1
                comps.day = 1
                let january1 = cal.date(from: comps) ?? start
                let yearString = yearOnlyFormatter.string(from: january1)

                let pattern = forcedLocalizedString(
                    key: "SAME_YEAR_RANGE", locale: globalSettings.locale)
                return String(format: pattern, startNoYear, endNoYear, yearString)
            } else {
                // ---- CROSS-YEAR RANGE ----
                // Show day+month+year for both dates
                let startWithYear = dayMonthYearFormatter.string(from: start)
                let endWithYear = dayMonthYearFormatter.string(from: end)

                let pattern = forcedLocalizedString(
                    key: "CROSS_YEAR_RANGE", locale: globalSettings.locale)
                return String(format: pattern, startWithYear, endWithYear)
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
                            Text(
                                forcedLocalizedString(
                                    key: interval.displayName, locale: globalSettings.locale)
                            )
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
