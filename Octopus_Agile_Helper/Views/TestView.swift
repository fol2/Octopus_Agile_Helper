import SwiftUI
import CoreData
import Charts
import OctopusHelperShared
import Combine

// MARK: - Products Fetcher
class ProductsFetcher: NSObject, ObservableObject, NSFetchedResultsControllerDelegate {
    @Published private(set) var products: [ProductEntity] = []
    private let controller: NSFetchedResultsController<ProductEntity>
    
    init(context: NSManagedObjectContext) {
        let request = NSFetchRequest<ProductEntity>(entityName: "ProductEntity")
        request.sortDescriptors = [NSSortDescriptor(keyPath: \ProductEntity.display_name, ascending: true)]
        
        controller = NSFetchedResultsController(
            fetchRequest: request,
            managedObjectContext: context,
            sectionNameKeyPath: nil,
            cacheName: nil
        )
        
        super.init()
        controller.delegate = self
        
        // Initial fetch with localized error handling
        do {
            try controller.performFetch()
            products = controller.fetchedObjects ?? []
        } catch {
            products = []
        }
    }
    
    // MARK: - NSFetchedResultsControllerDelegate
    func controllerDidChangeContent(_ controller: NSFetchedResultsController<NSFetchRequestResult>) {
        products = controller.fetchedObjects as? [ProductEntity] ?? []
    }
}

struct TestView: View {
    // 使用与ProductsRepository相同的上下文
    private let viewContext = PersistenceController.shared.container.viewContext
    @StateObject private var globalTimer = GlobalTimer()
    @StateObject private var ratesViewModel: RatesViewModel
    @StateObject private var consumptionVM = ConsumptionViewModel()
    @StateObject private var productsFetcher: ProductsFetcher
    @State private var showingDBViewer = false
    @State private var selectedTariffCode: String?
    @State private var availableTariffCodes: [String] = []
    @State private var navigationPath = NavigationPath()
    @State private var showingProductsList = false

    // Entity declarations for Core Data
    private static let rateEntity = NSEntityDescription.entity(
        forEntityName: "RateEntity",
        in: PersistenceController.shared.container.viewContext
    )!
    private static let standingChargeEntity = NSEntityDescription.entity(
        forEntityName: "StandingChargeEntity",
        in: PersistenceController.shared.container.viewContext
    )!
    private static let consumptionEntity = NSEntityDescription.entity(
        forEntityName: "EConsumAgile",
        in: PersistenceController.shared.container.viewContext
    )!

    // Use @State to hold fetched NSManagedObject arrays
    @State private var standingCharges: [NSManagedObject] = []
    @FetchRequest private var consumption: FetchedResults<NSManagedObject>

    init(ratesViewModel: RatesViewModel) {
        self._ratesViewModel = StateObject(wrappedValue: ratesViewModel)
        self._consumptionVM = StateObject(wrappedValue: ConsumptionViewModel())
        self._productsFetcher = StateObject(wrappedValue: ProductsFetcher(context: PersistenceController.shared.container.viewContext))
        
        let consumptionRequest = FetchRequest<NSManagedObject>(
            entity: TestView.consumptionEntity,
            sortDescriptors: [NSSortDescriptor(key: "interval_start", ascending: true)]
        )
        _consumption = consumptionRequest
    }
    
    var products: [ProductEntity] {
        productsFetcher.products
    }
    
    @State private var selectedProductCode: String?
    
    // MARK: - Rates Computed Properties
    private var combinedRates: [NSManagedObject] {
        // Now we use `tariff_code` to filter. 
        if selectedTariffCode != nil {
            return ratesViewModel.allRatesMerged.filter { rate in
                rate.value(forKey: "tariff_code") as? String == selectedTariffCode
            }
        } else {
            return ratesViewModel.allRatesMerged
        }
    }

    private var availableRateProducts: Set<String> {
        // we now rely on `tariff_code` instead of `product_code`
        let all = ratesViewModel.allRatesMerged.compactMap {
            $0.value(forKey: "tariff_code") as? String
        }
        return Set(all)
    }
    
