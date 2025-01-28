import Charts
import CoreData
import OctopusHelperShared
import SwiftUI

/// Main Detail View
@available(iOS 17.0, *)
public struct TariffComparisonDetailView: View {
    @Environment(\.dismiss) var dismiss

    // MARK: - Input Properties
    let selectedPlanCode: String
    let fullTariffCode: String
    let isManualPlan: Bool
    let manualRatePencePerKWh: Double
    let manualStandingChargePencePerDay: Double
    let selectedProduct: NSManagedObject?

    @ObservedObject var globalSettings: GlobalSettingsManager
    @ObservedObject var compareTariffVM: TariffViewModel
    @ObservedObject var consumptionVM: ConsumptionViewModel
    @ObservedObject var ratesVM: RatesViewModel

    @Binding var currentDate: Date
    @Binding var selectedInterval: CompareIntervalType
    @Binding var overlapStart: Date?
    @Binding var overlapEnd: Date?

    // MARK: - State for Calculations & Data
    @State private var showContent = false

    /// Holds the official account data (decoded from JSON in GlobalSettings)
    @State private var accountData: OctopusAccountResponse? = nil

    /// The combined monthly calculations for both "savedAccount" and "compare" tariff
    @State private var monthlyCalculations: MonthlyCalculationsData? = nil
    @State private var isCalculatingMonthly = false
    @State private var monthlyCalculationError: Error? = nil

    /// Summaries for the entire overlap period (sums of monthly)
    @State private var accountTotals: TariffViewModel.TariffCalculation?
    @State private var compareTotals: TariffViewModel.TariffCalculation?

    /// Rate analysis data
    @State private var isFetchingRateAnalysis = false
    @State private var rateAnalysisError: Error? = nil
    @State private var currentStandingCharge: Double = 0.0
    @State private var highestRate: Double = 0.0
    @State private var lowestRate: Double = 0.0

    /// For monthly trends chart
    @State private var monthlyRates: [MonthlyRate] = []
    @State private var isCalculatingMonthlyRates = false
    @State private var monthlyRatesError: Error? = nil

    /// Helper for showing a user-friendly name of the compared plan
    private var comparedPlanName: String {
        if isManualPlan {
            return "Manual Plan"
        } else if let product = selectedProduct,
            let displayName = product.value(forKey: "display_name") as? String
        {
            return displayName
        } else {
            return "Compared Plan"
        }
    }

    // MARK: - Initialization
    public init(
        selectedPlanCode: String,
        fullTariffCode: String,
        isManualPlan: Bool,
        manualRatePencePerKWh: Double,
        manualStandingChargePencePerDay: Double,
        selectedProduct: NSManagedObject?,
        globalSettings: GlobalSettingsManager,
        compareTariffVM: TariffViewModel,
        consumptionVM: ConsumptionViewModel,
        ratesVM: RatesViewModel,
        currentDate: Binding<Date>,
        selectedInterval: Binding<CompareIntervalType>,
        overlapStart: Binding<Date?>,
        overlapEnd: Binding<Date?>
    ) {
        self.selectedPlanCode = selectedPlanCode
        self.fullTariffCode = fullTariffCode
        self.isManualPlan = isManualPlan
        self.manualRatePencePerKWh = manualRatePencePerKWh
        self.manualStandingChargePencePerDay = manualStandingChargePencePerDay
        self.selectedProduct = selectedProduct

        self.globalSettings = globalSettings
        self.compareTariffVM = compareTariffVM
        self.consumptionVM = consumptionVM
        self.ratesVM = ratesVM

        self._currentDate = currentDate
        self._selectedInterval = selectedInterval
        self._overlapStart = overlapStart
        self._overlapEnd = overlapEnd
    }

