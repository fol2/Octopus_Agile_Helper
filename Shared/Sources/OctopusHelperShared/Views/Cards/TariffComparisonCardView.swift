import Combine
import CoreData
import SwiftUI

// MARK: - Enums & Support Types

public struct TariffComparisonCardSettings: Codable {
    var selectedPlanCode: String
    var isManualPlan: Bool
    var manualRatePencePerKWh: Double
    var manualStandingChargePencePerDay: Double

    static let `default` = TariffComparisonCardSettings(
        selectedPlanCode: "",
        isManualPlan: false,
        manualRatePencePerKWh: 30.0,
        manualStandingChargePencePerDay: 45.0
    )
}

// Add this extension for UserDefaults persistence
extension TariffComparisonCardSettings {
    fileprivate func saveToUserDefaults() {
        if let encoded = try? JSONEncoder().encode(self) {
            UserDefaults.standard.set(encoded, forKey: "TariffComparisonCardSettings")
            UserDefaults.standard.synchronize()  // Force immediate write
        }
    }
}

public class TariffComparisonCardSettingsManager: ObservableObject {
    private var isBatchUpdating = false
    private var isInitializing = false

    @Published var settings: TariffComparisonCardSettings {
        didSet {
            // Skip saving if we're in a batch update or initializing
            guard !isBatchUpdating && !isInitializing else { return }
            saveSettings()
        }
    }

    // Helper: only write if new JSON actually differs from what's stored.
    private func needsSave(_ newSettings: TariffComparisonCardSettings) -> Bool {
        let encoder = JSONEncoder()
        guard let newData = try? encoder.encode(newSettings) else {
            return true  // if we can't encode, we usually want to attempt saving anyway
        }
        // Compare to what's in user defaults now:
        if let oldData = UserDefaults.standard.data(forKey: userDefaultsKey) {
            // If bytes match, skip
            if oldData.elementsEqual(newData) {
                return false
            }
        }
        return true
    }

    private let userDefaultsKey = "TariffTariffComparisonCardSettings"

    init() {
        isInitializing = true
        if let data = UserDefaults.standard.data(forKey: userDefaultsKey),
            let decoded = try? JSONDecoder().decode(TariffComparisonCardSettings.self, from: data)
        {
            self.settings = decoded
        } else {
            self.settings = .default
        }
        isInitializing = false
    }

    func batchUpdate(_ updates: () -> Void) {
        isBatchUpdating = true
        updates()
        isBatchUpdating = false
        saveSettings()
    }

    private func saveSettings() {
        // Only write out if truly changed from what's in user defaults
        guard needsSave(settings) else {
            print("⚠️ TariffComparisonCardSettingsManager: No real changes, skipping re-save.")
            return
        }
        do {
            let encoded = try JSONEncoder().encode(settings)
            UserDefaults.standard.set(encoded, forKey: userDefaultsKey)
            print("✅ TariffComparisonCardSettingsManager: New settings saved.")
        } catch {
            print("❌ TariffComparisonCardSettingsManager: Failed to encode settings: \(error)")
        }
    }
}

public enum CompareIntervalType: String, CaseIterable {
    case daily = "DAILY"
    case weekly = "WEEKLY"
    case monthly = "MONTHLY"
    case quarterly = "QUARTERLY"

    var displayName: String {
        switch self {
        case .daily: "Daily"
        case .weekly: "Weekly"
        case .monthly: "Monthly"
        case .quarterly: "Quarterly"
        }
    }

    // Bridge to TariffViewModel's interval enum
    var vmInterval: TariffViewModel.IntervalType {
        switch self {
        case .daily: return .daily
        case .weekly: return .weekly
        case .monthly: return .monthly
        case .quarterly: return .quarterly
        }
    }
}

private struct ProductGroup: Identifiable, Hashable {
    let id: UUID
    let displayName: String
    let products: [NSManagedObject]
    let isVariable: Bool
    let isTracker: Bool
    let isGreen: Bool

    init(
        id: UUID = UUID(),
        displayName: String,
        products: [NSManagedObject],
        isVariable: Bool,
        isTracker: Bool,
        isGreen: Bool
    ) {
        self.id = id
        self.displayName = displayName
        self.products = products
        self.isVariable = isVariable
        self.isTracker = isTracker
        self.isGreen = isGreen
    }

    static func == (lhs: ProductGroup, rhs: ProductGroup) -> Bool {
        lhs.id == rhs.id && lhs.displayName == rhs.displayName
    }
    func hash(into hasher: inout Hasher) {
        hasher.combine(id)
        hasher.combine(displayName)
    }

    var availableDates: [Date] {
        products.compactMap { $0.value(forKey: "available_from") as? Date }
            .filter { $0 != Date.distantPast }
            .sorted(by: >)
    }

    func productCode(for date: Date) -> String? {
        products.first { product in
            guard let availableFrom = product.value(forKey: "available_from") as? Date else {
                return false
            }
            return abs(availableFrom.timeIntervalSince(date)) < 1
        }?.value(forKey: "code") as? String
    }

    func formatDate(_ date: Date, locale: Locale) -> String {
        let df = DateFormatter()
        df.locale = locale
        df.setLocalizedDateFormatFromTemplate("yMMMMd")
        return df.string(from: date)
    }
}

// MARK: - Main TariffComparisonCardView

/// Tracks active menus, text fields, and the last user interaction time
private final class CollapseStateManager: ObservableObject {
    @Published var activeMenus = 0
    @Published var activeTextFields = 0
    @Published var lastInteraction = Date()

    /// If either a menu or text field is active, we block auto-collapse
    var shouldBlockCollapse: Bool {
        activeMenus > 0 || activeTextFields > 0
    }

    /// Whenever there's user interaction, update `lastInteraction`
    func userInteracted() {
        lastInteraction = Date()
    }
}

public struct TariffComparisonCardView: View {
    // Dependencies
    @ObservedObject var consumptionVM: ConsumptionViewModel
    @ObservedObject var ratesVM: RatesViewModel
    @ObservedObject var globalSettings: GlobalSettingsManager

    // Two separate TariffViewModels for actual account vs. comparison
    @StateObject private var accountTariffVM = TariffViewModel()
    @StateObject private var compareTariffVM = TariffViewModel()
    @StateObject private var collapseState = CollapseStateManager()

    // Interval & date state
    @State private var selectedInterval: CompareIntervalType = .daily
    @State private var currentDate = Date()

    // Other UI states
    @State private var minAllowedDate: Date?
    @State private var maxAllowedDate: Date?
    @State private var hasDateOverlap = true
    @State private var hasInitiallyLoaded = false  // Track if view has loaded initially
    @State private var overlapStart: Date?
    @State private var overlapEnd: Date?

    // New state variables for partial period tracking
    @State private var actualCalculationPeriod: (start: Date, end: Date)?
    @State private var isPartialPeriod: Bool = false
    @State private var requestedPeriod: (start: Date, end: Date)?

    // Manage compare plan settings
    @StateObject private var compareSettings = TariffComparisonCardSettingsManager()

    // Refresh toggles & scene states
    @State private var refreshTrigger = false
    @ObservedObject private var refreshManager = CardRefreshManager.shared

    // Card flipping
    @State private var isFlipped = false

    // For region-based plan selection
    @State private var availablePlans: [NSManagedObject] = []
    @State private var currentFullTariffCode: String = ""  // Add this state variable

    @State private var cachedAccountResponse: OctopusAccountResponse?
    @State private var showingDetails = false  // Add this state

    @State private var isChangingPlan = false

    // Add new state properties
    @State private var calculationError: String? = nil
    @State private var didAutoAdjustRange: Bool = false

    @State private var hasInitialized = false

    public init(
        consumptionVM: ConsumptionViewModel,
        ratesVM: RatesViewModel,
        globalSettings: GlobalSettingsManager
    ) {
        DebugLogger.debug("🔄 TariffComparisonCardView init started", component: .tariffViewModel)
        self.consumptionVM = consumptionVM
        self.ratesVM = ratesVM
        self.globalSettings = globalSettings
        DebugLogger.debug("🔄 TariffComparisonCardView init completed", component: .tariffViewModel)
    }

    // MARK: - Body
    public var body: some View {
        mainContent
            .sheet(isPresented: $showingDetails) {
                detailsSheetView
            }
            .environment(\.locale, globalSettings.locale)
            .environmentObject(collapseState)  // Provide the collapse state manager
            .onAppear {
                if !hasInitialized {
                    handleOnAppear()
                    hasInitialized = true
                }
            }
            .task {
                handleTask()
            }
            // MARK: - OnChange handlers
            .onChange(of: consumptionVM.minInterval) { _, _ in
                compareSettings.batchUpdate {
                    updateAllowedDateRange()
                }
            }
            .onChange(of: consumptionVM.maxInterval) { _, _ in
                compareSettings.batchUpdate {
                    updateAllowedDateRange()
                }
            }
            .onChange(of: compareSettings.settings.selectedPlanCode) { _ in
                Task {
                    await recalcBothTariffs(partialOverlap: true)
                }
            }
            .onChange(of: compareSettings.settings.manualRatePencePerKWh) { _ in
                if compareSettings.settings.isManualPlan {
                    Task {
                        await recalcBothTariffs(partialOverlap: true)
                    }
                }
            }
            .onChange(of: compareSettings.settings.manualStandingChargePencePerDay) { _ in
                if compareSettings.settings.isManualPlan {
                    Task {
                        await recalcBothTariffs(partialOverlap: true)
                    }
                }
            }
            .onChange(of: compareSettings.settings.isManualPlan) { _ in
                Task {
                    await recalcBothTariffs(partialOverlap: true)
                }
            }
            .onChange(of: consumptionVM.fetchState) { _, newState in
                if case .success = newState {
                    Task {
                        await recalcBothTariffs(partialOverlap: true)
                    }
                }
            }
    }

    // MARK: - Main Content
    private var mainContent: some View {
        VStack(alignment: .leading, spacing: 12) {
            headerSection
                .padding(.bottom, 2)

            Spacer()
                .padding(.vertical, 4)

            if !hasAccountInfo {
                noAccountView
            } else {
                VStack(spacing: 0) {
                    configurationSection

                    Spacer()
                        .padding(.vertical, 8)

                    dateNavigationSection

                    resultsSection
                }
            }
        }
        .rateCardStyle()  // Apply your custom card style
    }

    // MARK: - Header
    private var headerSection: some View {
        HStack {
            if let def = CardRegistry.shared.definition(for: .tariffComparison) {
                Image(systemName: def.iconName)
                    .foregroundColor(Theme.icon)
                Text(LocalizedStringKey(def.displayNameKey))
                    .font(Theme.titleFont())
                    .foregroundColor(Theme.secondaryTextColor)
                Spacer()
                Button(action: {
                    showingDetails = true
                }) {
                    Image(systemName: "info.circle.fill")
                        .foregroundColor(Theme.secondaryTextColor)
                }
                .buttonStyle(.plain)
            }
        }
    }

    // MARK: - Sheet View
    private var detailsSheetView: some View {
        // First, get the selected product
        let selectedProduct = availablePlans.first {
            ($0.value(forKey: "code") as? String) == compareSettings.settings.selectedPlanCode
        }

        // Get standing charges
        let charges = getStandingCharges()

        return TariffComparisonDetailView(
            selectedPlanCode: compareSettings.settings.selectedPlanCode,
            fullTariffCode: currentFullTariffCode,
            isManualPlan: compareSettings.settings.isManualPlan,
            manualRatePencePerKWh: compareSettings.settings.manualRatePencePerKWh,
            manualStandingChargePencePerDay: compareSettings.settings
                .manualStandingChargePencePerDay,
            selectedProduct: selectedProduct,
            globalSettings: globalSettings,
            compareTariffVM: compareTariffVM,
            consumptionVM: consumptionVM,
            ratesVM: ratesVM,
            currentDate: $currentDate,
            selectedInterval: $selectedInterval,
            overlapStart: $overlapStart,
            overlapEnd: $overlapEnd
        )
    }

