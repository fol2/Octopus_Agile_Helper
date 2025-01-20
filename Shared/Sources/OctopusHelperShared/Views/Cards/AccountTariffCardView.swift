import Combine
import CoreData
import SwiftUI

public struct AccountTariffCardView: View {
    // MARK: - Dependencies
    @ObservedObject var viewModel: RatesViewModel
    @EnvironmentObject var globalSettings: GlobalSettingsManager
    @StateObject private var tariffVM = TariffViewModel()
    @StateObject private var consumptionVM = ConsumptionViewModel()

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
    public init(viewModel: RatesViewModel) {
        self.viewModel = viewModel
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
            let start = startOfDay
            let end = calendar.date(byAdding: .day, value: 1, to: start)!
            return (start: start, end: end)

        case .weekly:
            let weekStart = calendar.date(
                from: calendar.dateComponents([.yearForWeekOfYear, .weekOfYear], from: startOfDay))!
            let weekEnd = calendar.date(byAdding: .weekOfYear, value: 1, to: weekStart)!
            return (start: weekStart, end: weekEnd)

        case .monthly:
            let monthStart = calendar.date(
                from: calendar.dateComponents([.year, .month], from: startOfDay))!
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

    private func navigateDate(forward: Bool) {
        let calendar = Calendar.current
        var newDate: Date?

        switch selectedInterval {
        case .daily:
            newDate = calendar.date(byAdding: .day, value: forward ? 1 : -1, to: currentDate)
        case .weekly:
            newDate = calendar.date(byAdding: .weekOfYear, value: forward ? 1 : -1, to: currentDate)
        case .monthly:
            newDate = calendar.date(byAdding: .month, value: forward ? 1 : -1, to: currentDate)
        }

        if let newDate = newDate,
            let maxDate = maxAllowedDate,
            let minDate = minAllowedDate,
            newDate <= maxDate && newDate >= minDate
        {
            currentDate = newDate
            savePreferences()
            calculateCosts()
        }
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
        formatter.locale = globalSettings.locale

        switch selectedInterval {
        case .daily:
            // For English locale, use UK date format
            if formatter.locale.languageCode == "en" {
                formatter.dateFormat = "d MMM yyyy"  // Direct format for "1 Jul 2024"
            } else {
                formatter.dateStyle = .medium
                formatter.timeStyle = .none
            }
            return formatter.string(from: dateRange.start)

        case .weekly:
            // For English locale, use UK date format
            if formatter.locale.languageCode == "en" {
                formatter.dateFormat = "d MMM yyyy"  // Direct format for "1 Jul 2024"
            } else {
                formatter.dateStyle = .medium
                formatter.timeStyle = .none
            }
            // For weekly, show Monday to Sunday (end - 1 day)
            let displayEnd = Calendar.current.date(byAdding: .day, value: -1, to: dateRange.end)!
            return
                "\(formatter.string(from: dateRange.start)) - \(formatter.string(from: displayEnd))"

        case .monthly:
            // For monthly, show only month and year
            if formatter.locale.languageCode == "en" {
                formatter.dateFormat = "MMMM yyyy"  // Direct format for "July 2024"
            } else {
                formatter.dateStyle = .long
                formatter.timeStyle = .none
            }
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
                            .font(Theme.subFont())
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
                        initiatingView
                    } else {
                        mainContentView
                    }
                case .loading:
                    loadingView
                case .partial:
                    mainContentView
                case .success:
                    mainContentView
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
                await loadConsumptionIfNeeded()
                updateAllowedDateRange()
                calculateCosts()
            }
        }
        .onChange(of: globalSettings.locale) { _, _ in
            refreshTrigger.toggle()
        }
        .onChange(of: consumptionVM.minInterval) { _, _ in
            updateAllowedDateRange()
        }
        .id("account-tariff-\(refreshTrigger)")
        .sheet(isPresented: $showingDetails) {
            NavigationView {
                AccountTariffDetailView(
                    tariffVM: TariffViewModel(),
                    selectedInterval: $selectedInterval,
                    currentDate: $currentDate
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
                .frame(width: 40, alignment: .leading)
                .id("left-nav-\(isAtMinDate)-\(tariffVM.isCalculating)")

                // Center content - flexible width
                VStack(alignment: .center, spacing: 2) {
                    Text(formatDateRange())
                        .font(Theme.secondaryFont())
                        .foregroundColor(Theme.mainTextColor)
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)
                    // Use a fixed height container for the loading indicator
                    ZStack {
                        if tariffVM.isCalculating {
                            ProgressView()
                                .progressViewStyle(CircularProgressViewStyle())
                                .scaleEffect(0.7)
                        }
                    }
                    .frame(height: 16)  // Fixed height for the loading indicator area
                }
                .frame(maxWidth: .infinity)
                .frame(minHeight: 44)  // Fixed minimum height for the entire navigation area
                .padding(.horizontal, 8)

                // Right navigation area - fixed width
                HStack {
                    if !isAtMaxDate && !tariffVM.isCalculating {
                        Button(action: { navigateDate(forward: true) }) {
                            Image(systemName: "chevron.right")
                                .imageScale(.large)
                                .foregroundColor(Theme.mainColor)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.borderless)
                    }
                }
                .frame(width: 40, alignment: .trailing)
                .id("right-nav-\(isAtMaxDate)-\(tariffVM.isCalculating)")
            }
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
    @Binding var selectedInterval: AccountTariffCardView.IntervalType
    @Binding var currentDate: Date
    @EnvironmentObject var globalSettings: GlobalSettingsManager
    @Environment(\.dismiss) var dismiss

    // MARK: - State
    @State private var displayedRatesByDate: [(String, TariffViewModel.TariffCalculation)] = []
    @State private var hasInitiallyLoaded = false
    @State private var loadedDays: [Date] = []
    @State private var refreshTrigger = UUID()
    @State private var forceReRenderToggle = false

    private let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "d MMM yyyy"  // UK format
        return formatter
    }()

