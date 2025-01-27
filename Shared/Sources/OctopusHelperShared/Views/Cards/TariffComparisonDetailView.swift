import Charts
import CoreData
import SwiftUI

// MARK: - Main Detail View
public struct TariffComparisonDetailView: View {
    @Environment(\.dismiss) var dismiss
    let selectedPlanCode: String
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

    public init(
        selectedPlanCode: String,
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
                if let acctCalc = compareTariffVM.currentCalculation,
                    let cmpCalc = compareTariffVM.currentCalculation
                {
                    ComparisonInsightCard(
                        accountCalc: acctCalc,
                        compareCalc: cmpCalc,
                        showVAT: globalSettings.settings.showRatesWithVAT,
                        overlapStart: overlapStart,
                        overlapEnd: overlapEnd,
                        consumptionVM: consumptionVM,
                        selectedProduct: selectedProduct,
                        isManualPlan: isManualPlan,
                        globalSettings: globalSettings,
                        compareTariffVM: compareTariffVM
                    )
                    .opacity(showContent ? 1 : 0)
                    .offset(y: showContent ? 0 : 20)
                } else {
                    #if DEBUG
                        let _ = print("Debug: Calculations missing")
                        let _ = print(
                            "- currentCalculation: \(String(describing: compareTariffVM.currentCalculation))"
                        )
                    #endif
                }

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
private struct ComparisonInsightCard: View {
    let accountCalc: TariffViewModel.TariffCalculation
    let compareCalc: TariffViewModel.TariffCalculation
    let showVAT: Bool
    let overlapStart: Date?  // Keep these for backward compatibility
    let overlapEnd: Date?  // but we won't use them
    @ObservedObject var consumptionVM: ConsumptionViewModel
    let selectedProduct: NSManagedObject?
    let isManualPlan: Bool
    @ObservedObject var globalSettings: GlobalSettingsManager
    @ObservedObject var compareTariffVM: TariffViewModel

    private func calculateOverlapPeriod() -> (start: Date?, end: Date?)? {
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

    // MARK: - View Body
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Cost Comparison")
                .font(Theme.mainFont2())
                .foregroundColor(Theme.mainTextColor)

            HStack(spacing: 20) {
                // Cost difference visualization
                ZStack {
                    Circle()
                        .stroke(Theme.secondaryTextColor.opacity(0.2), lineWidth: 8)
                    Circle()
                        .trim(from: 0, to: calculateSavingsPercentage())
                        .stroke(
                            costDifference > 0 ? Color.red : Color.green,
                            style: StrokeStyle(lineWidth: 8, lineCap: .round)
                        )
                        .rotationEffect(.degrees(-90))

                    VStack(spacing: 4) {
                        Text(costDifference > 0 ? "More" : "Savings")
                            .font(Theme.captionFont())
                            .foregroundColor(Theme.secondaryTextColor)
                        Text("£\(String(format: "%.2f", abs(costDifference) / 100))")
                            .font(Theme.mainFont())
                            .foregroundColor(costDifference > 0 ? .red : .green)
                    }
                }
                .frame(width: 100, height: 100)

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
        .padding()
        .background(
            RoundedRectangle(cornerRadius: 16)
                .fill(Theme.mainBackground)
                .shadow(color: Color.black.opacity(0.05), radius: 10, x: 0, y: 2)
        )
        .onAppear {
            Task {
                calculateOverlapPeriod()
            }
        }
    }

    private var accountCost: Double {
        showVAT ? accountCalc.costIncVAT : accountCalc.costExcVAT
    }

    private var compareCost: Double {
        showVAT ? compareCalc.costIncVAT : compareCalc.costExcVAT
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
        // Enhanced formatting
        let df = DateFormatter()
        df.dateFormat = "d MMM yyyy"
        return "\(df.string(from: start)) - \(df.string(from: end))"
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
