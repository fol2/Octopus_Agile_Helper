import Charts
import Combine
import CoreData
import OctopusHelperShared
import SwiftUI

// MARK: - Products Fetcher
class ProductsFetcher: NSObject, ObservableObject, NSFetchedResultsControllerDelegate {
    @Published private(set) var products: [ProductEntity] = []
    private let controller: NSFetchedResultsController<ProductEntity>

    init(context: NSManagedObjectContext) {
        let request = NSFetchRequest<ProductEntity>(entityName: "ProductEntity")
        request.sortDescriptors = [
            NSSortDescriptor(keyPath: \ProductEntity.display_name, ascending: true)
        ]

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
    func controllerDidChangeContent(_ controller: NSFetchedResultsController<NSFetchRequestResult>)
    {
        products = controller.fetchedObjects as? [ProductEntity] ?? []
    }
}

// MARK: - TestView
struct TestView: View {
    // CoreData context
    private let viewContext = PersistenceController.shared.container.viewContext

    // Global states and models
    @StateObject private var globalTimer = GlobalTimer()
    @StateObject private var ratesViewModel: RatesViewModel
    @StateObject private var consumptionVM = ConsumptionViewModel()
    @StateObject private var productsFetcher: ProductsFetcher
    @EnvironmentObject private var globalSettings: GlobalSettingsManager

    // Repositories & paths
    private let repository = RatesRepository.shared
    @State private var navigationPath = NavigationPath()

    // Sheets & modals
    @State private var showingDBViewer = false
    @State private var showingSettings = false

    // Product & Tariff Selections
    @State private var selectedProductCode: String?
    @State private var availableTariffCodes: [String] = []
    @State private var selectedTariffCode: String?

    // Loaded data
    @State private var standingCharges: [NSManagedObject] = []

    // MARK: - Computed
    var products: [ProductEntity] {
        productsFetcher.products
    }

    private var combinedRates: [NSManagedObject] {
        guard let tariffCode = selectedTariffCode else {
            return []
        }
        return ratesViewModel.allRates(for: tariffCode)
    }

    private var availableRateProducts: Set<String> {
        let all = combinedRates.compactMap {
            $0.value(forKey: "tariff_code") as? String
        }
        return Set(all)
    }

    // MARK: - Initializer
    init(ratesViewModel: RatesViewModel) {
        self._ratesViewModel = StateObject(wrappedValue: ratesViewModel)
        self._consumptionVM = StateObject(wrappedValue: ConsumptionViewModel())
        self._productsFetcher = StateObject(
            wrappedValue: ProductsFetcher(
                context: PersistenceController.shared.container.viewContext)
        )
    }

    // MARK: - Body
    var body: some View {
        NavigationStack(path: $navigationPath) {
            List {
                // 1. Fetch & Sync Data Section
                DataFetchSection(
                    products: products,
                    selectedProductCode: $selectedProductCode,
                    availableTariffCodes: $availableTariffCodes,
                    selectedTariffCode: $selectedTariffCode,
                    showingDBViewer: $showingDBViewer,
                    ratesViewModel: ratesViewModel,
                    consumptionVM: consumptionVM
                )

                // 2. Standing Charges
                StandingChargesSection(
                    standingCharges: $standingCharges,
                    onAppearAction: {
                        Task { await refreshRatesAndCharges() }
                    }
                )

                // 3. Rates
                RatesSection(
                    combinedRates: combinedRates,
                    availableRateProducts: availableRateProducts
                )

                // 4. Consumption
                ConsumptionSection()

                // 5. Calculations (placeholder)
                CalculationsSection()

                // 6. Settings Overview
                SettingsOverviewSection()
            }
            .listStyle(.insetGrouped)
            .onChange(of: selectedTariffCode) { _, newTariff in
                if newTariff == nil {
                    standingCharges = []
                } else {
                    loadRatesFromCoreData()
                    Task {
                        await refreshRatesAndCharges()
                    }
                }
            }
            .onAppear {
                globalTimer.startTimer()
                Task {
                    await consumptionVM.loadData()
                    if selectedTariffCode != nil {
                        loadRatesFromCoreData()
                        await refreshRatesAndCharges()
                    }
                }
            }
            .navigationDestination(for: String.self) { route in
                switch route {
                case "products_list":
                    ProductsListView(products: products)
                default:
                    EmptyView()
                }
            }
            .sheet(isPresented: $showingDBViewer) {
                DBViewerView(context: viewContext)
            }
            .sheet(isPresented: $showingSettings) {
                SettingsView()
            }
            .navigationTitle("Test View")
            .navigationBarTitleDisplayMode(.large)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    NavigationLink(destination: SettingsView()) {
                        Image(systemName: "gear")
                            .foregroundColor(Theme.mainTextColor)
                            .font(Theme.secondaryFont())
                    }
                }
            }
        }
        .onDisappear {
            globalTimer.stopTimer()
        }
    }
}