    var body: some View {
        NavigationStack(path: $navigationPath) {
            List {
                // Fetch Data Section
                Section("Fetch Data") {
                    VStack(alignment: .leading, spacing: 10) {
                        // 1. Status
                        if let state = ratesViewModel.productStates[selectedTariffCode ?? ""] {
                            Text("Status: \(state.fetchStatus.description)")
                        } else {
                            Text("Status: Not Started")
                        }
                        
                        // 2. Fetch Products with navigation
                        HStack(spacing: 8) {
                            Button(action: {
                                Task {
                                    await ratesViewModel.syncProducts()
                                }
                            }) {
                                Label(String(localized: "Fetch Products"), systemImage: "cart")
                            }
                            .buttonStyle(.bordered)
                            .layoutPriority(1)
                            
                            Spacer()
                            
                            NavigationLink(value: "products_list") {
                                Text("Products: \(productsFetcher.products.count)")
                                    .font(.caption)
                                    .foregroundColor(.gray)
                                    .padding(.trailing, -16)
                            }
                        }
                        
                        // 3. Product Code Selection
                        Picker("Select Product Code", selection: Binding(
                            get: { selectedProductCode },
                            set: { newValue in
                                selectedProductCode = newValue
                                if let code = newValue {
                                    Task {
                                        do {
                                            print("🔍 Loading local product details for: \(code)")
                                            let localDetails = try await ProductDetailRepository.shared.loadLocalProductDetail(code: code)
                                            if !localDetails.isEmpty {
                                                let codes = try await ProductDetailRepository.shared.fetchTariffCodes(for: code)
                                                print("📦 Found local tariff codes: \(codes)")
                                                await MainActor.run {
                                                    self.availableTariffCodes = codes
                                                    self.selectedTariffCode = nil
                                                }
                                            } else {
                                                print("📝 No local data found for: \(code)")
                                                await MainActor.run {
                                                    self.availableTariffCodes = []
                                                    self.selectedTariffCode = nil
                                                }
                                            }
                                        } catch {
                                            print("❌ Error loading local data: \(error.localizedDescription)")
                                            await MainActor.run {
                                                self.availableTariffCodes = []
                                                self.selectedTariffCode = nil
                                            }
                                        }
                                    }
                                } else {
                                    availableTariffCodes = []
                                    selectedTariffCode = nil
                                }
                            }
                        )) {
                            Text("Select a product code").tag(Optional<String>.none)
                            ForEach(products, id: \.code) { product in
                                Text(product.code ?? "").tag(Optional(product.code ?? ""))
                            }
                        }
                        .pickerStyle(.menu)
                        
                        // 4. Fetch Product Details
                        Button(action: {
                            guard let code = selectedProductCode else { return }
                            Task {
                                do {
                                    print("🌐 Fetching product details from API for: \(code)")
                                    let startTime = Date()
                                    _ = try await ProductDetailRepository.shared.fetchAndStoreProductDetail(productCode: code)
                                    let codes = try await ProductDetailRepository.shared.fetchTariffCodes(for: code)
                                    print("📊 Fetched tariff codes: \(codes)")
                                    await MainActor.run {
                                        self.availableTariffCodes = codes
                                        self.selectedTariffCode = nil
                                    }
                                    let duration = Date().timeIntervalSince(startTime)
                                    print("✅ API fetch completed in \(String(format: "%.2f", duration)) seconds")
                                } catch {
                                    print("❌ Error fetching from API: \(error.localizedDescription)")
                                    await MainActor.run {
                                        self.availableTariffCodes = []
                                        self.selectedTariffCode = nil
                                    }
                                }
                            }
                        }) {
                            Label(String(localized: "Fetch Product Details"), systemImage: "doc.text.magnifyingglass")
                        }
                        .buttonStyle(.bordered)
                        .disabled(selectedProductCode == nil)
                        
                        // 5. Tariff Code Selection
                        if !availableTariffCodes.isEmpty {
                            Picker("Select Tariff Code", selection: $selectedTariffCode) {
                                Text("Select a tariff code").tag(Optional<String>.none)
                                ForEach(availableTariffCodes.sorted(), id: \.self) { code in
                                    Text(code).tag(Optional(code))
                                }
                            }
                            .pickerStyle(.menu)
                        }
                        
                        // 6. Fetch Rates
                        Button(action: {
                            guard let tariffCode = selectedTariffCode else { return }
                            Task {
                                await ratesViewModel.fetchRates(tariffCode: tariffCode)
                            }
                        }) {
                            Label(String(localized: "Fetch Rates"), systemImage: "chart.line.uptrend.xyaxis")
                        }
                        .buttonStyle(.bordered)
                        .disabled(selectedTariffCode == nil)
                        
                        // 7. Fetch Consumption
                        Button(action: {
                            Task {
                                await consumptionVM.refreshDataFromAPI(force: true)
                            }
                        }) {
                            Label(String(localized: "Fetch Consumption"), systemImage: "bolt")
                        }
                        .buttonStyle(.bordered)
                        
                        // 8. Fetch All Data
                        Button(action: {
                            Task {
                                await ratesViewModel.syncProducts()
                                await ratesViewModel.fetchRatesForDefaultProduct()
                                await consumptionVM.refreshDataFromAPI(force: true)
                            }
                        }) {
                            Label(String(localized: "Fetch All Data"), systemImage: "arrow.triangle.2.circlepath")
                        }
                        .buttonStyle(.bordered)
                        
                        // 9. View Database
                        Button(action: {
                            showingDBViewer = true
                        }) {
                            Label(String(localized: "View Database"), systemImage: "server.rack")
                        }
                        .buttonStyle(.bordered)
                    }
                    .padding(.vertical, 8)
                }
                
                // Charts Section
                Section(header: Text("Standing Charges")) {
                    Text("Standing Charges (\(standingCharges.count))")
                    standingChargesChart()
                }

                Section {
                    Text("Rates (\(combinedRates.count))")

                    // Debug info
                    VStack(alignment: .leading) {
                        Text("Available Rates: \(combinedRates.count)")
                            .font(.caption)
                            .foregroundColor(.secondary)
                        Text("Distinct Products: \(availableRateProducts.count)")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }

                    ratesChart()
                }
                .onChange(of: selectedProductCode) { _, _ in
                    // Reload with updated standingCharges predicate
                    refreshRatesAndCharges()
                }
                
                // Consumption Section
                Section(header: Text("Consumption")) {
                    Text("Consumption")
                        .onAppear {
                        }
                    // consumptionChart()
                }
                
                // Calculations Section
                Section(LocalizedStringKey("Calculations")) {
                    VStack {
                        Text(LocalizedStringKey("Total Cost: £\(String(format: "%.2f", calculateTotalCost()))"))
                        Text(LocalizedStringKey("Average Cost per kWh: \(String(format: "%.2f", averageCostPerKWh()))p"))
                        Text(LocalizedStringKey("Total Consumption: \(String(format: "%.2f", totalConsumption())) kWh"))
                    }
                }
            }
            .navigationDestination(for: String.self) { route in
                switch route {
                case "products_list":
                    List {
                        ForEach(products, id: \.self) { product in
                            NavigationLink {
                                ProductDetailView(product: product)
                            } label: {
                                ProductRow(product: product)
                            }
                        }
                    }
                    .navigationTitle("Products")
                default:
                    EmptyView()
                }
            }
            .sheet(isPresented: $showingDBViewer) {
                DBViewerView(context: viewContext)
            }
        }
        .onAppear {
            globalTimer.startTimer()
            Task {
                await consumptionVM.loadData()
                // Removed automatic rates fetching
            }
        }
        .onDisappear {
            globalTimer.stopTimer()
        }
    }
    