    // MARK: - Body
    public var body: some View {
        ScrollView {
            VStack(spacing: 20) {

                // Header
                headerSection
                    .opacity(showContent ? 1 : 0)
                    .offset(y: showContent ? 0 : 20)

                // Quick Comparison Card
                ComparisonInsightCard(
                    accountTotals: accountTotals,
                    compareTotals: compareTotals,
                    isCalculating: isCalculatingMonthly,
                    error: monthlyCalculationError,
                    showVAT: globalSettings.settings.showRatesWithVAT,
                    comparedPlanName: comparedPlanName,
                    overlapDateRange: monthlyCalculations?.dateRange
                )
                .opacity(showContent ? 1 : 0)
                .offset(y: showContent ? 0 : 20)

                // Rate Analysis Card
                RateAnalysisCard(
                    isManualPlan: isManualPlan,
                    manualStandingChargePencePerDay: manualStandingChargePencePerDay,
                    fullTariffCode: fullTariffCode,
                    currentStandingCharge: currentStandingCharge,
                    highestRate: highestRate,
                    lowestRate: lowestRate,
                    compareTotals: compareTotals,
                    isFetching: isFetchingRateAnalysis,
                    error: rateAnalysisError,
                    showVAT: globalSettings.settings.showRatesWithVAT
                )
                .opacity(showContent ? 1 : 0)
                .offset(y: showContent ? 0 : 20)

                // Monthly Comparison Table
                MonthlyComparisonTable(
                    monthlyCalculations: monthlyCalculations,
                    isCalculating: isCalculatingMonthly,
                    showVAT: globalSettings.settings.showRatesWithVAT
                )
                .opacity(showContent ? 1 : 0)
                .offset(y: showContent ? 0 : 20)

                // Monthly Trends Card
                MonthlyTrendsCard(
                    monthlyRates: monthlyRates,
                    isManualPlan: isManualPlan,
                    manualRatePencePerKWh: manualRatePencePerKWh,
                    showVAT: globalSettings.settings.showRatesWithVAT
                )
                .opacity(showContent ? 1 : 0)
                .offset(y: showContent ? 0 : 20)

            }
            .padding(.horizontal)
            .padding(.top)
        }
        .background(Theme.mainBackground)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .principal) {
                Text("Plan Details")
                    .font(Theme.titleFont())
                    .foregroundColor(Theme.mainTextColor)
            }
            ToolbarItem(placement: .navigationBarTrailing) {
                Button {
                    withAnimation(.spring(duration: 0.3)) {
                        dismiss()
                    }
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundColor(Theme.secondaryTextColor.opacity(0.9))
                        .imageScale(.large)
                }
            }
        }
        .onAppear {
            withAnimation(.easeOut(duration: 0.5)) {
                showContent = true
            }
        }
        // Load data in a single task
        .task {
            // 1) Load account data from GlobalSettings
            if let rawData = globalSettings.settings.accountData {
                self.accountData = try? JSONDecoder().decode(
                    OctopusAccountResponse.self, from: rawData)
            }

            // 2) Calculate monthly data for "savedAccount" vs. "compare"
            await calculateMonthlyData()

            // 3) Fetch rate analysis data
            await fetchRateAnalysis()

            // 4) Calculate monthly average rates for the chart
            await calculateMonthlyRates()
        }
    }

    // MARK: - Header Section
    private var headerSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            if isManualPlan {
                ManualPlanSummaryView(
                    manualRatePencePerKWh: manualRatePencePerKWh,
                    manualStandingChargePencePerDay: manualStandingChargePencePerDay
                )
            } else if let product = selectedProduct {
                ProductHeaderView(product: product)
            }
        }
        .padding()
        .background(
            RoundedRectangle(cornerRadius: 16)
                .fill(Theme.mainBackground)
                .shadow(color: Color.black.opacity(0.05), radius: 10, x: 0, y: 2)
        )
    }
}

// MARK: - Parent-Level Data Structures & Methods
@available(iOS 17.0, *)
extension TariffComparisonDetailView {

    /// Used to hold the final monthly calculations for both account & compare tariffs.
    struct MonthlyCalculationsData {
        let months: [(start: Date, end: Date)]
        let accountCalculations: [NSManagedObject]
        let compareCalculations: [NSManagedObject]
        let dateRange: (start: Date, end: Date)

        // We can easily compute the overall sums (for the entire date range)
        var accountTotals: TariffViewModel.TariffCalculation {
            sumMonthlyCalculations(accountCalculations)
        }
        var compareTotals: TariffViewModel.TariffCalculation {
            sumMonthlyCalculations(compareCalculations)
        }
    }

    /// Builds a mock account response for manual plans.
    private func buildMockAccountResponseForManual() -> OctopusAccountResponse {
        let now = Date()
        let dateFormatter = ISO8601DateFormatter()
        let fromStr = dateFormatter.string(from: now.addingTimeInterval(-3600 * 24 * 365))
        let toStr = dateFormatter.string(from: now.addingTimeInterval(3600 * 24 * 365))

        let manualAgreement = OctopusAgreement(
            tariff_code: "MANUAL",
            valid_from: fromStr,
            valid_to: toStr)
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
        return OctopusAccountResponse(number: "manualAccount", properties: [prop])
    }

    /// Determines the overall overlap period from consumption data / product availability.
    private func calculateOverlapPeriod() -> (Date, Date)? {
        guard
            let consumptionStart = consumptionVM.minInterval,
            let consumptionEnd = consumptionVM.maxInterval
        else {
            return nil
        }

        let startDate: Date
        if isManualPlan {
            startDate = consumptionStart
        } else if let product = selectedProduct,
            let availableFrom = product.value(forKey: "available_from") as? Date
        {
            startDate = max(consumptionStart, availableFrom)
        } else {
            startDate = consumptionStart
        }

        // The "endDate" for cost calculations is consumptionEnd (which typically means
        // data up to the end of that day).
        // We'll keep it simple and just use consumptionEnd as final.
        let endDate = consumptionEnd

        return (startDate, endDate)
    }

    /// Calculates the monthly breakdown for both "savedAccount" and "compareTariff", storing
    /// everything in `monthlyCalculations`, plus sets `accountTotals` and `compareTotals`.
    private func calculateMonthlyData() async {
        isCalculatingMonthly = true
        defer { isCalculatingMonthly = false }

        do {
            guard let (startDate, endDate) = calculateOverlapPeriod() else {
                monthlyCalculations = nil
                accountTotals = nil
                compareTotals = nil
                return
            }

            let months = breakdownDateRangeIntoMonths(start: startDate, end: endDate)

            // Prepare relevant tariff code
            let compareTariffCode = isManualPlan ? "manualPlan" : fullTariffCode
            let compareAccountData = isManualPlan ? buildMockAccountResponseForManual() : nil

            // 1) Account tariff
            let storedAccountCalcs = try await fetchStoredMonthlyCalculations(
                months: months,
                tariffCode: "savedAccount"
            )
            let allAccountCalcs = try await calculateMissingMonths(
                months: months,
                storedCalculations: storedAccountCalcs,
                tariffCode: "savedAccount",
                accountData: accountData
            )

            // 2) Compare tariff
            let storedCompareCalcs = try await fetchStoredMonthlyCalculations(
                months: months,
                tariffCode: compareTariffCode
            )
            let allCompareCalcs = try await calculateMissingMonths(
                months: months,
                storedCalculations: storedCompareCalcs,
                tariffCode: compareTariffCode,
                accountData: compareAccountData
            )

            let newData = MonthlyCalculationsData(
                months: months,
                accountCalculations: allAccountCalcs,
                compareCalculations: allCompareCalcs,
                dateRange: (startDate, endDate)
            )

            self.monthlyCalculations = newData
            self.accountTotals = newData.accountTotals
            self.compareTotals = newData.compareTotals

        } catch {
            monthlyCalculationError = error
            monthlyCalculations = nil
            accountTotals = nil
            compareTotals = nil
        }
    }

