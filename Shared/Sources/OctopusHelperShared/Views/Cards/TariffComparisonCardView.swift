//
//  TariffComparisonCardView.swift
//  Octopus_Agile_Helper
//
//  Purpose:
//    Compare the user's actual tariff costs (from their Octopus account)
//    with an alternative plan that the user selects (or a manual input).
//
//  Features:
//    - Daily/Weekly/Monthly intervals with date navigation
//    - front side: shows "Account cost" vs. "Comparison plan cost" + difference
//    - back side: allows user to select an existing Octopus plan in their region or a "Manual plan"
//      that has a single rate (p/kWh) + daily standing charge (p/day).
//    - local state stored in UserDefaults
//

import CoreData
import SwiftUI

/// A struct in UserDefaults to hold the user's chosen compare plan code (if any),
/// and whether we're using manual plan mode, plus manual input rates.
private struct ComparisonCardSettings: Codable {
    var selectedPlanCode: String
    var isManualPlan: Bool
    var manualRatePencePerKWh: Double
    var manualStandingChargePencePerDay: Double

    static let `default` = ComparisonCardSettings(
        selectedPlanCode: "",
        isManualPlan: false,
        manualRatePencePerKWh: 30.0,
        manualStandingChargePencePerDay: 45.0
    )
}

private class ComparisonCardSettingsManager: ObservableObject {
    private let userDefaultsKey = "TariffComparisonCardSettings"
    @Published var settings: ComparisonCardSettings {
        didSet { saveSettings() }
    }