    // MARK: - Cost Calculation Methods
    private func calculateTotalCost() -> Double {
        var totalCost = 0.0
        // Calculate consumption cost
        for cons in consumption {
            if let start = cons.value(forKey: "interval_start") as? Date,
               let consumption = cons.value(forKey: "consumption") as? Double,
               let rate = combinedRates.first(where: { ($0.value(forKey: "valid_from") as? Date ?? Date()) == start }),
               let rateValue = rate.value(forKey: "value_including_vat") as? Double {
                totalCost += consumption * rateValue / 100.0 // Convert pence to pounds
            }
        }
        
        // Add standing charges
        let cal = Calendar.current
        let uniqueDays: Set<Date> = Set(consumption.compactMap { cons in
            guard let date = cons.value(forKey: "interval_start") as? Date else { return nil }
            return cal.startOfDay(for: date)
        })
        
        let dailyCharge = currentStandingCharge()
        totalCost += Double(uniqueDays.count) * dailyCharge / 100.0 // Convert pence to pounds
        
        return totalCost
    }
    
    private func averageCostPerKWh() -> Double {
        let total = calculateTotalCost()
        let totalConsumptionValue = totalConsumption()
        guard totalConsumptionValue > 0 else {
            return 0
        }
        let average = (total * 100.0) / totalConsumptionValue
        return average
    }
    
