import SwiftUI
import CoreData
import Charts
import OctopusHelperShared

struct TestView: View {
    @Environment(\.managedObjectContext) private var viewContext
    
    // Break up complex expressions into separate declarations
    private static let rateEntity = NSEntityDescription.entity(forEntityName: "RateEntity", in: PersistenceController.shared.container.viewContext)!
    private static let consumptionEntity = NSEntityDescription.entity(forEntityName: "EConsumAgile", in: PersistenceController.shared.container.viewContext)!
    private static let productEntity = NSEntityDescription.entity(forEntityName: "ProductEntity", in: PersistenceController.shared.container.viewContext)!
    private static let standingChargeEntity = NSEntityDescription.entity(forEntityName: "StandingChargeEntity", in: PersistenceController.shared.container.viewContext)!
    
    @FetchRequest(entity: TestView.rateEntity,
                 sortDescriptors: [NSSortDescriptor(keyPath: \OctopusHelperSharedRateEntity.validFrom, ascending: true)])
    private var rates: FetchedResults<OctopusHelperSharedRateEntity>
    
    @FetchRequest(entity: TestView.consumptionEntity,
                 sortDescriptors: [NSSortDescriptor(keyPath: \EConsumAgile.interval_start, ascending: true)])
    private var consumption: FetchedResults<EConsumAgile>
    
    @FetchRequest(entity: TestView.productEntity,
                 sortDescriptors: [NSSortDescriptor(keyPath: \ProductEntity.display_name, ascending: true)])
    private var products: FetchedResults<ProductEntity>
    
    @FetchRequest(entity: TestView.standingChargeEntity,
                 sortDescriptors: [NSSortDescriptor(keyPath: \StandingChargeEntity.valid_from, ascending: true)])
    private var standingCharges: FetchedResults<StandingChargeEntity>
    
    // MARK: - Chart Data Structure
    private struct ChartDataPoint: Identifiable, Hashable {
        let id = UUID()
        let date: Date
        let value: Double
        
        func hash(into hasher: inout Hasher) {
            hasher.combine(id)
        }
        
        static func == (lhs: ChartDataPoint, rhs: ChartDataPoint) -> Bool {
            lhs.id == rhs.id
        }
    }
    
    private func standingChargesChart() -> some View {
        let chartData: [ChartDataPoint] = standingCharges.map { charge in
            ChartDataPoint(
                date: charge.valid_from ?? Date(),
                value: charge.value_including_vat
            )
        }
        
        return Chart(chartData) { point in
            LineMark(
                x: .value("Time", point.date),
                y: .value("Charge", point.value)
            )
        }
        .foregroundStyle(.orange)
        .frame(height: 200)
        .chartXAxis {
            AxisMarks(values: .stride(by: .day, count: 7))
        }
    }
    
    private func ratesChart() -> some View {
        let chartData: [ChartDataPoint] = Array(rates.prefix(48)).map { rate in
            ChartDataPoint(
                date: rate.validFrom ?? Date(),
                value: rate.valueIncludingVAT
            )
        }
        
        return Chart(chartData) { point in
            LineMark(
                x: .value("Time", point.date),
                y: .value("Rate", point.value)
            )
        }
        .foregroundStyle(.blue)
        .frame(height: 200)
        .chartXAxis {
            AxisMarks(values: .stride(by: .hour, count: 6))
        }
    }
    
    private func consumptionChart() -> some View {
        let chartData: [ChartDataPoint] = Array(consumption.prefix(48)).map { cons in
            ChartDataPoint(
                date: cons.interval_start ?? Date(),
                value: cons.consumption
            )
        }
        
        return Chart(chartData) { point in
            BarMark(
                x: .value("Time", point.date),
                y: .value("Consumption", point.value)
            )
        }
        .foregroundStyle(.green)
        .frame(height: 200)
        .chartXAxis {
            AxisMarks(values: .stride(by: .hour, count: 6))
        }
    }
    