    init() {
        if let data = UserDefaults.standard.data(forKey: userDefaultsKey),
            let decoded = try? JSONDecoder().decode(ComparisonCardSettings.self, from: data)
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

/// Like in AccountTariffCardView, we define an interval approach
private enum CompareIntervalType: String, CaseIterable {
    case daily = "DAILY"
    case weekly = "WEEKLY"
    case monthly = "MONTHLY"
    case quarterly = "QUARTERLY"

    var displayName: String { rawValue.capitalized }

    // We map to TariffViewModel.IntervalType for actual cost calculation
    var vmInterval: TariffViewModel.IntervalType {
        switch self {
        case .daily: return .daily
        case .weekly: return .weekly
        case .monthly: return .monthly
        case .quarterly: return .quarterly
        }
    }
}

/// Groups products by their base name/plan and available dates
private struct ProductGroup: Identifiable, Hashable {
    let id: UUID
    let displayName: String  // e.g. "Agile", "Go"
    let products: [NSManagedObject]  // All products in this group
    let isVariable: Bool
    let isTracker: Bool
    let isGreen: Bool

    init(
        id: UUID = UUID(), displayName: String, products: [NSManagedObject], isVariable: Bool,
        isTracker: Bool, isGreen: Bool
    ) {
        self.id = id
        self.displayName = displayName
        self.products = products
        self.isVariable = isVariable
        self.isTracker = isTracker
        self.isGreen = isGreen
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(id)
        hasher.combine(displayName)
    }

    static func == (lhs: ProductGroup, rhs: ProductGroup) -> Bool {
        lhs.id == rhs.id && lhs.displayName == rhs.displayName
    }

    /// Get available dates for this group, sorted newest to oldest
    var availableDates: [Date] {
        products.compactMap { product in
            product.value(forKey: "available_from") as? Date
        }
        .filter { $0 != Date.distantPast }
        .sorted(by: >)
    }

    /// Find product code for a specific available_from date
    func productCode(for date: Date) -> String? {
        products.first { product in
            guard let availableFrom = product.value(forKey: "available_from") as? Date else {
                return false
            }
            return abs(availableFrom.timeIntervalSince(date)) < 1  // Within 1 second
        }?.value(forKey: "code") as? String
    }

    /// Format available date for display
    func formatDate(_ date: Date) -> String {
        let df = DateFormatter()
        df.dateStyle = .medium
        return df.string(from: date)
    }
}

// Add state for grouped selection
@MainActor
private class GroupedSelectionState: ObservableObject {
    @Published var selectedGroupName: String = ""
    @Published var selectedDate: Date?

    func reset() {
        selectedGroupName = ""
        selectedDate = nil
    }
}

/// The main card view
public struct TariffComparisonCardView: View {
    // Dependencies
    @ObservedObject var consumptionVM: ConsumptionViewModel
    @ObservedObject var ratesVM: RatesViewModel
    @ObservedObject var globalSettings: GlobalSettingsManager

    // We create two TariffViewModels:
    // 1) For the user's actual account data
    @StateObject private var accountTariffVM = TariffViewModel()
    // 2) For the compare plan
    @StateObject private var compareTariffVM = TariffViewModel()

    // Compare interval & date, just like AccountTariffCardView
    @State private var selectedInterval: CompareIntervalType = .daily
    @State private var currentDate = Date()

    // Replace flip with sheet presentation
    @State private var showingSettingsSheet = false

    // Additional UI states
    @State private var minAllowedDate: Date?
    @State private var maxAllowedDate: Date?

    @State private var productMinDate: Date?  // product.available_from
    @State private var productMaxDate: Date?  // product.available_to
    @State private var hasDateOverlap: Bool = true  // Track overlap status

    // Settings manager for selected plan & manual plan input
    @StateObject private var compareSettings = ComparisonCardSettingsManager()

    // A small refresh toggle
    @State private var refreshTrigger = false

    // For region-based plan selection, we need to store:
    @State private var availablePlans: [NSManagedObject] = []
    // we load them from ProductEntity + ProductDetailEntity

    // Use the shared manager for refresh timing
    @ObservedObject private var refreshManager = CardRefreshManager.shared

    @State private var isFlipped = false  // New state for flip animation

    public init(
        consumptionVM: ConsumptionViewModel,
        ratesVM: RatesViewModel,
        globalSettings: GlobalSettingsManager
    ) {
        self.consumptionVM = consumptionVM
        self.ratesVM = ratesVM
        self.globalSettings = globalSettings
    }

    // MARK: - Body
    public var body: some View {
        Group {
            if isFlipped {
                backView
            } else {
                frontView
            }
        }
        .rateCardStyle()
        .rotation3DEffect(
            .degrees(isFlipped ? 180 : 0),
            axis: (x: 0, y: 1, z: 0)
        )
        .animation(.spring(duration: 0.6), value: isFlipped)
        .environment(\.locale, globalSettings.locale)
        .id("tariff-compare-card-\(refreshTrigger)")
        .onChange(of: globalSettings.locale) { _, _ in
            refreshTrigger.toggle()
        }
        // Re-render on half-hour
        .onReceive(refreshManager.$halfHourTick) { tickTime in
            guard tickTime != nil else { return }
            refreshTrigger.toggle()
        }
        // Also re-render if app becomes active
        .onReceive(refreshManager.$sceneActiveTick) { _ in
            refreshTrigger.toggle()
        }
        .onAppear {
            Task {
                DebugLogger.debug(
                    """
                    🔄 TariffComparisonCardView appeared:
                    - Has account info: \(hasAccountInfo)
                    - Consumption state: \(consumptionVM.fetchState)
                    - Records count: \(consumptionVM.consumptionRecords.count)
                    - Available plans: \(availablePlans.count)
                    - Manual mode: \(compareSettings.settings.isManualPlan)
                    - Selected plan: \(compareSettings.settings.selectedPlanCode)
                    """, component: .tariffViewModel)

                updateAllowedDateRange()
                await loadComparisonPlansIfNeeded()

                // do initial calculations
                await recalcAccountTariff()
                await recalcCompareTariff()
            }
        }
        .onChange(of: consumptionVM.minInterval) { _, _ in
            updateAllowedDateRange()
        }
        .onChange(of: consumptionVM.maxInterval) { _, _ in
            updateAllowedDateRange()
        }
        .onChange(of: compareSettings.settings.selectedPlanCode) { _ in
            // If user picks a new plan, re-check product's available_from/available_to
            loadProductAvailability()
            updateAllowedDateRange()
            Task { await recalcCompareTariff() }
        }
        .onChange(of: consumptionVM.fetchState) { oldState, newState in
            DebugLogger.debug(
                """
                🔄 Consumption state changed:
                - From: \(oldState)
                - To: \(newState)
                - Records count: \(consumptionVM.consumptionRecords.count)
                """, component: .tariffViewModel)
        }
    }

    private var frontView: some View {
        VStack(spacing: 0) {
            // Header with flip button
            HStack {
                if let def = CardRegistry.shared.definition(for: .tariffComparison) {
                    HStack {
                        Image(systemName: def.iconName)
                            .foregroundColor(Theme.icon)
                        Text(LocalizedStringKey(def.displayNameKey))
                            .font(Theme.titleFont())
                            .foregroundColor(Theme.secondaryTextColor)
                    }
                }

                Spacer()

                if hasAccountInfo {
                    if compareTariffVM.isCalculating || accountTariffVM.isCalculating {
                        ProgressView()
                            .scaleEffect(0.8)
                    } else {
                        Button {
                            withAnimation {
                                isFlipped.toggle()
                            }
                        } label: {
                            Image(systemName: "info.circle.fill")
                                .foregroundColor(Theme.secondaryTextColor)
                        }
                    }
                }
            }

            if !hasAccountInfo {
                // Show placeholder when no account info
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
                        .padding(.horizontal)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 24)
            } else {
                // Configuration Section - Collapsible
                CollapsibleSection(
                    label: {
                        Group {
                            if compareSettings.settings.isManualPlan {
                                ManualPlanSummaryView(settings: compareSettings.settings)
                            } else if let selectedGroup = groupProducts(availablePlans).first(
                                where: {
                                    group in
                                    group.availableDates.contains { date in
                                        group.productCode(for: date)
                                            == compareSettings.settings.selectedPlanCode
                                    }
                                }),
                                let selectedDate = selectedGroup.availableDates.first(where: {
                                    date in
                                    selectedGroup.productCode(for: date)
                                        == compareSettings.settings.selectedPlanCode
                                })
                            {
                                PlanSummaryView(group: selectedGroup, availableDate: selectedDate)
                            } else {
                                Text("Select Plan")
                                    .foregroundColor(Theme.secondaryTextColor)
                            }
                        }
                    }
                ) {
                    VStack(spacing: 12) {
                        // Manual/Plan Toggle
                        Picker("Mode", selection: $compareSettings.settings.isManualPlan) {
                            Text("Octopus Plan").tag(false)
                            Text("Manual Plan").tag(true)
                        }
                        .pickerStyle(.segmented)
                        .padding(.horizontal)

                        if compareSettings.settings.isManualPlan {
                            ManualInputView(settings: $compareSettings.settings)
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
                .padding(.horizontal)

                Divider()
                    .padding(.horizontal)
                    .padding(.vertical, 2)

                // Interval navigation (moved after plan selection)
                intervalNavigationView

                Divider()
                    .padding(.horizontal)
                    .padding(.vertical, 2)

                // Comparison Results (moved to bottom)
                comparisonView
            }
        }
    }

    private var backView: some View {
        VStack(spacing: 0) {
            // Back header
            HStack {
                Text("Plan Details")
                    .font(Theme.titleFont())
                    .foregroundColor(Theme.secondaryTextColor)
                Spacer()
                Button {
                    withAnimation {
                        isFlipped.toggle()
                    }
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundColor(Theme.secondaryTextColor)
                }
            }

            if compareSettings.settings.isManualPlan {
                ManualPlanDetailView(settings: compareSettings.settings)
            } else if let selectedProduct = availablePlans.first(where: {
                $0.value(forKey: "code") as? String == compareSettings.settings.selectedPlanCode
            }) {
                ProductDetailView(product: selectedProduct)
            } else {
                VStack(spacing: 16) {
                    Image(systemName: "chart.line.uptrend.xyaxis")
                        .font(.system(size: 40))
                        .foregroundColor(Theme.secondaryTextColor.opacity(0.7))
                    Text("Select a plan to view details")
                        .font(Theme.subFont())
                        .foregroundColor(Theme.secondaryTextColor)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .rotation3DEffect(.degrees(180), axis: (x: 0, y: 1, z: 0))
    }

    // MARK: - Settings Sheet
    private var settingsSheet: some View {
        NavigationStack {
            Form {
                Section {
                    Toggle("Use Manual Plan", isOn: $compareSettings.settings.isManualPlan)
                        .toggleStyle(.switch)
                        .tint(Theme.mainColor)
                        .onChange(of: compareSettings.settings.isManualPlan) { _ in
                            if compareSettings.settings.isManualPlan {
                                // Clear selectedPlanCode if any
                                compareSettings.settings.selectedPlanCode = ""
                                Task {
                                    await recalcCompareTariff()
                                }
                            } else {
                                // If we have a leftover code, use it, else do nothing
                                if compareSettings.settings.selectedPlanCode.isEmpty,
                                    !availablePlans.isEmpty
                                {
                                    // auto pick the first plan
                                    let firstPlan = availablePlans[0]
                                    if let code = firstPlan.value(forKey: "code") as? String {
                                        compareSettings.settings.selectedPlanCode = code
                                        Task {
                                            await recalcCompareTariff()
                                        }
                                    }
                                } else {
                                    Task {
                                        await recalcCompareTariff()
                                    }
                                }
                            }
                        }
                } header: {
                    Text("Comparison Mode")
                } footer: {
                    Text("Manual plans use a fixed rate for all hours")
                }

                if compareSettings.settings.isManualPlan {
                    Section("Manual Rates") {
                        HStack {
                            Text("Energy Rate")
                            TextField(
                                "p/kWh",
                                value: $compareSettings.settings.manualRatePencePerKWh,
                                format: .number
                            )
                            .keyboardType(.decimalPad)
                            .multilineTextAlignment(.trailing)
                            .foregroundColor(Theme.mainTextColor)
                        }

                        HStack {
                            Text("Daily Charge")
                            TextField(
                                "p/day",
                                value: $compareSettings.settings.manualStandingChargePencePerDay,
                                format: .number
                            )
                            .keyboardType(.decimalPad)
                            .multilineTextAlignment(.trailing)
                            .foregroundColor(Theme.mainTextColor)
                        }
                    }
                } else {
                    Section("Available Plans") {
                        if availablePlans.isEmpty {
                            Text("No plans found for your region")
                                .foregroundColor(Theme.secondaryTextColor)
                        } else {
                            PlanSelectionListView(
                                groups: groupProducts(availablePlans),
                                selectedPlanCode: $compareSettings.settings.selectedPlanCode,
                                region: globalSettings.settings.effectiveRegion
                            )
                        }
                    }
                }
            }
            .navigationTitle("Comparison Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") {
                        showingSettingsSheet = false
                    }
                }
            }
            .environment(\.locale, globalSettings.locale)
        }
    }

    // MARK: - Loading View
    private var loadingView: some View {
        VStack(spacing: 8) {
            ProgressView()
                .scaleEffect(1.2)
            Text("Loading comparison data...")
                .font(Theme.subFont())
                .foregroundColor(Theme.secondaryTextColor)
            Text("This may take a moment")
                .font(Theme.captionFont())
                .foregroundColor(Theme.secondaryTextColor.opacity(0.7))
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 24)
    }

    private var errorView: some View {
        VStack(spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundColor(.red)
                .imageScale(.large)
            Text("Error loading comparison data")
                .font(Theme.subFont())
                .foregroundColor(Theme.secondaryTextColor)
            if let error = accountTariffVM.error ?? compareTariffVM.error {
                VStack(spacing: 4) {
                    Text(error.localizedDescription)
                        .font(Theme.captionFont())
                        .foregroundColor(Theme.secondaryTextColor.opacity(0.7))

                    // Show additional debug info if available
                    if let debugInfo = (error as? TariffError)?.debugDescription {
                        Text(debugInfo)
                            .font(.caption2)
                            .foregroundColor(Theme.secondaryTextColor.opacity(0.5))
                            .multilineTextAlignment(.center)
                            .padding(.horizontal)
                    }
                }
            }
            Button {
                Task {
                    await recalcAccountTariff()
                    await recalcCompareTariff()
                }
            } label: {
                Text("Retry")
                    .font(Theme.subFont())
                    .foregroundColor(Theme.mainColor)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 24)
    }

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
                .padding(.horizontal)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 24)
    }

    private var noConsumptionView: some View {
        VStack(spacing: 8) {
            ProgressView()
                .scaleEffect(1.2)
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

    private var noPlansAvailableView: some View {
        VStack(spacing: 16) {
            Image(systemName: "exclamationmark.triangle")
                .font(.system(size: 32))
                .foregroundColor(Theme.secondaryTextColor.opacity(0.7))

            VStack(spacing: 8) {
                Text("No plans available")
                    .font(Theme.mainFont())
                    .foregroundColor(Theme.mainTextColor)

                Text("No Octopus Energy plans found for your region")
                    .font(Theme.subFont())
                    .foregroundColor(Theme.secondaryTextColor)
                    .multilineTextAlignment(.center)
            }
        }
        .frame(maxWidth: .infinity)
        .frame(minHeight: 120)
        .padding(.vertical, 16)
    }

    // MARK: - Main Content View
    private var mainContentView: some View {
        VStack(spacing: 0) {
            intervalNavigationView
            comparisonView
        }
    }

    /// The bottom portion showing account vs. compare cost
    private var comparisonView: some View {
        VStack(alignment: .leading, spacing: 12) {
            // First check if a plan is selected or manual mode is enabled
            if !compareSettings.settings.isManualPlan
                && compareSettings.settings.selectedPlanCode.isEmpty
            {
                noPlanSelectedView
            } else if !hasDateOverlap {
                // Show no overlap message
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
            } else {
                // Obtain the two calculations
                let accountCalc = accountTariffVM.currentCalculation
                let compareCalc = compareTariffVM.currentCalculation

                // If either is missing, show placeholders
                if accountCalc == nil || compareCalc == nil {
                    HStack {
                        Spacer()
                        Text("Loading calculations...")
                            .font(Theme.secondaryFont())
                            .foregroundColor(Theme.secondaryTextColor)
                        Spacer()
                    }
                    .padding(.vertical, 12)
                } else if let acct = accountCalc, let cmp = compareCalc {
                    let accountCost = userSelectedVAT ? acct.costIncVAT : acct.costExcVAT
                    let compareCost = userSelectedVAT ? cmp.costIncVAT : cmp.costExcVAT
                    let diff = compareCost - accountCost
                    let accountCostStr = String(format: "£%.2f", accountCost / 100.0)
                    let compareCostStr = String(format: "£%.2f", compareCost / 100.0)

                    // Difference first
                    let diffStr = String(format: "£%.2f", abs(diff) / 100.0)
                    let diffColor: Color =
                        diff > 0 ? .red : (diff < 0 ? .green : Theme.secondaryTextColor)
                    let sign = diff > 0 ? "+" : (diff < 0 ? "−" : "")

                    HStack(alignment: .top, spacing: 16) {
                        // Left side: Difference and costs
                        VStack(alignment: .leading, spacing: 8) {
                            // Difference row
                            HStack(alignment: .firstTextBaseline) {
                                Text("\(sign)\(diffStr)")
                                    .font(Theme.mainFont())
                                    .foregroundColor(diffColor)
                                Text("difference")
                                    .font(Theme.subFont())
                                    .foregroundColor(Theme.secondaryTextColor)
                                Spacer()
                            }

                            Divider()
                                .padding(.horizontal)

                            // Costs stacked vertically
                            VStack(alignment: .leading, spacing: 8) {
                                // My Account cost
                                HStack(spacing: 8) {
                                    Image(systemName: "creditcard.fill")
                                        .foregroundColor(Theme.icon)
                                        .imageScale(.small)
                                    VStack(alignment: .leading, spacing: 2) {
                                        HStack(spacing: 4) {
                                            Text("My Account:")
                                                .font(Theme.subFont())
                                                .foregroundColor(Theme.secondaryTextColor)
                                            Text(accountCostStr)
                                                .font(Theme.subFont())
                                                .foregroundColor(Theme.mainTextColor)
                                        }
                                        if let avgRate = calculateAverageRate(calculation: acct) {
                                            Text("Avg: \(avgRate)p/kWh")
                                                .font(Theme.captionFont())
                                                .foregroundColor(Theme.secondaryTextColor)
                                        }
                                    }
                                }

                                // Compare plan cost
                                HStack(spacing: 8) {
                                    Image(systemName: "chart.line.uptrend.xyaxis")
                                        .foregroundColor(Theme.icon)
                                        .imageScale(.small)
                                    VStack(alignment: .leading, spacing: 2) {
                                        HStack(spacing: 4) {
                                            Text("\(comparePlanLabel):")
                                                .font(Theme.subFont())
                                                .foregroundColor(Theme.secondaryTextColor)
                                            Text(compareCostStr)
                                                .font(Theme.subFont())
                                                .foregroundColor(Theme.mainTextColor)
                                        }
                                        if let avgRate = calculateAverageRate(calculation: cmp) {
                                            Text("Avg: \(avgRate)p/kWh")
                                                .font(Theme.captionFont())
                                                .foregroundColor(Theme.secondaryTextColor)
                                        }
                                    }
                                }
                            }
                        }

                        // Right side: Interval selector
                        VStack(spacing: 6) {
                            ForEach(CompareIntervalType.allCases, id: \.self) { interval in
                                Button {
                                    selectedInterval = interval
                                    Task {
                                        await recalcBothTariffs()
                                    }
                                } label: {
                                    HStack {
                                        // Icon based on interval type
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
                                    .frame(height: 28)  // Add fixed height
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
                        .padding(.vertical, 6)  // Add vertical padding to the VStack containing buttons
                    }
                    .padding(.vertical, 6)
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

    /// The daily/weekly/monthly row with date navigation
    private var intervalNavigationView: some View {
        VStack(spacing: 0) {
            // Top row with left arrow, date range, right arrow
            HStack(spacing: 0) {
                // left arrow
                HStack {
                    if canGoEarlier && !accountTariffVM.isCalculating
                        && !compareTariffVM.isCalculating
                    {
                        Button {
                            navigateDate(forward: false)
                        } label: {
                            Image(systemName: "chevron.left")
                                .foregroundColor(Theme.mainColor)
                        }
                    }
                }
                .frame(width: 44)

                Spacer(minLength: 0)
                // Center date range
                HStack {
                    Spacer()
                    Text(formatDateRange())
                        .font(Theme.secondaryFont())
                        .foregroundColor(Theme.mainTextColor)
                        .overlay(alignment: .bottom) {
                            if accountTariffVM.isCalculating || compareTariffVM.isCalculating {
                                ProgressView().scaleEffect(0.5).offset(y: 10)
                            }
                        }
                    Spacer()
                }
                .frame(height: 44)

                Spacer(minLength: 0)
                // right arrow
                HStack {
                    if canGoLater && !accountTariffVM.isCalculating
                        && !compareTariffVM.isCalculating
                    {
                        Button {
                            navigateDate(forward: true)
                        } label: {
                            Image(systemName: "chevron.right")
                                .foregroundColor(Theme.mainColor)
                        }
                    }
                }
                .frame(width: 44)
            }
        }
    }

    // MARK: - Helpers

    private var hasAccountInfo: Bool {
        let s = globalSettings.settings
        return !s.apiKey.isEmpty && !(s.electricityMPAN ?? "").isEmpty
            && !(s.electricityMeterSerialNumber ?? "").isEmpty
    }

    private var userSelectedVAT: Bool {
        globalSettings.settings.showRatesWithVAT
    }

    /// Label for the compare plan, e.g. "Manual Plan" or the plan's display name
    private var comparePlanLabel: String {
        if compareSettings.settings.isManualPlan { return "Manual Plan" }
        if let found = availablePlans.first(where: {
            ($0.value(forKey: "code") as? String) == compareSettings.settings.selectedPlanCode
        }) {
            // show the plan's short name
            return (found.value(forKey: "display_name") as? String)
                ?? (found.value(forKey: "full_name") as? String)
                ?? compareSettings.settings.selectedPlanCode
        }
        return "Select a Plan"
    }

    /// Load plan from `ProductEntity` filtered by brand=OCTOPUS_ENERGY, direction=IMPORT,
    /// then check `ProductDetailEntity` for a matching region (globalSettings.settings.effectiveRegion).
    @MainActor
    private func loadComparisonPlansIfNeeded() async {
        do {
            let region = globalSettings.settings.effectiveRegion
            DebugLogger.debug(
                "Loading comparison plans for region: \(region)", component: .tariffViewModel)

            // 1. First try to fetch from local DB
            var allProducts = try await ProductsRepository.shared.fetchAllLocalProducts()

            // 2. If no products found, try to sync from API
            if allProducts.isEmpty {
                DebugLogger.debug(
                    "No local products found, syncing from API...", component: .tariffViewModel)
                allProducts = try await ProductsRepository.shared.syncAllProducts()
            }

            // 3. Filter for Octopus Energy import products
            let filteredProducts = allProducts.filter { p in
                let brand = (p.value(forKey: "brand") as? String) ?? ""
                let direction = (p.value(forKey: "direction") as? String) ?? ""
                return brand == "OCTOPUS_ENERGY" && direction == "IMPORT"
            }

            DebugLogger.debug(
                "Found \(filteredProducts.count) Octopus Energy import products",
                component: .tariffViewModel)

            // 4. For each product, check if we have details for the user's region
            var productsWithRegionDetails: [NSManagedObject] = []
            for product in filteredProducts {
                guard let code = product.value(forKey: "code") as? String else { continue }

                // Try to load details from local DB
                var details = try await ProductDetailRepository.shared.loadLocalProductDetail(
                    code: code)

                // If no details found, fetch from API
                if details.isEmpty {
                    DebugLogger.debug(
                        "No local details for \(code), fetching from API...",
                        component: .tariffViewModel)
                    details = try await ProductDetailRepository.shared.fetchAndStoreProductDetail(
                        productCode: code)
                }

                // Check if any detail matches our region
                let hasMatchingRegion = details.contains { detail in
                    let detailRegion = detail.value(forKey: "region") as? String
                    return detailRegion == region
                }

                if hasMatchingRegion {
                    productsWithRegionDetails.append(product)
                }
            }

            // Sort by display_name or code
            productsWithRegionDetails.sort { obj1, obj2 in
                let name1 =
                    (obj1.value(forKey: "display_name") as? String)
                    ?? (obj1.value(forKey: "code") as? String) ?? ""
                let name2 =
                    (obj2.value(forKey: "display_name") as? String)
                    ?? (obj2.value(forKey: "code") as? String) ?? ""
                return name1 < name2
            }

            availablePlans = productsWithRegionDetails

            // If we have plans but no selection, auto-select the first one
            if !productsWithRegionDetails.isEmpty && !compareSettings.settings.isManualPlan
                && compareSettings.settings.selectedPlanCode.isEmpty
            {
                if let code = productsWithRegionDetails[0].value(forKey: "code") as? String {
                    compareSettings.settings.selectedPlanCode = code
                    await recalcCompareTariff()
                }
            }
        } catch {
            DebugLogger.debug(
                "Error loading comparison plans: \(error)", component: .tariffViewModel)
        }
    }

    /// Fetch product availability (available_from, available_to) for the currently selected plan.
    /// If manual plan is chosen, we can treat this as "unbounded" or some default you prefer.
    private func loadProductAvailability() {
        guard !compareSettings.settings.isManualPlan else {
            // Manual plan => no real limit
            productMinDate = nil
            productMaxDate = nil
            return
        }
        // If we have a selected plan code, find the ProductEntity or details
        guard
            let productObj = availablePlans.first(where: {
                ($0.value(forKey: "code") as? String) == compareSettings.settings.selectedPlanCode
            })
        else {
            productMinDate = nil
            productMaxDate = nil
            return
        }

        // In your posted code, "available_from" and "available_to" are properties on ProductEntity
        let minD = productObj.value(forKey: "available_from") as? Date
        let maxD = productObj.value(forKey: "available_to") as? Date

        productMinDate = minD == Date.distantPast ? nil : minD
        productMaxDate = maxD == Date.distantFuture ? nil : maxD
    }

    /// Called whenever the user changes plan or we reload consumption. Merges
    /// the account's [minAllowedDate, maxAllowedDate] with the product's [productMinDate, productMaxDate].
    /// The final effective range is:
    ///
    ///   effectiveMin = max(accountMinDate, productMinDate)
    ///   effectiveMax = min(accountMaxDate, productMaxDate)
    ///
    private func updateAllowedDateRange() {
        // Original code used:
        //   minAllowedDate = consumptionVM.minInterval
        //   maxAllowedDate = consumptionVM.maxInterval
        // Let's keep that as our base for "account min/max":
        let accountMin = consumptionVM.minInterval
        let accountMax = consumptionVM.maxInterval

        // Then incorporate product's min/max:
        var combinedMin = accountMin
        if let productStart = productMinDate {
            if let accMin = combinedMin {
                combinedMin = max(accMin, productStart)
            } else {
                // If for some reason accountMin was nil but productMin not
                combinedMin = productStart
            }
        }

        var combinedMax = accountMax
        if let productEnd = productMaxDate {
            if let accMax = combinedMax {
                combinedMax = min(accMax, productEnd)
            } else {
                combinedMax = productEnd
            }
        }

        minAllowedDate = combinedMin
        maxAllowedDate = combinedMax

        // Log the merged ranges
        let dateFormatter = DateFormatter()
        dateFormatter.dateStyle = .medium
        dateFormatter.timeStyle = .short

        DebugLogger.debug(
            """
            Merged date range:
            - Account: [\(accountMin.map { dateFormatter.string(from: $0) } ?? "nil"), \(accountMax.map { dateFormatter.string(from: $0) } ?? "nil")]
            - Product: [\(productMinDate.map { dateFormatter.string(from: $0) } ?? "nil"), \(productMaxDate.map { dateFormatter.string(from: $0) } ?? "nil")]
            => Final:   [\(combinedMin.map { dateFormatter.string(from: $0) } ?? "nil"), \(combinedMax.map { dateFormatter.string(from: $0) } ?? "nil")]
            """, component: .tariffViewModel)

        // Now clamp currentDate to this new range:
        clampCurrentDateToAllowedRange()
    }

    /// Helper to clamp `currentDate` within [minAllowedDate, maxAllowedDate].
    private func clampCurrentDateToAllowedRange() {
        if let minD = minAllowedDate, currentDate < minD { currentDate = minD }
        if let maxD = maxAllowedDate, currentDate > maxD { currentDate = maxD }
    }

    /// Recalculate the user's actual account cost for the chosen interval & date
    @MainActor
    private func recalcAccountTariff() async {
        if !hasAccountInfo { return }

        // Ensure we have consumption data
        guard !consumptionVM.consumptionRecords.isEmpty else {
            DebugLogger.debug("No consumption records available", component: .tariffViewModel)
            return
        }

        // Get the date range for the selected interval
        let (startDate, endDate) = getDateRange(for: currentDate, intervalType: selectedInterval)

        // Check if we have complete data for this range
        let calendar = Calendar.current
        let now = Date()
        let todayStart = calendar.startOfDay(for: now)
        let yesterdayStart = calendar.date(byAdding: .day, value: -1, to: todayStart) ?? todayStart

        // For weekly/monthly intervals, we need to check if the START date of the interval
        // is before today, since we can only calculate complete intervals
        switch selectedInterval {
        case .daily:
            // For daily, the entire day must be complete
            guard endDate <= todayStart else {
                DebugLogger.debug(
                    "Cannot calculate costs for incomplete day", component: .tariffViewModel)
                return
            }
        case .weekly, .monthly, .quarterly:
            // For weekly/monthly/quarterly, the start date must be before today
            guard startDate < yesterdayStart else {
                DebugLogger.debug(
                    "Cannot calculate costs for incomplete \(selectedInterval.rawValue)",
                    component: .tariffViewModel)
                return
            }
        }

        do {
            await accountTariffVM.calculateCosts(
                for: currentDate,
                tariffCode: "savedAccount",
                intervalType: selectedInterval.vmInterval,
                accountData: getAccountResponse()
            )
        } catch {
            DebugLogger.debug(
                "Error calculating account tariff: \(error)", component: .tariffViewModel)
        }
    }

    /// Get the date range for a given date and interval type
    private func getDateRange(for date: Date, intervalType: CompareIntervalType) -> (
        start: Date, end: Date
    ) {
        let calendar = Calendar.current
        let startOfDay = calendar.startOfDay(for: date)

        switch intervalType {
        case .daily:
            let endDate = calendar.date(byAdding: .day, value: 1, to: startOfDay) ?? startOfDay
            return (startOfDay, endDate)

        case .weekly:
            let weekStart =
                calendar.date(
                    from: calendar.dateComponents(
                        [.yearForWeekOfYear, .weekOfYear], from: startOfDay)) ?? startOfDay
            let weekEnd = calendar.date(byAdding: .weekOfYear, value: 1, to: weekStart) ?? weekStart
            return (weekStart, weekEnd)

        case .monthly:
            let monthStart =
                calendar.date(from: calendar.dateComponents([.year, .month], from: startOfDay))
                ?? startOfDay
            let monthEnd = calendar.date(byAdding: .month, value: 1, to: monthStart) ?? monthStart
            return (monthStart, monthEnd)
        case .quarterly:
            let month = calendar.component(.month, from: startOfDay)
            let quarterStartMonth = ((month - 1) / 3) * 3 + 1

            var startComponents = calendar.dateComponents([.year], from: startOfDay)
            startComponents.month = quarterStartMonth
            startComponents.day = 1

            let quarterStart = calendar.date(from: startComponents)!
            let quarterEnd = calendar.date(byAdding: .month, value: 2, to: quarterStart)!

            return (quarterStart, quarterEnd)
        }
    }

    /// Overridden version of getDateRange that further clamps to productMinDate if needed.
    /// If the resulting interval has no overlap, we can return (nil, nil) or handle it upstream.
    private func getCombinedDateRange(for baseDate: Date, intervalType: CompareIntervalType) -> (
        Date, Date
    )? {
        // Normal monthly/weekly/daily boundaries:
        let (baseStart, baseEnd) = getDateRange(for: baseDate, intervalType: intervalType)

        let dateFormatter = DateFormatter()
        dateFormatter.dateStyle = .medium
        dateFormatter.timeStyle = .short

        DebugLogger.debug(
            """
            Computing combined date range:
            - Base interval: [\(dateFormatter.string(from: baseStart)), \(dateFormatter.string(from: baseEnd))]
            - Product bounds: [\(productMinDate.map { dateFormatter.string(from: $0) } ?? "nil"), \(productMaxDate.map { dateFormatter.string(from: $0) } ?? "nil")]
            - Account bounds: [\(minAllowedDate.map { dateFormatter.string(from: $0) } ?? "nil"), \(maxAllowedDate.map { dateFormatter.string(from: $0) } ?? "nil")]
            """, component: .tariffViewModel)

        // Now clamp to [productMinDate, productMaxDate] if present
        //   i.e. start = max(baseStart, productMinDate)
        //        end   = min(baseEnd, productMaxDate)
        // And also clamp to [accountMinDate, accountMaxDate] which we have in minAllowedDate / maxAllowedDate
        var finalStart = baseStart
        var finalEnd = baseEnd

        // clamp to productMin if available
        if let pMin = productMinDate {
            if finalEnd < pMin {
                // no overlap at all
                DebugLogger.debug(
                    "No overlap: interval ends before product start", component: .tariffViewModel)
                return nil
            }
            finalStart = max(finalStart, pMin)
        }
        // if you have productMaxDate
        if let pMax = productMaxDate {
            if finalStart > pMax {
                DebugLogger.debug(
                    "No overlap: interval starts after product end", component: .tariffViewModel)
                return nil
            }
            finalEnd = min(finalEnd, pMax)
        }

        // Also clamp to account min/max
        if let aMin = minAllowedDate {
            if finalEnd < aMin {
                DebugLogger.debug(
                    "No overlap: interval ends before account data start",
                    component: .tariffViewModel)
                return nil
            }
            finalStart = max(finalStart, aMin)
        }
        if let aMax = maxAllowedDate {
            if finalStart > aMax {
                DebugLogger.debug(
                    "No overlap: interval starts after account data end",
                    component: .tariffViewModel)
                return nil
            }
            finalEnd = min(finalEnd, aMax)
        }

        // If after all that we have finalEnd <= finalStart, no overlap
        if finalEnd <= finalStart {
            DebugLogger.debug("No overlap: final end <= final start", component: .tariffViewModel)
            return nil
        }

        DebugLogger.debug(
            """
            Final clamped range: [\(dateFormatter.string(from: finalStart)), \(dateFormatter.string(from: finalEnd))]
            """, component: .tariffViewModel)

        return (finalStart, finalEnd)
    }

    /// Recalculate the alternative plan cost
    @MainActor
    private func recalcCompareTariff() async {
        // Ensure we have consumption data
        guard !consumptionVM.consumptionRecords.isEmpty else {
            DebugLogger.debug("No consumption records available", component: .tariffViewModel)
            hasDateOverlap = false
            return
        }

        // Use the new combined approach
        guard
            let (start, end) = getCombinedDateRange(
                for: currentDate, intervalType: selectedInterval)
        else {
            // If there's no overlap, skip calculation but use calculateCosts with empty tariff
            // to properly reset the state
            DebugLogger.debug(
                "No date overlap for compare plan vs. account data.", component: .tariffViewModel)
            hasDateOverlap = false
            await compareTariffVM.calculateCosts(
                for: currentDate,
                tariffCode: "",  // empty tariff code indicates no calculation needed
                intervalType: selectedInterval.vmInterval
            )
            return
        }

        // We have overlap
        hasDateOverlap = true

        do {
            if compareSettings.settings.isManualPlan {
                // If manual, we do a "mock" approach:
                // We'll create an in-memory "Manual Plan" object each time:
                await compareTariffVM.calculateCosts(
                    for: currentDate,
                    tariffCode: "manualPlan",
                    intervalType: selectedInterval.vmInterval,
                    accountData: buildMockAccountResponseForManual()
                )
            } else {
                // If user has selected an actual product code, we find the region-based tariff code:
                let code = compareSettings.settings.selectedPlanCode
                if code.isEmpty {
                    // nothing selected
                    await compareTariffVM.calculateCosts(
                        for: currentDate,
                        tariffCode: "",
                        intervalType: selectedInterval.vmInterval
                    )
                    return
                }
                let region = globalSettings.settings.effectiveRegion

                // 1) Try to find tariff code from local data first
                var tariffCode = try await ProductDetailRepository.shared.findTariffCode(
                    productCode: code, region: region)

                // 2) If not found locally, fetch from API and try again
                if tariffCode == nil {
                    DebugLogger.debug(
                        "No local product details found for \(code), fetching from API...",
                        component: .tariffViewModel)
                    _ = try await ProductDetailRepository.shared.fetchAndStoreProductDetail(
                        productCode: code)
                    tariffCode = try await ProductDetailRepository.shared.findTariffCode(
                        productCode: code, region: region)
                }

                // 3) If still not found after API fetch, throw error
                guard let finalTariffCode = tariffCode else {
                    throw TariffError.productDetailNotFound(code: code, region: region)
                }

                // 4) Call standard calculation with found tariff code
                await compareTariffVM.calculateCosts(
                    for: currentDate,
                    tariffCode: finalTariffCode,
                    intervalType: selectedInterval.vmInterval
                )
            }
        } catch {
            DebugLogger.debug(
                "Error in tariff comparison flow: \(error)", component: .tariffViewModel)
            // Let TariffViewModel handle the error through its calculateCosts method
            await compareTariffVM.calculateCosts(
                for: currentDate,
                tariffCode: "",  // empty tariff code to indicate error
                intervalType: selectedInterval.vmInterval
            )
        }
    }

    /// Recalculate both tariffs
    @MainActor
    private func recalcBothTariffs() async {
        await recalcAccountTariff()
        await recalcCompareTariff()
    }

    /// Step date by one interval in either direction
    private func navigateDate(forward: Bool) {
        let calendar = Calendar.current
        let nextDate: Date
        switch selectedInterval {
        case .daily:
            guard let day = calendar.date(byAdding: .day, value: forward ? 1 : -1, to: currentDate)
            else { return }
            nextDate = day
        case .weekly:
            guard
                let wk = calendar.date(
                    byAdding: .weekOfYear, value: forward ? 1 : -1, to: currentDate)
            else { return }
            nextDate = wk
        case .monthly:
            guard let mo = calendar.date(byAdding: .month, value: forward ? 1 : -1, to: currentDate)
            else { return }
            nextDate = mo
        case .quarterly:
            // For quarterly, we move by 3 months and ensure proper quarter boundaries
            let month = calendar.component(.month, from: currentDate)
            let currentQuarterStartMonth = ((month - 1) / 3) * 3 + 1

            var dateComponents = calendar.dateComponents([.year, .month, .day], from: currentDate)
            dateComponents.month = currentQuarterStartMonth + (forward ? 3 : -3)
            dateComponents.day = 1

            guard let qtr = calendar.date(from: dateComponents) else { return }
            nextDate = qtr
        }

        // clamp
        if let minD = minAllowedDate, nextDate < minD { return }
        if let maxD = maxAllowedDate, nextDate > maxD { return }

        // Update the date and trigger recalculation
        currentDate = nextDate
        Task {
            await recalcBothTariffs()
        }
    }

    private var canGoEarlier: Bool {
        guard let minD = minAllowedDate else { return true }
        return currentDate > minD
    }

    private var canGoLater: Bool {
        guard let maxD = maxAllowedDate else { return true }
        return currentDate < maxD
    }

    private func formatDateRange() -> String {
        // same as AccountTariffCardView
        let cal = Calendar.current
        let startOfDay = cal.startOfDay(for: currentDate)
        switch selectedInterval {
        case .daily:
            let df = DateFormatter()
            df.locale = globalSettings.locale
            df.dateStyle = .medium
            return df.string(from: startOfDay)
        case .weekly:
            let weekStart = cal.date(
                from: cal.dateComponents([.yearForWeekOfYear, .weekOfYear], from: startOfDay))!
            let weekEnd = cal.date(byAdding: .day, value: 6, to: weekStart)!
            let df = DateFormatter()
            df.locale = globalSettings.locale
            df.dateStyle = .medium
            let s1 = df.string(from: weekStart)
            let s2 = df.string(from: weekEnd)
            return "\(s1) - \(s2)"
        case .monthly:
            let monthStart = cal.date(from: cal.dateComponents([.year, .month], from: startOfDay))!
            let df = DateFormatter()
            df.locale = globalSettings.locale
            df.dateFormat = "LLLL yyyy"  // e.g. "July 2025"
            return df.string(from: monthStart)
        case .quarterly:
            let month = cal.component(.month, from: startOfDay)
            let quarterStartMonth = ((month - 1) / 3) * 3 + 1

            var startComponents = cal.dateComponents([.year], from: startOfDay)
            startComponents.month = quarterStartMonth
            startComponents.day = 1

            let quarterStart = cal.date(from: startComponents)!
            let quarterEnd = cal.date(byAdding: .month, value: 2, to: quarterStart)!

            let df = DateFormatter()
            df.locale = globalSettings.locale
            df.dateFormat = "LLLL"  // Month name only
            let startMonth = df.string(from: quarterStart)
            let endMonth = df.string(from: quarterEnd)

            df.dateFormat = "yyyy"
            let year = df.string(from: quarterStart)

            return "\(startMonth) - \(endMonth) \(year)"
        }
    }

    private func getAccountResponse() -> OctopusAccountResponse? {
        guard let data = globalSettings.settings.accountData,
            let decoded = try? JSONDecoder().decode(OctopusAccountResponse.self, from: data)
        else {
            return nil
        }
        return decoded
    }

    /// Build a "mock" account response that will cause the TariffCalculation to use a single "flat rate"
    /// We do that by forging a single "agreement" with a code "MANUAL" etc.
    /// In practice, you might patch your TariffCalculationRepository to handle a "manualPlan" code directly
    /// and skip reading from DB. For demonstration, we show a minimal approach:
    private func buildMockAccountResponseForManual() -> OctopusAccountResponse {
        // We'll create a single property -> single meter point -> single agreement with code "MANUAL"
        // Then in TariffCalculationRepository you'd see "tariffCode: manualPlan" and handle it specially
        // or do a fallback approach. This is just for demonstration.
        let now = Date()
        let dateFormatter = ISO8601DateFormatter()
        let fromStr = dateFormatter.string(from: now.addingTimeInterval(-3600 * 24 * 365))  // 1 year ago
        let toStr = dateFormatter.string(from: now.addingTimeInterval(3600 * 24 * 365))  // 1 year ahead
        let manualAgreement = OctopusAgreement(
            tariff_code: "MANUAL",
            valid_from: fromStr,
            valid_to: toStr
        )
        let mp = OctopusElectricityMP(
            mpan: "0000000000000",
            meters: [OctopusElecMeter(serial_number: "MANUAL")],
            agreements: [manualAgreement]
        )
        let prop = OctopusProperty(
            id: 0,
            electricity_meter_points: [mp],
            gas_meter_points: nil,
            address_line_1: nil,
            moved_in_at: nil,
            postcode: nil
        )
        let account = OctopusAccountResponse(
            number: "manualAccount",
            properties: [prop]
        )
        return account
    }

    // MARK: - Helper Methods
    /// Group products by their characteristics
    private func groupProducts(_ products: [NSManagedObject]) -> [ProductGroup] {
        // Group by full display name
        var groups: [String: [NSManagedObject]] = [:]

        for product in products {
            guard let displayName = product.value(forKey: "display_name") as? String else {
                continue
            }
            groups[displayName, default: []].append(product)
        }

        // Convert to ProductGroup array and sort by name
        return groups.map { displayName, productsInGroup in
            // Get characteristics from the first product in group (they should all be the same)
            let firstProduct = productsInGroup[0]
            let isVariable = (firstProduct.value(forKey: "is_variable") as? Bool) ?? false
            let isTracker = (firstProduct.value(forKey: "is_tracker") as? Bool) ?? false
            let isGreen = (firstProduct.value(forKey: "is_green") as? Bool) ?? false

            return ProductGroup(
                id: UUID(),
                displayName: displayName,
                products: productsInGroup,
                isVariable: isVariable,
                isTracker: isTracker,
                isGreen: isGreen
            )
        }
        .sorted { $0.displayName < $1.displayName }
    }

    private func formatDate(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .none
        return formatter.string(from: date)
    }

    private func calculateAverageRate(calculation: TariffViewModel.TariffCalculation) -> String? {
        // Get total consumption in kWh
        let totalConsumption = calculation.totalKWh
        guard totalConsumption > 0 else { return nil }

        // Get total cost in pence (already in pence)
        let totalCost = userSelectedVAT ? calculation.costIncVAT : calculation.costExcVAT

        // Calculate average rate (pence per kWh)
        let avgRate = Double(totalCost) / totalConsumption

        // Format to 2 decimal places
        return String(format: "%.2f", avgRate)
    }
}

// Add new TariffError type at the top level of the file
enum TariffError: LocalizedError, CustomDebugStringConvertible {
    case productDetailNotFound(code: String, region: String)
    case apiError(underlying: Error)
    case calculationError(underlying: Error)

    var errorDescription: String? {
        switch self {
        case .productDetailNotFound(let code, let region):
            return "Could not find tariff details for product \(code) in region \(region)"
        case .apiError:
            return "Failed to fetch product details from Octopus API"
        case .calculationError:
            return "Failed to calculate tariff costs"
        }
    }

    var debugDescription: String {
        switch self {
        case .productDetailNotFound(let code, let region):
            return "Product: \(code), Region: \(region)"
        case .apiError(let error):
            return "API Error: \(error.localizedDescription)"
        case .calculationError(let error):
            return "Calculation Error: \(error.localizedDescription)"
        }
    }
}

// MARK: - Plan Selection Views
private struct PlanSelectionListView: View {
    let groups: [ProductGroup]
    @Binding var selectedPlanCode: String
    let region: String

    var body: some View {
        ForEach(groups, id: \.displayName) { group in
            NavigationLink {
                PlanDetailView(
                    group: group,
                    region: region,
                    selectedPlanCode: $selectedPlanCode
                )
            } label: {
                HStack {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(group.displayName)
                            .foregroundColor(Theme.mainTextColor)

                        HStack(spacing: 4) {
                            if group.isVariable {
                                BadgeView("Variable", color: .orange)
                            }
                            if group.isTracker {
                                BadgeView("Tracker", color: .blue)
                            }
                            if group.isGreen {
                                BadgeView("Green", color: .green)
                            }
                        }
                    }

                    Spacer()

                    if selectedPlanCode == group.products.first?.value(forKey: "code") as? String {
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundColor(Theme.mainColor)
                    }
                }
            }
        }
    }
}

private struct PlanDetailView: View {
    let group: ProductGroup
    let region: String
    @Binding var selectedPlanCode: String

    @State private var selectedDate: Date?
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        List {
            Section("Available Versions") {
                ForEach(group.availableDates, id: \.self) { date in
                    Button {
                        selectedDate = date
                        if let code = group.productCode(for: date) {
                            selectedPlanCode = code
                            dismiss()
                        }
                    } label: {
                        HStack {
                            Text(group.formatDate(date))
                                .foregroundColor(Theme.mainTextColor)

                            Spacer()

                            if selectedPlanCode == group.productCode(for: date) {
                                Image(systemName: "checkmark.circle.fill")
                                    .foregroundColor(Theme.mainColor)
                            }
                        }
                    }
                }
            }

            Section {
                if let product = group.products.first,
                    let fullDesc = product.value(forKey: "full_description") as? String
                {
                    Text(fullDesc)
                        .font(.caption)
                        .foregroundColor(Theme.secondaryTextColor)
                }
            }
        }
        .navigationTitle(group.displayName)
    }
}

private struct BadgeView: View {
    let text: String
    let color: Color

    init(_ text: String, color: Color) {
        self.text = text
        self.color = color
    }

    var body: some View {
        Text(text)
            .font(.system(size: 12, weight: .medium))
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(color.opacity(0.2))
            .foregroundColor(color)
            .clipShape(Capsule())
    }
}

// New subviews for configuration
private struct ManualInputView: View {
    @Binding var settings: ComparisonCardSettings

    var body: some View {
        VStack(spacing: 12) {
            HStack {
                Text("Energy Rate")
                    .foregroundColor(Theme.secondaryTextColor)
                Spacer()
                TextField(
                    "p/kWh",
                    value: $settings.manualRatePencePerKWh,
                    format: .number.precision(.fractionLength(2))
                )
                .keyboardType(.decimalPad)
                .multilineTextAlignment(.trailing)
                .frame(width: 80)
                .textFieldStyle(.roundedBorder)
                Text("p/kWh")
                    .foregroundColor(Theme.secondaryTextColor)
                    .font(Theme.captionFont())
            }

            HStack {
                Text("Daily Charge")
                    .foregroundColor(Theme.secondaryTextColor)
                Spacer()
                TextField(
                    "p/day",
                    value: $settings.manualStandingChargePencePerDay,
                    format: .number.precision(.fractionLength(2))
                )
                .keyboardType(.decimalPad)
                .multilineTextAlignment(.trailing)
                .frame(width: 80)
                .textFieldStyle(.roundedBorder)
                Text("p/day")
                    .foregroundColor(Theme.secondaryTextColor)
                    .font(Theme.captionFont())
            }
        }
        .padding(.horizontal)
    }
}

private struct PlanSelectionView: View {
    let groups: [ProductGroup]
    @Binding var selectedPlanCode: String
    let region: String

    var body: some View {
        VStack(spacing: 12) {
            // Product Group Picker
            Menu {
                ForEach(groups) { group in
                    Button {
                        // Select the latest version by default
                        if let latestDate = group.availableDates.first,
                            let code = group.productCode(for: latestDate)
                        {
                            selectedPlanCode = code
                        }
                    } label: {
                        HStack {
                            Text(group.displayName)
                            // Badges inline with product name
                            if group.isVariable {
                                BadgeView("Variable", color: .orange)
                            }
                            if group.isTracker {
                                BadgeView("Tracker", color: .blue)
                            }
                            if group.isGreen {
                                BadgeView("Green", color: .green)
                            }
                            Spacer()
                            if let latestDate = group.availableDates.first,
                                let code = group.productCode(for: latestDate),
                                selectedPlanCode == code
                            {
                                Image(systemName: "checkmark")
                            }
                        }
                    }
                }
            } label: {
                HStack {
                    if let selectedGroup = groups.first(where: { group in
                        group.availableDates.contains { date in
                            group.productCode(for: date) == selectedPlanCode
                        }
                    }) {
                        // Selected plan name and badges in a wrapping HStack
                        HStack(spacing: 4) {
                            Text(selectedGroup.displayName)
                                .foregroundColor(Theme.mainTextColor)
                            if selectedGroup.isVariable {
                                BadgeView("Variable", color: .orange)
                            }
                            if selectedGroup.isTracker {
                                BadgeView("Tracker", color: .blue)
                            }
                            if selectedGroup.isGreen {
                                BadgeView("Green", color: .green)
                            }
                        }
                    } else {
                        Text("Select Plan")
                            .foregroundColor(Theme.mainTextColor)
                    }
                    Spacer()
                    Image(systemName: "chevron.down")
                        .foregroundColor(Theme.secondaryTextColor)
                }
                .padding()
                .background(Theme.mainBackground.opacity(0.3))
                .cornerRadius(8)
            }

            // Version/Availability Information
            if let selectedGroup = groups.first(where: { group in
                group.availableDates.contains { date in
                    group.productCode(for: date) == selectedPlanCode
                }
            }) {
                // Always show version menu or info
                if selectedGroup.availableDates.count > 1 {
                    // Multiple versions - show as menu
                    Menu {
                        ForEach(selectedGroup.availableDates, id: \.self) { date in
                            if let code = selectedGroup.productCode(for: date) {
                                Button {
                                    selectedPlanCode = code
                                } label: {
                                    HStack {
                                        Text(selectedGroup.formatDate(date))
                                        Spacer()
                                        if selectedPlanCode == code {
                                            Image(systemName: "checkmark")
                                        }
                                    }
                                }
                            }
                        }
                    } label: {
                        HStack {
                            if let selectedDate = selectedGroup.availableDates.first(where: {
                                date in
                                selectedGroup.productCode(for: date) == selectedPlanCode
                            }) {
                                Text("Available from: \(selectedGroup.formatDate(selectedDate))")
                                    .foregroundColor(Theme.mainTextColor)
                            }
                            Spacer()
                            Image(systemName: "chevron.down")
                                .foregroundColor(Theme.secondaryTextColor)
                        }
                        .padding()
                        .background(Theme.mainBackground.opacity(0.3))
                        .cornerRadius(8)
                    }
                }
            } else {
                Text("No plan selected")
                    .foregroundColor(Theme.secondaryTextColor)
            }
        }
        .padding(.horizontal)
    }
}

// Replace CollapsibleSection struct
private struct CollapsibleSection<Label: View, Content: View>: View {
    let label: () -> Label
    let content: () -> Content
    @State private var isExpanded = false

    init(
        @ViewBuilder label: @escaping () -> Label,
        @ViewBuilder content: @escaping () -> Content
    ) {
        self.label = label
        self.content = content
    }

    var body: some View {
        VStack(spacing: 0) {
            Button {
                withAnimation(.spring(duration: 0.3)) {
                    isExpanded.toggle()
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
                .padding()
                .background(Theme.mainBackground.opacity(0.3))
                .cornerRadius(8)
            }
            .buttonStyle(.plain)

            if isExpanded {
                content()
                    .transition(.move(edge: .top).combined(with: .opacity))
            }
        }
    }
}

private struct PlanSummaryView: View {
    let group: ProductGroup
    let availableDate: Date

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            // Product name and badges
            HStack(spacing: 4) {
                Text(group.displayName)
                    .foregroundColor(Theme.mainTextColor)
                if group.isVariable {
                    BadgeView("Variable", color: .orange)
                }
                if group.isTracker {
                    BadgeView("Tracker", color: .blue)
                }
                if group.isGreen {
                    BadgeView("Green", color: .green)
                }
            }

            // Available date
            Text("Available from: \(group.formatDate(availableDate))")
                .font(Theme.captionFont())
                .foregroundColor(Theme.secondaryTextColor)
        }
    }
}

private struct ManualPlanSummaryView: View {
    let settings: ComparisonCardSettings

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 4) {
                Text("Manual Plan")
                    .foregroundColor(Theme.mainTextColor)
                BadgeView("Fixed Rate", color: .purple)
            }

            Text(
                "\(String(format: "%.1f", settings.manualRatePencePerKWh))p/kWh + \(String(format: "%.1f", settings.manualStandingChargePencePerDay))p/day"
            )
            .font(Theme.captionFont())
            .foregroundColor(Theme.secondaryTextColor)
        }
    }
}

// Enhanced Product Detail View
private struct ProductDetailView: View {
    let product: NSManagedObject
    @EnvironmentObject var globalSettings: GlobalSettingsManager
    @State private var loadError: Error?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                // Basic Info Section
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

                // Badges
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

                // Availability Section
                VStack(alignment: .leading, spacing: 8) {
                    Text("Availability")
                        .font(Theme.subFont())
                        .foregroundColor(Theme.secondaryTextColor)

                    if let availableFrom = product.value(forKey: "available_from") as? Date,
                        availableFrom != Date.distantPast
                    {
                        Text("From: \(formatDate(availableFrom))")
                            .font(Theme.captionFont())
                            .foregroundColor(Theme.secondaryTextColor)
                    }

                    if let availableTo = product.value(forKey: "available_to") as? Date,
                        availableTo != Date.distantFuture
                    {
                        Text("To: \(formatDate(availableTo))")
                            .font(Theme.captionFont())
                            .foregroundColor(Theme.secondaryTextColor)
                    }
                }
                .padding(.top, 8)

                // Product and Tariff Information
                VStack(alignment: .leading, spacing: 8) {
                    if let code = product.value(forKey: "code") as? String {
                        Text("Product Code: \(code)")
                            .font(Theme.captionFont())
                            .foregroundColor(Theme.secondaryTextColor)
                    } else {
                        Text("Product Code Not Available")
                            .font(Theme.captionFont())
                            .foregroundColor(.red)
                    }

                    // Load and show tariff code for user's region
                    TariffCodeView(
                        productCode: product.value(forKey: "code") as? String ?? "",
                        region: globalSettings.settings.effectiveRegion
                    )
                }
                .padding(.top, 8)

                if let error = loadError {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Error Loading Product Details")
                            .font(Theme.subFont())
                            .foregroundColor(.red)
                        Text(error.localizedDescription)
                            .font(Theme.captionFont())
                            .foregroundColor(Theme.secondaryTextColor)
                    }
                    .padding(.top, 8)
                }
            }
            .padding()
        }
    }

    private func formatDate(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .none
        return formatter.string(from: date)
    }
}

private struct TariffCodeView: View {
    let productCode: String
    let region: String
    @State private var tariffCode: String?
    @State private var isLoading = true
    @State private var loadError: Error?

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            if isLoading {
                HStack(spacing: 8) {
                    ProgressView()
                        .scaleEffect(0.8)
                    Text("Loading tariff details...")
                        .font(Theme.captionFont())
                        .foregroundColor(Theme.secondaryTextColor)
                }
            } else if let error = loadError {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Error Loading Tariff")
                        .font(Theme.captionFont())
                        .foregroundColor(.red)
                    Text(error.localizedDescription)
                        .font(Theme.captionFont())
                        .foregroundColor(Theme.secondaryTextColor)
                    Button("Retry") {
                        loadTariffCode()
                    }
                    .font(Theme.captionFont())
                    .foregroundColor(Theme.mainColor)
                }
            } else if let code = tariffCode {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Your Region: \(region)")
                        .font(Theme.captionFont())
                        .foregroundColor(Theme.secondaryTextColor)
                    Text("Tariff Code: \(code)")
                        .font(Theme.captionFont())
                        .foregroundColor(Theme.secondaryTextColor)
                }
            } else {
                Text("No tariff available for your region")
                    .font(Theme.captionFont())
                    .foregroundColor(Theme.secondaryTextColor)
            }
        }
        .onAppear {
            loadTariffCode()
        }
    }