    private func totalConsumption() -> Double {
        let total = consumption.reduce(0.0) { sum, cons in
            sum + (cons.value(forKey: "consumption") as? Double ?? 0.0)
        }
        return total
    }
    
    private func currentStandingCharge() -> Double {
        guard let latest = standingCharges.last else { return 0 }
        return latest.value(forKey: "value_including_vat") as? Double ?? 0.0
    }
    
    private func averageRate() -> Double {
        guard !combinedRates.isEmpty else { return 0 }
        let sum = combinedRates.reduce(0.0) { total, rate in
            total + (rate.value(forKey: "value_including_vat") as? Double ?? 0.0)
        }
        return sum / Double(combinedRates.count)
    }
    
    private func highestRate() -> Double {
        combinedRates.max(by: { 
            ($0.value(forKey: "value_including_vat") as? Double ?? 0.0) < 
            ($1.value(forKey: "value_including_vat") as? Double ?? 0.0)
        })?.value(forKey: "value_including_vat") as? Double ?? 0
    }
    
    private func lowestRate() -> Double {
        combinedRates.min(by: { 
            ($0.value(forKey: "value_including_vat") as? Double ?? 0.0) < 
            ($1.value(forKey: "value_including_vat") as? Double ?? 0.0)
        })?.value(forKey: "value_including_vat") as? Double ?? 0
    }
    
    // MARK: - Helper Methods
    private func refreshRatesAndCharges() {
        do {
            let requestCharges = NSFetchRequest<NSManagedObject>(entityName: "StandingChargeEntity")
            requestCharges.sortDescriptors = [NSSortDescriptor(key: "valid_from", ascending: true)]
            requestCharges.predicate = standingChargesPredicate()

            self.standingCharges = try viewContext.fetch(requestCharges)
        } catch {
            print("Error fetching StandingCharges: \(error)")
            self.standingCharges = []
        }
    }
    
    private func standingChargesPredicate() -> NSPredicate {
        guard let code = selectedTariffCode,
              !code.isEmpty
        else {
            // If there's no selected product, default to an empty predicate or agile fallback
            return NSPredicate(format: "tariff_code == %@", ratesViewModel.currentAgileCode)
        }
        // If your StandingChargeEntity now stores `tariff_code` or something else, adapt as needed:
        return NSPredicate(format: "tariff_code == %@", code)
    }

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
        let chartData = standingCharges.map { charge in
            ChartDataPoint(
                date: charge.value(forKey: "valid_from") as? Date ?? Date(),
                value: charge.value(forKey: "value_including_vat") as? Double ?? 0.0
            )
        }
        return Chart(chartData) { point in
            LineMark(
                x: .value("Time", point.date),
                y: .value("Charge", point.value)
            )
        }
        .foregroundStyle(.green)
        .frame(height: 200)
    }

    // MARK: - Chart Helpers
    private func ratesChart() -> some View {
        let chartData = combinedRates.prefix(48).map { rate in
            ChartDataPoint(
                date: rate.value(forKey: "valid_from") as? Date ?? Date(),
                value: rate.value(forKey: "value_including_vat") as? Double ?? 0.0
            )
        }
        return Chart(chartData) { point in
            LineMark(x: .value("Time", point.date),
                     y: .value("Rate", point.value))
        }
        .foregroundStyle(.blue)
        .frame(height: 200)
        .chartXAxis {
            AxisMarks(values: .stride(by: .hour, count: 6))
        }
    }
}

