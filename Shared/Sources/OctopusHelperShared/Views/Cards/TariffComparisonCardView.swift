import Combine
import CoreData
import SwiftUI

// MARK: - Enums & Support Types

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
    @Published var settings: ComparisonCardSettings {
        didSet { saveSettings() }
    }
    private let userDefaultsKey = "TariffComparisonCardSettings"

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

private enum CompareIntervalType: String, CaseIterable {
    case daily = "DAILY"
    case weekly = "WEEKLY"
    case monthly = "MONTHLY"
    case quarterly = "QUARTERLY"

    var displayName: String { rawValue.capitalized }

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

    func formatDate(_ date: Date) -> String {
        let df = DateFormatter()
        df.dateFormat = "d MMMM yyyy"
        return df.string(from: date)
    }
}

// MARK: - Main TariffComparisonCardView

public struct TariffComparisonCardView: View {
    // Dependencies
    @ObservedObject var consumptionVM: ConsumptionViewModel
    @ObservedObject var ratesVM: RatesViewModel
    @ObservedObject var globalSettings: GlobalSettingsManager

    // Two separate TariffViewModels for actual account vs. comparison
    @StateObject private var accountTariffVM = TariffViewModel()
    @StateObject private var compareTariffVM = TariffViewModel()

    // Interval & date state
    @State private var selectedInterval: CompareIntervalType = .daily
    @State private var currentDate = Date()

    // Other UI states
    @State private var showingSettingsSheet = false
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
    @StateObject private var compareSettings = ComparisonCardSettingsManager()

    // Refresh toggles & scene states
    @State private var refreshTrigger = false
    @ObservedObject private var refreshManager = CardRefreshManager.shared

    // Card flipping
    @State private var isFlipped = false

    // For region-based plan selection
    @State private var availablePlans: [NSManagedObject] = []

    public init(
        consumptionVM: ConsumptionViewModel,
        ratesVM: RatesViewModel,
        globalSettings: GlobalSettingsManager
    ) {
        self.consumptionVM = consumptionVM
        self.ratesVM = ratesVM
        self.globalSettings = globalSettings
    }

    public var body: some View {
        Group {
            if isFlipped {
                backView
            } else {
                frontView
            }
        }
        .rateCardStyle()
        .rotation3DEffect(.degrees(isFlipped ? 180 : 0), axis: (x: 0, y: 1, z: 0))
        .animation(.spring(duration: 0.6), value: isFlipped)
        .environment(\.locale, globalSettings.locale)
        .onAppear {
            Task {
                guard !hasInitiallyLoaded else { return }
                initializeFromSettings()
                updateAllowedDateRange()
                await loadComparisonPlansIfNeeded()
                await recalcBothTariffs(partialOverlap: true)
                hasInitiallyLoaded = true
            }
        }
        .onChange(of: consumptionVM.minInterval) { _, _ in
            updateAllowedDateRange()
        }
        .onChange(of: consumptionVM.maxInterval) { _, _ in
            updateAllowedDateRange()
        }
        .onChange(of: compareSettings.settings.selectedPlanCode) { _ in
            Task {
                await recalcBothTariffs(partialOverlap: true)
            }
        }
        .onChange(of: compareSettings.settings.manualRatePencePerKWh) { _ in
            if compareSettings.settings.isManualPlan {
                Task { await recalcBothTariffs(partialOverlap: true) }
            }
        }
        .onChange(of: compareSettings.settings.manualStandingChargePencePerDay) { _ in
            if compareSettings.settings.isManualPlan {
                Task { await recalcBothTariffs(partialOverlap: true) }
            }
        }
        .onChange(of: compareSettings.settings.isManualPlan) { _ in
            Task {
                await recalcBothTariffs(partialOverlap: true)
            }
        }
        .onChange(of: consumptionVM.fetchState) { oldState, newState in
            if case .success = newState {
                Task {
                    await recalcBothTariffs(partialOverlap: true)
                }
            }
        }
    }