    var body: some View {
        NavigationView {
            List {
                // Products Section
                Section("Products") {
                    if !products.isEmpty {
                        ForEach(products, id: \.self) { product in
                            VStack(alignment: .leading, spacing: 4) {
                                Text(product.display_name ?? "Unknown Product")
                                    .font(.headline)
                                Text(product.full_name ?? "")
                                    .font(.subheadline)
                                Text("Code: \(product.code ?? "")")
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                            }
                            .padding(.vertical, 4)
                        }
                    } else {
                        Text("No products available")
                    }
                }
                
                // Standing Charges Section
                Section("Standing Charges") {
                    if !standingCharges.isEmpty {
                        VStack(alignment: .leading) {
                            Text("Current Standing Charge: \(currentStandingCharge(), specifier: "%.2f")p/day")
                            standingChargesChart()
                        }
                        .padding(.vertical)
                    } else {
                        Text("No standing charges available")
                    }
                }
                
                // Rates Section
                Section("Rate Analysis") {
                    if !rates.isEmpty {
                        VStack(alignment: .leading) {
                            Text("Average Rate (incl. VAT): \(averageRate(), specifier: "%.2f")p/kWh")
                            Text("Highest Rate: \(highestRate(), specifier: "%.2f")p/kWh")
                            Text("Lowest Rate: \(lowestRate(), specifier: "%.2f")p/kWh")
                            ratesChart()
                        }
                        .padding(.vertical)
                    } else {
                        Text("No rate data available")
                    }
                }
                
                // Consumption Section
                Section("Consumption Analysis") {
                    if !consumption.isEmpty {
                        VStack(alignment: .leading) {
                            Text("Total Consumption: \(totalConsumption(), specifier: "%.2f")kWh")
                            Text("Average Consumption: \(averageConsumption(), specifier: "%.2f")kWh")
                            consumptionChart()
                        }
                        .padding(.vertical)
                    } else {
                        Text("No consumption data available")
                    }
                }
                
                // Cost Analysis Section
                Section("Cost Analysis") {
                    if !rates.isEmpty && !consumption.isEmpty {
                        VStack(alignment: .leading) {
                            Text("Total Cost: £\(calculateTotalCost(), specifier: "%.2f")")
                            Text("Average Cost per kWh: \(averageCostPerKWh(), specifier: "%.2f")p")
                            Text("Daily Standing Charge: \(currentStandingCharge(), specifier: "%.2f")p")
                        }
                        .padding(.vertical)
                    } else {
                        Text("Insufficient data for cost analysis")
                    }
                }
            }
            .navigationTitle("Data Analysis")
        }
    }
    
    // MARK: - Cost Calculation Methods
    private func calculateTotalCost() -> Double {
        var totalCost = 0.0
        
        // Calculate consumption cost
        for cons in consumption {
            guard let start = cons.interval_start else { continue }
            if let rate = rates.first(where: { $0.validFrom == start }) {
                totalCost += cons.consumption * rate.valueIncludingVAT / 100.0 // Convert pence to pounds
            }
        }
        
        // Add standing charges
        let uniqueDays: Set<Date> = Set(consumption.compactMap { cons in
            guard let date = cons.interval_start else { return nil }
            return Calendar.current.startOfDay(for: date)
        })
        
        let dailyCharge = currentStandingCharge()
        totalCost += Double(uniqueDays.count) * dailyCharge / 100.0 // Convert pence to pounds
        
        return totalCost
    }
    
    private func averageCostPerKWh() -> Double {
        let total = calculateTotalCost()
        let totalConsumptionValue = totalConsumption()
        guard totalConsumptionValue > 0 else { return 0 }
        return (total * 100.0) / totalConsumptionValue // Convert back to pence for display
    }
    
    private func currentStandingCharge() -> Double {
        guard let latest = standingCharges.last else { return 0 }
        return latest.value_including_vat
    }
    
    private func averageRate() -> Double {
        guard !rates.isEmpty else { return 0 }
        let sum = rates.reduce(0.0) { $0 + $1.valueIncludingVAT }
        return sum / Double(rates.count)
    }
    
    private func highestRate() -> Double {
        rates.max(by: { $0.valueIncludingVAT < $1.valueIncludingVAT })?.valueIncludingVAT ?? 0
    }
    
    private func lowestRate() -> Double {
        rates.min(by: { $0.valueIncludingVAT < $1.valueIncludingVAT })?.valueIncludingVAT ?? 0
    }
    
    private func totalConsumption() -> Double {
        consumption.reduce(0.0) { $0 + $1.consumption }
    }
    
    private func averageConsumption() -> Double {
        guard !consumption.isEmpty else { return 0 }
        return totalConsumption() / Double(consumption.count)
    }
}

struct TestView_Previews: PreviewProvider {
    static var previews: some View {
        TestView()
            .environment(\.managedObjectContext, PersistenceController.preview.container.viewContext)
    }
}
