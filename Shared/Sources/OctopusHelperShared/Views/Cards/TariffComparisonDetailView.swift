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
                    globalSettings: globalSettings,
                    compareTariffVM: compareTariffVM
                )
                .opacity(showContent ? 1 : 0)
                .offset(y: showContent ? 0 : 20)

                // Rate Analysis Card
                RateAnalysisCard(
                    compareTariffVM: compareTariffVM,
                    showVAT: globalSettings.settings.showRatesWithVAT
                )
                .opacity(showContent ? 1 : 0)
                .offset(y: showContent ? 0 : 20)

                // Monthly Trends Card
                MonthlyTrendsCard(
                    compareTariffVM: compareTariffVM,
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
    @ObservedObject var globalSettings: GlobalSettingsManager
    @ObservedObject var compareTariffVM: TariffViewModel

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

        isCalculating = true
        defer { isCalculating = false }

        do {
            // Get account data for savedAccount tariff
            let accountData: OctopusAccountResponse?
            if let rawData = globalSettings.settings.accountData {
                accountData = try JSONDecoder().decode(OctopusAccountResponse.self, from: rawData)
            } else {
                accountData = nil
            }

            // Calculate for account tariff
            await compareTariffVM.calculateCosts(
                for: startDate,
                tariffCode: "savedAccount",
                intervalType: .monthly,
                accountData: accountData,
                partialStart: startDate,
                partialEnd: endDate
            )
            if let calc = compareTariffVM.currentCalculation {
                accountCalculation = calc
            }

            // Calculate for comparison tariff
            let tariffCode = isManualPlan ? "manualPlan" : fullTariffCode
            let compareAccountData = isManualPlan ? buildMockAccountResponseForManual() : nil

            // Log the tariff code we're trying to calculate
            DebugLogger.shared.log(
                "🔄 Calculating costs for tariff",
                details: [
                    "tariffCode": tariffCode,
                    "startDate": startDate.description,
                    "endDate": endDate.description,
                ]
            )

            await compareTariffVM.calculateCosts(
                for: startDate,
                tariffCode: tariffCode,
                intervalType: .monthly,
                accountData: compareAccountData,
                partialStart: startDate,
                partialEnd: endDate
            )
            if let calc = compareTariffVM.currentCalculation {
                compareCalculation = calc
            }
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

    private var accountCost: Double {
        guard let calc = accountCalculation else { return 0 }
        return showVAT ? calc.costIncVAT : calc.costExcVAT
    }

    private var compareCost: Double {
        guard let calc = compareCalculation else { return 0 }
        return showVAT ? calc.costIncVAT : calc.costExcVAT
    }

    private var costDifference: Double {
        compareCost - accountCost
    }

    private func calculateSavingsPercentage() -> Double {
        guard accountCost > 0 else { return 0 }
        return min(abs(costDifference) / accountCost, 1.0)
    }

    private func calculateSavingsPercentageString() -> String? {
        guard accountCost > 0 else { return nil }
        let percentage = abs(costDifference) / accountCost * 100
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
                            .font(Theme.subFont())
                            .foregroundColor(.red)
                    }
                    Text(error.localizedDescription)
                        .font(Theme.captionFont())
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
                            .font(Theme.captionFont())
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
                                .font(Theme.captionFont())
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
                            cost: accountCost,
                            color: Theme.mainColor
                        )
                        costBreakdownRow(
                            label: "Compared Plan",
                            cost: compareCost,
                            color: Theme.secondaryTextColor
                        )

                        if let savingsPercentage = calculateSavingsPercentageString() {
                            Text(savingsPercentage)
                                .font(Theme.captionFont())
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
                .font(Theme.subFont())
                .foregroundColor(Theme.secondaryTextColor)
            Spacer()
            Text("£\(String(format: "%.2f", cost / 100))")
                .font(Theme.subFont())
                .foregroundColor(color)
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
    let showVAT: Bool

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
                        value: rates.lowest,
                        icon: "arrow.down.circle"
                    )
                    rateRow(
                        label: "Highest Rate",
                        value: rates.highest,
                        icon: "arrow.up.circle"
                    )
                    rateRow(
                        label: "Standing Charge",
                        value: showVAT ? calc.standingChargeIncVAT : calc.standingChargeExcVAT,
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
    }

    private func extractRates(from calc: TariffViewModel.TariffCalculation) -> (
        average: Double, lowest: Double, highest: Double
    ) {
        let avgRate = showVAT ? calc.averageUnitRateIncVAT : calc.averageUnitRateExcVAT
        // Note: Add properties for lowest and highest rates in TariffCalculation
        return (average: avgRate, lowest: avgRate * 0.8, highest: avgRate * 1.2)  // Placeholder
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
private struct MonthlyTrendsCard: View {
    @ObservedObject var compareTariffVM: TariffViewModel
    let showVAT: Bool

    private struct ChartDataPoint: Identifiable {
        let id = UUID()
        let month: String
        let rate: Double
    }

    private var chartData: [ChartDataPoint] {
        (0..<6).map { month in
            ChartDataPoint(
                month: "Month \(month + 1)",
                rate: Double.random(in: 20...40)
            )
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Monthly Trends")
                .font(Theme.mainFont2())
                .foregroundColor(Theme.mainTextColor)

            if let calc = compareTariffVM.currentCalculation {
                // Placeholder for monthly data visualization
                // TODO: Implement actual monthly data extraction and visualization
                Chart(chartData) { dataPoint in
                    LineMark(
                        x: .value("Month", dataPoint.month),
                        y: .value("Rate", dataPoint.rate)
                    )
                    .foregroundStyle(Theme.mainColor)
                }
                .frame(height: 200)

                // Add Monthly Comparison Table
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
        let accountCost: Double
        let compareCost: Double

        var difference: Double {
            compareCost - accountCost
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
                accountCost: Double.random(in: 8000...15000),
                compareCost: Double.random(in: 8000...15000)
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
                        Text(formatCurrency(data.accountCost))
                            .frame(width: 70, alignment: .trailing)
                        Text(formatCurrency(data.compareCost))
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

                // Add available to if exists
                if let availableTo = product.value(forKey: "available_to") as? Date {
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