    // Break out standing-charge logic into a helper function
    private func getStandingCharges() -> (excVAT: Double, incVAT: Double) {
        if compareSettings.settings.isManualPlan {
            return (
                compareSettings.settings.manualStandingChargePencePerDay,
                compareSettings.settings.manualStandingChargePencePerDay
            )
        } else if let currentStandingCharge = ratesVM.currentStandingCharge(
            tariffCode: currentFullTariffCode)
        {
            let excVAT =
                currentStandingCharge.value(forKey: "value_excluding_vat") as? Double ?? 0.0
            let incVAT =
                currentStandingCharge.value(forKey: "value_including_vat") as? Double ?? 0.0
            return (excVAT, incVAT)
        } else {
            return (0.0, 0.0)
        }
    }

    // MARK: - Lifecycle handlers
    private func handleOnAppear() {
        DebugLogger.debug(
            "🔄 TariffComparisonCardView onAppear triggered", component: .tariffViewModel)
        Task {
            guard !hasInitiallyLoaded else {
                DebugLogger.debug(
                    "⏭️ Skipping initialization - already loaded", component: .tariffViewModel)
                return
            }

            DebugLogger.debug("🔄 Starting initial setup", component: .tariffViewModel)
            compareSettings.batchUpdate {
                DebugLogger.debug("🔄 Initializing from settings", component: .tariffViewModel)
                initializeFromSettings()
                updateAllowedDateRange()
            }

            DebugLogger.debug("🔄 Loading comparison plans", component: .tariffViewModel)
            await loadComparisonPlansIfNeeded()

            DebugLogger.debug("🔄 Recalculating tariffs", component: .tariffViewModel)
            await recalcBothTariffs(partialOverlap: true)

            hasInitiallyLoaded = true
            DebugLogger.debug("✅ Initial setup completed", component: .tariffViewModel)
        }
    }

    private func handleTask() {
        guard let data = globalSettings.settings.accountData else { return }
        Task.detached(priority: .userInitiated) {
            let decoded = try? JSONDecoder().decode(OctopusAccountResponse.self, from: data)
            await MainActor.run {
                cachedAccountResponse = decoded
            }
        }
    }

    // MARK: - Configuration Section
    private var configurationSection: some View {
        CollapsibleSection(
            label: {
                if compareSettings.settings.isManualPlan {
                    ManualPlanSummaryView(settings: compareSettings.settings)
                } else if let groupInfo = findSelectedGroup() {
                    PlanSummaryView(group: groupInfo.group, availableDate: groupInfo.date)
                } else {
                    Text("Select Plan")
                        .foregroundColor(Theme.secondaryTextColor)
                }
            },
            content: {
                ComparisonPlanSelectionView(
                    compareSettings: compareSettings,
                    availablePlans: $availablePlans,
                    globalSettings: globalSettings,
                    compareTariffVM: compareTariffVM,
                    currentDate: $currentDate,
                    selectedInterval: $selectedInterval,
                    overlapStart: $overlapStart,
                    overlapEnd: $overlapEnd
                )
            }
        )
        .padding(.top, 8)
        .padding(.horizontal)
    }

    // MARK: - Date Navigation Section
    private var dateNavigationSection: some View {
        ComparisonDateNavView(
            currentDate: $currentDate,
            selectedInterval: $selectedInterval,
            minDate: minAllowedDate,
            maxDate: maxAllowedDate,
            isCalculating: (accountTariffVM.isCalculating || compareTariffVM.isCalculating),
            onDateChanged: { newDate in
                currentDate = newDate
                savePreferences()
                Task { await recalcBothTariffs(partialOverlap: true) }
            },
            globalSettings: globalSettings,
            accountTariffVM: accountTariffVM,
            compareTariffVM: compareTariffVM,
            consumptionVM: consumptionVM
        )
        .padding(.vertical, 4)  // ← Match Account card's 44pt height containers
    }

    // MARK: - Results Section
    private var resultsSection: some View {
        comparisonResultsView
            .padding(.vertical, 8)  // ← Match vertical padding in Account card
    }

    // MARK: - Comparison Results
    private var comparisonResultsView: some View {
        ZStack {
            if consumptionVM.consumptionRecords.isEmpty {
                noConsumptionView
            } else if !compareSettings.settings.isManualPlan
                && compareSettings.settings.selectedPlanCode.isEmpty
            {
                noPlanSelectedView
            } else if selectedInterval == .daily && !hasOverlapInDaily {
                noOverlapView
            } else if !hasDateOverlap {
                noOverlapView
            } else {
                let acctCalc = accountTariffVM.currentCalculation
                let cmpCalc = compareTariffVM.currentCalculation

                // Actual content with opacity
                actualContentView(acctCalc: acctCalc, cmpCalc: cmpCalc)
                    .opacity((acctCalc != nil && cmpCalc != nil) ? 1 : 0)

                // Placeholder with same dimensions
                ComparisonCostPlaceholderView(
                    selectedInterval: selectedInterval,
                    comparePlanLabel: comparePlanLabel,
                    isPartialPeriod: isPartialPeriod,
                    requestedPeriod: requestedPeriod,
                    actualPeriod: actualCalculationPeriod
                )
                .opacity((acctCalc == nil || cmpCalc == nil) ? 1 : 0)
            }
        }
    }

    @ViewBuilder
    private func actualContentView(
        acctCalc: TariffViewModel.TariffCalculation?, cmpCalc: TariffViewModel.TariffCalculation?
    ) -> some View {
        if let acctCalc = acctCalc, let cmpCalc = cmpCalc {
            ComparisonCostSummaryView(
                accountCalculation: acctCalc,
                compareCalculation: cmpCalc,
                calculationError: calculationError,
                didAutoAdjustRange: didAutoAdjustRange,
                showVAT: globalSettings.settings.showRatesWithVAT,
                selectedInterval: $selectedInterval,
                currentDate: $currentDate,
                isCalculating: (accountTariffVM.isCalculating || compareTariffVM.isCalculating),
                comparePlanLabel: comparePlanLabel,
                onIntervalChange: { newInterval in
                    selectedInterval = newInterval
                    if let savedDate = globalSettings.settings.lastViewedComparisonDates[
                        newInterval.rawValue]
                    {
                        currentDate = savedDate
                    }
                    updateAllowedDateRange()
                    savePreferences()
                    Task {
                        await recalcBothTariffs(partialOverlap: true)
                    }
                },
                isPartialPeriod: isPartialPeriod,
                requestedPeriod: requestedPeriod,
                actualPeriod: actualCalculationPeriod
            )
        }
    }

    // MARK: - Helper UI blocks for states
    private var noAccountView: some View {
        VStack(spacing: 8) {
            Image(systemName: "exclamationmark.triangle")
                .foregroundColor(.orange)
                .imageScale(.large)
            Text("No account data available")
                .font(Theme.subFont())
                .foregroundColor(Theme.secondaryTextColor)
            Text("Please configure your Octopus account in settings to compare tariffs")
                .font(Theme.captionFont())
                .foregroundColor(Theme.secondaryTextColor.opacity(0.7))
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 24)
    }

    private var noConsumptionView: some View {
        VStack(spacing: 8) {
            ProgressView().scaleEffect(1.2)
            Text("Waiting for consumption data...")
                .font(Theme.subFont())
                .foregroundColor(Theme.secondaryTextColor)
            Text("This may take a moment to load")
                .font(Theme.captionFont())
                .foregroundColor(Theme.secondaryTextColor.opacity(0.7))
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 24)
    }

    private var noPlanSelectedView: some View {
        VStack(spacing: 16) {
            Image(systemName: "chart.line.uptrend.xyaxis")
                .font(.system(size: 32))
                .foregroundColor(Theme.secondaryTextColor.opacity(0.7))
            VStack(spacing: 8) {
                Text("No comparison plan selected")
                    .font(Theme.mainFont())
                    .foregroundColor(Theme.mainTextColor)
                Text("Tap to select a plan or enter manual rates")
                    .font(Theme.subFont())
                    .foregroundColor(Theme.secondaryTextColor)
                    .multilineTextAlignment(.center)
            }
        }
        .frame(maxWidth: .infinity)
        .frame(minHeight: 120)
        .padding(.vertical, 16)
    }

    private var noOverlapView: some View {
        VStack(spacing: 16) {
            Image(systemName: "calendar.badge.exclamationmark")
                .font(.system(size: 32))
                .foregroundColor(Theme.secondaryTextColor.opacity(0.7))
            VStack(spacing: 8) {
                Text("No Date Overlap")
                    .font(Theme.mainFont())
                    .foregroundColor(Theme.mainTextColor)
                Text("The selected plan is not available for this time period")
                    .font(Theme.subFont())
                    .foregroundColor(Theme.secondaryTextColor)
                    .multilineTextAlignment(.center)
            }
        }
        .frame(maxWidth: .infinity)
        .frame(minHeight: 120)
        .padding(.vertical, 16)
    }

    // MARK: - Logic & Data

    private var hasAccountInfo: Bool {
        let s = globalSettings.settings
        return !s.apiKey.isEmpty && !(s.electricityMPAN ?? "").isEmpty
            && !(s.electricityMeterSerialNumber ?? "").isEmpty
    }

    private var comparePlanLabel: String {
        if compareSettings.settings.isManualPlan { return "Manual Plan" }
        if let product = availablePlans.first(where: {
            ($0.value(forKey: "code") as? String) == compareSettings.settings.selectedPlanCode
        }) {
            return (product.value(forKey: "display_name") as? String)
                ?? (product.value(forKey: "full_name") as? String)
                ?? compareSettings.settings.selectedPlanCode
        }
        return "Select a Plan"
    }

    private func initializeFromSettings() {
        selectedInterval =
            CompareIntervalType(rawValue: globalSettings.settings.selectedComparisonInterval)
            ?? .daily
        currentDate =
            globalSettings.settings.lastViewedComparisonDates[
                globalSettings.settings.selectedComparisonInterval
            ] ?? Date()
    }

    private func savePreferences() {
        // Batch global settings updates
        globalSettings.batchUpdate {
            globalSettings.settings.selectedComparisonInterval = selectedInterval.rawValue
            globalSettings.settings.lastViewedComparisonDates[selectedInterval.rawValue] =
                currentDate
        }
    }

    private func updateAllowedDateRange() {
        // Get consumption min date
        let consumptionMin = consumptionVM.minInterval

        // Get product available from date
        var productMin: Date? = nil
        if !compareSettings.settings.isManualPlan {
            if let (group, date) = findSelectedGroup() {
                productMin = date
            }
        }

        // Use the later of consumption min and product available from
        minAllowedDate = [consumptionMin, productMin].compactMap { $0 }.max()

        // Set max date
        let calendar = Calendar.current
        let today = Date()
        let startOfToday = calendar.startOfDay(for: today)
        let latestDailyDate = calendar.date(byAdding: .day, value: -1, to: startOfToday) ?? today

        switch selectedInterval {
        case .daily:
            // Same logic as AccountTariffCardView: clamp to yesterday if data ends earlier
            let rawMax = consumptionVM.maxInterval ?? .distantFuture
            maxAllowedDate = min(rawMax, latestDailyDate)
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
            let rawMax = consumptionVM.maxInterval ?? .distantFuture
            maxAllowedDate =
                hasPartialWeekData
                ? min(rawMax, consumptionVM.maxInterval ?? .distantFuture)
                : min(rawMax, lastCompleteWeekEnd)
        case .monthly:
            // Find the end of the last complete month
            let lastDayOfPreviousMonth =
                calendar.date(from: calendar.dateComponents([.year, .month], from: today)) ?? today
            let rawMax = consumptionVM.maxInterval ?? .distantFuture
            maxAllowedDate = min(rawMax, lastDayOfPreviousMonth)
        case .quarterly:
            // Find the end of the last complete quarter
            let currentMonth = calendar.component(.month, from: today)
            let currentQuarter = ((currentMonth - 1) / 3)
            let lastQuarterEndMonth = currentQuarter * 3  // 0->0, 1->3, 2->6, 3->9
            var components = calendar.dateComponents([.year], from: today)
            components.month = lastQuarterEndMonth + 1  // Add 1 because we want the first day of next period
            components.day = 1
            let lastQuarterEnd = calendar.date(from: components) ?? today
            let rawMax = consumptionVM.maxInterval ?? .distantFuture
            maxAllowedDate = min(rawMax, lastQuarterEnd)
        }

        // Clamp current date if needed using IntervalBoundary
        if let mn = minAllowedDate {
            let boundary = accountTariffVM.getBoundary(
                for: currentDate,
                intervalType: selectedInterval.vmInterval,
                billingDay: globalSettings.settings.billingDay
            )

            // New logic for handling partial overlap
            if selectedInterval == .weekly {
                // For weekly intervals, if the boundary starts before minAllowedDate
                // but ends after it, we want to clamp to a week starting at minAllowedDate
                if boundary.start < mn && boundary.end > mn {
                    // Find the next week boundary starting from minAllowedDate
                    let weekStart =
                        calendar.date(
                            from: calendar.dateComponents(
                                [.yearForWeekOfYear, .weekOfYear], from: mn)
                        ) ?? mn
                    currentDate = weekStart
                } else if !boundary.overlapsWithData(minDate: mn, maxDate: nil) {
                    currentDate = mn
                }
            } else {
                // Original logic for other intervals
                if !boundary.overlapsWithData(minDate: mn, maxDate: nil) {
                    currentDate = mn
                }
            }
        }

        if let mx = maxAllowedDate {
            let boundary = accountTariffVM.getBoundary(
                for: currentDate,
                intervalType: selectedInterval.vmInterval,
                billingDay: globalSettings.settings.billingDay
            )
            if boundary.isAfterData(maxDate: mx) {
                currentDate = mx
            }
        }
    }