    // MARK: - Front View
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
                        ProgressView().scaleEffect(0.8)
                    } else {
                        Button(action: {
                            withAnimation {
                                isFlipped.toggle()
                            }
                        }) {
                            Image(systemName: "info.circle.fill")
                                .foregroundColor(Theme.secondaryTextColor)
                        }
                    }
                }
            }
            .padding(.bottom, 2)

            if !hasAccountInfo {
                noAccountView
            } else {
                // Collapsible configuration
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
                .padding(.horizontal)

                Divider().padding(.horizontal).padding(.vertical, 2)

                // Date navigation sub-view
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
                .padding(.horizontal)

                Divider().padding(.horizontal).padding(.vertical, 2)

                // Comparison results
                comparisonResultsView
            }
        }
    }

    // MARK: - Back View
    private var backView: some View {
        VStack(spacing: 0) {
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
            .padding(.bottom, 2)

            if compareSettings.settings.isManualPlan {
                ManualPlanDetailView(settings: compareSettings.settings)
            } else if let product = availablePlans.first(where: {
                ($0.value(forKey: "code") as? String) == compareSettings.settings.selectedPlanCode
            }) {
                ProductDetailView(product: product)
                    .environmentObject(globalSettings)
            } else {
                VStack(spacing: 16) {
                    Image(systemName: "exclamationmark.triangle")
                        .font(.system(size: 36))
                        .foregroundColor(.orange)
                    Text("No product details available.")
                        .foregroundColor(Theme.secondaryTextColor)
                }
                .padding(.vertical, 20)
            }
        }
        .padding(.horizontal)
        .padding(.top, 8)
        .rotation3DEffect(.degrees(180), axis: (x: 0, y: 1, z: 0))  // Counter-rotation for back view content
    }

    // MARK: - Comparison Results
    @ViewBuilder
    private var comparisonResultsView: some View {
        if consumptionVM.consumptionRecords.isEmpty {
            noConsumptionView
        } else if !compareSettings.settings.isManualPlan,
            compareSettings.settings.selectedPlanCode.isEmpty
        {
            noPlanSelectedView
        } else if selectedInterval == .daily && !hasOverlapInDaily {
            // Show no overlap view if there's no data for the selected day
            noOverlapView
        } else if !hasDateOverlap {
            noOverlapView
        } else {
            let acctCalc = accountTariffVM.currentCalculation
            let cmpCalc = compareTariffVM.currentCalculation

            if acctCalc == nil || cmpCalc == nil {
                // Replace simple loading text with a placeholder that matches the structure
                ComparisonCostPlaceholderView(
                    selectedInterval: selectedInterval,
                    comparePlanLabel: comparePlanLabel,
                    isPartialPeriod: isPartialPeriod
                )
            } else {
                // Show cost comparison
                ComparisonCostSummaryView(
                    accountCalculation: acctCalc!,
                    compareCalculation: cmpCalc!,
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
                .padding(.horizontal)
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
        globalSettings.settings.selectedComparisonInterval = selectedInterval.rawValue
        globalSettings.settings.lastViewedComparisonDates[selectedInterval.rawValue] = currentDate
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
            // Keep existing logic
            maxAllowedDate = consumptionVM.maxInterval
        case .monthly:
            maxAllowedDate = consumptionVM.maxInterval
        case .quarterly:
            maxAllowedDate = consumptionVM.maxInterval
        }

        // Clamp current date if needed using IntervalBoundary
        if let mn = minAllowedDate {
            let boundary = accountTariffVM.getBoundary(
                for: currentDate,
                intervalType: selectedInterval.vmInterval,
                billingDay: globalSettings.settings.billingDay
            )
            if !boundary.overlapsWithData(minDate: mn, maxDate: nil) {
                currentDate = mn
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
        do {
            let region = globalSettings.settings.effectiveRegion
            var allProducts = try await ProductsRepository.shared.fetchAllLocalProducts()
            if allProducts.isEmpty {
                allProducts = try await ProductsRepository.shared.syncAllProducts()
            }

            let filtered = allProducts.filter { p in
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

            if !regionProducts.isEmpty,
                !compareSettings.settings.isManualPlan,
                compareSettings.settings.selectedPlanCode.isEmpty
            {
                if let firstCode = regionProducts[0].value(forKey: "code") as? String {
                    compareSettings.settings.selectedPlanCode = firstCode
                    await recalcBothTariffs(partialOverlap: true)
                }
            }
        } catch {
            DebugLogger.debug(
                "❌ Error loading comparison plans: \(error.localizedDescription)",
                component: .tariffViewModel)
        }
    }

    // MARK: - Calculation Routines

    private func recalcBothTariffs(partialOverlap: Bool = false) async {
        // Calculate the requested date range based on interval type
        let (requestedStart, requestedEnd) = TariffViewModel().calculateDateRange(
            for: currentDate,
            intervalType: selectedInterval.vmInterval,
            billingDay: globalSettings.settings.billingDay
        )

        // Determine the actual calculation period considering all constraints
        guard
            let (overlapStart, overlapEnd) = await determineOverlapPeriod(
                requestedStart: requestedStart,
                requestedEnd: requestedEnd
            )
        else {
            hasDateOverlap = false
            await accountTariffVM.resetCalculationState()
            await compareTariffVM.resetCalculationState()
            return
        }

        hasDateOverlap = true

        // Calculate both tariffs with the same overlap period
        async let acctCalc = recalcAccountTariff(start: overlapStart, end: overlapEnd)
        async let cmpCalc = recalcCompareTariff(start: overlapStart, end: overlapEnd)
        _ = await (acctCalc, cmpCalc)
    }

    @MainActor
    private func recalcAccountTariff(start: Date, end: Date) async {
        if !hasAccountInfo { return }
        guard !consumptionVM.consumptionRecords.isEmpty else { return }

        do {
            await accountTariffVM.calculateCosts(
                for: currentDate,
                tariffCode: "savedAccount",
                intervalType: selectedInterval.vmInterval,
                accountData: getAccountResponse(),
                partialStart: start,
                partialEnd: end
            )
        } catch {
            DebugLogger.debug(
                "❌ Error in recalcAccountTariff: \(error.localizedDescription)",
                component: .tariffViewModel)
        }
    }

    @MainActor
    private func recalcCompareTariff(start: Date, end: Date) async {
        guard !consumptionVM.consumptionRecords.isEmpty else {
            hasDateOverlap = false
            return
        }

        do {
            if compareSettings.settings.isManualPlan {
                // Build mock account response for manual plan
                let mockAccount = buildMockAccountResponseForManual()
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
                    hasDateOverlap = false
                    await compareTariffVM.calculateCosts(
                        for: currentDate,
                        tariffCode: "",
                        intervalType: selectedInterval.vmInterval
                    )
                    return
                }

                // Get tariff code for the selected product
                let region = globalSettings.settings.effectiveRegion
                var tariffCode = try await ProductDetailRepository.shared.findTariffCode(
                    productCode: code, region: region)
                if tariffCode == nil {
                    _ = try await ProductDetailRepository.shared.fetchAndStoreProductDetail(
                        productCode: code)
                    tariffCode = try await ProductDetailRepository.shared.findTariffCode(
                        productCode: code, region: region)
                }

                guard let finalCode = tariffCode else {
                    throw TariffError.productDetailNotFound(code: code, region: region)
                }

                await compareTariffVM.calculateCosts(
                    for: currentDate,
                    tariffCode: finalCode,
                    intervalType: selectedInterval.vmInterval,
                    partialStart: start,
                    partialEnd: end
                )
            }
        } catch {
            hasDateOverlap = false
            DebugLogger.debug(
                "❌ Error in recalcCompareTariff: \(error.localizedDescription)",
                component: .tariffViewModel)
            await compareTariffVM.calculateCosts(
                for: currentDate,
                tariffCode: "",
                intervalType: selectedInterval.vmInterval
            )
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
    private func determineOverlapPeriod(requestedStart: Date, requestedEnd: Date) async -> (
        Date, Date
    )? {
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
            tariff_code: "MANUAL", valid_from: fromStr, valid_to: toStr)
        let mp = OctopusElectricityMP(
            mpan: "0000000000000",
            meters: [OctopusElecMeter(serial_number: "MANUAL")],
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
                            .foregroundColor(Theme.mainColor)
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
            HStack {
                let canGoForward = canNavigateForward()
                if canGoForward && !isCalculating {
                    Button {
                        moveDate(forward: true)
                    } label: {
                        Image(systemName: "chevron.right")
                            .foregroundColor(Theme.mainColor)
                    }
                }
            }
            .frame(width: 44)
        }
        .padding(.vertical, 4)
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
        return prevBoundary.overlapsWithData(minDate: minDate, maxDate: maxDate)
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
        var candidate = calendar.startOfDay(for: date)

        while true {
            guard let prevDay = calendar.date(byAdding: .day, value: -1, to: candidate) else {
                return nil
            }
            candidate = calendar.startOfDay(for: prevDay)

            // Bounds check
            if let minDate = minDate, candidate < calendar.startOfDay(for: minDate) {
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
            if let maxDate = maxDate, candidate > calendar.startOfDay(for: maxDate) {
                return nil
            }

            // If the candidate is in the set, we found our next valid day
            if dailySet.contains(candidate) {
                return candidate
            }
        }
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
            let prevDate = calendar.date(byAdding: .weekOfYear, value: -1, to: currentDate)
            guard let date = prevDate else { return nil }
            // Validate using boundary
            let boundary = accountTariffVM.getBoundary(
                for: date,
                intervalType: selectedInterval.vmInterval,
                billingDay: globalSettings.settings.billingDay
            )
            return boundary.overlapsWithData(minDate: minDate, maxDate: maxDate) ? date : nil

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
        let (start, end) = accountTariffVM.calculateDateRange(
            for: currentDate,
            intervalType: selectedInterval.vmInterval,
            billingDay: globalSettings.settings.billingDay
        )

        // Format dates according to requirements:
        // - Daily: "23 Jan 2025"
        // - Weekly: "20 Jan - 26 Jan 2025" (or "30 Dec 2024 - 5 Jan 2025")
        // - Monthly: "4 Jan - 3 Feb 2025" (or "4 Dec 2024 - 3 Jan 2025")
        // - Quarterly: "4 Jan - 3 Mar 2025" (or "4 Dec 2024 - 3 Jan 2025")

        let cal = Calendar.current

        // Shared formatters
        let dayMonthFmt = DateFormatter()
        dayMonthFmt.locale = globalSettings.locale
        dayMonthFmt.dateFormat = "d MMM"

        let dayMonthYearFmt = DateFormatter()
        dayMonthYearFmt.locale = globalSettings.locale
        dayMonthYearFmt.dateFormat = "d MMM yyyy"

        switch selectedInterval {
        case .daily:
            // "23 Jan 2025"
            return dayMonthYearFmt.string(from: start)

        case .weekly:
            // "20 Jan - 26 Jan 2025" or crossing year => "30 Dec 2024 - 5 Jan 2025"
            let startYear = cal.component(.year, from: start)
            let endYear = cal.component(.year, from: end)

            if startYear == endYear {
                return
                    "\(dayMonthFmt.string(from: start)) - \(dayMonthFmt.string(from: end)) \(startYear)"
            } else {
                return
                    "\(dayMonthFmt.string(from: start)) \(startYear) - \(dayMonthFmt.string(from: end)) \(endYear)"
            }

        case .monthly:
            // "4 Jan - 3 Feb 2025" or crossing year => "4 Dec 2024 - 3 Jan 2025"
            let startYear = cal.component(.year, from: start)
            let endYear = cal.component(.year, from: end)

            if startYear == endYear {
                return
                    "\(dayMonthFmt.string(from: start)) - \(dayMonthFmt.string(from: end)) \(startYear)"
            } else {
                return
                    "\(dayMonthFmt.string(from: start)) \(startYear) - \(dayMonthFmt.string(from: end)) \(endYear)"
            }

        case .quarterly:
            // "4 Jan - 3 Mar 2025" or crossing year => "4 Dec 2024 - 3 Jan 2025"
            let startYear = cal.component(.year, from: start)
            let endYear = cal.component(.year, from: end)

            if startYear == endYear {
                return
                    "\(dayMonthFmt.string(from: start)) - \(dayMonthFmt.string(from: end)) \(startYear)"
            } else {
                return
                    "\(dayMonthFmt.string(from: start)) \(startYear) - \(dayMonthFmt.string(from: end)) \(endYear)"
            }
        }
    }
}

// MARK: - Subviews: Plan Selection

private struct ComparisonPlanSelectionView: View {
    @ObservedObject var compareSettings: ComparisonCardSettingsManager
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
                Text("Manual Plan").tag(true)
            }
            .pickerStyle(.segmented)
            .padding(.horizontal)

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
    let accountCalculation: TariffViewModel.TariffCalculation
    let compareCalculation: TariffViewModel.TariffCalculation
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
        VStack(spacing: 8) {
            // Show partial period info if applicable
            if isPartialPeriod, let requested = requestedPeriod, let actual = actualPeriod {
                HStack {
                    Image(systemName: "info.circle")
                        .foregroundColor(Theme.secondaryTextColor)
                    Text("Showing partial period")
                        .font(Theme.captionFont())
                        .foregroundColor(Theme.secondaryTextColor)
                }
                .padding(.horizontal)
                .transition(.opacity.combined(with: .move(edge: .top)))
            }

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
                        Text("difference")
                            .font(Theme.subFont())
                            .foregroundColor(Theme.secondaryTextColor)
                        Spacer()
                    }

                    Divider().padding(.horizontal)

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

                // Right side interval switcher
                VStack(spacing: 6) {
                    ForEach(CompareIntervalType.allCases, id: \.self) { interval in
                        Button {
                            withAnimation {
                                onIntervalChange(interval)
                            }
                        } label: {
                            HStack {
                                Image(systemName: iconName(for: interval))
                                    .imageScale(.small)
                                Spacer(minLength: 16)
                                Text(interval.displayName)
                                    .font(.callout)
                            }
                            .font(Theme.subFont())
                            .foregroundColor(
                                selectedInterval == interval
                                    ? Theme.mainTextColor : Theme.secondaryTextColor
                            )
                            .frame(height: 28)
                            .frame(width: 110, alignment: .leading)
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
            .padding(.vertical, 6)

            // Show date range info for partial period
            if isPartialPeriod, let requested = requestedPeriod, let actual = actualPeriod {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Available data: \(formatDateRange(actual.start, actual.end))")
                        .font(Theme.captionFont())
                        .foregroundColor(Theme.secondaryTextColor)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal)
                .transition(.opacity.combined(with: .move(edge: .bottom)))
            }
        }
        .animation(.spring(duration: 0.3), value: isPartialPeriod)
    }

    private func formatDateRange(_ start: Date, _ end: Date) -> String {
        let df = DateFormatter()
        df.dateFormat = "d MMM yyyy"
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
    let selectedInterval: CompareIntervalType
    let comparePlanLabel: String
    let isPartialPeriod: Bool

    init(
        selectedInterval: CompareIntervalType, comparePlanLabel: String,
        isPartialPeriod: Bool = false
    ) {
        self.selectedInterval = selectedInterval
        self.comparePlanLabel = comparePlanLabel
        self.isPartialPeriod = isPartialPeriod
    }

    var body: some View {
        VStack(spacing: 8) {
            // Show partial period placeholder if applicable
            if isPartialPeriod {
                HStack {
                    Image(systemName: "info.circle")
                        .foregroundColor(Theme.secondaryTextColor.opacity(0.5))
                    Text("Showing partial period")
                        .font(Theme.captionFont())
                        .foregroundColor(Theme.secondaryTextColor.opacity(0.5))
                }
                .padding(.horizontal)
                .transition(.opacity.combined(with: .move(edge: .top)))
            }

            HStack(alignment: .top, spacing: 16) {
                // Left difference & cost block with shimmer effect
                VStack(alignment: .leading, spacing: 8) {
                    // Diff row
                    HStack(alignment: .firstTextBaseline) {
                        RoundedRectangle(cornerRadius: 4)
                            .fill(Theme.secondaryTextColor.opacity(0.2))
                            .frame(width: 80, height: 20)
                        Text("difference")
                            .font(Theme.subFont())
                            .foregroundColor(Theme.secondaryTextColor)
                        Spacer()
                    }

                    Divider().padding(.horizontal)

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

                // Right side interval switcher (keep the same as actual view)
                VStack(spacing: 6) {
                    ForEach(CompareIntervalType.allCases, id: \.self) { interval in
                        HStack {
                            Image(systemName: iconName(for: interval))
                                .imageScale(.small)
                            Spacer(minLength: 16)
                            Text(interval.displayName)
                                .font(.callout)
                        }
                        .font(Theme.subFont())
                        .foregroundColor(
                            selectedInterval == interval
                                ? Theme.mainTextColor : Theme.secondaryTextColor
                        )
                        .frame(height: 28)
                        .frame(width: 110, alignment: .leading)
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
            .padding(.vertical, 6)

            // Show placeholder for date range info
            if isPartialPeriod {
                VStack(alignment: .leading, spacing: 4) {
                    RoundedRectangle(cornerRadius: 4)
                        .fill(Theme.secondaryTextColor.opacity(0.2))
                        .frame(height: 16)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal)
                .transition(.opacity.combined(with: .move(edge: .bottom)))
            }
        }
        .animation(.spring(duration: 0.3), value: isPartialPeriod)
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
            Text("A fixed-rate plan where the same rate applies to all hours.")
                .font(Theme.captionFont())
                .foregroundColor(Theme.secondaryTextColor)
                .padding(.top, 8)
        }
        .padding()
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

private struct PlanSummaryView: View {
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
            Text("Available from: \(group.formatDate(availableDate))")
                .font(Theme.captionFont())
                .foregroundColor(Theme.secondaryTextColor)
        }
    }
}

// Reuse the PlanSelectionView, PlanDetailView, etc. from existing code:

private struct PlanSelectionView: View {
    let groups: [ProductGroup]
    @Binding var selectedPlanCode: String
    let region: String

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
                    }
                }
            } label: {
                HStack {
                    if let active = groups.first(where: { isCurrentlySelected($0) }) {
                        HStack(spacing: 4) {
                            Text(active.displayName)
                            if active.isVariable { BadgeView("Variable", color: .orange) }
                            if active.isTracker { BadgeView("Tracker", color: .blue) }
                            if active.isGreen { BadgeView("Green", color: .green) }
                        }
                        .foregroundColor(Theme.mainTextColor)
                    } else {
                        Text("Select Plan").foregroundColor(Theme.mainTextColor)
                    }
                    Spacer()
                    Image(systemName: "chevron.down")
                        .foregroundColor(Theme.secondaryTextColor)
                }
                .padding()
                .background(Theme.mainBackground.opacity(0.3))
                .cornerRadius(8)
            }

            // If multiple versions, show separate menu
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
                                            Text(group.formatDate(date))
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
                                Text("Available from: \(group.formatDate(date))")
                                Spacer()
                                Image(systemName: "chevron.down")
                            }
                            .padding()
                            .background(Theme.mainBackground.opacity(0.3))
                            .cornerRadius(8)
                        }
                    } else {
                        // Single date case - show as plain text
                        HStack {
                            Text("Available from: \(group.formatDate(date))")
                            Spacer()
                        }
                        .padding()
                        .background(Theme.mainBackground.opacity(0.3))
                        .cornerRadius(8)
                    }
                }
            }
        }
        .padding(.horizontal)
    }

    private func isCurrentlySelected(_ group: ProductGroup) -> Bool {
        group.availableDates.contains { date in
            group.productCode(for: date) == selectedPlanCode
        }
    }
}