struct IdentifiableProduct: Identifiable, Equatable, Hashable {
    let id: String
    let product: NSManagedObject
    
    init(product: NSManagedObject) {
        self.product = product
        self.id = product.value(forKey: "code") as? String ?? UUID().uuidString
    }
    
    static func == (lhs: IdentifiableProduct, rhs: IdentifiableProduct) -> Bool {
        lhs.id == rhs.id
    }
    
    func hash(into hasher: inout Hasher) {
        hasher.combine(id)
    }
}

// MARK: - Product Row View
struct ProductRow: View {
    let product: ProductEntity
    
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(product.value(forKey: "display_name") as? String ?? "Unknown")
                .font(.headline)
            Text(product.value(forKey: "code") as? String ?? "")
                .font(.subheadline)
                .foregroundColor(.secondary)
            HStack {
                if product.value(forKey: "is_variable") as? Bool ?? false {
                    Label(LocalizedStringKey("可变"), systemImage: "chart.xyaxis.line")
                        .font(.caption)
                }
                if product.value(forKey: "is_green") as? Bool ?? false {
                    Label(LocalizedStringKey("环保"), systemImage: "leaf")
                        .font(.caption)
                }
                if product.value(forKey: "is_tracker") as? Bool ?? false {
                    Label(LocalizedStringKey("追踪"), systemImage: "location")
                        .font(.caption)
                }
            }
        }
        .padding(.vertical, 4)
    }
}

struct TestView_Previews: PreviewProvider {
    static var previews: some View {
        TestView(ratesViewModel: RatesViewModel(globalTimer: GlobalTimer()))
            .environment(\.managedObjectContext, PersistenceController.preview.container.viewContext)
    }
}

// MARK: - Database Viewer
struct DBViewerView: View {
    let context: NSManagedObjectContext
    @Environment(\.dismiss) private var dismiss
    @State private var selectedEntity: String?
    @State private var entities: [String] = []
    @State private var records: [NSManagedObject] = []
    @State private var showingResetConfirmation = false
    @State private var resetStatus: String?
    
    init(context: NSManagedObjectContext) {
        self.context = context
        let model = context.persistentStoreCoordinator?.managedObjectModel
        _entities = State(initialValue: model?.entities.compactMap { $0.name } ?? [])
    }
    