    private func findSelectedGroup() -> (group: ProductGroup, date: Date)? {
        let groups = groupProducts(availablePlans)
        // Find group that has the code
        for g in groups {
            for d in g.availableDates {
                if g.productCode(for: d) == compareSettings.settings.selectedPlanCode {
                    return (g, d)
                }
            }
        }
        return nil
    }

    /// Build array of product groups by displayName
    private func groupProducts(_ products: [NSManagedObject]) -> [ProductGroup] {
        var groupsDict: [String: [NSManagedObject]] = [:]
        for product in products {
            guard let displayName = product.value(forKey: "display_name") as? String else {
                continue
            }
            groupsDict[displayName, default: []].append(product)
        }
        return groupsDict.map { (name, array) in
            let first = array.first!
            let isVar = (first.value(forKey: "is_variable") as? Bool) ?? false
            let isTrk = (first.value(forKey: "is_tracker") as? Bool) ?? false
            let isGrn = (first.value(forKey: "is_green") as? Bool) ?? false
            return ProductGroup(
                displayName: name, products: array, isVariable: isVar, isTracker: isTrk,
                isGreen: isGrn)
        }
        .sorted { $0.displayName < $1.displayName }
    }

    private func loadComparisonPlansIfNeeded() async {
        DebugLogger.debug("🔄 Starting loadComparisonPlansIfNeeded", component: .tariffViewModel)
        do {
            let region = globalSettings.settings.effectiveRegion
            DebugLogger.debug(
                "🔍 Fetching local products for region: \(region)", component: .tariffViewModel)
            var allProducts = try await ProductsRepository.shared.fetchAllLocalProducts()
            if allProducts.isEmpty {
                allProducts = try await ProductsRepository.shared.syncAllProducts()
            }

            // Convert to main thread managed objects
            let mainContext = PersistenceController.shared.container.viewContext
            let objectIDs = allProducts.map { $0.objectID }
            let mainThreadProducts = objectIDs.compactMap {
                mainContext.object(with: $0) as? NSManagedObject
            }

            let filtered = mainThreadProducts.filter { p in
                let brand = (p.value(forKey: "brand") as? String) ?? ""
                let direction = (p.value(forKey: "direction") as? String) ?? ""
                return brand == "OCTOPUS_ENERGY" && direction == "IMPORT"
            }

            var regionProducts: [NSManagedObject] = []
            for product in filtered {
                guard let code = product.value(forKey: "code") as? String else { continue }
                var details = try await ProductDetailRepository.shared.loadLocalProductDetail(
                    code: code)
                if details.isEmpty {
                    details = try await ProductDetailRepository.shared.fetchAndStoreProductDetail(
                        productCode: code)
                }
                let hasMatch = details.contains { $0.value(forKey: "region") as? String == region }
                if hasMatch { regionProducts.append(product) }
            }
            regionProducts.sort {
                let name1 =
                    ($0.value(forKey: "display_name") as? String)
                    ?? ($0.value(forKey: "code") as? String) ?? ""
                let name2 =
                    ($1.value(forKey: "display_name") as? String)
                    ?? ($1.value(forKey: "code") as? String) ?? ""
                return name1 < name2
            }
            availablePlans = regionProducts

            // Add null check before accessing first element
            if !regionProducts.isEmpty,
                !compareSettings.settings.isManualPlan,
                compareSettings.settings.selectedPlanCode.isEmpty
            {
                DebugLogger.debug("🔄 Setting initial plan selection", component: .tariffViewModel)
                if let firstCode = regionProducts[0].value(forKey: "code") as? String {
                    compareSettings.settings.selectedPlanCode = firstCode
                    await recalcBothTariffs(partialOverlap: true, isChangingPlan: true)
                }
            }
            DebugLogger.debug("✅ Loaded \(allProducts.count) products", component: .tariffViewModel)
            DebugLogger.debug(
                "✅ Filtered to \(regionProducts.count) region-specific products",
                component: .tariffViewModel)
        } catch {
            DebugLogger.debug(
                "❌ Error loading comparison plans: \(error.localizedDescription)",
                component: .tariffViewModel)
        }
    }

    // MARK: - Calculation Routines

    private func recalcBothTariffs(
        partialOverlap: Bool = false,
        isChangingPlan: Bool = false
    ) async {
        DebugLogger.debug(
            "🔄 Starting recalcBothTariffs (partialOverlap: \(partialOverlap), isChangingPlan: \(isChangingPlan))",
            component: .tariffViewModel)
        self.isChangingPlan = isChangingPlan  // Set the state when recalculating

        do {
            DebugLogger.debug(
                "🔍 Calculating date range for current date: \(currentDate)",
                component: .tariffViewModel)
            // Calculate the requested date range based on interval type
            let (requestedStart, requestedEnd) = TariffViewModel().calculateDateRange(
                for: currentDate,
                intervalType: selectedInterval.vmInterval,
                billingDay: globalSettings.settings.billingDay
            )
            DebugLogger.debug(
                "📅 Requested period: \(requestedStart) to \(requestedEnd)",
                component: .tariffViewModel)

            // Determine the actual calculation period considering all constraints
            guard
                let (overlapStart, overlapEnd) = await determineOverlapPeriod(
                    requestedStart: requestedStart,
                    requestedEnd: requestedEnd,
                    isChangingPlan: isChangingPlan
                )
            else {
                DebugLogger.debug("⚠️ No valid overlap period found", component: .tariffViewModel)
                hasDateOverlap = false
                await accountTariffVM.resetCalculationState()
                await compareTariffVM.resetCalculationState()
                self.overlapStart = nil  // Reset overlap period
                self.overlapEnd = nil
                return
            }

            DebugLogger.debug(
                "📅 Overlap period determined: \(overlapStart) to \(overlapEnd)",
                component: .tariffViewModel)
            hasDateOverlap = true
            self.overlapStart = overlapStart  // Set overlap period
            self.overlapEnd = overlapEnd

            DebugLogger.debug(
                "🔄 Starting parallel tariff calculations", component: .tariffViewModel)
            async let acctCalc = recalcAccountTariff(start: overlapStart, end: overlapEnd)
            async let cmpCalc = recalcCompareTariff(start: overlapStart, end: overlapEnd)
            _ = await (acctCalc, cmpCalc)
            DebugLogger.debug("✅ Completed both tariff calculations", component: .tariffViewModel)

        } catch let error as TariffCalculationError {
            DebugLogger.debug("❌ TariffCalculationError: \(error)", component: .tariffViewModel)
            switch error {
            case .invalidDateRange:
                if !isChangingPlan {
                    // Retry with isChangingPlan = true
                    calculationError = "Adjusting date range to latest available data..."
                    didAutoAdjustRange = true
                    await recalcBothTariffs(partialOverlap: partialOverlap, isChangingPlan: true)
                } else {
                    // If we're already in changing plan mode, reset state
                    calculationError = "Unable to calculate costs for this date range"
                    hasDateOverlap = false
                    await accountTariffVM.resetCalculationState()
                    await compareTariffVM.resetCalculationState()
                }
            default:
                calculationError = "Error calculating costs"
                hasDateOverlap = false
                await accountTariffVM.resetCalculationState()
                await compareTariffVM.resetCalculationState()
            }
        } catch {
            // Handle other errors
            hasDateOverlap = false
            await accountTariffVM.resetCalculationState()
            await compareTariffVM.resetCalculationState()
        }
    }

    @MainActor
    private func recalcAccountTariff(start: Date, end: Date) async {
        DebugLogger.debug("🔄 Starting account tariff calculation", component: .tariffViewModel)
        if !hasAccountInfo {
            DebugLogger.debug("⚠️ No account info available", component: .tariffViewModel)
            return
        }
        guard !consumptionVM.consumptionRecords.isEmpty else {
            DebugLogger.debug("⚠️ No consumption records available", component: .tariffViewModel)
            return
        }

        guard let accountData = getAccountResponse() else {
            DebugLogger.debug("⚠️ Failed to get account response", component: .tariffViewModel)
            return
        }

        do {
            DebugLogger.debug("🔄 Calculating account costs", component: .tariffViewModel)
            await accountTariffVM.calculateCosts(
                for: currentDate,
                tariffCode: "savedAccount",
                intervalType: selectedInterval.vmInterval,
                accountData: accountData,
                partialStart: start,
                partialEnd: end,
                isChangingPlan: isChangingPlan
            )
            DebugLogger.debug("✅ Account tariff calculation completed", component: .tariffViewModel)
        } catch {
            DebugLogger.debug(
                "❌ Error in recalcAccountTariff: \(error.localizedDescription)",
                component: .tariffViewModel)
        }
    }

    @MainActor
    private func recalcCompareTariff(start: Date, end: Date) async {
        DebugLogger.debug("🔄 Starting comparison tariff calculation", component: .tariffViewModel)

        // Add safety check for empty selection
        guard
            !compareSettings.settings.selectedPlanCode.isEmpty
                || compareSettings.settings.isManualPlan
        else {
            DebugLogger.debug("⚠️ No plan selected - using fallback", component: .tariffViewModel)
            await handleMissingPlanSelection()
            return
        }

        // Minimal patch: ensure coverage for the needed date range
        await ensureRatesCoverage(start: start, end: end)

        guard !consumptionVM.consumptionRecords.isEmpty else {
            DebugLogger.debug("⚠️ No consumption records available", component: .tariffViewModel)
            hasDateOverlap = false
            return
        }

        do {
            if compareSettings.settings.isManualPlan {
                DebugLogger.debug("🔄 Calculating manual plan costs", component: .tariffViewModel)
                let mockAccount = buildMockAccountResponseForManual()
                currentFullTariffCode = "manualPlan"  // Set for manual plan
                await compareTariffVM.calculateCosts(
                    for: currentDate,
                    tariffCode: "manualPlan",
                    intervalType: selectedInterval.vmInterval,
                    accountData: mockAccount,
                    partialStart: start,
                    partialEnd: end
                )
            } else {
                let code = compareSettings.settings.selectedPlanCode
                if code.isEmpty {
                    DebugLogger.debug("⚠️ No plan code selected", component: .tariffViewModel)
                    hasDateOverlap = false
                    await compareTariffVM.calculateCosts(
                        for: currentDate,
                        tariffCode: "",
                        intervalType: selectedInterval.vmInterval
                    )
                    return
                }

                DebugLogger.debug(
                    "🔍 Finding tariff code for product: \(code)", component: .tariffViewModel)
                let region = globalSettings.settings.effectiveRegion
                var tariffCode = try await ProductDetailRepository.shared.findTariffCode(
                    productCode: code, region: region)

                if tariffCode == nil {
                    DebugLogger.debug(
                        "🔄 Fetching product details for: \(code)", component: .tariffViewModel)
                    _ = try await ProductDetailRepository.shared.fetchAndStoreProductDetail(
                        productCode: code)
                    tariffCode = try await ProductDetailRepository.shared.findTariffCode(
                        productCode: code, region: region)
                }

                guard let finalCode = tariffCode else {
                    DebugLogger.debug(
                        "❌ No tariff code found for product: \(code)", component: .tariffViewModel)
                    throw TariffError.productDetailNotFound(code: code, region: region)
                }
                currentFullTariffCode = finalCode  // Store the full tariff code

                DebugLogger.debug(
                    "🔄 Calculating costs for tariff: \(finalCode)", component: .tariffViewModel)
                await compareTariffVM.calculateCosts(
                    for: currentDate,
                    tariffCode: finalCode,
                    intervalType: selectedInterval.vmInterval,
                    partialStart: start,
                    partialEnd: end
                )
            }
            DebugLogger.debug(
                "✅ Comparison tariff calculation completed", component: .tariffViewModel)
        } catch {
            DebugLogger.debug(
                "❌ Error in recalcCompareTariff: \(error.localizedDescription)",
                component: .tariffViewModel)
            hasDateOverlap = false
            currentFullTariffCode = ""
            await compareTariffVM.calculateCosts(
                for: currentDate,
                tariffCode: "",
                intervalType: selectedInterval.vmInterval
            )
        }
    }