    private let monthFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "MMMM yyyy"
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
        guard !hasInitiallyLoaded else { return }

        await MainActor.run {
            hasInitiallyLoaded = true
        }

        let calendar = Calendar.current
        let now = Date()
        let startOfToday = calendar.startOfDay(for: now)

        switch selectedInterval {
        case .daily:
            // Load today and last 30 days in descending order
            var daysToLoad: [Date] = []
            daysToLoad.append(startOfToday)  // Today first
            for dayOffset in 1...30 {  // Then past days
                if let date = calendar.date(byAdding: .day, value: -dayOffset, to: startOfToday) {
                    daysToLoad.append(date)
                }
            }
            await loadDates(daysToLoad, interval: .daily)

        case .weekly:
            // Load current week and last 12 weeks in descending order
            var weeksToLoad: [Date] = []
            // Current week first
            let currentWeekStart = calendar.date(
                from: calendar.dateComponents([.yearForWeekOfYear, .weekOfYear], from: now))!
            weeksToLoad.append(currentWeekStart)

            // Then past weeks
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
            await loadDates(weeksToLoad, interval: .weekly)

        case .monthly:
            // Load current month and last 6 months in descending order
            var monthsToLoad: [Date] = []
            // Current month first
            let currentMonthStart = calendar.date(
                from: calendar.dateComponents([.year, .month], from: now))!
            monthsToLoad.append(currentMonthStart)

            // Then past months
            for monthOffset in 1...6 {
                if let date = calendar.date(byAdding: .month, value: -monthOffset, to: startOfToday)
                {
                    let monthStart = calendar.date(
                        from: calendar.dateComponents([.year, .month], from: date))!
                    monthsToLoad.append(monthStart)
                }
            }
            await loadDates(monthsToLoad, interval: .monthly)
        }
    }

    private func loadDates(_ dates: [Date], interval: AccountTariffCardView.IntervalType) async {
        // Clear existing data when changing intervals
        await MainActor.run {
            displayedRatesByDate = []
            loadedDays = []
        }

        // Load dates sequentially in descending order (they're already sorted)
        for date in dates {
            await loadPeriod(date, interval: interval)
        }

        // No need to sort as data is already in descending order
    }

    private func loadPeriod(_ date: Date, interval: AccountTariffCardView.IntervalType) async {
        let calendar = Calendar.current
        let periodStart = calendar.startOfDay(for: date)

        // Skip if already loaded
        if loadedDays.contains(where: { calendar.isDate($0, inSameDayAs: periodStart) }) {
            return
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
            // Header with title and close button
            HStack {
                Text("Account Tariff Details")
                    .font(Theme.titleFont())
                    .foregroundColor(Theme.mainTextColor)
                Spacer()
                Button {
                    dismiss()
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundColor(Theme.secondaryTextColor)
                        .imageScale(.large)
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