    var body: some View {
        NavigationView {
            List {
                Section("Entities") {
                    ForEach(entities, id: \.self) { entity in
                        Button(action: {
                            selectedEntity = entity
                            loadRecords(for: entity)
                        }) {
                            HStack {
                                Text(entity)
                                Spacer()
                                if selectedEntity == entity {
                                    Image(systemName: "checkmark")
                                }
                            }
                        }
                    }
                }
                
                if let selectedEntity = selectedEntity {
                    Section("\(selectedEntity) Records: \(records.count)") {
                        if let status = resetStatus {
                            Text(status)
                                .foregroundColor(.secondary)
                                .italic()
                        }
                        
                        if records.isEmpty {
                            Text("No records found")
                                .foregroundColor(.secondary)
                        } else {
                            ForEach(records.indices, id: \.self) { index in
                                RecordView(record: records[index])
                            }
                        }
                    }
                }
            }
            .navigationTitle("Database Viewer")
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("Done") {
                        dismiss()
                    }
                }
                if selectedEntity != nil {
                    ToolbarItem(placement: .navigationBarLeading) {
                        Menu {
                            Button(action: {
                                if let entity = selectedEntity {
                                    loadRecords(for: entity)
                                }
                            }) {
                                Label("Refresh", systemImage: "arrow.clockwise")
                            }
                            
                            Button(role: .destructive, action: {
                                showingResetConfirmation = true
                            }) {
                                Label("Reset Data", systemImage: "trash")
                            }
                        } label: {
                            Image(systemName: "ellipsis.circle")
                        }
                    }
                }
            }
            .confirmationDialog(
                "Reset \(selectedEntity ?? "") Data",
                isPresented: $showingResetConfirmation,
                titleVisibility: .visible
            ) {
                Button("Reset All Records", role: .destructive) {
                    resetEntityData()
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("This will delete all records for this entity. This action cannot be undone.")
            }
        }
    }
    
    private func loadRecords(for entityName: String) {
        let fetchRequest = NSFetchRequest<NSManagedObject>(entityName: entityName)
        do {
            records = try context.fetch(fetchRequest)
            resetStatus = nil
        } catch {
            print("Error fetching records: \(error)")
            records = []
        }
    }
    
    private func resetEntityData() {
        guard let entityName = selectedEntity else { return }
        
        let fetchRequest = NSFetchRequest<NSFetchRequestResult>(entityName: entityName)
        let batchDeleteRequest = NSBatchDeleteRequest(fetchRequest: fetchRequest)
        batchDeleteRequest.resultType = .resultTypeObjectIDs
        
        do {
            let result = try context.execute(batchDeleteRequest) as? NSBatchDeleteResult
            let changes: [AnyHashable: Any] = [
                NSDeletedObjectsKey: result?.result as? [NSManagedObjectID] ?? []
            ]
            NSManagedObjectContext.mergeChanges(fromRemoteContextSave: changes, into: [context])
            try context.save()
            
            // Reload records and show status
            records = []
            resetStatus = "✓ Data reset successfully"
            
            // Schedule status message to clear after 3 seconds
            DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
                resetStatus = nil
            }
        } catch {
            print("Error resetting entity data: \(error)")
            resetStatus = "❌ Error resetting data: \(error.localizedDescription)"
        }
    }
}

struct RecordView: View {
    let record: NSManagedObject
    @State private var isExpanded = false
    
    var body: some View {
        VStack(alignment: .leading) {
            Button(action: { isExpanded.toggle() }) {
                HStack {
                    Text("Record \(record.objectID.uriRepresentation().lastPathComponent)")
                        .fontWeight(.medium)
                    Spacer()
                    Image(systemName: "chevron.right")
                        .rotationEffect(.degrees(isExpanded ? 90 : 0))
                        .animation(.easeInOut, value: isExpanded)
                }
            }
            
            if isExpanded {
                ForEach(Array(record.entity.attributesByName.keys).sorted(), id: \.self) { key in
                    HStack(alignment: .top) {
                        Text(key)
                            .foregroundColor(.secondary)
                            .font(.caption)
                        Spacer()
                        let value = record.value(forKey: key)
                        Text(formatValue(value))
                            .font(.caption)
                            .multilineTextAlignment(.trailing)
                    }
                    .padding(.leading)
                }
            }
        }
    }
    
    private func formatValue(_ value: Any?) -> String {
        guard let value = value else { return "nil" }
        
        switch value {
        case let date as Date:
            let formatter = DateFormatter()
            formatter.dateStyle = .medium
            formatter.timeStyle = .medium
            return formatter.string(from: date)
        case let number as NSNumber:
            return number.stringValue
        case let string as String:
            return string
        case let bool as Bool:
            return bool ? "true" : "false"
        case let data as Data:
            return "Data(\(data.count) bytes)"
        default:
            return String(describing: value)
        }
    }
}

extension Set {
    mutating func remove(atOffsets: IndexSet, from array: [Element]) {
        for index in atOffsets {
            remove(array[index])
        }
    }
}