private struct ManualInputView: View {
    @Binding var settings: ComparisonCardSettings
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
            tariff_code: "MANUAL", valid_from: fromStr, valid_to: toStr)
        let mp = OctopusElectricityMP(
            mpan: "0000000000000",
            meters: [OctopusElecMeter(serial_number: "MANUAL")],
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
            await compareTariffVM.resetCalculationState()
            let mockAccount = buildMockAccountResponseForManual()
            await compareTariffVM.calculateCosts(
                for: currentDate,
                tariffCode: "manualPlan",
                intervalType: selectedInterval.vmInterval,
                accountData: mockAccount,
                partialStart: overlapStart,
                partialEnd: overlapEnd
            )
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
                        set: { newValue in
                            settings.manualRatePencePerKWh = newValue
                            recalculateWithNewRates()
                        }
                    )
                )
                .frame(width: 80)
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
                        set: { newValue in
                            settings.manualStandingChargePencePerDay = newValue
                            recalculateWithNewRates()
                        }
                    )
                )
                .frame(width: 80)
                Text("p/day")
                    .foregroundColor(Theme.secondaryTextColor)
                    .font(Theme.captionFont())
            }
        }
        .padding(.horizontal)
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
                }
            }
            UIApplication.shared.sendAction(
                #selector(UIResponder.resignFirstResponder),
                to: nil, from: nil, for: nil)
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
                }
            }
            activeTextField = nil
        }

        func textField(
            _ textField: UITextField, shouldChangeCharactersIn range: NSRange,
            replacementString string: String
        ) -> Bool {
            // Allow only numbers and decimal point
            let allowedCharacters = CharacterSet(charactersIn: "0123456789.")
            let characterSet = CharacterSet(charactersIn: string)

            // Prevent multiple decimal points
            if string == "." {
                let currentText = textField.text ?? ""
                if currentText.contains(".") {
                    return false
                }
            }

            return allowedCharacters.isSuperset(of: characterSet)
        }

        func textFieldDidChangeSelection(_ textField: UITextField) {
            // Don't update the value while typing to avoid premature recalculation
        }
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
            .padding(.horizontal, 8).padding(.vertical, 4)
            .background(color.opacity(0.2))
            .foregroundColor(color)
            .clipShape(Capsule())
    }
}

// The CollapsibleSection used in frontView
private struct CollapsibleSection<Label: View, Content: View>: View {
    private let label: () -> Label
    private let content: () -> Content
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
            .padding()
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
        df.dateFormat = "d MMMM yyyy"
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