// MARK: - Actions
extension TestView {
    /// Loads rates from CoreData for the selected tariff
    private func loadRatesFromCoreData() {
        guard let tariffCode = selectedTariffCode else { return }

        Task {
            do {
                let freshRates = try await repository.fetchAllRates()
                let filtered = freshRates.filter { rate in
                    (rate.value(forKey: "tariff_code") as? String) == tariffCode
                }
                if !filtered.isEmpty {
                    await MainActor.run {
                        var state = ratesViewModel.productStates[tariffCode] ?? ProductRatesState()
                        state.allRates = filtered
                        state.upcomingRates = ratesViewModel.filterUpcoming(
                            rates: filtered, now: Date())
                        ratesViewModel.productStates[tariffCode] = state
                    }
                }
            } catch {
                print("❌ Error loading rates: \(error)")
            }
        }
    }

    /// Refresh rates and standing charges from local or remote
    @MainActor
    private func refreshRatesAndCharges() async {
        guard let tariffCode = selectedTariffCode else {
            standingCharges = []
            return
        }

        // Load from ViewModel
        standingCharges = ratesViewModel.standingCharges(tariffCode: tariffCode)

        // If empty, load from repository
        if standingCharges.isEmpty {
            do {
                let freshStandingCharges = try await repository.fetchAllStandingCharges()
                standingCharges = freshStandingCharges.filter { charge in
                    (charge.value(forKey: "tariff_code") as? String) == tariffCode
                }
            } catch {
                print("❌ Error loading standing charges: \(error)")
            }
        }
    }
}

// MARK: - DataFetchSection
struct DataFetchSection: View {
    let products: [ProductEntity]

    @Binding var selectedProductCode: String?
    @Binding var availableTariffCodes: [String]
    @Binding var selectedTariffCode: String?
    @Binding var showingDBViewer: Bool

    @ObservedObject var ratesViewModel: RatesViewModel
    @ObservedObject var consumptionVM: ConsumptionViewModel

    @State private var navigationToProductsList: String?

    var body: some View {
        Section("Fetch Data") {
            // 1. Status
            let statusText: String = {
                if let code = selectedTariffCode,
                    let state = ratesViewModel.productStates[code]
                {
                    return "Status: \(state.fetchStatus.description)"
                } else {
                    return "Status: Not Started"
                }
            }()
            Text(statusText)

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
                    Text("Products: \(products.count)")
                        .font(.caption)
                        .foregroundColor(.gray)
                        .padding(.trailing, -16)
                }
            }

            // 3. Product Code Selection
            productPicker

            // 4. Fetch Product Details
            Button(action: {
                guard let code = selectedProductCode else { return }
                Task {
                    do {
                        print("🌐 Fetching product details from API for: \(code)")
                        let startTime = Date()
                        _ = try await ProductDetailRepository.shared
                            .fetchAndStoreProductDetail(productCode: code)
                        let codes = try await ProductDetailRepository.shared
                            .fetchTariffCodes(for: code)
                        print("📊 Fetched tariff codes: \(codes)")
                        await MainActor.run {
                            self.availableTariffCodes = codes
                            self.selectedTariffCode = nil
                        }
                        let duration = Date().timeIntervalSince(startTime)
                        print(
                            "✅ API fetch completed in \(String(format: "%.2f", duration)) seconds")
                    } catch {
                        print("❌ Error fetching from API: \(error.localizedDescription)")
                        await MainActor.run {
                            self.availableTariffCodes = []
                            self.selectedTariffCode = nil
                        }
                    }
                }
            }) {
                Label(
                    String(localized: "Fetch Product Details"),
                    systemImage: "doc.text.magnifyingglass")
            }
            .buttonStyle(.bordered)
            .disabled(selectedProductCode == nil)

            // 5. Tariff Code Selection
            if !availableTariffCodes.isEmpty {
                tariffPicker
            }

