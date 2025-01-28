import Charts
import CoreData
import OctopusHelperShared
import SwiftUI

@available(iOS 17.0, *)
// MARK: - Main Detail View
public struct TariffComparisonDetailView: View {
    @Environment(\.dismiss) var dismiss
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

    // Add new states for animations
    @State private var showContent = false
    @State private var selectedInsightTab = 0

    // New state properties for calculations and animation
    @State private var accountCalculation: TariffViewModel.TariffCalculation?
    @State private var compareCalculation: TariffViewModel.TariffCalculation?
    @State private var isCalculating = false
    @State private var error: Error?
    @State private var animatedDifference: Double = 0
    @State private var animatedPercentage: Double = 0
    @State private var displayNumber: Int = 0

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

    public var body: some View {
        ScrollView {
            VStack(spacing: 20) {
                // Header
                headerSection
                    .opacity(showContent ? 1 : 0)
                    .offset(y: showContent ? 0 : 20)

                // Quick Comparison Card
                ComparisonInsightCard(
                    showVAT: globalSettings.settings.showRatesWithVAT,
                    consumptionVM: consumptionVM,
                    selectedProduct: selectedProduct,
                    isManualPlan: isManualPlan,
                    selectedPlanCode: selectedPlanCode,
                    fullTariffCode: fullTariffCode,
                    manualRatePencePerKWh: manualRatePencePerKWh,
                    manualStandingChargePencePerDay: manualStandingChargePencePerDay,
                    globalSettings: globalSettings,
                    compareTariffVM: compareTariffVM,
                    ratesVM: ratesVM
                )
                .opacity(showContent ? 1 : 0)
                .offset(y: showContent ? 0 : 20)

                // Rate Analysis Card
                RateAnalysisCard(
                    compareTariffVM: compareTariffVM,
                    ratesVM: ratesVM,
                    showVAT: globalSettings.settings.showRatesWithVAT,
                    isManualPlan: isManualPlan,
                    manualStandingChargePencePerDay: manualStandingChargePencePerDay,
                    fullTariffCode: fullTariffCode
                )
                .opacity(showContent ? 1 : 0)
                .offset(y: showContent ? 0 : 20)

                // Monthly Trends Card
                MonthlyTrendsCard(
                    compareTariffVM: compareTariffVM,
                    consumptionVM: consumptionVM,
                    showVAT: globalSettings.settings.showRatesWithVAT,
                    selectedProduct: selectedProduct,
                    isManualPlan: isManualPlan,
                    manualRatePencePerKWh: manualRatePencePerKWh,
                    fullTariffCode: fullTariffCode
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

// MARK: - Comparison Insight Card
@MainActor
private struct ComparisonInsightCard: View {
    private let calculationRepository = TariffCalculationRepository(
        consumptionRepository: .shared,
        ratesRepository: .shared
    )
    let showVAT: Bool
    @ObservedObject var consumptionVM: ConsumptionViewModel
    let selectedProduct: NSManagedObject?
    let isManualPlan: Bool
    let selectedPlanCode: String
    let fullTariffCode: String
    let manualRatePencePerKWh: Double
    let manualStandingChargePencePerDay: Double
    @ObservedObject var globalSettings: GlobalSettingsManager
    @ObservedObject var compareTariffVM: TariffViewModel
    @ObservedObject var ratesVM: RatesViewModel

    // New state properties for calculations and animation
    @State private var accountCalculation: TariffViewModel.TariffCalculation?
    @State private var compareCalculation: TariffViewModel.TariffCalculation?
    @State private var isCalculating = false
    @State private var error: Error?
    @State private var animatedDifference: Double = 0
    @State private var animatedPercentage: Double = 0
    @State private var displayNumber: Int = 0

    private func calculateOverlapPeriod() -> (start: Date, end: Date)? {
        // Get consumption data range
        guard let consumptionStart = consumptionVM.minInterval,
            let consumptionEnd = consumptionVM.maxInterval
        else {
            DebugLogger.shared.log(
                "⚠️ calculatedOverlapPeriod: Missing consumption data",
                details: [
                    "minInterval": String(describing: consumptionVM.minInterval),
                    "maxInterval": String(describing: consumptionVM.maxInterval),
                ]
            )
            return nil
        }

        // Calculate start date
        let startDate: Date
        if isManualPlan {
            startDate = consumptionStart
            DebugLogger.shared.log(
                "📅 Using manual plan start date",
                details: ["startDate": startDate]
            )
        } else if let product = selectedProduct,
            let availableFrom = product.value(forKey: "available_from") as? Date
        {
            startDate = max(consumptionStart, availableFrom)
            DebugLogger.shared.log(
                "📅 Using product start date",
                details: [
                    "startDate": startDate,
                    "availableFrom": availableFrom,
                    "consumptionStart": consumptionStart,
                ]
            )
        } else {
            startDate = consumptionStart
            DebugLogger.shared.log(
                "📅 Using consumption start date",
                details: ["startDate": startDate]
            )
        }

        // For end date, we use consumptionEnd for calculation
        // but display the previous day since consumptionEnd represents the end of that day's data
        let calendar = Calendar.current
        let displayEndDate =
            calendar.date(byAdding: .day, value: -1, to: consumptionEnd) ?? consumptionEnd

        DebugLogger.shared.log(
            "📅 End date",
            details: [
                "consumptionEnd": consumptionEnd,
                "displayEndDate": displayEndDate,
            ]
        )

        return (startDate, displayEndDate)
    }

    private func calculateCosts() async {
        guard let (startDate, endDate) = calculateOverlapPeriod() else {
            DebugLogger.shared.log(
                "⚠️ No valid overlap period found",
                details: ["error": "Could not calculate overlap period"]
            )
            return
        }

        // Get standing charges using the new repository function
        let standingCharges =
            if isManualPlan {
                (excVAT: manualStandingChargePencePerDay, incVAT: manualStandingChargePencePerDay)
            } else if let charges = try? await RatesRepository.shared.getLatestStandingCharge(
                tariffCode: fullTariffCode)
            {
                charges
            } else {
                (excVAT: 0.0, incVAT: 0.0)
            }

        DebugLogger.shared.log(
            "🔄 Starting cost calculation",
            details: [
                "startDate": startDate.description,
                "endDate": endDate.description,
                "isManualPlan": isManualPlan,
                "selectedPlanCode": selectedPlanCode,
                "fullTariffCode": fullTariffCode,
                "showVAT": showVAT,
                "standingChargeExcVAT": String(standingCharges.excVAT),
                "standingChargeIncVAT": String(standingCharges.incVAT),
            ]
        )

        isCalculating = true
        defer { isCalculating = false }

        do {
            // Get account data for savedAccount tariff
            let accountData: OctopusAccountResponse?
            if let rawData = globalSettings.settings.accountData {
                accountData = try JSONDecoder().decode(OctopusAccountResponse.self, from: rawData)
                DebugLogger.shared.log(
                    "📊 Account data loaded",
                    details: [
                        "accountNumber": accountData?.number ?? "N/A",
                        "propertiesCount": String(accountData?.properties.count ?? 0),
                    ]
                )
            } else {
                accountData = nil
                DebugLogger.shared.log(
                    "⚠️ No account data available",
                    details: ["status": "No account data found"]
                )
            }

            // Calculate for account tariff
            let months = breakdownDateRangeIntoMonths(start: startDate, end: endDate)
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
            accountCalculation = sumMonthlyCalculations(allAccountCalcs)

            // Calculate for comparison tariff
            let tariffCode = isManualPlan ? "manualPlan" : fullTariffCode
            let compareAccountData = isManualPlan ? buildMockAccountResponseForManual() : nil

            let storedCompareCalcs = try await fetchStoredMonthlyCalculations(
                months: months,
                tariffCode: tariffCode
            )
            let allCompareCalcs = try await calculateMissingMonths(
                months: months,
                storedCalculations: storedCompareCalcs,
                tariffCode: tariffCode,
                accountData: compareAccountData
            )
            compareCalculation = sumMonthlyCalculations(allCompareCalcs)

            // Log results
            if let acct = accountCalculation {
                DebugLogger.shared.log(
                    "💰 Account tariff calculation completed",
                    details: [
                        "totalKWh": String(acct.totalKWh),
                        "costExcVAT": String(acct.costExcVAT),
                        "costIncVAT": String(acct.costIncVAT),
                        "avgRateExcVAT": String(acct.averageUnitRateExcVAT),
                        "avgRateIncVAT": String(acct.averageUnitRateIncVAT),
                        "standingChargeExcVAT": String(acct.standingChargeExcVAT),
                        "standingChargeIncVAT": String(acct.standingChargeIncVAT),
                    ]
                )
            }

            if let comp = compareCalculation {
                DebugLogger.shared.log(
                    "💰 Compare tariff calculation completed",
                    details: [
                        "tariffCode": tariffCode,
                        "totalKWh": String(comp.totalKWh),
                        "costExcVAT": String(comp.costExcVAT),
                        "costIncVAT": String(comp.costIncVAT),
                        "avgRateExcVAT": String(comp.averageUnitRateExcVAT),
                        "avgRateIncVAT": String(comp.averageUnitRateIncVAT),
                        "standingChargeExcVAT": String(comp.standingChargeExcVAT),
                        "standingChargeIncVAT": String(comp.standingChargeIncVAT),
                    ]
                )
            }

            // Log cost comparison
            let costDiff = costDifference
            DebugLogger.shared.log(
                "💡 Cost comparison",
                details: [
                    "difference": String(costDiff),
                    "percentageDifference": String(calculateSavingsPercentage() * 100),
                    "showingVAT": String(showVAT),
                ]
            )
        } catch let apiError as OctopusAPIError {
            self.error = apiError
            DebugLogger.shared.log(
                "❌ API Error calculating costs",
                details: [
                    "error": apiError.localizedDescription,
                    "errorType": "OctopusAPIError",
                ]
            )
        } catch {
            self.error = error
            DebugLogger.shared.log(
                "❌ Error calculating costs",
                details: [
                    "error": error.localizedDescription,
                    "errorType": String(describing: type(of: error)),
                ]
            )
        }
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

    private var accountCostDV: Double {
        guard let calc = accountCalculation else { return 0 }
        return showVAT ? calc.costIncVAT : calc.costExcVAT
    }

    private var compareCostDV: Double {
        guard let calc = compareCalculation else { return 0 }
        return showVAT ? calc.costIncVAT : calc.costExcVAT
    }

    private var costDifference: Double {
        compareCostDV - accountCostDV
    }

    private func calculateSavingsPercentage() -> Double {
        guard accountCostDV > 0 else { return 0 }
        return min(abs(costDifference) / accountCostDV, 1.0)
    }

    private func calculateSavingsPercentageString() -> String? {
        guard accountCostDV > 0 else { return nil }
        let percentage = abs(costDifference) / accountCostDV * 100
        return String(format: "%.1f%% \(costDifference > 0 ? "increase" : "savings")", percentage)
    }

    private func startNumberAnimation() async {
        let targetValue = Int(round(abs(costDifference) / 100))
        displayNumber = 0

        // Calculate step size based on target value
        let duration: TimeInterval = 1.5  // Match spring animation duration
        let steps = min(max(targetValue, 20), 50)  // At least 20 steps, max 50 steps
        let stepDuration = duration / TimeInterval(steps)

        for step in 1...steps {
            try? await Task.sleep(for: .milliseconds(Int(stepDuration * 1000)))
            displayNumber = Int(round((Double(step) / Double(steps)) * Double(targetValue)))
        }
        // Ensure we end at exact target
        displayNumber = targetValue
    }

    // MARK: - View Body
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Cost Comparison")
                .font(Theme.mainFont2())
                .foregroundColor(Theme.mainTextColor)

            if let (start, end) = calculateOverlapPeriod() {
                HStack(spacing: 6) {
                    Image(systemName: "calendar")
                        .font(.system(size: 12))
                        .foregroundColor(Theme.secondaryTextColor.opacity(0.8))

                    Text(formatDateRange(start: start, end: end))
                        .font(.system(size: 14))
                        .foregroundColor(Theme.secondaryTextColor)
                }
                .padding(.bottom, 6)
            }

            if let error = error {
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
            } else if isCalculating {
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
            } else if let acctCalc = accountCalculation,
                let cmpCalc = compareCalculation
            {
                HStack(spacing: 20) {
                    // Cost difference visualization
                    ZStack {
                        Circle()
                            .stroke(Theme.secondaryTextColor.opacity(0.2), lineWidth: 8)
                        Circle()
                            .trim(from: 0, to: animatedPercentage)
                            .stroke(
                                costDifference > 0 ? Color.red : Color.green,
                                style: StrokeStyle(lineWidth: 8, lineCap: .round)
                            )
                            .rotationEffect(.degrees(-90))

                        VStack(spacing: 4) {
                            Text(costDifference > 0 ? "More" : "Savings")
                                .font(Theme.subFont())
                                .foregroundColor(Theme.secondaryTextColor)
                            Text("£\(displayNumber)")
                                .font(Theme.mainFont())
                                .foregroundColor(costDifference > 0 ? .red : .green)
                        }
                    }
                    .frame(width: 100, height: 100)
                    .task {
                        // Reset animations
                        animatedDifference = 0
                        animatedPercentage = 0

                        try? await Task.sleep(for: .milliseconds(100))

                        // Animate to new values
                        withAnimation(.spring(duration: 1.5, bounce: 0.2)) {
                            animatedDifference = costDifference
                            animatedPercentage = calculateSavingsPercentage()
                        }
                        // Start number counting animation
                        await startNumberAnimation()
                    }

                    // Detailed breakdown
                    VStack(alignment: .leading, spacing: 8) {
                        costBreakdownRow(
                            label: "My Account",
                            cost: accountCostDV,
                            color: Theme.secondaryTextColor
                        )
                        costBreakdownRow(
                            label: planName,
                            cost: compareCostDV,
                            color: Theme.mainColor
                        )

                        if let savingsPercentage = calculateSavingsPercentageString() {
                            Text(savingsPercentage)
                                .font(Theme.subFont())
                                .foregroundColor(Theme.secondaryTextColor)
                        }
                    }
                }
            }
        }
        .padding()
        .background(
            RoundedRectangle(cornerRadius: 16)
                .fill(Theme.mainBackground)
                .shadow(color: Color.black.opacity(0.05), radius: 10, x: 0, y: 2)
        )
        .task {
            await calculateCosts()
        }
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

    private var planName: String {
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

    private func formatDateRange(start: Date, end: Date) -> String {
        let df = DateFormatter()
        df.dateStyle = .medium

        // If in same year, only show year once at the end
        let calendar = Calendar.current
        if calendar.component(.year, from: start) == calendar.component(.year, from: end) {
            df.setLocalizedDateFormatFromTemplate("d MMM")
            let startStr = df.string(from: start)
            df.setLocalizedDateFormatFromTemplate("d MMM yyyy")
            let endStr = df.string(from: end)
            return "\(startStr) - \(endStr)"
        } else {
            df.setLocalizedDateFormatFromTemplate("d MMM yyyy")
            return "\(df.string(from: start)) - \(df.string(from: end))"
        }
    }
}

// MARK: - Rate Analysis Card
private struct RateAnalysisCard: View {
    @ObservedObject var compareTariffVM: TariffViewModel
    @ObservedObject var ratesVM: RatesViewModel
    let showVAT: Bool
    let isManualPlan: Bool
    let manualStandingChargePencePerDay: Double
    let fullTariffCode: String
    @State private var currentStandingCharge: Double = 0.0
    @State private var highestRate: Double = 0.0
    @State private var lowestRate: Double = 0.0

    private func loadRates() async {
        // Load standing charge
        if isManualPlan {
            currentStandingCharge = manualStandingChargePencePerDay
        } else if let charges = try? await RatesRepository.shared.getLatestStandingCharge(
            tariffCode: fullTariffCode)
        {
            currentStandingCharge = showVAT ? charges.incVAT : charges.excVAT
        }

        // Load rates
        if !isManualPlan {
            if let rates = try? await RatesRepository.shared.fetchRatesByTariffCode(fullTariffCode)
            {
                // Get highest rate
                let highest = rates.max { a, b in
                    let aValue =
                        (a.value(forKey: showVAT ? "value_including_vat" : "value_excluding_vat")
                            as? Double) ?? Double.infinity
                    let bValue =
                        (b.value(forKey: showVAT ? "value_including_vat" : "value_excluding_vat")
                            as? Double) ?? Double.infinity
                    return aValue < bValue
                }
                if let rate = highest?.value(
                    forKey: showVAT ? "value_including_vat" : "value_excluding_vat") as? Double
                {
                    highestRate = rate
                }

                // Get lowest rate
                let lowest = rates.min { a, b in
                    let aValue =
                        (a.value(forKey: showVAT ? "value_including_vat" : "value_excluding_vat")
                            as? Double) ?? Double.infinity
                    let bValue =
                        (b.value(forKey: showVAT ? "value_including_vat" : "value_excluding_vat")
                            as? Double) ?? Double.infinity
                    return aValue < bValue
                }
                if let rate = lowest?.value(
                    forKey: showVAT ? "value_including_vat" : "value_excluding_vat") as? Double
                {
                    lowestRate = rate
                }
            }
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Rate Analysis")
                .font(Theme.mainFont2())
                .foregroundColor(Theme.mainTextColor)

            if let calc = compareTariffVM.currentCalculation {
                let rates = extractRates(from: calc)

                VStack(spacing: 12) {
                    rateRow(
                        label: "Average Rate",
                        value: rates.average,
                        icon: "chart.line.flattrend.xyaxis"
                    )
                    rateRow(
                        label: "Lowest Rate",
                        value: lowestRate,
                        icon: "arrow.down.circle"
                    )
                    rateRow(
                        label: "Highest Rate",
                        value: highestRate,
                        icon: "arrow.up.circle"
                    )

                    rateRow(
                        label: "Standing Charge",
                        value: currentStandingCharge,
                        icon: "clock",
                        isDaily: true
                    )
                }
            }
        }
        .padding()
        .background(
            RoundedRectangle(cornerRadius: 16)
                .fill(Theme.mainBackground)
                .shadow(color: Color.black.opacity(0.05), radius: 10, x: 0, y: 2)
        )
        .task {
            await loadRates()
        }
    }

    private func extractRates(from calc: TariffViewModel.TariffCalculation) -> (
        average: Double, lowest: Double, highest: Double
    ) {
        // Use the total cost minus standing charge divided by total consumption for average rate
        let avgRate =
            calc.totalKWh > 0
            ? ((showVAT ? calc.costIncVAT : calc.costExcVAT)
                - (showVAT ? calc.standingChargeIncVAT : calc.standingChargeExcVAT)) / calc.totalKWh
            : 0.0

        // Return actual rates
        return (average: avgRate, lowest: lowestRate, highest: highestRate)
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

    private func logStandingChargeError(_ error: String, details: [String: String] = [:]) {
        DebugLogger.shared.log(
            "⚠️ Standing charge error: \(error)",
            details: details.merging([
                "tariffCode": fullTariffCode,
                "isManualPlan": String(isManualPlan),
            ]) { (_, new) in new }
        )
    }
}

// MARK: - Monthly Average Rates Card
private struct MonthlyTrendsCard: View {
    @ObservedObject var compareTariffVM: TariffViewModel
    @ObservedObject var consumptionVM: ConsumptionViewModel
    let showVAT: Bool
    let selectedProduct: NSManagedObject?
    let isManualPlan: Bool
    let manualRatePencePerKWh: Double
    let fullTariffCode: String

    // Chart interaction states
    @State private var hoveredMonth: Date? = nil
    @State private var hoveredRate: Double? = nil
    @State private var tooltipPosition: CGPoint = .zero
    @State private var lastSnappedMonth: Date? = nil
    @State private var monthlyRates: [MonthlyRate] = []

    // Haptic feedback generator
    private let hapticFeedback = UIImpactFeedbackGenerator(style: .light)

    private struct MonthlyRate: Identifiable {
        let id = UUID()
        let month: Date
        let averageRate: Double
    }

    private func calculateMonthlyRates() async {
        // Get date range
        guard let startDate = getStartDate(),
            let endDate = getEndDate()
        else {
            return
        }

        // Generate months between start and end
        let calendar = Calendar.current
        var currentDate = startDate
        var newRates: [MonthlyRate] = []

        // For manual plan, just use the fixed rate for all months
        if isManualPlan {
            while currentDate <= endDate {
                newRates.append(
                    MonthlyRate(
                        month: currentDate,
                        averageRate: manualRatePencePerKWh
                    ))
                currentDate = calendar.date(byAdding: .month, value: 1, to: currentDate)!
            }
        } else {
            // For actual plans, fetch all rates once and calculate monthly averages
            if let rates = try? await RatesRepository.shared.fetchRatesByTariffCode(fullTariffCode)
            {
                while currentDate <= endDate {
                    let monthEnd = calendar.date(byAdding: .month, value: 1, to: currentDate)!

                    // Filter rates that overlap with this month
                    let monthlyRates = rates.filter { rate in
                        guard let validFrom = rate.value(forKey: "valid_from") as? Date,
                            let validTo = rate.value(forKey: "valid_to") as? Date
                        else {
                            return false
                        }
                        // Rate overlaps with the month if:
                        // 1. Rate starts before month ends AND
                        // 2. Rate ends after month starts
                        return validFrom < monthEnd && validTo > currentDate
                    }

                    if !monthlyRates.isEmpty {
                        // Calculate time-weighted average for the month
                        var totalDuration: TimeInterval = 0
                        var weightedSum: Double = 0

                        for rate in monthlyRates {
                            guard let validFrom = rate.value(forKey: "valid_from") as? Date,
                                let validTo = rate.value(forKey: "valid_to") as? Date,
                                let rateValue = rate.value(
                                    forKey: showVAT ? "value_including_vat" : "value_excluding_vat")
                                    as? Double
                            else {
                                continue
                            }

                            // Calculate overlap duration within this month
                            let overlapStart = max(validFrom, currentDate)
                            let overlapEnd = min(validTo, monthEnd)
                            let duration = overlapEnd.timeIntervalSince(overlapStart)

                            totalDuration += duration
                            weightedSum += rateValue * duration
                        }

                        if totalDuration > 0 {
                            let avgRate = weightedSum / totalDuration
                            newRates.append(
                                MonthlyRate(
                                    month: currentDate,
                                    averageRate: avgRate
                                ))
                        }
                    }

                    currentDate = monthEnd
                }
            }
        }

        // Update state on main thread
        await MainActor.run {
            monthlyRates = newRates
        }
    }

    private func getStartDate() -> Date? {
        if isManualPlan {
            // For manual plan, use consumption start date
            return consumptionVM.minInterval
        } else if let product = selectedProduct,
            let availableFrom = product.value(forKey: "available_from") as? Date
        {
            // For actual plan, use product's available_from date
            return availableFrom
        }
        return consumptionVM.minInterval
    }

    private func getEndDate() -> Date? {
        // End at consumption data end
        consumptionVM.maxInterval
    }

    private var yRange: (Double, Double) {
        let rates = monthlyRates.map { $0.averageRate }
        guard !rates.isEmpty else { return (0, 50) }
        let minVal = min(0, (rates.min() ?? 0) - 2)
        let maxVal = (rates.max() ?? 0) + 2
        return (minVal, maxVal)
    }

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

                // Keep existing Monthly Comparison Table
                MonthlyComparisonTable(
                    compareTariffVM: compareTariffVM,
                    showVAT: showVAT
                )
            }
        }
        .padding()
        .background(
            RoundedRectangle(cornerRadius: 16)
                .fill(Theme.mainBackground)
                .shadow(color: Color.black.opacity(0.05), radius: 10, x: 0, y: 2)
        )
        .task {
            await calculateMonthlyRates()
        }
    }

    private var chartView: some View {
        let (minVal, maxVal) = yRange

        // Calculate dynamic bar width based on number of bars
        let maxPossibleBars = 65.0  // same as InteractiveLineChartCardView
        let currentBars = Double(monthlyRates.count)
        let baseWidthPerBar = 5.0
        let barGapRatio = 0.7  // 70% bar, 30% gap
        let totalChunk = (maxPossibleBars / currentBars) * baseWidthPerBar
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
                .frame(maxWidth: .infinity)
        }
        .chartOverlay { proxy in
            GeometryReader { geo in
                Rectangle()
                    .fill(.clear)
                    .contentShape(Rectangle())
                    .gesture(
                        DragGesture(minimumDistance: 0)
                            .onChanged { drag in
                                handleDragChanged(drag: drag, proxy: proxy, geo: geo)
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
                    let plotArea = proxy.plotFrame
                {
                    let rect = geo[plotArea]
                    drawTooltip(rect: rect, xPos: xPos, month: month, rate: rate)
                }
            }
        }
    }

    private func handleDragChanged(
        drag: DragGesture.Value,
        proxy: ChartProxy,
        geo: GeometryProxy
    ) {
        guard let plotFrame = proxy.plotFrame else { return }

        let location = drag.location
        let plotRect = geo[plotFrame]

        // Clamp x position to plot bounds
        let clampedX = min(max(location.x, plotRect.minX), plotRect.maxX)

        // Get location in plot
        let locationInPlot = CGPoint(
            x: clampedX - plotRect.minX,
            y: location.y - plotRect.minY
        )

        if let date: Date = proxy.value(atX: locationInPlot.x) {
            // Find nearest month
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
        let calendar = Calendar.current
        return monthlyRates.min {
            abs($0.month.timeIntervalSince(date)) < abs($1.month.timeIntervalSince(date))
        }?.month
    }

    @ViewBuilder
    private func drawTooltip(
        rect: CGRect,
        xPos: CGFloat,
        month: Date,
        rate: Double
    ) -> some View {
        // Vertical highlight line
        Rectangle()
            .fill(Theme.mainColor.opacity(0.3))
            .frame(width: 2, height: rect.height)
            .position(x: rect.minX + xPos, y: rect.midY)

        // Tooltip
        VStack(alignment: .leading, spacing: 4) {
            Text(formatMonth(month))
                .font(Theme.subFont())
            Text("\(formatRate(rate)) avg")
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

    private func formatMonth(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "MMM yyyy"
        return formatter.string(from: date)
    }

    private func formatRate(_ rate: Double) -> String {
        String(format: "%.1fp", rate)
    }
}

// MARK: - Monthly Comparison Table
private struct MonthlyComparisonTable: View {
    @ObservedObject var compareTariffVM: TariffViewModel
    let showVAT: Bool

    private struct MonthlyComparison: Identifiable {
        let id = UUID()
        let month: Date
        let consumption: Double  // kWh
        let accountCostDV: Double
        let compareCostDV: Double

        var difference: Double {
            compareCostDV - accountCostDV
        }
    }

    private var monthlyData: [MonthlyComparison] {
        // TODO: Replace with actual data from compareTariffVM
        // This is placeholder data
        let calendar = Calendar.current
        let now = Date()
        return (0..<6).map { monthOffset in
            let month = calendar.date(byAdding: .month, value: -monthOffset, to: now)!
            return MonthlyComparison(
                month: month,
                consumption: Double.random(in: 200...400),
                accountCostDV: Double.random(in: 8000...15000),
                compareCostDV: Double.random(in: 8000...15000)
            )
        }
    }

    var body: some View {
        VStack(spacing: 16) {
            // Header
            HStack {
                Text("Monthly Comparison")
                    .font(Theme.mainFont2())  // Updated to match other section titles
                    .foregroundColor(Theme.mainTextColor)
                Spacer()
            }

            // Table Header
            HStack {
                Text("Month")
                    .frame(width: 90, alignment: .leading)
                Text("kWh")
                    .frame(width: 60, alignment: .trailing)
                Spacer()
                Text("Current")
                    .frame(width: 70, alignment: .trailing)
                Text("Compare")
                    .frame(width: 70, alignment: .trailing)
                Text("Diff")
                    .frame(width: 70, alignment: .trailing)
            }
            .font(Theme.captionFont())
            .foregroundColor(Theme.secondaryTextColor)

            // Table Content
            VStack(spacing: 12) {
                ForEach(monthlyData) { data in
                    HStack {
                        Text(formatMonth(data.month))
                            .frame(width: 90, alignment: .leading)
                        Text(formatConsumption(data.consumption))
                            .frame(width: 60, alignment: .trailing)
                        Spacer()
                        Text(formatCurrency(data.accountCostDV))
                            .frame(width: 70, alignment: .trailing)
                        Text(formatCurrency(data.compareCostDV))
                            .frame(width: 70, alignment: .trailing)
                        Text(formatDifference(data.difference))
                            .frame(width: 70, alignment: .trailing)
                            .foregroundColor(data.difference > 0 ? .red : .green)
                    }
                    .font(Theme.subFont())
                    .foregroundColor(Theme.mainTextColor)
                }
            }
        }
        .padding(.vertical, 16)  // Added vertical padding to match other sections
        .padding(.horizontal, 4)
    }

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
private struct ProductHeaderView: View {
    let product: NSManagedObject
    @Environment(\.dismiss) var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {  // Increased spacing
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
            VStack(alignment: .leading, spacing: 8) {  // Changed to VStack
                if let displayName = product.value(forKey: "display_name") as? String {
                    Text(displayName)
                        .font(.system(size: 36))  // Larger font
                        .foregroundColor(Theme.mainTextColor)
                }

                // Badges in their own row
                HStack(spacing: 8) {  // Increased spacing between badges
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
                    .font(.system(size: 17))  // Larger font
                    .foregroundColor(Theme.secondaryTextColor)
                    .lineSpacing(4)
            }

            // Availability info
            if let availableFrom = product.value(forKey: "available_from") as? Date {
                Text("Available from: \(formatDate(availableFrom))")
                    .font(.system(size: 16))  // Larger font
                    .foregroundColor(Theme.secondaryTextColor)

                // Add available to if exists and is before year 2100
                if let availableTo = product.value(forKey: "available_to") as? Date,
                    Calendar.current.component(.year, from: availableTo) < 2100
                {
                    Text("Available to: \(formatDate(availableTo))")
                        .font(.system(size: 16))  // Larger font
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

private struct ManualPlanSummaryView: View {
    let manualRatePencePerKWh: Double
    let manualStandingChargePencePerDay: Double

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 4) {
                Text("Manual Plan")
                    .foregroundColor(Theme.mainTextColor)
                BadgeView("Fixed Rate", color: .purple)
            }
            Text(
                "\(String(format: "%.1f", manualRatePencePerKWh))p/kWh + \(String(format: "%.1f", manualStandingChargePencePerDay))p/day"
            )
            .font(Theme.captionFont())
            .foregroundColor(Theme.secondaryTextColor)
        }
    }
}

// MARK: - Cache Types
private struct CacheInputs: Equatable {
    let minInterval: Date?
    let maxInterval: Date?
    let productId: NSManagedObjectID?
    let isManual: Bool

    static func == (lhs: CacheInputs, rhs: CacheInputs) -> Bool {
        lhs.minInterval == rhs.minInterval && lhs.maxInterval == rhs.maxInterval
            && lhs.productId == rhs.productId && lhs.isManual == rhs.isManual
    }
}

@MainActor
private let calculationRepository = TariffCalculationRepository(
    consumptionRepository: .shared,
    ratesRepository: .shared
)

// MARK: - Helper Functions
func breakdownDateRangeIntoMonths(start: Date, end: Date) -> [(start: Date, end: Date)] {
    var months: [(start: Date, end: Date)] = []
    let calendar = Calendar.current

    var currentDate = start
    while currentDate < end {
        // Get start of month
        let monthStart = calendar.date(
            from: calendar.dateComponents([.year, .month], from: currentDate))!

        // Get start of next month
        let nextMonth = calendar.date(byAdding: .month, value: 1, to: monthStart)!

        // The end date for this month is either the next month start or the overall end date
        let monthEnd = min(nextMonth, end)

        months.append((start: max(monthStart, start), end: monthEnd))

        // Move to next month
        currentDate = nextMonth
    }

    return months
}

func fetchStoredMonthlyCalculations(
    months: [(start: Date, end: Date)],
    tariffCode: String
) async throws -> [NSManagedObject] {
    var storedCalculations: [NSManagedObject] = []

    for month in months {
        if let stored = try await calculationRepository.fetchStoredCalculation(
            tariffCode: tariffCode,
            intervalType: "MONTHLY",
            periodStart: month.start,
            periodEnd: month.end
        ) {
            storedCalculations.append(stored)
        }
    }

    return storedCalculations
}

func calculateMissingMonths(
    months: [(start: Date, end: Date)],
    storedCalculations: [NSManagedObject],
    tariffCode: String,
    accountData: OctopusAccountResponse? = nil
) async throws -> [NSManagedObject] {
    var allCalculations = storedCalculations

    for month in months {
        // Check if we already have this month
        let hasMonth = storedCalculations.contains { calc in
            (calc.value(forKey: "period_start") as? Date) == month.start
                && (calc.value(forKey: "period_end") as? Date) == month.end
        }

        if !hasMonth {
            // Calculate missing month
            let calculation: NSManagedObject
            if tariffCode == "savedAccount" {
                guard let accData = accountData else { continue }
                let results = try await calculationRepository.calculateCostForAccount(
                    accountData: accData,
                    startDate: month.start,
                    endDate: month.end,
                    intervalType: "MONTHLY"
                )
                guard let firstResult = results.first else { continue }
                calculation = firstResult
            } else {
                calculation = try await calculationRepository.calculateCostForPeriod(
                    tariffCode: tariffCode,
                    startDate: month.start,
                    endDate: month.end,
                    intervalType: "MONTHLY"
                )
            }
            allCalculations.append(calculation)
        }
    }

    return allCalculations
}

func sumMonthlyCalculations(_ calculations: [NSManagedObject]) -> TariffViewModel.TariffCalculation
{
    var totalKWh = 0.0
    var totalCostExcVAT = 0.0
    var totalCostIncVAT = 0.0
    var totalStandingChargeExcVAT = 0.0
    var totalStandingChargeIncVAT = 0.0

    for calc in calculations {
        totalKWh += calc.value(forKey: "total_consumption_kwh") as? Double ?? 0.0
        totalCostExcVAT += calc.value(forKey: "total_cost_exc_vat") as? Double ?? 0.0
        totalCostIncVAT += calc.value(forKey: "total_cost_inc_vat") as? Double ?? 0.0
        totalStandingChargeExcVAT +=
            calc.value(forKey: "standing_charge_cost_exc_vat") as? Double ?? 0.0
        totalStandingChargeIncVAT +=
            calc.value(forKey: "standing_charge_cost_inc_vat") as? Double ?? 0.0
    }

    let avgRateExcVAT =
        totalKWh > 0 ? (totalCostExcVAT - totalStandingChargeExcVAT) / totalKWh : 0.0
    let avgRateIncVAT =
        totalKWh > 0 ? (totalCostIncVAT - totalStandingChargeIncVAT) / totalKWh : 0.0

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