    /// Fetches standing charge, highest rate, and lowest rate for the chosen tariff.
    private func fetchRateAnalysis() async {
        isFetchingRateAnalysis = true
        defer { isFetchingRateAnalysis = false }

        do {
            // 1) Standing charge
            if isManualPlan {
                currentStandingCharge = manualStandingChargePencePerDay
            } else if let charges = try? await RatesRepository.shared.getLatestStandingCharge(
                tariffCode: fullTariffCode)
            {
                currentStandingCharge =
                    globalSettings.settings.showRatesWithVAT
                    ? charges.incVAT : charges.excVAT
            }

            // 2) Highest / lowest rate
            if !isManualPlan {
                if let rates = try? await RatesRepository.shared.fetchRatesByTariffCode(
                    fullTariffCode)
                {
                    let showVAT = globalSettings.settings.showRatesWithVAT

                    // Highest
                    if let highest = rates.max(by: { a, b in
                        let aVal =
                            (a.value(
                                forKey: showVAT ? "value_including_vat" : "value_excluding_vat")
                                as? Double) ?? 0
                        let bVal =
                            (b.value(
                                forKey: showVAT ? "value_including_vat" : "value_excluding_vat")
                                as? Double) ?? 0
                        return aVal < bVal
                    }),
                        let highestVal = highest.value(
                            forKey: showVAT ? "value_including_vat" : "value_excluding_vat")
                            as? Double
                    {
                        highestRate = highestVal
                    }

                    // Lowest
                    if let lowest = rates.min(by: { a, b in
                        let aVal =
                            (a.value(
                                forKey: showVAT ? "value_including_vat" : "value_excluding_vat")
                                as? Double) ?? 999_999
                        let bVal =
                            (b.value(
                                forKey: showVAT ? "value_including_vat" : "value_excluding_vat")
                                as? Double) ?? 999_999
                        return aVal < bVal
                    }),
                        let lowestVal = lowest.value(
                            forKey: showVAT ? "value_including_vat" : "value_excluding_vat")
                            as? Double
                    {
                        lowestRate = lowestVal
                    }
                }
            }

        } catch {
            rateAnalysisError = error
        }
    }

    // MARK: Monthly Trend Chart Data
    struct MonthlyRate: Identifiable {
        let id = UUID()
        let month: Date
        let averageRate: Double
    }

    /// Calculates the monthly average rates (time-weighted) for display in the bar chart.
    private func calculateMonthlyRates() async {
        isCalculatingMonthlyRates = true
        defer { isCalculatingMonthlyRates = false }

        do {
            guard let (startDate, endDate) = calculateOverlapPeriod() else {
                monthlyRates = []
                return
            }

            var result: [MonthlyRate] = []
            let calendar = Calendar.current

            // Step through each month in [startDate, endDate]
            var currentDate = calendar.date(
                from: calendar.dateComponents([.year, .month], from: startDate))!
            while currentDate <= endDate {
                let monthEnd = calendar.date(byAdding: .month, value: 1, to: currentDate)!

                if isManualPlan {
                    // For manual plan, it's always the same rate
                    result.append(
                        MonthlyRate(month: currentDate, averageRate: manualRatePencePerKWh)
                    )
                } else {
                    // Actual plan from DB
                    if let rates = try? await RatesRepository.shared.fetchRatesByTariffCode(
                        fullTariffCode)
                    {
                        let showVAT = globalSettings.settings.showRatesWithVAT

                        // Filter rates that overlap with [currentDate, monthEnd)
                        let monthlyRates = rates.filter { rate in
                            guard
                                let validFrom = rate.value(forKey: "valid_from") as? Date,
                                let validTo = rate.value(forKey: "valid_to") as? Date
                            else {
                                return false
                            }
                            // Overlap if validFrom < monthEnd && validTo > currentDate
                            return validFrom < monthEnd && validTo > currentDate
                        }

                        if !monthlyRates.isEmpty {
                            var totalDuration: TimeInterval = 0
                            var weightedSum: Double = 0

                            for rateObj in monthlyRates {
                                guard
                                    let validFrom = rateObj.value(forKey: "valid_from") as? Date,
                                    let validTo = rateObj.value(forKey: "valid_to") as? Date,
                                    let rateVal = rateObj.value(
                                        forKey: showVAT
                                            ? "value_including_vat" : "value_excluding_vat")
                                        as? Double
                                else {
                                    continue
                                }

                                let overlapStart = max(validFrom, currentDate)
                                let overlapEnd = min(validTo, monthEnd)
                                let duration = overlapEnd.timeIntervalSince(overlapStart)

                                totalDuration += duration
                                weightedSum += rateVal * duration
                            }

                            if totalDuration > 0 {
                                let avgRate = weightedSum / totalDuration
                                result.append(MonthlyRate(month: currentDate, averageRate: avgRate))
                            }
                        }
                    }
                }

                currentDate = monthEnd
            }

            // Update state
            self.monthlyRates = result

        } catch {
            monthlyRatesError = error
            monthlyRates = []
        }
    }
}