    @MainActor
    private func handleMissingPlanSelection() async {
        DebugLogger.debug("🔄 Attempting automatic plan recovery", component: .tariffViewModel)

        // 1. Try to find first available plan
        if let firstPlan = availablePlans.first,
            let code = firstPlan.value(forKey: "code") as? String
        {
            compareSettings.settings.selectedPlanCode = code
            DebugLogger.debug("🔁 Recovered with plan: \(code)", component: .tariffViewModel)
            await recalcBothTariffs(partialOverlap: true, isChangingPlan: true)
            return
        }

        // 2. Fallback to manual mode if no plans available
        compareSettings.settings.isManualPlan = true
        DebugLogger.debug(
            "⚠️ No plans available - falling back to manual mode", component: .tariffViewModel)
        await recalcBothTariffs(partialOverlap: true, isChangingPlan: true)
    }

    private func getAccountResponse() -> OctopusAccountResponse? {
        // Instead of decoding synchronously each time, decode once in background and store in @State
        guard
            let cached = cachedAccountResponse
                ?? decodeAccountDataSynchronouslyIfNeeded()
        else {
            return nil
        }
        return cached
    }

    private func decodeAccountDataSynchronouslyIfNeeded() -> OctopusAccountResponse? {
        // If we absolutely need a fallback decode, do so off the main thread:
        // In practice, you can do what was done in AccountTariffCardView,
        // i.e. decode in .task or .onChange, then store in cachedAccountResponse
        // For minimal diff, we do a quick background decode:
        guard let accountData = globalSettings.settings.accountData else {
            return nil
        }
        let semaphore = DispatchSemaphore(value: 0)
        var result: OctopusAccountResponse? = nil
        DispatchQueue.global(qos: .userInitiated).async {
            let decoded = try? JSONDecoder().decode(OctopusAccountResponse.self, from: accountData)
            result = decoded
            semaphore.signal()
        }
        // Wait briefly so we can return synchronously
        // This is still not ideal, but a "minimal diff" approach:
        _ = semaphore.wait(timeout: .now() + 2.0)
        if let final = result {
            DispatchQueue.main.async {
                self.cachedAccountResponse = final
            }
        }
        return result
    }

    // MARK: - Helper for Overlap

    /// Find overlap between standard start...end and the tariff validity
    private func findOverlapRange(_ start: Date, _ end: Date, _ tariffCode: String) -> (Date, Date)
    {
        // For savedAccount, we use the consumption data range as the validity period
        if tariffCode == "savedAccount" {
            if let minDate = consumptionVM.minInterval,
                let maxDate = consumptionVM.maxInterval
            {
                let range = minDate...maxDate
                let overlap = intersectRanges(start...end, range)
                return overlap
            }
        }
        return (start, end)
    }

    /// Fetch the validity range for a given plan code
    private func fetchPlanValidityRange(_ planCode: String) async -> ClosedRange<Date> {
        // For manual plan, use a wide range
        if compareSettings.settings.isManualPlan {
            let now = Date()
            return now.addingTimeInterval(
                -365 * 24 * 3600)...now.addingTimeInterval(365 * 24 * 3600)
        }

        // For actual plans, only check when the plan became available for signup
        if let product = availablePlans.first(where: {
            ($0.value(forKey: "code") as? String) == planCode
        }) {
            let from = (product.value(forKey: "available_from") as? Date) ?? Date.distantPast
            // Once a customer can join a plan, they can use it indefinitely
            return from...Date.distantFuture
        }

        // Default to a wide range if we can't determine
        let now = Date()
        return now.addingTimeInterval(-365 * 24 * 3600)...now.addingTimeInterval(365 * 24 * 3600)
    }

    /// Find the intersection between two date ranges
    private func intersectRanges(_ r1: ClosedRange<Date>, _ r2: ClosedRange<Date>) -> (Date, Date) {
        let start = max(r1.lowerBound, r2.lowerBound)
        let end = min(r1.upperBound, r2.upperBound)
        return (start, end)
    }

    /// Determine the actual calculation period based on data availability and tariff validity
    private func determineOverlapPeriod(
        requestedStart: Date,
        requestedEnd: Date,
        isChangingPlan: Bool = false
    ) async -> (Date, Date)? {
        // If changing plan, use latest consumption record as base
        if isChangingPlan {
            guard let latestRecord = consumptionVM.maxInterval else {
                return nil
            }

            // Calculate new range based on latest record
            let (newStart, newEnd) = TariffViewModel().calculateDateRange(
                for: latestRecord,
                intervalType: selectedInterval.vmInterval,
                billingDay: globalSettings.settings.billingDay
            )

            return (newStart, newEnd)
        }

        // Get consumption data range
        guard let consumptionStart = consumptionVM.minInterval,
            let consumptionEnd = consumptionVM.maxInterval
        else {
            return nil
        }

        // Get account tariff range
        let accountRange = await fetchAccountValidityRange()

        // Get comparison tariff range
        let compareRange = await fetchPlanValidityRange(compareSettings.settings.selectedPlanCode)

        // Find intersection of all ranges
        let (start1, end1) = intersectRanges(
            requestedStart...requestedEnd, consumptionStart...consumptionEnd)
        let (start2, end2) = intersectRanges(accountRange, compareRange)

        // Create ranges for final intersection
        let range1 = start1...end1
        let range2 = start2...end2
        let (finalStart, finalEnd) = intersectRanges(range1, range2)

        // Check if this is a partial period
        isPartialPeriod = finalStart != requestedStart || finalEnd != requestedEnd

        // Store both the requested and actual periods
        requestedPeriod = (requestedStart, requestedEnd)
        actualCalculationPeriod = (finalStart, finalEnd)

        return (finalStart, finalEnd)
    }

    /// Fetch the validity range for account tariffs
    private func fetchAccountValidityRange() async -> ClosedRange<Date> {
        if let accountData = getAccountResponse(),
            let firstProperty = accountData.properties.first,
            let elecMP = firstProperty.electricity_meter_points?.first,
            let agreements = elecMP.agreements
        {

            let dateFormatter = ISO8601DateFormatter()

            // Find the overall validity range across all agreements
            var minDate = Date.distantFuture
            var maxDate = Date.distantPast

            for agreement in agreements {
                if let fromStr = agreement.valid_from,
                    let from = dateFormatter.date(from: fromStr)
                {
                    minDate = min(minDate, from)
                }

                if let toStr = agreement.valid_to,
                    let to = dateFormatter.date(from: toStr)
                {
                    maxDate = max(maxDate, to)
                }
            }

            if minDate < maxDate {
                return minDate...maxDate
            }
        }

        // Default to a wide range if we can't determine
        let now = Date()
        return now.addingTimeInterval(-365 * 24 * 3600)...now.addingTimeInterval(365 * 24 * 3600)
    }

    private func buildMockAccountResponseForManual() -> OctopusAccountResponse {
        let now = Date()
        let dateFormatter = ISO8601DateFormatter()
        let fromStr = dateFormatter.string(from: now.addingTimeInterval(-3600 * 24 * 365))
        let toStr = dateFormatter.string(from: now.addingTimeInterval(3600 * 24 * 365))
        let manualAgreement = OctopusAgreement(
            tariff_code: "manualPlan", valid_from: fromStr, valid_to: toStr)
        let mp = OctopusElectricityMP(
            mpan: "0000000000000",
            meters: [OctopusElecMeter(serial_number: "manualPlan")],
            agreements: [manualAgreement]
        )
        let prop = OctopusProperty(
            id: 0, electricity_meter_points: [mp], gas_meter_points: nil, address_line_1: nil,
            moved_in_at: nil, postcode: nil)
        return OctopusAccountResponse(number: "manualAccount", properties: [prop])
    }

    // Add helper property to check for daily data overlap
    private var hasOverlapInDaily: Bool {
        guard selectedInterval == .daily else { return true }
        // Check if there's any consumption data for the selected day
        let cal = Calendar.current
        let dayStart = cal.startOfDay(for: currentDate)
        let dayEnd = cal.date(byAdding: .day, value: 1, to: dayStart)!

        return consumptionVM.consumptionRecords.contains { record in
            guard let start = record.value(forKey: "interval_start") as? Date else { return false }
            return start >= dayStart && start < dayEnd
        }
    }
}

// MARK: - Subviews: Date Navigation

private struct ComparisonDateNavView: View {
    @Binding var currentDate: Date
    @Binding var selectedInterval: CompareIntervalType
    let minDate: Date?
    let maxDate: Date?
    let isCalculating: Bool
    let onDateChanged: (Date) -> Void
    @ObservedObject var globalSettings: GlobalSettingsManager
    @ObservedObject var accountTariffVM: TariffViewModel
    @ObservedObject var compareTariffVM: TariffViewModel
    @ObservedObject var consumptionVM: ConsumptionViewModel

    // Add computed properties for boundaries
    private var currentBoundary: TariffViewModel.IntervalBoundary {
        accountTariffVM.getBoundary(
            for: currentDate,
            intervalType: selectedInterval.vmInterval,
            billingDay: globalSettings.settings.billingDay
        )
    }

    private var previousBoundary: TariffViewModel.IntervalBoundary? {
        guard let prevDate = getPreviousDate() else { return nil }
        return accountTariffVM.getBoundary(
            for: prevDate,
            intervalType: selectedInterval.vmInterval,
            billingDay: globalSettings.settings.billingDay
        )
    }

    private var nextBoundary: TariffViewModel.IntervalBoundary? {
        guard let nextDate = getNextDate() else { return nil }
        return accountTariffVM.getBoundary(
            for: nextDate,
            intervalType: selectedInterval.vmInterval,
            billingDay: globalSettings.settings.billingDay
        )
    }

