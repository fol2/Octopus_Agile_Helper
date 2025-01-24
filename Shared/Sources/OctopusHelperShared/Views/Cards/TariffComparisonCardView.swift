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
        .rotation3DEffect(.degrees(isFlipped ? 180 : 0), axis: (x: 0, y: 1, z: 0))
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
        // Re-render if app becomes active
        .onReceive(refreshManager.$sceneActiveTick) { _ in
            refreshTrigger.toggle()
        }
        .onAppear {
            Task {
                initializeFromSettings()
                updateAllowedDateRange()
                await loadComparisonPlansIfNeeded()
                await recalcBothTariffs(partialOverlap: true)
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
        .onChange(of: consumptionVM.fetchState) { oldState, newState in
            if case .success = newState {
                Task {
                    await recalcBothTariffs(partialOverlap: true)
                }
            }
        }
    }

    // MARK: - FRONT VIEW (Main UI)
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
                            globalSettings: globalSettings
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
                    globalSettings: globalSettings
                )
                .padding(.horizontal)
                Divider().padding(.horizontal).padding(.vertical, 2)

                // Comparison results
                comparisonResultsView
            }
        }
    }

    // MARK: - BACK VIEW (Plan Info)
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
                    .rotation3DEffect(.degrees(180), axis: (x: 0, y: 1, z: 0))
            } else if let product = availablePlans.first(where: {
                ($0.value(forKey: "code") as? String) == compareSettings.settings.selectedPlanCode
            }) {
                ProductDetailView(product: product)
                    .rotation3DEffect(.degrees(180), axis: (x: 0, y: 1, z: 0))
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
                .rotation3DEffect(.degrees(180), axis: (x: 0, y: 1, z: 0))
            }
        }
        .padding(.horizontal)
        .padding(.top, 8)
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
        } else if !hasDateOverlap {
            noOverlapView
        } else {
            let acctCalc = accountTariffVM.currentCalculation
            let cmpCalc = compareTariffVM.currentCalculation

            if acctCalc == nil || cmpCalc == nil {
                HStack {
                    Spacer()
                    Text("Loading calculations...")
                        .font(Theme.secondaryFont())
                        .foregroundColor(Theme.secondaryTextColor)
                    Spacer()
                }
                .padding(.vertical, 12)
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
                    }
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
        minAllowedDate = consumptionVM.minInterval
        maxAllowedDate = consumptionVM.maxInterval

        if let mn = minAllowedDate, currentDate < mn {
            currentDate = mn
        }
        if let mx = maxAllowedDate, currentDate > mx {
            currentDate = mx
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
        // Default to true for partial overlap to ensure fair comparison
        async let acctCalc = recalcAccountTariff(partialOverlap: partialOverlap)
        async let cmpCalc = recalcCompareTariff(partialOverlap: partialOverlap)
        _ = await (acctCalc, cmpCalc)
    }

    @MainActor
    private func recalcAccountTariff(partialOverlap: Bool) async {
        if !hasAccountInfo { return }
        guard !consumptionVM.consumptionRecords.isEmpty else { return }

        do {
            let (start, end) = TariffViewModel().calculateDateRange(
                for: currentDate,
                intervalType: selectedInterval.vmInterval,
                billingDay: globalSettings.settings.billingDay
            )

            // For account tariff, we use consumption data range as validity period
            let (overlapStart, overlapEnd) =
                partialOverlap
                ? findOverlapRange(start, end, "savedAccount")
                : (start, end)

            await accountTariffVM.calculateCosts(
                for: currentDate,
                tariffCode: "savedAccount",
                intervalType: selectedInterval.vmInterval,
                accountData: getAccountResponse(),
                partialStart: overlapStart,
                partialEnd: overlapEnd
            )
        } catch {
            DebugLogger.debug(
                "❌ Error in recalcAccountTariff: \(error.localizedDescription)",
                component: .tariffViewModel)
        }
    }

    @MainActor
    private func recalcCompareTariff(partialOverlap: Bool) async {
        guard !consumptionVM.consumptionRecords.isEmpty else {
            hasDateOverlap = false
            return
        }

        do {
            let (start, end) = TariffViewModel().calculateDateRange(
                for: currentDate,
                intervalType: selectedInterval.vmInterval,
                billingDay: globalSettings.settings.billingDay
            )
            var (overlapStart, overlapEnd) = (start, end)

            // If partialOverlap, find the date overlap with the chosen plan's validity
            if partialOverlap {
                let planRange = await fetchPlanValidityRange(
                    compareSettings.settings.selectedPlanCode)
                (overlapStart, overlapEnd) = intersectRanges(start...end, planRange)

                // If there's no intersection, skip
                if overlapEnd <= overlapStart {
                    hasDateOverlap = false
                    await compareTariffVM.resetCalculationState()
                    return
                }
            }

            hasDateOverlap = true

            if compareSettings.settings.isManualPlan {
                // Build mock account response for manual plan
                let mockAccount = buildMockAccountResponseForManual()
                await compareTariffVM.calculateCosts(
                    for: currentDate,
                    tariffCode: "manualPlan",
                    intervalType: selectedInterval.vmInterval,
                    accountData: mockAccount,
                    partialStart: overlapStart,
                    partialEnd: overlapEnd
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
                    partialStart: overlapStart,
                    partialEnd: overlapEnd
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

        // For actual plans, find the product and get its validity range
        if let product = availablePlans.first(where: {
            ($0.value(forKey: "code") as? String) == planCode
        }) {
            let from = (product.value(forKey: "available_from") as? Date) ?? Date.distantPast
            let to = (product.value(forKey: "available_to") as? Date) ?? Date.distantFuture
            return from...to
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

    var body: some View {
        HStack(spacing: 0) {
            HStack {
                if !atMin && !isCalculating {
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

            HStack {
                Spacer()
                Text(dateRangeText())
                    .font(Theme.secondaryFont())
                    .foregroundColor(Theme.mainTextColor)
                    .overlay(alignment: .bottom) {
                        if isCalculating {
                            ProgressView()
                                .scaleEffect(0.7)
                                .offset(y: 14)
                        }
                    }
                Spacer()
            }
            .frame(height: 44)

            Spacer(minLength: 0)

            HStack {
                if !atMax && !isCalculating {
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

    private var atMin: Bool {
        TariffViewModel().isDateAtMinimum(
            currentDate,
            intervalType: selectedInterval.vmInterval,
            minDate: minDate,
            billingDay: globalSettings.settings.billingDay
        )
    }

    private var atMax: Bool {
        TariffViewModel().isDateAtMaximum(
            currentDate,
            intervalType: selectedInterval.vmInterval,
            maxDate: maxDate,
            billingDay: globalSettings.settings.billingDay
        )
    }

    private func moveDate(forward: Bool) {
        if let newDate = TariffViewModel().nextDate(
            from: currentDate,
            forward: forward,
            intervalType: selectedInterval.vmInterval,
            minDate: minDate,
            maxDate: maxDate,
            billingDay: globalSettings.settings.billingDay
        ) {
            onDateChanged(newDate)
        }
    }

    private func dateRangeText() -> String {
        let (start, end) = TariffViewModel().calculateDateRange(
            for: currentDate,
            intervalType: selectedInterval.vmInterval,
            billingDay: globalSettings.settings.billingDay
        )
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_GB")

        switch selectedInterval {
        case .daily:
            formatter.dateFormat = "d MMMM yyyy"
            return formatter.string(from: start)
        case .weekly:
            formatter.dateFormat = "d MMMM yyyy"
            let endDate = Calendar.current.date(byAdding: .day, value: 6, to: start) ?? end
            return "\(formatter.string(from: start)) - \(formatter.string(from: endDate))"
        case .monthly:
            formatter.dateFormat = "LLLL yyyy"
            return formatter.string(from: start)
        case .quarterly:
            let cal = Calendar.current
            let month = cal.component(.month, from: start)
            let qStartMonth = ((month - 1) / 3) * 3 + 1
            var comps = cal.dateComponents([.year], from: start)
            comps.month = qStartMonth
            comps.day = 1
            let qStart = cal.date(from: comps) ?? start
            let qEnd = cal.date(byAdding: .month, value: 2, to: qStart) ?? end

            let df2 = DateFormatter()
            df2.dateFormat = "LLLL"
            let startName = df2.string(from: qStart)
            let endName = df2.string(from: qEnd)

            df2.dateFormat = "yyyy"
            let year = df2.string(from: qStart)
            return "\(startName) - \(endName) \(year)"
        }
    }
}

// MARK: - Subviews: Plan Selection

private struct ComparisonPlanSelectionView: View {
    @ObservedObject var compareSettings: ComparisonCardSettingsManager
    @Binding var availablePlans: [NSManagedObject]
    @ObservedObject var globalSettings: GlobalSettingsManager

    var body: some View {
        VStack(spacing: 12) {
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

    var body: some View {
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
                        averageRate: averageRate(for: accountCalculation)
                    )
                    costRow(
                        label: comparePlanLabel,
                        cost: compareCost,
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
                                .frame(width: 24, alignment: .leading)
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
    }

    private func costRow(label: String, cost: Double, averageRate: String?) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "bolt.fill")
                .foregroundColor(Theme.icon)
                .imageScale(.small)
                .opacity(0)  // placeholder for alignment
            VStack(alignment: .leading, spacing: 2) {
                HStack {
                    Text("\(label):")
                        .font(Theme.subFont())
                        .foregroundColor(Theme.secondaryTextColor)
                    Text("£\(String(format: "%.2f", cost / 100.0))")
                        .font(Theme.subFont())
                        .foregroundColor(Theme.mainTextColor)
                }
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
        let totalCost = showVAT ? calc.costIncVAT : calc.costExcVAT
        let avg = Double(totalCost) / totalKWh
        return String(format: "%.2f", avg)
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
                        if let date = group.availableDates.first(where: {
                            group.productCode(for: $0) == selectedPlanCode
                        }) {
                            HStack {
                                Text("Available from: \(group.formatDate(date))")
                                Spacer()
                                Image(systemName: "chevron.down")
                            }
                            .padding()
                            .background(Theme.mainBackground.opacity(0.3))
                            .cornerRadius(8)
                        } else {
                            Text("No specific date selected")
                        }
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

    var body: some View {
        VStack(spacing: 12) {
            HStack {
                Text("Energy Rate").foregroundColor(Theme.secondaryTextColor)
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
                Text("Daily Charge").foregroundColor(Theme.secondaryTextColor)
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

// ProductDetailView from existing code
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
    }

    private var productMeta: some View {
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
            if isLoading {
                HStack(spacing: 8) {
                    ProgressView().scaleEffect(0.8)
                    Text("Loading tariff details...")
                        .font(Theme.captionFont())
                        .foregroundColor(Theme.secondaryTextColor)
                }
            } else if let tc = tariffCode {
                Text("Tariff Code: \(tc)")
                    .font(Theme.captionFont())
                    .foregroundColor(Theme.secondaryTextColor)
            } else {
                Text("No tariff code available for your region")
                    .font(Theme.captionFont())
                    .foregroundColor(Theme.secondaryTextColor)
            }
        }
        .padding(.top, 8)
    }

    private func loadTariffCode() async {
        guard let code = product.value(forKey: "code") as? String else {
            self.loadError = TariffError.productDetailNotFound(code: "unknown", region: "n/a")
            self.isLoading = false
            return
        }
        do {
            let details = try await ProductDetailRepository.shared.loadLocalProductDetail(
                code: code)
            let region = (product.value(forKey: "region") as? String) ?? "A"
            if let detail = details.first(where: { $0.value(forKey: "region") as? String == region }
            ) {
                tariffCode = detail.value(forKey: "tariff_code") as? String
            }
            isLoading = false
        } catch {
            self.loadError = error
            self.isLoading = false
        }
    }

    private func formatDate(_ date: Date) -> String {
        let df = DateFormatter()
        df.dateStyle = .medium
        df.timeStyle = .none
        return df.string(from: date)
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