// MARK: - Comparison Insight Card
@available(iOS 17.0, *)
private struct ComparisonInsightCard: View {
    let accountTotals: TariffViewModel.TariffCalculation?
    let compareTotals: TariffViewModel.TariffCalculation?
    let isCalculating: Bool
    let error: Error?
    let showVAT: Bool
    let comparedPlanName: String
    let overlapDateRange: (start: Date, end: Date)?

    // For animated difference gauge
    @State private var animatedPercentage: Double = 0
    @State private var displayNumber: Int = 0

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Cost Comparison")
                .font(Theme.mainFont2())
                .foregroundColor(Theme.mainTextColor)

            // Reintroduce the date range below the title
            if let range = overlapDateRange {
                HStack(spacing: 6) {
                    Image(systemName: "calendar")
                        .font(.system(size: 12))
                        .foregroundColor(Theme.secondaryTextColor.opacity(0.8))
                    Text(formatDateRange(start: range.start, end: range.end))
                        .font(.system(size: 14))
                        .foregroundColor(Theme.secondaryTextColor)
                }
            }

            if let error = error {
                errorView(error)
            } else if isCalculating {
                loadingView
            } else if let acct = accountTotals, let cmp = compareTotals {
                contentView(acct: acct, cmp: cmp)
            }
        }
        .padding()
        .background(
            RoundedRectangle(cornerRadius: 16)
                .fill(Theme.mainBackground)
                .shadow(color: Color.black.opacity(0.05), radius: 10, x: 0, y: 2)
        )
    }

    private func contentView(
        acct: TariffViewModel.TariffCalculation,
        cmp: TariffViewModel.TariffCalculation
    ) -> some View {
        let accountCostDV = showVAT ? acct.costIncVAT : acct.costExcVAT
        let compareCostDV = showVAT ? cmp.costIncVAT : cmp.costExcVAT
        let diff = compareCostDV - accountCostDV

        return HStack(spacing: 20) {
            ZStack {
                Circle()
                    .stroke(Theme.secondaryTextColor.opacity(0.2), lineWidth: 8)
                Circle()
                    .trim(from: 0, to: animatedPercentage)
                    .stroke(
                        diff > 0 ? Color.red : Color.green,
                        style: StrokeStyle(lineWidth: 8, lineCap: .round)
                    )
                    .rotationEffect(.degrees(-90))

                VStack(spacing: 4) {
                    Text(diff > 0 ? "More" : "Savings")
                        .font(Theme.subFont())
                        .foregroundColor(Theme.secondaryTextColor)
                    Text("£\(displayNumber)")
                        .font(Theme.mainFont())
                        .foregroundColor(diff > 0 ? .red : .green)
                }
            }
            .frame(width: 100, height: 100)
            .task {
                // Animate
                withAnimation(.spring(duration: 1.5, bounce: 0.2)) {
                    animatedPercentage = calculateSavingsPercentage(
                        diff: diff, accountCost: accountCostDV)
                }
                await startNumberAnimation(diff: diff)
            }

            VStack(alignment: .leading, spacing: 8) {
                costBreakdownRow(
                    label: "My Account", cost: accountCostDV, color: Theme.secondaryTextColor)
                costBreakdownRow(
                    label: comparedPlanName, cost: compareCostDV, color: Theme.mainColor)

                if let pctString = calculateSavingsPercentageString(
                    diff: diff, accountCost: accountCostDV)
                {
                    Text(pctString)
                        .font(Theme.subFont())
                        .foregroundColor(Theme.secondaryTextColor)
                }
            }
        }
    }

    private var loadingView: some View {
        HStack {
            Spacer()
            VStack(spacing: 8) {
                ProgressView()
                Text("Calculating costs...")
                    .font(Theme.subFont())
                    .foregroundColor(Theme.secondaryTextColor)
            }
            Spacer()
        }
    }

    private func errorView(_ error: Error) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundColor(.red)
                Text("Error")
                    .font(Theme.mainFont())
                    .foregroundColor(.red)
            }
            Text(error.localizedDescription)
                .font(Theme.subFont())
                .foregroundColor(Theme.secondaryTextColor)
        }
        .padding()
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(Color.red.opacity(0.1))
        )
    }

    // MARK: - Animations
    private func startNumberAnimation(diff: Double) async {
        let absValuePounds = abs(diff) / 100.0
        let targetValue = Int(round(absValuePounds))
        displayNumber = 0

        let duration: TimeInterval = 1.5
        let steps = min(max(targetValue, 20), 50)
        let stepDuration = duration / TimeInterval(steps)

        for step in 1...steps {
            try? await Task.sleep(for: .milliseconds(Int(stepDuration * 1000)))
            displayNumber = Int(round((Double(step) / Double(steps)) * Double(targetValue)))
        }
        displayNumber = targetValue
    }

    private func calculateSavingsPercentage(diff: Double, accountCost: Double) -> Double {
        guard accountCost > 0 else { return 0 }
        return min(abs(diff) / accountCost, 1.0)
    }

    private func calculateSavingsPercentageString(diff: Double, accountCost: Double) -> String? {
        guard accountCost > 0 else { return nil }
        let pct = abs(diff) / accountCost * 100
        let suffix = diff > 0 ? "increase" : "savings"
        return String(format: "%.1f%% \(suffix)", pct)
    }

    private func costBreakdownRow(label: String, cost: Double, color: Color) -> some View {
        HStack {
            Text(label)
                .font(Theme.titleFont())
                .foregroundColor(Theme.secondaryTextColor)
            Spacer()
            Text("£\(String(format: "%.2f", cost / 100))")
                .font(Theme.titleFont())
                .foregroundColor(color)
        }
    }

    /// Format the date range as short or medium style
    private func formatDateRange(start: Date, end: Date) -> String {
        let df = DateFormatter()
        df.dateStyle = .medium

        // If in same year, only show year once
        let calendar = Calendar.current
        if calendar.component(.year, from: start) == calendar.component(.year, from: end) {
            df.setLocalizedDateFormatFromTemplate("d MMM")
            let s = df.string(from: start)
            df.setLocalizedDateFormatFromTemplate("d MMM yyyy")
            let e = df.string(from: end)
            return "\(s) - \(e)"
        }
        return "\(df.string(from: start)) - \(df.string(from: end))"
    }
}