    var body: some View {
        HStack(spacing: 0) {
            // Left
            HStack {
                let canGoBack = canNavigateBackward()
                if canGoBack && !isCalculating {
                    Button {
                        moveDate(forward: false)
                    } label: {
                        Image(systemName: "chevron.left")
                            .imageScale(.large)
                            .foregroundColor(Theme.mainColor)
                            .contentShape(Rectangle())
                    }
                }
            }
            .frame(width: 44)

            Spacer(minLength: 0)

            // Center
            Text(dateRangeText())
                .font(Theme.secondaryFont())
                .foregroundColor(Theme.mainTextColor)

            Spacer(minLength: 0)

            // Right
            HStack(spacing: 0) {
                // Jump to max date button
                let canGoForward = canNavigateForward()
                if let maxDate = maxDate, currentDate < maxDate && !isCalculating && canGoForward {
                    Button {
                        if selectedInterval == .daily {
                            // For daily intervals, find the latest available day from consumption data
                            if let dailySet = buildDailySet(),
                                let latestAvailable = dailySet.max()
                            {
                                currentDate = latestAvailable
                                onDateChanged(latestAvailable)
                            }
                        } else {
                            // For other intervals, use maxDate
                            currentDate = maxDate
                            onDateChanged(maxDate)
                        }
                    } label: {
                        Image(systemName: "chevron.right.to.line")
                            .imageScale(.large)
                            .foregroundColor(Theme.mainColor)
                            .contentShape(Rectangle())
                    }
                    .disabled(isCalculating)
                    .frame(width: 24)
                    .padding(.trailing, 8)
                } else {
                    // Invisible placeholder to maintain layout
                    Color.clear
                        .frame(width: 24)
                        .padding(.trailing, 8)
                }

                // Original navigation button
                if canGoForward && !isCalculating {
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
            .frame(width: 56)  // Fixed width for stable layout
            .contentShape(Rectangle())
        }
        .padding(.top, 4)
    }

    // MARK: - Navigation Logic
    private func canNavigateBackward() -> Bool {
        // Don't allow navigation while calculating
        if isCalculating { return false }

        // For daily intervals, check if previous date exists in consumption data
        if selectedInterval == .daily {
            if let dailySet = buildDailySet() {
                return findPreviousAvailableDay(from: currentDate, in: dailySet) != nil
            }
        }

        // For other intervals, use boundary checking
        guard let prevDate = getPreviousDate() else { return false }

        // Use IntervalBoundary to check if the previous date's interval overlaps with allowed data range
        let prevBoundary = accountTariffVM.getBoundary(
            for: prevDate,
            intervalType: selectedInterval.vmInterval,
            billingDay: globalSettings.settings.billingDay
        )

        // Special handling for weekly to allow partial overlap at start
        if selectedInterval == .weekly {
            return prevBoundary.end > (minDate ?? Date.distantPast)
        } else {
            return prevBoundary.overlapsWithData(minDate: minDate, maxDate: maxDate)
        }
    }

    private func canNavigateForward() -> Bool {
        // Don't allow navigation while calculating
        if isCalculating { return false }

        // For daily intervals, check if next date exists in consumption data
        if selectedInterval == .daily {
            if let dailySet = buildDailySet() {
                return findNextAvailableDay(from: currentDate, in: dailySet) != nil
            }
        }

        // For other intervals, use boundary checking
        guard let nextBoundary = nextBoundary else { return false }
        return !nextBoundary.isAfterData(maxDate: maxDate)
    }

    private func buildDailySet() -> Set<Date>? {
        let minD = minDate ?? Date.distantPast
        let maxD = maxDate ?? Date.distantFuture
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

    private func findPreviousAvailableDay(from date: Date, in dailySet: Set<Date>) -> Date? {
        let calendar = Calendar.current
        let startOfCurrentDay = calendar.startOfDay(for: date)

        // Filter valid dates (before current day and within bounds)
        let validDates = dailySet.filter { date in
            let startOfDate = calendar.startOfDay(for: date)

            // Must be before current day
            guard startOfDate < startOfCurrentDay else { return false }

            // Check bounds
            if let minDate = minDate {
                let startOfMin = calendar.startOfDay(for: minDate)
                if startOfDate < startOfMin { return false }
            }

            return true
        }

        // Return the most recent valid date
        return validDates.max()
    }

    private func findNextAvailableDay(from date: Date, in dailySet: Set<Date>) -> Date? {
        let calendar = Calendar.current
        let startOfCurrentDay = calendar.startOfDay(for: date)

        // Filter valid dates (after current day and within bounds)
        let validDates = dailySet.filter { date in
            let startOfDate = calendar.startOfDay(for: date)

            // Must be after current day
            guard startOfDate > startOfCurrentDay else { return false }

            // Check bounds
            if let maxDate = maxDate {
                let startOfMax = calendar.startOfDay(for: maxDate)
                if startOfDate > startOfMax { return false }
            }

            return true
        }

        // Return the earliest valid date
        return validDates.min()
    }

    private func getPreviousDate() -> Date? {
        let calendar = Calendar.current

        switch selectedInterval {
        case .daily:
            if let dailySet = buildDailySet() {
                return findPreviousAvailableDay(from: currentDate, in: dailySet)
            }
            return calendar.date(byAdding: .day, value: -1, to: currentDate)

        case .weekly:
            guard let mn = minDate else { return nil }
            let prevDate = calendar.date(byAdding: .weekOfYear, value: -1, to: currentDate)
            guard let date = prevDate else { return nil }

            // Get boundary for the previous week
            let boundary = accountTariffVM.getBoundary(
                for: date,
                intervalType: selectedInterval.vmInterval,
                billingDay: globalSettings.settings.billingDay
            )

            // Match the logic in canNavigateBackward to allow partial overlap at start
            return boundary.end > mn ? date : nil

        case .monthly:
            let prevDate = calendar.date(byAdding: .month, value: -1, to: currentDate)
            guard let date = prevDate else { return nil }
            // Validate using boundary
            let boundary = accountTariffVM.getBoundary(
                for: date,
                intervalType: selectedInterval.vmInterval,
                billingDay: globalSettings.settings.billingDay
            )
            return boundary.overlapsWithData(minDate: minDate, maxDate: maxDate) ? date : nil

        case .quarterly:
            let prevDate = calendar.date(byAdding: .month, value: -3, to: currentDate)
            guard let date = prevDate else { return nil }
            // Validate using boundary
            let boundary = accountTariffVM.getBoundary(
                for: date,
                intervalType: selectedInterval.vmInterval,
                billingDay: globalSettings.settings.billingDay
            )
            return boundary.overlapsWithData(minDate: minDate, maxDate: maxDate) ? date : nil
        }
    }

    private func getNextDate() -> Date? {
        let calendar = Calendar.current

        switch selectedInterval {
        case .daily:
            if let dailySet = buildDailySet() {
                return findNextAvailableDay(from: currentDate, in: dailySet)
            }
            return calendar.date(byAdding: .day, value: 1, to: currentDate)

        case .weekly:
            let nextDate = calendar.date(byAdding: .weekOfYear, value: 1, to: currentDate)
            guard let date = nextDate else { return nil }
            // Validate using boundary
            let boundary = accountTariffVM.getBoundary(
                for: date,
                intervalType: selectedInterval.vmInterval,
                billingDay: globalSettings.settings.billingDay
            )
            return !boundary.isAfterData(maxDate: maxDate) ? date : nil

        case .monthly:
            let nextDate = calendar.date(byAdding: .month, value: 1, to: currentDate)
            guard let date = nextDate else { return nil }
            // Validate using boundary
            let boundary = accountTariffVM.getBoundary(
                for: date,
                intervalType: selectedInterval.vmInterval,
                billingDay: globalSettings.settings.billingDay
            )
            return !boundary.isAfterData(maxDate: maxDate) ? date : nil

        case .quarterly:
            let nextDate = calendar.date(byAdding: .month, value: 3, to: currentDate)
            guard let date = nextDate else { return nil }
            // Validate using boundary
            let boundary = accountTariffVM.getBoundary(
                for: date,
                intervalType: selectedInterval.vmInterval,
                billingDay: globalSettings.settings.billingDay
            )
            return !boundary.isAfterData(maxDate: maxDate) ? date : nil
        }
    }

    private func moveDate(forward: Bool) {
        if let newDate = forward ? getNextDate() : getPreviousDate() {
            onDateChanged(newDate)
        }
    }

    private func dateRangeText() -> String {
        // 1. Grab start/end from your view model
        let (start, end) = accountTariffVM.calculateDateRange(
            for: currentDate,
            intervalType: selectedInterval.vmInterval,
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

        case .weekly, .monthly, .quarterly:
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

// MARK: - Subviews: Plan Selection

private struct ComparisonPlanSelectionView: View {
    @ObservedObject var compareSettings: TariffComparisonCardSettingsManager
    @Binding var availablePlans: [NSManagedObject]
    @ObservedObject var globalSettings: GlobalSettingsManager
    @ObservedObject var compareTariffVM: TariffViewModel
    @Binding var currentDate: Date
    @Binding var selectedInterval: CompareIntervalType
    @Binding var overlapStart: Date?
    @Binding var overlapEnd: Date?

    var body: some View {
        VStack(spacing: 12) {
            Picker("Mode", selection: $compareSettings.settings.isManualPlan) {
                Text("Octopus Plan").tag(false)
                Text("manualPlan").tag(true)
            }
            .pickerStyle(.segmented)

            if compareSettings.settings.isManualPlan {
                ManualInputView(
                    settings: $compareSettings.settings,
                    compareTariffVM: compareTariffVM,
                    currentDate: $currentDate,
                    selectedInterval: $selectedInterval,
                    overlapStart: $overlapStart,
                    overlapEnd: $overlapEnd
                )
            } else {
                PlanSelectionView(
                    groups: groupProducts(availablePlans),
                    selectedPlanCode: $compareSettings.settings.selectedPlanCode,
                    region: globalSettings.settings.effectiveRegion
                )
            }
        }
        .padding(.vertical, 4)
    }

    private func groupProducts(_ products: [NSManagedObject]) -> [ProductGroup] {
        var groupsDict: [String: [NSManagedObject]] = [:]
        for product in products {
            guard let displayName = product.value(forKey: "display_name") as? String else {
                continue
            }
            groupsDict[displayName, default: []].append(product)
        }
        return groupsDict.map { (name, array) in
            let first = array.first!
            let isVar = (first.value(forKey: "is_variable") as? Bool) ?? false
            let isTrk = (first.value(forKey: "is_tracker") as? Bool) ?? false
            let isGrn = (first.value(forKey: "is_green") as? Bool) ?? false
            return ProductGroup(
                displayName: name, products: array, isVariable: isVar, isTracker: isTrk,
                isGreen: isGrn)
        }
        .sorted { $0.displayName < $1.displayName }
    }
}

// MARK: - Subviews: Comparison Results

private struct ComparisonCostSummaryView: View {
    @EnvironmentObject var globalSettings: GlobalSettingsManager
    let accountCalculation: TariffViewModel.TariffCalculation
    let compareCalculation: TariffViewModel.TariffCalculation
    let calculationError: String?
    let didAutoAdjustRange: Bool
    let showVAT: Bool
    @Binding var selectedInterval: CompareIntervalType
    @Binding var currentDate: Date
    let isCalculating: Bool
    let comparePlanLabel: String
    let onIntervalChange: (CompareIntervalType) -> Void

    // Add new properties for partial period info
    let isPartialPeriod: Bool
    let requestedPeriod: (start: Date, end: Date)?
    let actualPeriod: (start: Date, end: Date)?

    var body: some View {
        VStack(spacing: 0) {
            if let error = calculationError {
                Text(error)
                    .foregroundColor(.red)
                    .font(.caption)
            }
            if didAutoAdjustRange {
                Text("Date range adjusted to latest available data")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            // Show partial period info if applicable
            // Always reserve consistent space to avoid layout shifting
            HStack {
                if isPartialPeriod, let requested = requestedPeriod, let actual = actualPeriod {
                    Image(systemName: "info.circle")
                        .foregroundColor(Theme.secondaryTextColor)
                    Text(
                        "Available data: \(formatDateRange(actual.start, Calendar.current.date(byAdding: .day, value: -1, to: actual.end) ?? actual.end))"
                    )
                    .font(Theme.captionFont())
                    .foregroundColor(Theme.secondaryTextColor)
                }
            }
            .frame(height: 20)  // Explicit height matching the content

            HStack(alignment: .top, spacing: 16) {
                // Left difference & cost block
                VStack(alignment: .leading, spacing: 8) {
                    let accountCost =
                        showVAT ? accountCalculation.costIncVAT : accountCalculation.costExcVAT
                    let compareCost =
                        showVAT ? compareCalculation.costIncVAT : compareCalculation.costExcVAT
                    let diff = compareCost - accountCost
                    let diffStr = String(format: "£%.2f", abs(diff) / 100.0)
                    let sign = diff > 0 ? "+" : (diff < 0 ? "−" : "")
                    let diffColor: Color =
                        diff > 0 ? .red : (diff < 0 ? .green : Theme.secondaryTextColor)

                    // Diff row
                    HStack(alignment: .firstTextBaseline) {
                        if isCalculating {
                            ProgressView().scaleEffect(0.8)
                        } else {
                            Text("\(sign)\(diffStr)")
                                .font(Theme.mainFont())
                                .foregroundColor(diffColor)
                        }
                        Text("diff.")
                            .font(Theme.subFont())
                            .foregroundColor(Theme.secondaryTextColor)
                    }

                    Spacer()

                    // My account vs compare
                    VStack(alignment: .leading, spacing: 8) {
                        costRow(
                            label: "My Account",
                            cost: accountCost,
                            calculation: accountCalculation,
                            averageRate: averageRate(for: accountCalculation)
                        )
                        costRow(
                            label: comparePlanLabel,
                            cost: compareCost,
                            calculation: compareCalculation,
                            averageRate: averageRate(for: compareCalculation)
                        )
                    }
                }
                Spacer()
                // Right side interval switcher
                VStack(spacing: 6) {
                    ForEach(CompareIntervalType.allCases, id: \.self) { interval in
                        Button {
                            withAnimation { onIntervalChange(interval) }
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
                                            ? Theme.mainColor.opacity(0.2) : .clear)
                            )
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.vertical, 6)
            }
            .padding(.vertical, 2)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func formatDateRange(_ start: Date, _ end: Date) -> String {
        let df = DateFormatter()
        df.locale = globalSettings.locale
        // Let the system figure out the best localised pattern:
        df.setLocalizedDateFormatFromTemplate("yMMMd")
        // e.g. "May 12, 2024" in English, "2024年5月12日" in Chinese
        return "\(df.string(from: start)) - \(df.string(from: end))"
    }

    private func costRow(
        label: String, cost: Double, calculation: TariffViewModel.TariffCalculation,
        averageRate: String?
    ) -> some View {
        HStack(spacing: 8) {
            // Use specific icons for different types
            if label.lowercased().contains("my account") {
                Image(systemName: "person.crop.circle")
                    .foregroundColor(Theme.icon)
                    .imageScale(.small)
            } else {
                // For selected plan
                Image(systemName: "shippingbox.fill")
                    .foregroundColor(Theme.icon)
                    .imageScale(.small)
            }

            VStack(alignment: .leading, spacing: 2) {
                HStack {
                    Text("\(label):")
                        .font(Theme.subFont())
                        .foregroundColor(Theme.secondaryTextColor)
                    Text("£\(String(format: "%.2f", cost / 100.0))")
                        .font(Theme.subFont())
                        .foregroundColor(Theme.mainTextColor)
                }
                let standingCharge =
                    showVAT ? calculation.standingChargeIncVAT : calculation.standingChargeExcVAT
                Text("£\(String(format: "%.2f", standingCharge / 100.0)) standing charge")
                    .font(Theme.captionFont())
                    .foregroundColor(Theme.secondaryTextColor)
                if let avg = averageRate {
                    Text("Avg: \(avg)p/kWh")
                        .font(Theme.captionFont())
                        .foregroundColor(Theme.secondaryTextColor)
                }
            }
        }
    }

    private func iconName(for interval: CompareIntervalType) -> String {
        switch interval {
        case .daily: return "calendar.day.timeline.left"
        case .weekly: return "calendar.badge.clock"
        case .monthly: return "calendar"
        case .quarterly: return "calendar.badge.plus"
        }
    }

    private func averageRate(for calc: TariffViewModel.TariffCalculation) -> String? {
        let totalKWh = calc.totalKWh
        guard totalKWh > 0 else { return nil }

        // Use the pre-calculated average rate that excludes standing charge
        let avgRate = showVAT ? calc.averageUnitRateIncVAT : calc.averageUnitRateExcVAT
        return String(format: "%.2f", avgRate)
    }
}

// Add the placeholder view after ComparisonCostSummaryView
private struct ComparisonCostPlaceholderView: View {
    @EnvironmentObject var globalSettings: GlobalSettingsManager
    let selectedInterval: CompareIntervalType
    let comparePlanLabel: String
    let isPartialPeriod: Bool
    let requestedPeriod: (start: Date, end: Date)?
    let actualPeriod: (start: Date, end: Date)?

    init(
        selectedInterval: CompareIntervalType,
        comparePlanLabel: String,
        isPartialPeriod: Bool = false,
        requestedPeriod: (start: Date, end: Date)? = nil,
        actualPeriod: (start: Date, end: Date)? = nil
    ) {
        self.selectedInterval = selectedInterval
        self.comparePlanLabel = comparePlanLabel
        self.isPartialPeriod = isPartialPeriod
        self.requestedPeriod = requestedPeriod
        self.actualPeriod = actualPeriod
    }

    private func formatDateRange(_ start: Date, _ end: Date) -> String {
        let df = DateFormatter()
        df.locale = globalSettings.locale
        df.setLocalizedDateFormatFromTemplate("yMMMd")
        return "\(df.string(from: start)) - \(df.string(from: end))"
    }

    var body: some View {
        VStack(spacing: 0) {  // Changed to match actual view's spacing
            // Partial period info with same layout as actual view
            HStack {
                if isPartialPeriod, let actual = actualPeriod {
                    Image(systemName: "info.circle")
                        .foregroundColor(Theme.secondaryTextColor.opacity(0.5))
                    Text(
                        "Available data: \(formatDateRange(actual.start, Calendar.current.date(byAdding: .day, value: -1, to: actual.end) ?? actual.end))"
                    )
                    .font(Theme.captionFont())
                    .foregroundColor(Theme.secondaryTextColor.opacity(0.5))
                }
            }
            .frame(height: 20)  // Match exact height of actual view

            HStack(alignment: .top, spacing: 16) {
                // Rest of the view remains similar but with consistent spacing
                VStack(alignment: .leading, spacing: 8) {
                    // Diff row
                    HStack(alignment: .firstTextBaseline) {
                        RoundedRectangle(cornerRadius: 4)
                            .fill(Theme.secondaryTextColor.opacity(0.2))
                            .frame(width: 80, height: 36)
                        Text("diff.")
                            .font(Theme.subFont())
                            .foregroundColor(Theme.secondaryTextColor)
                    }

                    Spacer()  // Match spacing distribution

                    // Cost rows placeholder
                    VStack(alignment: .leading, spacing: 8) {
                        // My Account row
                        HStack(spacing: 8) {
                            Image(systemName: "person.crop.circle")
                                .foregroundColor(Theme.icon.opacity(0.5))
                                .imageScale(.small)
                            VStack(alignment: .leading, spacing: 2) {
                                HStack {
                                    Text("My Account:")
                                        .font(Theme.subFont())
                                        .foregroundColor(Theme.secondaryTextColor.opacity(0.5))
                                    RoundedRectangle(cornerRadius: 4)
                                        .fill(Theme.secondaryTextColor.opacity(0.2))
                                        .frame(width: 60, height: 16)
                                }
                                Text("£0.00 standing charge")
                                    .font(Theme.captionFont())
                                    .foregroundColor(Theme.secondaryTextColor.opacity(0.5))
                                RoundedRectangle(cornerRadius: 4)
                                    .fill(Theme.secondaryTextColor.opacity(0.2))
                                    .frame(width: 80, height: 14)
                            }
                        }

                        // Compare plan row
                        HStack(spacing: 8) {
                            Image(systemName: "shippingbox.fill")
                                .foregroundColor(Theme.icon.opacity(0.5))
                                .imageScale(.small)
                            VStack(alignment: .leading, spacing: 2) {
                                HStack {
                                    Text("\(comparePlanLabel):")
                                        .font(Theme.subFont())
                                        .foregroundColor(Theme.secondaryTextColor.opacity(0.5))
                                    RoundedRectangle(cornerRadius: 4)
                                        .fill(Theme.secondaryTextColor.opacity(0.2))
                                        .frame(width: 60, height: 16)
                                }
                                Text("£0.00 standing charge")
                                    .font(Theme.captionFont())
                                    .foregroundColor(Theme.secondaryTextColor.opacity(0.5))
                                RoundedRectangle(cornerRadius: 4)
                                    .fill(Theme.secondaryTextColor.opacity(0.2))
                                    .frame(width: 80, height: 14)
                            }
                        }
                    }
                }
                Spacer()

                // Right side interval switcher (keep the same as actual view)
                VStack(spacing: 6) {
                    ForEach(CompareIntervalType.allCases, id: \.self) { interval in
                        HStack {
                            Image(systemName: iconName(for: interval))
                                .imageScale(.small)
                                .frame(alignment: .leading)
                            Spacer()
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
                        .frame(width: 100, alignment: .leading)
                        .padding(.horizontal, 8)
                        .background(
                            RoundedRectangle(cornerRadius: 6)
                                .fill(
                                    selectedInterval == interval
                                        ? Theme.mainColor.opacity(0.2) : .clear)
                        )
                    }
                }
                .padding(.vertical, 6)
            }
            .padding(.vertical, 2)  // Match actual view's padding
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    // Helper function to create consistent cost row placeholders
    private func costRowPlaceholder(label: String, icon: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: icon)
                .foregroundColor(Theme.icon.opacity(0.5))
            VStack(alignment: .leading, spacing: 2) {
                HStack {
                    Text(label)
                        .font(Theme.subFont())
                        .foregroundColor(Theme.secondaryTextColor.opacity(0.5))
                    RoundedRectangle(cornerRadius: 4)
                        .fill(Theme.secondaryTextColor.opacity(0.2))
                        .frame(width: 60, height: 16)
                }
                Text("£0.00 standing charge")
                    .font(Theme.captionFont())
                    .foregroundColor(Theme.secondaryTextColor.opacity(0.5))
                RoundedRectangle(cornerRadius: 4)
                    .fill(Theme.secondaryTextColor.opacity(0.2))
                    .frame(width: 80, height: 14)
            }
        }
    }

    private func iconName(for interval: CompareIntervalType) -> String {
        switch interval {
        case .daily: return "calendar.day.timeline.left"
        case .weekly: return "calendar.badge.clock"
        case .monthly: return "calendar"
        case .quarterly: return "calendar.badge.plus"
        }
    }
}

// MARK: - Additional Sub-views

private struct ManualPlanDetailView: View {
    @EnvironmentObject var globalSettings: GlobalSettingsManager
    let settings: TariffComparisonCardSettings

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(
                forcedLocalizedString(
                    key: "Manual Plan Configuration",
                    locale: globalSettings.locale
                )
            )
            .font(Theme.mainFont2())
            .foregroundColor(Theme.mainTextColor)
            VStack(alignment: .leading, spacing: 8) {
                Text(
                    forcedLocalizedString(
                        key:
                            "Energy Rate: \(String(format: "%.2f", settings.manualRatePencePerKWh))p/kWh",
                        locale: globalSettings.locale
                    )
                )
                Text(
                    forcedLocalizedString(
                        key:
                            "Daily Standing Charge: \(String(format: "%.2f", settings.manualStandingChargePencePerDay))p/day",
                        locale: globalSettings.locale
                    )
                )
            }
            .font(Theme.subFont())
            .foregroundColor(Theme.secondaryTextColor)
            Text(
                forcedLocalizedString(
                    key: "A fixed-rate plan where the same rate applies to all hours.",
                    locale: globalSettings.locale
                )
            )
            .font(Theme.captionFont())
            .foregroundColor(Theme.secondaryTextColor)
            .padding(.top, 8)
        }
    }
}

private struct ManualPlanSummaryView: View {
    @EnvironmentObject var globalSettings: GlobalSettingsManager
    let settings: TariffComparisonCardSettings

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 4) {
                Text(
                    forcedLocalizedString(
                        key: "Manual Plan",
                        locale: globalSettings.locale
                    )
                )
                .foregroundColor(Theme.mainTextColor)
                BadgeView(
                    forcedLocalizedString(
                        key: "Fixed Rate",
                        locale: globalSettings.locale
                    ),
                    color: .purple
                )
            }
            Text(
                forcedLocalizedString(
                    key:
                        "\(String(format: "%.1f", settings.manualRatePencePerKWh))p/kWh + \(String(format: "%.1f", settings.manualStandingChargePencePerDay))p/day",
                    locale: globalSettings.locale
                )
            )
            .font(Theme.captionFont())
            .foregroundColor(Theme.secondaryTextColor)
        }
    }
}

private struct PlanSummaryView: View {
    @EnvironmentObject var globalSettings: GlobalSettingsManager

    let group: ProductGroup
    let availableDate: Date

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 4) {
                Text(group.displayName)
                    .foregroundColor(Theme.mainTextColor)
                if group.isVariable { BadgeView("Variable", color: .orange) }
                if group.isTracker { BadgeView("Tracker", color: .blue) }
                if group.isGreen { BadgeView("Green", color: .green) }
            }
            Text(
                "Available from: \(group.formatDate(availableDate, locale: globalSettings.locale))"
            )
            .font(Theme.captionFont())
            .foregroundColor(Theme.secondaryTextColor)
        }
    }
}

// Reuse the PlanSelectionView, PlanDetailView, etc. from existing code:

private struct PlanSelectionView: View {
    @EnvironmentObject var globalSettings: GlobalSettingsManager
    let groups: [ProductGroup]
    @Binding var selectedPlanCode: String
    let region: String

    // Add default selection state
    @State private var hasSetDefault = false

    var body: some View {
        VStack(spacing: 12) {
            Menu {
                ForEach(groups) { group in
                    Button {
                        if let date = group.availableDates.first,
                            let code = group.productCode(for: date)
                        {
                            selectedPlanCode = code
                        }
                    } label: {
                        HStack {
                            Text(group.displayName)
                            if group.isVariable { BadgeView("Variable", color: .orange) }
                            if group.isTracker { BadgeView("Tracker", color: .blue) }
                            if group.isGreen { BadgeView("Green", color: .green) }
                            Spacer()
                            if isCurrentlySelected(group) {
                                Image(systemName: "checkmark")
                            }
                        }
                        .padding(.vertical, 8)  // Increased padding for menu items
                    }
                }
            } label: {
                HStack {
                    if let active = groups.first(where: isCurrentlySelected) {
                        HStack(spacing: 4) {
                            Text(active.displayName)
                            if active.isVariable { BadgeView("Variable", color: .orange) }
                            if active.isTracker { BadgeView("Tracker", color: .blue) }
                            if active.isGreen { BadgeView("Green", color: .green) }
                        }
                        .foregroundColor(Theme.mainTextColor)
                    } else {
                        // Force select first available if none selected
                        Text(forcedDefaultSelection())
                            .foregroundColor(Theme.mainTextColor)
                    }
                    Spacer()
                    Image(systemName: "chevron.down")
                        .foregroundColor(Theme.secondaryTextColor)
                }
                .padding(.vertical, 12)  // Increased vertical padding for menu button
                .background(Theme.mainBackground.opacity(0.3))
                .cornerRadius(8)
            }
            .menuTracker()  // Track menu state

            // Version selection menu (if applicable)
            if let group = groups.first(where: { isCurrentlySelected($0) }) {
                if let date = group.availableDates.first(where: {
                    group.productCode(for: $0) == selectedPlanCode
                }) {
                    if group.availableDates.count > 1 {
                        Menu {
                            ForEach(group.availableDates, id: \.self) { date in
                                if let code = group.productCode(for: date) {
                                    Button {
                                        selectedPlanCode = code
                                    } label: {
                                        HStack {
                                            Text(
                                                group.formatDate(
                                                    date, locale: globalSettings.locale))
                                            Spacer()
                                            if selectedPlanCode == code {
                                                Image(systemName: "checkmark")
                                            }
                                        }
                                        .padding(.vertical, 8)  // Increased padding for menu items
                                    }
                                }
                            }
                        } label: {
                            HStack {
                                Text(
                                    "Available from: \(group.formatDate(date, locale: globalSettings.locale))"
                                )
                                Spacer()
                                Image(systemName: "chevron.down")
                            }
                            .padding(.vertical, 12)  // Increased vertical padding for menu button
                            .background(Theme.mainBackground.opacity(0.3))
                            .cornerRadius(8)
                        }
                        .menuTracker()  // Track menu state
                    } else {
                        // Single date case
                        HStack {
                            Text(
                                "Available from: \(group.formatDate(date, locale: globalSettings.locale))"
                            )
                            Spacer()
                        }
                        .padding(.vertical, 12)  // Increased vertical padding for single date display
                        .background(Theme.mainBackground.opacity(0.3))
                        .cornerRadius(8)
                    }
                }
            }
        }
        .padding(.vertical, 4)  // Added overall vertical padding to match ManualInputView
        .onAppear { enforceDefaultSelection() }
        .onChange(of: groups) { _ in enforceDefaultSelection() }
    }

    private func isCurrentlySelected(_ group: ProductGroup) -> Bool {
        group.availableDates.contains { date in
            group.productCode(for: date) == selectedPlanCode
        }
    }

    private func forcedDefaultSelection() -> String {
        guard let firstGroup = groups.first,
            let firstDate = firstGroup.availableDates.first,
            let code = firstGroup.productCode(for: firstDate)
        else {
            return "Select Plan"
        }
        return firstGroup.displayName
    }

    private func enforceDefaultSelection() {
        guard !hasSetDefault,
            selectedPlanCode.isEmpty,
            !groups.isEmpty,
            let firstGroup = groups.first,
            let firstDate = firstGroup.availableDates.first,
            let code = firstGroup.productCode(for: firstDate)
        else { return }

        DebugLogger.debug("🔄 Enforcing default plan selection: \(code)", component: .ui)
        selectedPlanCode = code
        hasSetDefault = true
    }
}

private struct ManualInputView: View {
    @Binding var settings: TariffComparisonCardSettings
    @ObservedObject var compareTariffVM: TariffViewModel
    @Binding var currentDate: Date
    @Binding var selectedInterval: CompareIntervalType
    @Binding var overlapStart: Date?
    @Binding var overlapEnd: Date?
    @EnvironmentObject var globalSettings: GlobalSettingsManager

    private let VAT_RATE = 0.05  // 5% VAT for electricity

    private func buildMockAccountResponseForManual() -> OctopusAccountResponse {
        let now = Date()
        let dateFormatter = ISO8601DateFormatter()
        let fromStr = dateFormatter.string(from: now.addingTimeInterval(-3600 * 24 * 365))
        let toStr = dateFormatter.string(from: now.addingTimeInterval(3600 * 24 * 365))
        let manualAgreement = OctopusAgreement(
            tariff_code: "manualPlan", valid_from: fromStr, valid_to: toStr)
        let mp = OctopusElectricityMP(
            mpan: "0000000000000",
            meters: [OctopusElecMeter(serial_number: "manualPlan")],
            agreements: [manualAgreement]
        )
        let prop = OctopusProperty(
            id: 0, electricity_meter_points: [mp], gas_meter_points: nil, address_line_1: nil,
            moved_in_at: nil, postcode: nil)
        return OctopusAccountResponse(number: "manualAccount", properties: [prop])
    }

    private func convertRateForVATChange(rate: Double, toIncludeVAT: Bool) -> Double {
        if toIncludeVAT {
            return rate * (1 + VAT_RATE)
        } else {
            return rate / (1 + VAT_RATE)
        }
    }

    private func recalculateWithNewRates() {
        Task {

            settings.saveToUserDefaults()

            // Add debug logging
            DebugLogger.debug("🔄 Starting manual rate recalculation", component: .tariffViewModel)

            // First reset to clear old data
            await compareTariffVM.resetCalculationState()

            // Build mock account with consistent tariff code
            let mockAccount = buildMockAccountResponseForManual()

            // Then recalculate with new rates
            await compareTariffVM.calculateCosts(
                for: currentDate,
                tariffCode: "manualPlan",  // Use consistent tariff code
                intervalType: selectedInterval.vmInterval,
                accountData: mockAccount,
                partialStart: overlapStart,
                partialEnd: overlapEnd
            )

            DebugLogger.debug("✅ Manual rate recalculation completed", component: .tariffViewModel)
        }
    }

    var body: some View {
        VStack(spacing: 12) {
            HStack {
                Text(
                    globalSettings.settings.showRatesWithVAT
                        ? "Energy Rate (inc. VAT)" : "Energy Rate (exc. VAT)"
                )
                .foregroundColor(Theme.secondaryTextColor)
                Spacer()
                NumberTextField(
                    placeholder: "p/kWh",
                    value: Binding(
                        get: { settings.manualRatePencePerKWh },
                        set: { settings.manualRatePencePerKWh = $0 }
                    ),
                    onCommit: recalculateWithNewRates
                )
                .frame(width: 80)
                .textFieldTracker()
                Text("p/kWh")
                    .foregroundColor(Theme.secondaryTextColor)
                    .font(Theme.captionFont())
            }

            HStack {
                Text(
                    globalSettings.settings.showRatesWithVAT
                        ? "Daily Charge (inc. VAT)" : "Daily Charge (exc. VAT)"
                )
                .foregroundColor(Theme.secondaryTextColor)
                Spacer()
                NumberTextField(
                    placeholder: "p/day",
                    value: Binding(
                        get: { settings.manualStandingChargePencePerDay },
                        set: { settings.manualStandingChargePencePerDay = $0 }
                    ),
                    onCommit: recalculateWithNewRates
                )
                .frame(width: 80)
                .textFieldTracker()
                Text("p/day")
                    .foregroundColor(Theme.secondaryTextColor)
                    .font(Theme.captionFont())
            }
        }
        .onChange(of: globalSettings.settings.showRatesWithVAT) { _, newValue in
            // Convert rates when VAT setting changes
            settings.manualRatePencePerKWh = convertRateForVATChange(
                rate: settings.manualRatePencePerKWh,
                toIncludeVAT: newValue
            )
            settings.manualStandingChargePencePerDay = convertRateForVATChange(
                rate: settings.manualStandingChargePencePerDay,
                toIncludeVAT: newValue
            )
            recalculateWithNewRates()
        }
    }
}

// Custom TextField with Done button
private struct NumberTextField: UIViewRepresentable {
    let placeholder: String
    @Binding var value: Double
    var onCommit: (() -> Void)?

    // Add the missing updateUIView method
    func updateUIView(_ uiView: UITextField, context: Context) {
        // Only update if the value has changed significantly to avoid formatting during typing
        if let currentText = uiView.text, let currentValue = Double(currentText) {
            if abs(currentValue - value) > 0.001 {  // Small threshold to avoid floating point comparison issues
                uiView.text = String(format: "%.2f", value)
            }
        } else {
            uiView.text = String(format: "%.2f", value)
        }
    }

    func makeUIView(context: Context) -> UITextField {
        let textField = UITextField()
        textField.placeholder = placeholder
        textField.keyboardType = .decimalPad
        textField.textAlignment = .right
        textField.borderStyle = .roundedRect
        textField.delegate = context.coordinator

        // Create toolbar
        let toolbar = UIToolbar()
        toolbar.sizeToFit()
        let flexSpace = UIBarButtonItem(
            barButtonSystemItem: .flexibleSpace, target: nil, action: nil)
        let doneButton = UIBarButtonItem(
            title: "Done", style: .done, target: context.coordinator,
            action: #selector(Coordinator.doneButtonTapped))
        toolbar.items = [flexSpace, doneButton]
        textField.inputAccessoryView = toolbar

        // Set initial value
        textField.text = String(format: "%.2f", value)

        return textField
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    class Coordinator: NSObject, UITextFieldDelegate {
        var parent: NumberTextField
        weak var activeTextField: UITextField?

        init(_ textField: NumberTextField) {
            self.parent = textField
        }

        @objc func doneButtonTapped() {
            if let textField = activeTextField,
                let text = textField.text,
                let value = Double(text)
            {
                // Format with two decimal places when done
                let formattedValue = Double(String(format: "%.2f", value)) ?? value
                DispatchQueue.main.async {
                    self.parent.value = formattedValue
                    textField.text = String(format: "%.2f", formattedValue)
                    self.parent.onCommit?()  // Call commit handler after value is set
                }
            }
            UIApplication.shared.sendAction(
                #selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
        }

        func textFieldDidBeginEditing(_ textField: UITextField) {
            activeTextField = textField
        }

        func textFieldDidEndEditing(_ textField: UITextField) {
            if let text = textField.text,
                let value = Double(text)
            {
                // Format with two decimal places when ending
                let formattedValue = Double(String(format: "%.2f", value)) ?? value
                DispatchQueue.main.async {
                    self.parent.value = formattedValue
                    textField.text = String(format: "%.2f", formattedValue)
                    self.parent.onCommit?()  // Call commit handler after value is set
                }
            }
            activeTextField = nil
        }

        // Keep existing validation methods
        func textField(
            _ textField: UITextField, shouldChangeCharactersIn range: NSRange,
            replacementString string: String
        ) -> Bool {
            // Existing validation code...
            return true
        }
    }
}

public struct BadgeView: View {
    let text: String
    let color: Color
    init(_ text: String, color: Color) {
        self.text = text
        self.color = color
    }
    public var body: some View {
        Text(text)
            .font(.system(size: 10, weight: .medium))
            .foregroundColor(color.opacity(1.2))
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(color.opacity(0.3))
            .clipShape(Capsule())

    }
}

/// Tracks when a SwiftUI `Menu` appears / disappears.
private struct MenuTracker: ViewModifier {
    @EnvironmentObject private var collapseState: CollapseStateManager

    func body(content: Content) -> some View {
        content
            .onAppear {
                collapseState.activeMenus += 1
                collapseState.userInteracted()
            }
            .onDisappear {
                collapseState.activeMenus -= 1
                collapseState.userInteracted()
            }
    }
}

/// Convenience extension so we can do `.menuTracker()`
extension View {
    fileprivate func menuTracker() -> some View {
        self.modifier(MenuTracker())
    }
}

/// Tracks when a UIKit text field (wrapped in SwiftUI) begins/ends editing.
private struct TextFieldTracker: ViewModifier {
    @EnvironmentObject private var collapseState: CollapseStateManager

    func body(content: Content) -> some View {
        content
            .onReceive(
                NotificationCenter.default.publisher(
                    for: UITextField.textDidBeginEditingNotification)
            ) { _ in
                collapseState.activeTextFields += 1
                collapseState.userInteracted()
            }
            .onReceive(
                NotificationCenter.default.publisher(for: UITextField.textDidEndEditingNotification)
            ) { _ in
                collapseState.activeTextFields -= 1
                collapseState.userInteracted()
            }
    }
}

/// Convenience extension so we can do `.textFieldTracker()`
extension View {
    fileprivate func textFieldTracker() -> some View {
        self.modifier(TextFieldTracker())
    }
}

// The CollapsibleSection used in frontView
private struct CollapsibleSection<Label: View, Content: View>: View {
    @EnvironmentObject private var collapseState: CollapseStateManager
    private let label: () -> Label
    private let content: () -> Content
    @State private var isExpanded = false
    @State private var autoCollapseTask: Task<Void, Never>?

    init(
        @ViewBuilder label: @escaping () -> Label,
        @ViewBuilder content: @escaping () -> Content
    ) {
        self.label = label
        self.content = content
    }

    private func startAutoCollapseTimer() {
        // Cancel any existing timer
        autoCollapseTask?.cancel()

        autoCollapseTask = Task {
            while !Task.isCancelled {
                let now = Date()
                let elapsed = now.timeIntervalSince(collapseState.lastInteraction)
                let block = collapseState.shouldBlockCollapse
                let shouldCollapse = (elapsed >= 5.0 && !block)

                if shouldCollapse {
                    await MainActor.run {
                        withAnimation(.spring(duration: 0.3)) {
                            isExpanded = false
                        }
                    }
                    break
                }

                // Sleep half a second between checks
                try? await Task.sleep(nanoseconds: 500_000_000)
            }
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            Button {
                collapseState.userInteracted()
                withAnimation(.spring(duration: 0.3)) {
                    isExpanded.toggle()
                }
                if isExpanded {
                    startAutoCollapseTimer()
                } else {
                    autoCollapseTask?.cancel()
                }
            } label: {
                HStack {
                    if !isExpanded {
                        label()
                    } else {
                        Text("Configuration")
                            .foregroundColor(Theme.mainTextColor)
                    }
                    Spacer()
                    Image(systemName: "chevron.down")
                        .foregroundColor(Theme.secondaryTextColor)
                        .rotationEffect(.degrees(isExpanded ? 180 : 0))
                }
                .background(Theme.mainBackground.opacity(0.3))
                .cornerRadius(8)
            }
            .buttonStyle(.plain)

            if isExpanded {
                content()
                    .padding(.vertical, 8)
                    .transition(.move(edge: .top).combined(with: .opacity))
                    .onTapGesture {
                        collapseState.userInteracted()
                        startAutoCollapseTimer()
                    }
            }
        }
        .onDisappear {
            autoCollapseTask?.cancel()
        }
    }
}

// MARK: - Product Detail View
private struct ProductDetailView: View {
    let product: NSManagedObject
    @EnvironmentObject var globalSettings: GlobalSettingsManager
    @State private var loadError: Error?
    @State private var isLoading = true
    @State private var tariffCode: String?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                basicInfo
                badges
                availability
                productMeta
                if let error = loadError {
                    Text("Error: \(error.localizedDescription)")
                        .foregroundColor(.red)
                }
            }
        }
        .onAppear { Task { await loadTariffCode() } }
    }

    private var basicInfo: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let displayName = product.value(forKey: "display_name") as? String {
                Text(displayName)
                    .font(Theme.mainFont2())
                    .foregroundColor(Theme.mainTextColor)
            } else {
                Text("Product Name Not Available")
                    .font(Theme.mainFont2())
                    .foregroundColor(Theme.secondaryTextColor)
            }
            if let fullName = product.value(forKey: "full_name") as? String {
                Text(fullName)
                    .font(Theme.subFont())
                    .foregroundColor(Theme.secondaryTextColor)
            }
            if let desc = product.value(forKey: "desc") as? String {
                Text(desc)
                    .font(Theme.subFont())
                    .foregroundColor(Theme.secondaryTextColor)
                    .padding(.top, 4)
            }
        }
    }