    private func loadTariffCode() {
        guard !productCode.isEmpty else {
            self.loadError = TariffError.productDetailNotFound(code: "unknown", region: region)
            self.isLoading = false
            return
        }

        isLoading = true
        loadError = nil

        Task {
            do {
                let details = try await ProductDetailRepository.shared.loadLocalProductDetail(
                    code: productCode)

                await MainActor.run {
                    if let detail = details.first(where: { detail in
                        detail.value(forKey: "region") as? String == region
                    }) {
                        self.tariffCode = detail.value(forKey: "tariff_code") as? String
                        self.isLoading = false
                    } else {
                        self.loadError = TariffError.productDetailNotFound(
                            code: productCode, region: region)
                        self.isLoading = false
                    }
                }
            } catch {
                await MainActor.run {
                    self.loadError = error
                    self.isLoading = false
                }
                DebugLogger.debug(
                    "Error loading tariff code: \(error)", component: .tariffViewModel)
            }
        }
    }
}

private struct ManualPlanDetailView: View {
    let settings: ComparisonCardSettings

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Manual Plan Configuration")
                .font(Theme.mainFont2())
                .foregroundColor(Theme.mainTextColor)

            VStack(alignment: .leading, spacing: 8) {
                Text("Energy Rate: \(String(format: "%.2f", settings.manualRatePencePerKWh))p/kWh")
                Text(
                    "Daily Standing Charge: \(String(format: "%.2f", settings.manualStandingChargePencePerDay))p/day"
                )
            }
            .font(Theme.subFont())
            .foregroundColor(Theme.secondaryTextColor)

            Text("This is a fixed-rate plan where the same rate applies to all hours of the day.")
                .font(Theme.captionFont())
                .foregroundColor(Theme.secondaryTextColor)
                .padding(.top, 8)
        }
        .padding()
    }
}