// MARK: - Rate Analysis Card
@available(iOS 17.0, *)
private struct RateAnalysisCard: View {
    let isManualPlan: Bool
    let manualStandingChargePencePerDay: Double
    let fullTariffCode: String

    let currentStandingCharge: Double
    let highestRate: Double
    let lowestRate: Double
    let compareTotals: TariffViewModel.TariffCalculation?

    let isFetching: Bool
    let error: Error?
    let showVAT: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Rate Analysis")
                .font(Theme.mainFont2())
                .foregroundColor(Theme.mainTextColor)

            if let error = error {
                errorView(error)
            } else if isFetching {
                loadingView()
            } else {
                rateDetails()
            }
        }
        .padding()
        .background(
            RoundedRectangle(cornerRadius: 16)
                .fill(Theme.mainBackground)
                .shadow(color: Color.black.opacity(0.05), radius: 10, x: 0, y: 2)
        )
    }

    private func rateDetails() -> some View {
        VStack(spacing: 12) {
            // Show Average Rate if we have comparison totals
            if let c = compareTotals {
                let totalKWh = c.totalKWh
                let stand = showVAT ? c.standingChargeIncVAT : c.standingChargeExcVAT
                let cost = showVAT ? c.costIncVAT : c.costExcVAT
                let avgRate = totalKWh > 0 ? (cost - stand) / totalKWh : 0
                rateRow(label: "Average Rate", value: avgRate, icon: "chart.line.flattrend.xyaxis")
            }

            // Show Manual Plan text if applicable
            if isManualPlan {
                Text("Manual Plan: Fixed Rate")
                    .font(Theme.subFont())
                    .foregroundColor(Theme.secondaryTextColor)
            } else {
                // Only show highest/lowest rates for non-manual plans
                rateRow(label: "Highest Rate", value: highestRate, icon: "arrow.up.circle")
                rateRow(label: "Lowest Rate", value: lowestRate, icon: "arrow.down.circle")
            }

            let sc = isManualPlan ? manualStandingChargePencePerDay : currentStandingCharge
            rateRow(label: "Standing Charge", value: sc, icon: "clock", isDaily: true)
        }
    }

    private func loadingView() -> some View {
        HStack {
            Spacer()
            VStack(spacing: 8) {
                ProgressView()
                Text("Fetching rate analysis...")
                    .font(Theme.subFont())
                    .foregroundColor(Theme.secondaryTextColor)
            }
            Spacer()
        }
    }

    private func errorView(_ error: Error) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundColor(.red)
                Text("Error")
                    .font(Theme.mainFont())
                    .foregroundColor(.red)
            }
            Text(error.localizedDescription)
                .font(Theme.subFont())
                .foregroundColor(Theme.secondaryTextColor)
        }
        .padding()
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(Color.red.opacity(0.1))
        )
    }

    private func rateRow(label: String, value: Double, icon: String, isDaily: Bool = false)
        -> some View
    {
        HStack {
            Image(systemName: icon)
                .foregroundColor(Theme.icon)
                .frame(width: 24)
            Text(label)
                .font(Theme.subFont())
                .foregroundColor(Theme.secondaryTextColor)
            Spacer()
            Text("\(String(format: "%.2f", value))p\(isDaily ? "/day" : "/kWh")")
                .font(Theme.subFont())
                .foregroundColor(Theme.mainTextColor)
        }
    }
}

// MARK: - Monthly Trends Card
@available(iOS 17.0, *)
private struct MonthlyTrendsCard: View {
    let monthlyRates: [TariffComparisonDetailView.MonthlyRate]

    let isManualPlan: Bool
    let manualRatePencePerKWh: Double
    let showVAT: Bool

    // Chart interaction states
    @State private var hoveredMonth: Date? = nil
    @State private var hoveredRate: Double? = nil
    @State private var lastSnappedMonth: Date? = nil

    private let hapticFeedback = UIImpactFeedbackGenerator(style: .light)

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Monthly Average Rates")
                .font(Theme.mainFont2())
                .foregroundColor(Theme.mainTextColor)