    private var badges: some View {
        HStack(spacing: 8) {
            if (product.value(forKey: "is_green") as? Bool) == true {
                BadgeView("Green Energy", color: .green)
            }
            if (product.value(forKey: "is_tracker") as? Bool) == true {
                BadgeView("Tracker", color: .blue)
            }
            if (product.value(forKey: "is_variable") as? Bool) == true {
                BadgeView("Variable", color: .orange)
            }
            if (product.value(forKey: "is_prepay") as? Bool) == true {
                BadgeView("Prepay", color: .purple)
            }
        }
    }

    private var availability: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Signup Window")
                .font(Theme.subFont())
                .foregroundColor(Theme.secondaryTextColor)
            if let availableFrom = product.value(forKey: "available_from") as? Date,
                availableFrom != Date.distantPast
            {
                Text("Sign up available from: \(formatDate(availableFrom))")
                    .font(Theme.captionFont())
                    .foregroundColor(Theme.secondaryTextColor)
            }
            if let availableTo = product.value(forKey: "available_to") as? Date,
                availableTo != Date.distantFuture
            {
                Text("Last day to sign up: \(formatDate(availableTo))")
                    .font(Theme.captionFont())
                    .foregroundColor(Theme.secondaryTextColor)
            }
        }
        .padding(.top, 8)
    }

    private var productMeta: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let term = product.value(forKey: "term") as? Int {
                Text("Contract Term: \(term) months")
                    .font(Theme.captionFont())
                    .foregroundColor(Theme.secondaryTextColor)
            }
            if let brand = product.value(forKey: "brand") as? String {
                Text("Brand: \(brand)")
                    .font(Theme.captionFont())
                    .foregroundColor(Theme.secondaryTextColor)
            }
            if isLoading {
                ProgressView()
            } else if let code = tariffCode {
                Text("Tariff Code: \(code)")
                    .font(Theme.captionFont())
                    .foregroundColor(Theme.secondaryTextColor)
            }
        }
        .padding(.top, 8)
    }

    private func formatDate(_ date: Date) -> String {
        let df = DateFormatter()
        df.locale = globalSettings.locale
        // Let the system figure out the best localised pattern:
        df.setLocalizedDateFormatFromTemplate("yMMMMd")
        // e.g. "May 12, 2024" in English, "2024年5月12日" in Chinese
        return df.string(from: date)
    }

    private func loadTariffCode() async {
        isLoading = true
        do {
            if let code = product.value(forKey: "code") as? String {
                let region = globalSettings.settings.effectiveRegion
                let tariffCode = try await ProductDetailRepository.shared.findTariffCode(
                    productCode: code, region: region)
                await MainActor.run {
                    self.tariffCode = tariffCode
                    self.isLoading = false
                }
            }
        } catch {
            await MainActor.run {
                self.loadError = error
                self.isLoading = false
            }
        }
    }
}