            // 6. Fetch Rates
            Button(action: {
                guard let code = selectedTariffCode else { return }
                Task {
                    await ratesViewModel.fetchRates(tariffCode: code)
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
                Label(
                    String(localized: "Fetch All Data"), systemImage: "arrow.triangle.2.circlepath")
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
    }

    // MARK: Sub-views in DataFetchSection
    private var productPicker: some View {
        Picker(
            "Select Product Code",
            selection: Binding(
                get: { selectedProductCode },
                set: { newValue in
                    selectedProductCode = newValue
                    if let code = newValue {
                        Task {
                            do {
                                print("🔍 Loading local product details for: \(code)")
                                let localDetails = try await ProductDetailRepository.shared
                                    .loadLocalProductDetail(code: code)
                                if !localDetails.isEmpty {
                                    let codes = try await ProductDetailRepository.shared
                                        .fetchTariffCodes(for: code)
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
            )
        ) {
            Text("Select a product code").tag(Optional<String>.none)
            ForEach(products, id: \.code) { product in
                Text(product.code ?? "").tag(Optional(product.code ?? ""))
            }
        }
        .pickerStyle(.menu)
    }

    private var tariffPicker: some View {
        Picker("Select Tariff Code", selection: $selectedTariffCode) {
            Text("Select a tariff code").tag(Optional<String>.none)
            ForEach(availableTariffCodes.sorted(), id: \.self) { code in
                Text(code).tag(Optional(code))
            }
        }
        .pickerStyle(.menu)
    }
}

// MARK: - StandingChargesSection
struct StandingChargesSection: View {
    @Binding var standingCharges: [NSManagedObject]
    var onAppearAction: (() -> Void)?

    var body: some View {
        Section(header: Text("Standing Charges")) {
            if standingCharges.isEmpty {
                Text("No standing charges available")
                    .foregroundColor(.secondary)
                    .onAppear {
                        onAppearAction?()
                    }
            } else {
                Text("Standing Charges (\(standingCharges.count))")
                    .font(.headline)

                // List of standing charges
                StandingChargesListView(standingCharges: standingCharges)
            }
        }
    }
}

// MARK: - RatesSection
struct RatesSection: View {
    let combinedRates: [NSManagedObject]
    let availableRateProducts: Set<String>

    var body: some View {
        Section {
            if combinedRates.isEmpty {
                Text("No rates available")
                    .foregroundColor(.secondary)
            } else {
                Text("Rates (\(combinedRates.count))")

                VStack(alignment: .leading) {
                    Text("Available Rates: \(combinedRates.count)")
                        .font(.caption)
                        .foregroundColor(.secondary)
                    Text("Distinct Products: \(availableRateProducts.count)")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }

                RatesChartView(combinedRates: combinedRates)
            }
        }
    }
}

// MARK: - ConsumptionSection
struct ConsumptionSection: View {
    @EnvironmentObject private var globalSettings: GlobalSettingsManager

    var body: some View {
        Section(header: Text("Consumption")) {
            if globalSettings.settings.electricityMPAN != nil
                && globalSettings.settings.electricityMeterSerialNumber != nil
            {
                Text("Consumption data available")
                    .foregroundColor(.primary)
            } else {
                Text("Configure MPAN and Meter Serial to view consumption")
                    .foregroundColor(.secondary)
            }
        }
    }
}

// MARK: - CalculationsSection
struct CalculationsSection: View {
    @EnvironmentObject private var globalSettings: GlobalSettingsManager

    var body: some View {
        Section(LocalizedStringKey("Calculations")) {
            if !globalSettings.settings.apiKey.isEmpty {
                Text("Ready for calculations")
                    .foregroundColor(.primary)
            } else {
                Text("Configure API key to enable calculations")
                    .foregroundColor(.secondary)
            }
        }
    }
}

// MARK: - SettingsOverviewSection
struct SettingsOverviewSection: View {
    @EnvironmentObject private var globalSettings: GlobalSettingsManager

    private var regionText: String {
        let input = globalSettings.settings.regionInput.trimmingCharacters(
            in: .whitespacesAndNewlines
        ).uppercased()
        return input
    }

    private var activeCardsCount: Int {
        globalSettings.settings.cardSettings.filter { $0.isEnabled }.count
    }

    var body: some View {
        Section {
            HStack(alignment: .top, spacing: 20) {
                // Left side labels
                VStack(alignment: .leading, spacing: 12) {
                    Text("Region")
                        .foregroundStyle(Theme.secondaryTextColor)
                    Text("API Status")
                        .foregroundStyle(Theme.secondaryTextColor)
                    Text("MPAN")
                        .foregroundStyle(Theme.secondaryTextColor)
                    Text("Meter Serial")
                        .foregroundStyle(Theme.secondaryTextColor)
                    Text("Active Cards")
                        .foregroundStyle(Theme.secondaryTextColor)
                    Text("Rate Display")
                        .foregroundStyle(Theme.secondaryTextColor)
                    Text("Language")
                        .foregroundStyle(Theme.secondaryTextColor)
                }

                // Right side values
                VStack(alignment: .trailing, spacing: 12) {
                    Text(regionText)
                        .foregroundStyle(Theme.secondaryTextColor)

                    Text(!globalSettings.settings.apiKey.isEmpty ? "Configured" : "Not Configured")
                        .foregroundStyle(
                            !globalSettings.settings.apiKey.isEmpty ? Theme.mainTextColor : .red)

                    Text(
                        globalSettings.settings.electricityMPAN != nil
                            ? "Configured" : "Not Configured"
                    )
                    .foregroundStyle(
                        globalSettings.settings.electricityMPAN != nil ? Theme.mainTextColor : .red)

                    Text(
                        globalSettings.settings.electricityMeterSerialNumber != nil
                            ? "Configured" : "Not Configured"
                    )
                    .foregroundStyle(
                        globalSettings.settings.electricityMeterSerialNumber != nil
                            ? Theme.mainTextColor : .red)

                    Text("\(activeCardsCount)")
                        .foregroundStyle(Theme.secondaryTextColor)

                    Text(globalSettings.settings.showRatesInPounds ? "Pounds (£)" : "Pence (p)")
                        .foregroundStyle(Theme.secondaryTextColor)

                    Text(globalSettings.settings.selectedLanguage.displayNameWithAutonym)
                        .foregroundStyle(Theme.secondaryTextColor)
                }
                .frame(maxWidth: .infinity, alignment: .trailing)
            }
            .padding(.vertical, 8)
        } header: {
            Text("Settings Overview")
                .font(Theme.subFont())
                .foregroundStyle(Theme.secondaryTextColor)
                .textCase(.none)
        }
    }
}

// MARK: - ProductsListView
struct ProductsListView: View {
    let products: [ProductEntity]

    var body: some View {
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
    }
}

// MARK: - ProductRow
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

// MARK: - StandingChargesListView
struct StandingChargesListView: View {
    let standingCharges: [NSManagedObject]

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(standingCharges, id: \.self) { charge in
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text("Value (inc. VAT):")
                            .foregroundColor(.secondary)
                        Text(
                            String(
                                format: "%.2fp",
                                charge.value(forKey: "value_including_vat") as? Double ?? 0.0)
                        )
                        .bold()
                    }

                    HStack {
                        Text("Value (exc. VAT):")
                            .foregroundColor(.secondary)
                        Text(
                            String(
                                format: "%.2fp",
                                charge.value(forKey: "value_excluding_vat") as? Double ?? 0.0))
                    }

                    HStack {
                        Text("Valid from:")
                            .foregroundColor(.secondary)
                        Text((charge.value(forKey: "valid_from") as? Date)?.formatted() ?? "N/A")
                    }

                    HStack {
                        Text("Valid to:")
                            .foregroundColor(.secondary)
                        Text((charge.value(forKey: "valid_to") as? Date)?.formatted() ?? "Ongoing")
                    }
                }
                .padding(.vertical, 4)

                if charge != standingCharges.last {
                    Divider()
                }
            }
        }
        .padding(.horizontal, 4)
    }
}

// MARK: - RatesChartView
struct RatesChartView: View {
    let combinedRates: [NSManagedObject]

    struct ChartDataPoint: Identifiable, Hashable {
        let id = UUID()
        let date: Date
        let value: Double
    }

    var body: some View {
        let chartData = combinedRates.prefix(48).map { rate in
            ChartDataPoint(
                date: rate.value(forKey: "valid_from") as? Date ?? Date(),
                value: rate.value(forKey: "value_including_vat") as? Double ?? 0.0
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
}

// MARK: - DBViewerView
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
                // 1. Entities
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

                // 2. Records
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

                            Button(
                                role: .destructive,
                                action: {
                                    showingResetConfirmation = true
                                }
                            ) {
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

    // MARK: - Helpers
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

            // Reload
            records = []
            resetStatus = "✓ Data reset successfully"

            // Clear status after a short delay
            DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
                resetStatus = nil
            }
        } catch {
            print("Error resetting entity data: \(error)")
            resetStatus = "❌ Error resetting data: \(error.localizedDescription)"
        }
    }
}

// MARK: - RecordView
struct RecordView: View {
    let record: NSManagedObject
    @State private var isExpanded = false

    var body: some View {
        VStack(alignment: .leading) {
            Button(action: { isExpanded.toggle() }) {
                HStack {
                    let idString = record.objectID.uriRepresentation().lastPathComponent
                    Text("Record \(idString)")
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
            return date.formatted(date: .abbreviated, time: .shortened)
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

// MARK: - Previews
struct TestView_Previews: PreviewProvider {
    static var previews: some View {
        TestView(ratesViewModel: RatesViewModel(globalTimer: GlobalTimer()))
            .environment(
                \.managedObjectContext, PersistenceController.preview.container.viewContext
            )
            .environmentObject(GlobalSettingsManager())
    }
}