            if monthlyRates.isEmpty {
                Text("No monthly rate data available")
                    .font(Theme.secondaryFont())
                    .foregroundStyle(Theme.secondaryTextColor)
            } else {
                chartView
                    .frame(height: 200)
            }
        }
        .padding()
        .background(
            RoundedRectangle(cornerRadius: 16)
                .fill(Theme.mainBackground)
                .shadow(color: Color.black.opacity(0.05), radius: 10, x: 0, y: 2)
        )
    }

    private var chartView: some View {
        let range = yRange(monthlyRates)
        let minVal = range.0
        let maxVal = range.1

        // Simple dynamic bar width
        let count = Double(monthlyRates.count)
        let baseWidthPerBar = 5.0
        let barGapRatio = 0.7
        let maxPossibleBars = 65.0
        let totalChunk = (maxPossibleBars / count) * baseWidthPerBar
        let barWidth = totalChunk * barGapRatio

        return Chart(monthlyRates) { dataPoint in
            BarMark(
                x: .value("Month", dataPoint.month),
                y: .value("Rate", dataPoint.averageRate),
                width: .fixed(barWidth)
            )
            .foregroundStyle(dataPoint.averageRate < 0 ? Theme.secondaryColor : Theme.mainColor)
            .cornerRadius(4)
        }
        .chartYScale(domain: minVal...maxVal)
        .chartXAxis {
            AxisMarks(values: .stride(by: .month)) { _ in
                AxisGridLine()
                    .foregroundStyle(Theme.secondaryTextColor.opacity(0.1))
            }
        }
        .chartYAxis {
            AxisMarks { _ in
                AxisGridLine()
                    .foregroundStyle(Theme.secondaryTextColor.opacity(0.1))
            }
        }
        .chartXScale(range: .plotDimension(padding: 0))
        .chartPlotStyle { plotContent in
            plotContent
                .padding(.horizontal, 0)
                .padding(.leading, 16)
        }
        .chartOverlay { proxy in
            GeometryReader { geo in
                Rectangle()
                    .fill(.clear)
                    .contentShape(Rectangle())
                    .gesture(
                        DragGesture(minimumDistance: 0)
                            .onChanged { drag in
                                handleDragChanged(drag, proxy: proxy, geo: geo)
                            }
                            .onEnded { _ in
                                hoveredMonth = nil
                                hoveredRate = nil
                                lastSnappedMonth = nil
                            }
                    )

                if let month = hoveredMonth,
                    let rate = hoveredRate,
                    let xPos = proxy.position(forX: month),
                    let plotFrame = proxy.plotFrame
                {
                    let rect = geo[plotFrame]

                    // Vertical highlight
                    Rectangle()
                        .fill(Theme.mainColor.opacity(0.3))
                        .frame(width: 2, height: rect.height)
                        .position(x: rect.minX + xPos, y: rect.midY)

                    // Tooltip
                    VStack(alignment: .leading, spacing: 4) {
                        Text(formatMonth(month))
                            .font(Theme.subFont())
                        Text("\(String(format: "%.1f", rate))p avg")
                            .font(Theme.subFont())
                    }
                    .padding(6)
                    .background(Theme.secondaryBackground)
                    .foregroundStyle(Theme.mainTextColor)
                    .cornerRadius(6)
                    .fixedSize()
                    .position(
                        x: min(max(rect.minX + xPos, rect.minX + 60), rect.maxX - 60),
                        y: rect.minY + 20
                    )
                }
            }
        }
    }

    private func handleDragChanged(
        _ drag: DragGesture.Value,
        proxy: ChartProxy,
        geo: GeometryProxy
    ) {
        guard let plotFrame = proxy.plotFrame else { return }

        let location = drag.location
        let plotRect = geo[plotFrame]

        let clampedX = min(max(location.x, plotRect.minX), plotRect.maxX)
        let locationInPlot = CGPoint(
            x: clampedX - plotRect.minX,
            y: location.y - plotRect.minY)

        if let date: Date = proxy.value(atX: locationInPlot.x) {
            if let nearestMonth = findNearestMonth(to: date) {
                if nearestMonth != lastSnappedMonth {
                    hapticFeedback.impactOccurred(intensity: 0.7)
                    lastSnappedMonth = nearestMonth
                }
                hoveredMonth = nearestMonth
                hoveredRate =
                    monthlyRates.first {
                        Calendar.current.isDate(
                            $0.month, equalTo: nearestMonth, toGranularity: .month)
                    }?.averageRate
            }
        }
    }

    private func findNearestMonth(to date: Date) -> Date? {
        monthlyRates.min {
            abs($0.month.timeIntervalSince(date)) < abs($1.month.timeIntervalSince(date))
        }?.month
    }

    private func yRange(_ data: [TariffComparisonDetailView.MonthlyRate]) -> (Double, Double) {
        guard !data.isEmpty else { return (0, 50) }
        let vals = data.map { $0.averageRate }
        let minVal = min(0, vals.min() ?? 0) - 2
        let maxVal = (vals.max() ?? 0) + 2
        return (minVal, maxVal)
    }

    private func formatMonth(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "MMM yyyy"
        return formatter.string(from: date)
    }
}

// MARK: - Monthly Comparison Table
@available(iOS 17.0, *)
private struct MonthlyComparisonTable: View {
    struct MonthlyComparison: Identifiable {
        let id = UUID()
        let month: Date
        let consumption: Double  // kWh
        let accountCostDV: Double
        let compareCostDV: Double
        var difference: Double { compareCostDV - accountCostDV }
    }

    let monthlyCalculations: TariffComparisonDetailView.MonthlyCalculationsData?
    let isCalculating: Bool
    let showVAT: Bool