enum TariffError: LocalizedError, CustomDebugStringConvertible {
    case productDetailNotFound(code: String, region: String)
    case apiError(underlying: Error)
    case calculationError(underlying: Error)

    var errorDescription: String? {
        switch self {
        case .productDetailNotFound(let c, let r):
            return "Could not find tariff details for product \(c) in region \(r)"
        case .apiError: return "Failed to fetch product details from Octopus API"
        case .calculationError: return "Failed to calculate tariff costs"
        }
    }

    var debugDescription: String {
        switch self {
        case .productDetailNotFound(let c, let r):
            return "Product: \(c), Region: \(r)"
        case .apiError(let e):
            return "API Error: \(e.localizedDescription)"
        case .calculationError(let e):
            return "Calculation Error: \(e.localizedDescription)"
        }
    }
}
extension TariffComparisonCardView {

    /// Ensures that the local rates fully cover the requested [start ... end] interval.
    /// If coverage is missing, forces an immediate refresh from the API.
    fileprivate func ensureRatesCoverage(start: Date, end: Date) async {
        guard !currentFullTariffCode.isEmpty else {
            DebugLogger.debug(
                "⏭️ Skipping rate coverage check - empty tariff code", component: .tariffViewModel)
            return
        }

        // Add validation for date ordering
        let (validStart, validEnd) = start <= end ? (start, end) : (end, start)
        if start > end {
            DebugLogger.debug(
                "⚠️ Date range reversed: \(start) > \(end). Using clamped range",
                component: .tariffViewModel)
        }

        // 1. Get the stored coverage range
        let coverage = ratesVM.coverageInterval(for: currentFullTariffCode)

        // 2. Build the user-requested range with validated dates
        let requestedInterval = validStart...validEnd

        // 3. Compare coverage boundaries with requested boundaries
        let coversLowerBound = coverage.lowerBound <= requestedInterval.lowerBound
        let coversUpperBound = coverage.upperBound >= requestedInterval.upperBound
        let fullyCovered = coversLowerBound && coversUpperBound

        // 4. If not fully covered => force fetch
        if !fullyCovered {
            print(
                """
                ⚠️ ensureRatesCoverage: coverage is [\(coverage.lowerBound) ... \(coverage.upperBound)], \
                but requested [\(requestedInterval.lowerBound) ... \(requestedInterval.upperBound)] => Fetching now...
                """)

            await ratesVM.refreshRates(productCode: currentFullTariffCode, force: true)
        }
    }
}

extension Bundle {
    static func forcedBundle(for locale: Locale) -> Bundle {
        // Attempt language+script? or just language?
        let code = locale.identifier
        guard
            let path = Bundle.main.path(forResource: code, ofType: "lproj"),
            let b = Bundle(path: path)
        else {
            return .main
        }
        return b
    }
}

func forcedLocalizedString(key: String, locale: Locale) -> String {
    let bundle = Bundle.forcedBundle(for: locale)
    // If you want tableName, pass it in; here we just use nil
    return NSLocalizedString(key, tableName: nil, bundle: bundle, value: key, comment: "")
}