    var body: some View {
        VStack(spacing: 16) {
            HStack {
                Text("Monthly Comparison")
                    .font(Theme.mainFont2())
                    .foregroundColor(Theme.mainTextColor)
                Spacer()
            }

            if isCalculating {
                loadingView
            } else if let data = monthlyCalculations {
                // Build table data
                let tableData = buildMonthlyComparisons(data)

                // Table Header
                HStack {
                    Text("Month").frame(width: 90, alignment: .leading)
                    Text("kWh").frame(width: 60, alignment: .trailing)
                    Spacer()
                    Text("Current").frame(width: 70, alignment: .trailing)
                    Text("Compare").frame(width: 70, alignment: .trailing)
                    Text("Diff").frame(width: 70, alignment: .trailing)
                }
                .font(Theme.captionFont())
                .foregroundColor(Theme.secondaryTextColor)

                // Table Content
                VStack(spacing: 12) {
                    ForEach(tableData) { row in
                        HStack {
                            Text(formatMonth(row.month))
                                .frame(width: 90, alignment: .leading)
                            Text(formatConsumption(row.consumption))
                                .frame(width: 60, alignment: .trailing)
                            Spacer()
                            Text(formatCurrency(row.accountCostDV))
                                .frame(width: 70, alignment: .trailing)
                            Text(formatCurrency(row.compareCostDV))
                                .frame(width: 70, alignment: .trailing)
                            Text(formatDifference(row.difference))
                                .frame(width: 70, alignment: .trailing)
                                .foregroundColor(row.difference > 0 ? .red : .green)
                        }
                        .font(Theme.subFont())
                        .foregroundColor(Theme.mainTextColor)
                    }
                }
                .padding(.vertical, 8)
                .padding(.horizontal, 4)

            } else {
                Text("No monthly calculation data.")
                    .font(Theme.subFont())
                    .foregroundColor(Theme.secondaryTextColor)
            }
        }
        .padding(.vertical, 16)
        .padding(.horizontal, 4)
    }

    private func buildMonthlyComparisons(_ data: TariffComparisonDetailView.MonthlyCalculationsData)
        -> [MonthlyComparison]
    {
        // We zip the two arrays of NSManagedObject. Each array has 1 object per month in the same order.
        // But be mindful: the order is not guaranteed unless we sort them. Let's assume they are in ascending date order, or else sort them.

        let showVatKey = showVAT ? "total_cost_inc_vat" : "total_cost_exc_vat"

        // Sort by period_start in descending order
        let accountSorted = data.accountCalculations.sorted {
            guard
                let a = $0.value(forKey: "period_start") as? Date,
                let b = $1.value(forKey: "period_start") as? Date
            else { return false }
            return a > b  // Changed from < to > for descending order
        }
        let compareSorted = data.compareCalculations.sorted {
            guard
                let a = $0.value(forKey: "period_start") as? Date,
                let b = $1.value(forKey: "period_start") as? Date
            else { return false }
            return a > b  // Changed from < to > for descending order
        }

        var result: [MonthlyComparison] = []
        for (acctObj, compObj) in zip(accountSorted, compareSorted) {
            let month = (acctObj.value(forKey: "period_start") as? Date) ?? Date()
            let consumption = acctObj.value(forKey: "total_consumption_kwh") as? Double ?? 0.0

            let acctCost = acctObj.value(forKey: showVatKey) as? Double ?? 0.0
            let compCost = compObj.value(forKey: showVatKey) as? Double ?? 0.0

            let entry = MonthlyComparison(
                month: month,
                consumption: consumption,
                accountCostDV: acctCost,
                compareCostDV: compCost
            )
            result.append(entry)
        }

        return result
    }

    private var loadingView: some View {
        HStack {
            Spacer()
            VStack(spacing: 8) {
                ProgressView()
                Text("Calculating monthly breakdown...")
                    .font(Theme.subFont())
                    .foregroundColor(Theme.secondaryTextColor)
            }
            Spacer()
        }
    }

    // MARK: - Formatting
    private func formatMonth(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "MMM yyyy"
        return formatter.string(from: date)
    }

    private func formatConsumption(_ kwh: Double) -> String {
        String(format: "%.0f", kwh)
    }

    private func formatCurrency(_ amount: Double) -> String {
        String(format: "£%.2f", amount / 100)
    }

    private func formatDifference(_ amount: Double) -> String {
        String(format: "%@£%.2f", amount >= 0 ? "+" : "", amount / 100)
    }
}

// MARK: - Product Header View
@available(iOS 17.0, *)
private struct ProductHeaderView: View {
    let product: NSManagedObject
    @Environment(\.dismiss) var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            // Close button
            HStack {
                Spacer()
                Button {
                    dismiss()
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundColor(Theme.secondaryTextColor.opacity(0.9))
                        .imageScale(.medium)
                        .font(.system(size: 24))
                }
            }

            // Product name and badges
            VStack(alignment: .leading, spacing: 8) {
                if let displayName = product.value(forKey: "display_name") as? String {
                    Text(displayName)
                        .font(.system(size: 36))
                        .foregroundColor(Theme.mainTextColor)
                }
                HStack(spacing: 8) {
                    if (product.value(forKey: "is_green") as? Bool) == true {
                        BadgeView("Green", color: .green)
                    }
                    if (product.value(forKey: "is_tracker") as? Bool) == true {
                        BadgeView("Tracker", color: .blue)
                    }
                    if (product.value(forKey: "is_variable") as? Bool) == true {
                        BadgeView("Variable", color: .orange)
                    }
                }
            }

            // Product description
            if let desc = product.value(forKey: "desc") as? String {
                Text(desc)
                    .font(.system(size: 17))
                    .foregroundColor(Theme.secondaryTextColor)
                    .lineSpacing(4)
            }

            // Availability info
            if let availableFrom = product.value(forKey: "available_from") as? Date {
                Text("Available from: \(formatDate(availableFrom))")
                    .font(.system(size: 16))
                    .foregroundColor(Theme.secondaryTextColor)

                if let availableTo = product.value(forKey: "available_to") as? Date,
                    Calendar.current.component(.year, from: availableTo) < 2100
                {
                    Text("Available to: \(formatDate(availableTo))")
                        .font(.system(size: 16))
                        .foregroundColor(Theme.secondaryTextColor)
                }
            }
        }
    }

    private func formatDate(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        return formatter.string(from: date)
    }
}

// MARK: - Manual Plan Summary
@available(iOS 17.0, *)
private struct ManualPlanSummaryView: View {
    let manualRatePencePerKWh: Double
    let manualStandingChargePencePerDay: Double
    @Environment(\.dismiss) var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            // Close button
            HStack {
                Spacer()
                Button {
                    dismiss()
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundColor(Theme.secondaryTextColor.opacity(0.9))
                        .imageScale(.medium)
                        .font(.system(size: 24))
                }
            }

            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 4) {
                    Text("Manual Plan")
                        .font(.system(size: 36))
                        .foregroundColor(Theme.mainTextColor)
                }

                BadgeView("Fixed Rate", color: .purple)

                Text(
                    "\(String(format: "%.1f", manualRatePencePerKWh))p/kWh + \(String(format: "%.1f", manualStandingChargePencePerDay))p/day"
                )
                .font(.system(size: 17))
                .foregroundColor(Theme.secondaryTextColor)
                .padding(.top, 8)
            }
        }
    }
}

// MARK: - Badge View
@available(iOS 17.0, *)

// MARK: - Helper Calculation Functions
@MainActor
private let calculationRepository = TariffCalculationRepository(
    consumptionRepository: .shared,
    ratesRepository: .shared
)

/// Breaks a given date range into a list of month intervals.
func breakdownDateRangeIntoMonths(start: Date, end: Date) -> [(start: Date, end: Date)] {
    var months: [(start: Date, end: Date)] = []
    let calendar = Calendar.current

    var currentDate = start
    while currentDate < end {
        // Start of the month
        let monthStart = calendar.date(
            from: calendar.dateComponents([.year, .month], from: currentDate))!
        let nextMonth = calendar.date(byAdding: .month, value: 1, to: monthStart)!
        let monthEnd = min(nextMonth, end)

        months.append((start: max(monthStart, start), end: monthEnd))
        currentDate = nextMonth
    }
    return months
}

/// Fetch any monthly calculation objects already in Core Data.
func fetchStoredMonthlyCalculations(
    months: [(start: Date, end: Date)],
    tariffCode: String
) async throws -> [NSManagedObject] {
    var stored: [NSManagedObject] = []
    for month in months {
        if let calc = try await calculationRepository.fetchStoredCalculation(
            tariffCode: tariffCode,
            intervalType: "MONTHLY",
            periodStart: month.start,
            periodEnd: month.end
        ) {
            stored.append(calc)
        }
    }
    return stored
}

/// For each month, if there's no stored calculation, perform a new calculation.
func calculateMissingMonths(
    months: [(start: Date, end: Date)],
    storedCalculations: [NSManagedObject],
    tariffCode: String,
    accountData: OctopusAccountResponse? = nil
) async throws -> [NSManagedObject] {
    var all = storedCalculations

    for month in months {
        let hasMonth = storedCalculations.contains { calc in
            (calc.value(forKey: "period_start") as? Date) == month.start
                && (calc.value(forKey: "period_end") as? Date) == month.end
        }
        if !hasMonth {
            let calc: NSManagedObject
            if tariffCode == "savedAccount" {
                guard let accData = accountData else { continue }
                let results = try await calculationRepository.calculateCostForAccount(
                    accountData: accData,
                    startDate: month.start,
                    endDate: month.end,
                    intervalType: "MONTHLY"
                )
                guard let first = results.first else { continue }
                calc = first
            } else {
                calc = try await calculationRepository.calculateCostForPeriod(
                    tariffCode: tariffCode,
                    startDate: month.start,
                    endDate: month.end,
                    intervalType: "MONTHLY"
                )
            }
            all.append(calc)
        }
    }

    return all
}

/// Sums an array of monthly calculation objects into a single TariffCalculation struct.
func sumMonthlyCalculations(_ calculations: [NSManagedObject]) -> TariffViewModel.TariffCalculation
{
    var totalKWh = 0.0
    var totalCostExcVAT = 0.0
    var totalCostIncVAT = 0.0
    var totalStandingChargeExcVAT = 0.0
    var totalStandingChargeIncVAT = 0.0

    for calc in calculations {
        totalKWh += calc.value(forKey: "total_consumption_kwh") as? Double ?? 0
        totalCostExcVAT += calc.value(forKey: "total_cost_exc_vat") as? Double ?? 0
        totalCostIncVAT += calc.value(forKey: "total_cost_inc_vat") as? Double ?? 0
        totalStandingChargeExcVAT +=
            calc.value(forKey: "standing_charge_cost_exc_vat") as? Double ?? 0
        totalStandingChargeIncVAT +=
            calc.value(forKey: "standing_charge_cost_inc_vat") as? Double ?? 0
    }

    let avgRateExcVAT =
        totalKWh > 0
        ? (totalCostExcVAT - totalStandingChargeExcVAT) / totalKWh
        : 0.0
    let avgRateIncVAT =
        totalKWh > 0
        ? (totalCostIncVAT - totalStandingChargeIncVAT) / totalKWh
        : 0.0

    return TariffViewModel.TariffCalculation(
        periodStart: calculations.first?.value(forKey: "period_start") as? Date ?? Date(),
        periodEnd: calculations.last?.value(forKey: "period_end") as? Date ?? Date(),
        totalKWh: totalKWh,
        costExcVAT: totalCostExcVAT,
        costIncVAT: totalCostIncVAT,
        averageUnitRateExcVAT: avgRateExcVAT,
        averageUnitRateIncVAT: avgRateIncVAT,
        standingChargeExcVAT: totalStandingChargeExcVAT,
        standingChargeIncVAT: totalStandingChargeIncVAT
    )
}
