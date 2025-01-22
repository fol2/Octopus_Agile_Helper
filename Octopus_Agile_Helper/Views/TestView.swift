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
    @StateObject private var consumptionVM: ConsumptionViewModel
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

    // Pass tariffVM to DateRangeCalculationSection
    @StateObject private var tariffVM = TariffViewModel()

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
        self._consumptionVM = StateObject(
            wrappedValue: ConsumptionViewModel(globalSettingsManager: GlobalSettingsManager()))
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
                ConsumptionSection(consumptionVM: consumptionVM)

                // 5. Tariff Calculations Testing
                TariffCalculationsSection(selectedTariffCode: $selectedTariffCode)

                // 6. Date Range Calculation Testing
                DateRangeCalculationSection(
                    selectedTariffCode: $selectedTariffCode,
                    tariffVM: tariffVM
                )

                // 7. Rates Time Window Testing
                RatesTimeWindowTestSection()

                // 8. Settings Overview
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
                print("Debug - TestView appeared")
                print("Debug - GlobalSettings exists: \(String(describing: _globalSettings))")
                print(
                    "Debug - Current AGILE Code in settings: \(globalSettings.settings.currentAgileCode)"
                )
                globalTimer.startTimer()
                Task {
                    print("Debug - Starting initialization")
                    // Update ConsumptionViewModel with the environment GlobalSettingsManager
                    consumptionVM.updateGlobalSettingsManager(globalSettings)

                    // Only set AGILE plan, don't sync products
                    print("Debug - Setting AGILE plan")
                    await ratesViewModel.setAgileProductFromAccountOrFallback(
                        globalSettings: globalSettings)
                    print("Debug - AGILE plan set to: \(ratesViewModel.currentAgileCode)")

                    // Then load consumption data and rates if needed
                    print("Debug - Loading consumption data")
                    await consumptionVM.loadData()
                    if selectedTariffCode != nil {
                        print("Debug - Loading rates for tariff: \(selectedTariffCode ?? "")")
                        loadRatesFromCoreData()
                        await refreshRatesAndCharges()
                    }
                    print("Debug - Initialization complete")
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
        .environmentObject(ratesViewModel)
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
                    ratesViewModel.productStates[code] != nil
                {
                    return "Status: \(ratesViewModel.fetchState.description)"
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

                NavigationLink(value: "products_list" as String) {
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

            // 8. Fetch AGILE Rate
            Button(action: {
                Task {
                    await ratesViewModel.initializeProducts()
                }
            }) {
                Label(
                    String(localized: "Fetch AGILE Rate"),
                    systemImage: "arrow.triangle.2.circlepath")
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
    @ObservedObject var consumptionVM: ConsumptionViewModel

    var body: some View {
        Section(header: Text("Consumption")) {
            if globalSettings.settings.electricityMPAN != nil
                && globalSettings.settings.electricityMeterSerialNumber != nil
            {
                // Status
                HStack {
                    Text("Status:")
                    Text(statusText)
                        .foregroundColor(statusColor)
                }

                // Data Range
                if let minDate = consumptionVM.minInterval,
                    let maxDate = consumptionVM.maxInterval
                {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Data Range:")
                            .font(.caption)
                            .foregroundColor(.secondary)
                        Text("\(minDate.formatted()) to")
                            .font(.caption)
                        Text(maxDate.formatted())
                            .font(.caption)
                    }
                }

                // Record Count
                Text("Records: \(consumptionVM.consumptionRecords.count)")
                    .font(.caption)
                    .foregroundColor(.secondary)

                // Latest Consumption
                if let latest = consumptionVM.consumptionRecords.first {
                    if let consumption = latest.value(forKey: "consumption") as? Double,
                        let interval = latest.value(forKey: "interval_end") as? Date
                    {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Latest Reading:")
                                .font(.caption)
                                .foregroundColor(.secondary)
                            Text("\(consumption, specifier: "%.2f") kWh at")
                                .font(.caption)
                            Text(interval.formatted())
                                .font(.caption)
                        }
                    }
                }
            } else {
                Text("Configure MPAN and Meter Serial to view consumption")
                    .foregroundColor(.secondary)
            }
        }
    }

    private var statusText: String {
        switch consumptionVM.fetchState {
        case .idle: return "Idle"
        case .loading: return "Loading..."
        case .partial: return "Partial Data"
        case .success: return "Complete"
        case .failure(let error): return "Error: \(error.localizedDescription)"
        }
    }

    private var statusColor: Color {
        switch consumptionVM.fetchState {
        case .idle: return .primary
        case .loading: return .blue
        case .partial: return .orange
        case .success: return .green
        case .failure: return .red
        }
    }
}

// MARK: - TariffCalculationsSection
struct TariffCalculationsSection: View {
    @EnvironmentObject private var globalSettings: GlobalSettingsManager
    @Binding var selectedTariffCode: String?
    @State private var startDate = Calendar.current.startOfDay(
        for: Calendar.current.date(byAdding: .day, value: -7, to: Date()) ?? Date())
    @State private var endDate = Calendar.current.startOfDay(for: Date())
    @State private var calculationResults: [NSManagedObject] = []
    @State private var isCalculating = false
    @State private var errorMessage: String?
    @State private var calculationType = "single"  // "single" or "account"
    @State private var dateRangeError: String?
    @State private var isLoadingStored = false

    // State for date range constraints
    @State private var consumptionMinDate: Date?
    @State private var consumptionMaxDate: Date?
    @State private var productAvailableFrom: Date?

    private let repository: TariffCalculationRepository
    private let context: NSManagedObjectContext
    private let consumptionRepo = ElectricityConsumptionRepository.shared
    private let productsRepo = ProductsRepository.shared

    init(selectedTariffCode: Binding<String?>) {
        self._selectedTariffCode = selectedTariffCode
        self.context = PersistenceController.shared.container.viewContext
        self.repository = TariffCalculationRepository(context: self.context)
    }

    // Helper to normalize dates to start of day
    private func normalizeToStartOfDay(_ date: Date) -> Date {
        return Calendar.current.startOfDay(for: date)
    }

    // Helper to decode account data
    private var accountResponse: OctopusAccountResponse? {
        guard let accountData = globalSettings.settings.accountData,
            let decoded = try? JSONDecoder().decode(OctopusAccountResponse.self, from: accountData)
        else {
            return nil
        }
        return decoded
    }

    var body: some View {
        Section {
            VStack(alignment: .leading, spacing: 12) {
                // Calculation Type Picker
                Picker("Calculation Type", selection: $calculationType) {
                    Text("Single Tariff").tag("single")
                    Text("Account Based").tag("account")
                }
                .pickerStyle(.segmented)
                .padding(.bottom, 8)
                .onChange(of: calculationType) { _, _ in
                    Task {
                        await calculateCosts()
                    }
                }

                // Date Selection
                Group {
                    HStack {
                        Text("Start:")
                            .foregroundColor(.secondary)
                        DatePicker(
                            "Start Date",
                            selection: Binding(
                                get: { startDate },
                                set: { newValue in
                                    startDate = normalizeToStartOfDay(newValue)
                                    validateDateRange()
                                }
                            ),
                            in: getStartDateRange(),
                            displayedComponents: [.date]
                        )
                        .labelsHidden()
                    }

                    HStack {
                        Text("End:")
                            .foregroundColor(.secondary)
                        DatePicker(
                            "End Date",
                            selection: Binding(
                                get: { endDate },
                                set: { newValue in
                                    endDate = normalizeToStartOfDay(newValue)
                                    validateDateRange()
                                }
                            ),
                            in: getEndDateRange(),
                            displayedComponents: [.date]
                        )
                        .labelsHidden()
                    }
                }

                // Date Range Error
                if let error = dateRangeError {
                    Text(error)
                        .foregroundColor(.red)
                        .font(.caption)
                }

                // Action Buttons
                HStack {
                    // Load Stored Button
                    Button(action: {
                        Task {
                            await loadStoredCalculation()
                        }
                    }) {
                        HStack {
                            if isLoadingStored {
                                ProgressView()
                                    .progressViewStyle(CircularProgressViewStyle())
                            }
                            Text("Load Stored")
                        }
                    }
                    .buttonStyle(.bordered)
                    .disabled(
                        isLoadingStored
                            || (calculationType == "single" && selectedTariffCode == nil)
                            || (calculationType == "account" && accountResponse == nil))
                }

                // Requirements Notice
                if calculationType == "single" && selectedTariffCode == nil {
                    Text("Please select a tariff code above to calculate costs")
                        .font(.caption)
                        .foregroundColor(.secondary)
                } else if calculationType == "account" && accountResponse == nil {
                    Text(
                        "Please configure your Octopus account in settings to use account-based calculations"
                    )
                    .font(.caption)
                    .foregroundColor(.secondary)
                }

                // Error Message
                if let error = errorMessage {
                    Text(error)
                        .foregroundColor(.red)
                        .font(.caption)
                }

                // Results Display
                if !calculationResults.isEmpty {
                    Divider()
                    Text("Calculation Results")
                        .font(.headline)
                        .padding(.vertical, 4)

                    ScrollView {
                        VStack(alignment: .leading, spacing: 12) {
                            ForEach(calculationResults, id: \.self) { result in
                                TariffCalculationResultView(calculation: result)
                                if result != calculationResults.last {
                                    Divider()
                                }
                            }
                        }
                    }
                    .frame(maxHeight: 300)
                }
            }
            .padding(.vertical, 8)
            .onAppear {
                Task {
                    await loadDateConstraints()
                }
            }
            .onChange(of: selectedTariffCode) { _, _ in
                Task {
                    await loadProductAvailability()
                }
            }
            .onChange(of: calculationType) { _, _ in
                validateDateRange()
            }
        } header: {
            Text("Tariff Calculations")
                .font(Theme.subFont())
                .foregroundStyle(Theme.secondaryTextColor)
                .textCase(.none)
        }
    }

    private func getStartDateRange() -> ClosedRange<Date> {
        let minDate: Date
        if calculationType == "single" {
            // For single tariff, use the later of consumption min date and product available from
            minDate =
                [consumptionMinDate, productAvailableFrom]
                .compactMap { $0 }
                .max() ?? .distantPast
        } else {
            // For account calculation, only use consumption min date
            minDate = consumptionMinDate ?? .distantPast
        }
        return minDate...endDate
    }

    private func getEndDateRange() -> ClosedRange<Date> {
        return startDate...(consumptionMaxDate ?? .distantFuture)
    }

    private func loadDateConstraints() async {
        do {
            let records = try await consumptionRepo.fetchAllRecords()
            await MainActor.run {
                consumptionMinDate = records.compactMap {
                    $0.value(forKey: "interval_start") as? Date
                }
                .min()
                .map { normalizeToStartOfDay($0) }
                consumptionMaxDate = records.compactMap {
                    $0.value(forKey: "interval_end") as? Date
                }
                .max()
                .map { normalizeToStartOfDay($0) }
                validateDateRange()
            }
        } catch {
            print("Error fetching consumption date range: \(error)")
        }
    }

    private func loadProductAvailability() async {
        guard let tariffCode = selectedTariffCode else {
            await MainActor.run {
                productAvailableFrom = nil
                validateDateRange()
            }
            return
        }

        // Extract product code from tariff code (e.g. "E-1R-AGILE-24-04-03-H" -> "AGILE-24-04-03")
        let parts = tariffCode.components(separatedBy: "-")
        guard parts.count >= 6 else {
            await MainActor.run {
                productAvailableFrom = nil
                validateDateRange()
            }
            return
        }
        let productCode = parts[2...5].joined(separator: "-")

        do {
            let products = try await productsRepo.fetchLocalProducts()
            let product = products.first { $0.value(forKey: "code") as? String == productCode }
            await MainActor.run {
                productAvailableFrom = (product?.value(forKey: "available_from") as? Date)
                    .map { normalizeToStartOfDay($0) }
                validateDateRange()
            }
        } catch {
            print("Error fetching product available_from: \(error)")
            await MainActor.run {
                productAvailableFrom = nil
                validateDateRange()
            }
        }
    }

    private func validateDateRange() {
        // Clear any existing error
        dateRangeError = nil

        // 1. Basic validation - end date must be after start date
        guard endDate > startDate else {
            dateRangeError = "End date must be after start date"
            return
        }

        // 2. Check consumption data range
        if let min = consumptionMinDate, startDate < min {
            dateRangeError =
                "Start date cannot be before earliest consumption data (\(min.formatted(date: .abbreviated, time: .omitted)))"
            return
        }
        if let max = consumptionMaxDate, endDate > max {
            dateRangeError =
                "End date cannot be after latest consumption data (\(max.formatted(date: .abbreviated, time: .omitted)))"
            return
        }

        // 3. For single tariff calculation, check product availability
        if calculationType == "single", let availableFrom = productAvailableFrom {
            if startDate < availableFrom {
                dateRangeError =
                    "Start date cannot be before product availability date (\(availableFrom.formatted(date: .abbreviated, time: .omitted)))"
                return
            }
        }
    }

    private func calculateCosts() async {
        isCalculating = true
        errorMessage = nil
        calculationResults = []

        do {
            if calculationType == "single" {
                // Single tariff calculation
                if let tariffCode = selectedTariffCode {
                    // First try to fetch stored calculation
                    if let stored = try await repository.fetchStoredCalculation(
                        tariffCode: tariffCode,
                        intervalType: "CUSTOM",
                        periodStart: startDate,
                        periodEnd: endDate
                    ) {
                        await MainActor.run {
                            calculationResults = [stored]
                        }
                    } else {
                        // If no stored calculation, calculate new one
                        let result = try await repository.calculateCostForPeriod(
                            tariffCode: tariffCode,
                            startDate: startDate,
                            endDate: endDate,
                            intervalType: "CUSTOM"
                        )

                        await MainActor.run {
                            calculationResults = [result]
                        }
                    }
                }
            } else {
                // Account-based calculation
                if let accountData = accountResponse {
                    var storedResults: [NSManagedObject] = []
                    var needsCalculation = false

                    // Try to fetch stored calculations for all tariffs
                    for property in accountData.properties {
                        if let elecMP = property.electricity_meter_points?.first,
                            let agreements = elecMP.agreements
                        {
                            for agreement in agreements {
                                guard let tariffCode = agreement.tariff_code as String? else {
                                    continue
                                }

                                if let stored = try await repository.fetchStoredCalculation(
                                    tariffCode: tariffCode,
                                    intervalType: "CUSTOM",
                                    periodStart: startDate,
                                    periodEnd: endDate
                                ) {
                                    storedResults.append(stored)
                                } else {
                                    needsCalculation = true
                                    break
                                }
                            }
                        }
                    }

                    // If we have all stored calculations, use them
                    if !needsCalculation && !storedResults.isEmpty {
                        await MainActor.run {
                            calculationResults = storedResults
                        }
                    } else {
                        // Otherwise calculate all
                        let results = try await repository.calculateCostForAccount(
                            accountData: accountData,
                            startDate: startDate,
                            endDate: endDate,
                            intervalType: "CUSTOM"
                        )

                        await MainActor.run {
                            calculationResults = results
                        }
                    }
                } else {
                    errorMessage = "No account data available"
                }
            }
        } catch {
            await MainActor.run {
                errorMessage = "Calculation failed: \(error.localizedDescription)"
            }
        }

        await MainActor.run {
            isCalculating = false
        }
    }

    private func loadStoredCalculation() async {
        isLoadingStored = true
        errorMessage = nil

        do {
            if calculationType == "single" {
                // Single tariff calculation loading
                if let tariffCode = selectedTariffCode {
                    if let stored = try await repository.fetchStoredCalculation(
                        tariffCode: tariffCode,
                        intervalType: "CUSTOM",
                        periodStart: startDate,
                        periodEnd: endDate
                    ) {
                        await MainActor.run {
                            calculationResults = [stored]
                        }
                    } else {
                        await MainActor.run {
                            errorMessage = "No stored calculation found for these parameters"
                        }
                    }
                }
            } else {
                // Account-based calculation loading
                if let accountData = accountResponse {
                    // Get all tariff codes from the account's agreements
                    var storedResults: [NSManagedObject] = []

                    for property in accountData.properties {
                        if let elecMP = property.electricity_meter_points?.first,
                            let agreements = elecMP.agreements
                        {
                            for agreement in agreements {
                                // Safely unwrap the optional tariff_code
                                guard let tariffCode = agreement.tariff_code as String? else {
                                    continue
                                }

                                // Try to load stored calculation for each tariff
                                if let stored = try await repository.fetchStoredCalculation(
                                    tariffCode: tariffCode,
                                    intervalType: "CUSTOM",
                                    periodStart: startDate,
                                    periodEnd: endDate
                                ) {
                                    storedResults.append(stored)
                                }
                            }
                        }
                    }

                    await MainActor.run {
                        if storedResults.isEmpty {
                            errorMessage =
                                "No stored calculations found for account tariffs in this period"
                        } else {
                            calculationResults = storedResults
                        }
                    }
                } else {
                    await MainActor.run {
                        errorMessage = "No account data available"
                    }
                }
            }
        } catch {
            await MainActor.run {
                errorMessage = "Error loading stored calculation: \(error.localizedDescription)"
            }
        }

        await MainActor.run {
            isLoadingStored = false
        }
    }
}

// MARK: - TariffCalculationResultView
struct TariffCalculationResultView: View {
    let calculation: NSManagedObject

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            // Tariff Code
            Text(calculation.value(forKey: "tariff_code") as? String ?? "Unknown Tariff")
                .font(.headline)

            // Period
            if let start = calculation.value(forKey: "period_start") as? Date,
                let end = calculation.value(forKey: "period_end") as? Date
            {
                Text("Period: \(start.formatted()) to \(end.formatted())")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }

            // Consumption
            if let consumption = calculation.value(forKey: "total_consumption_kwh") as? Double {
                Text("Total Usage: \(String(format: "%.2f kWh", consumption))")
            }

            // Costs
            Group {
                if let costExc = calculation.value(forKey: "total_cost_exc_vat") as? Double {
                    Text("Cost (exc. VAT): £\(String(format: "%.2f", costExc/100))")
                }
                if let costInc = calculation.value(forKey: "total_cost_inc_vat") as? Double {
                    Text("Cost (inc. VAT): £\(String(format: "%.2f", costInc/100))")
                }
            }
            .font(.subheadline)

            // Standing Charges
            Group {
                if let standingExc = calculation.value(forKey: "standing_charge_cost_exc_vat")
                    as? Double
                {
                    Text("Standing Charge (exc. VAT): £\(String(format: "%.2f", standingExc/100))")
                }
                if let standingInc = calculation.value(forKey: "standing_charge_cost_inc_vat")
                    as? Double
                {
                    Text("Standing Charge (inc. VAT): £\(String(format: "%.2f", standingInc/100))")
                }
            }
            .font(.caption)
            .foregroundColor(.secondary)

            // Average Rates
            Group {
                if let avgExc = calculation.value(forKey: "average_unit_rate_exc_vat") as? Double {
                    Text("Avg. Rate (exc. VAT): \(String(format: "%.2f p/kWh", avgExc))")
                }
                if let avgInc = calculation.value(forKey: "average_unit_rate_inc_vat") as? Double {
                    Text("Avg. Rate (inc. VAT): \(String(format: "%.2f p/kWh", avgInc))")
                }
            }
            .font(.caption)
            .foregroundColor(.secondary)
        }
        .padding(.vertical, 4)
    }
}

// MARK: - SettingsOverviewSection
struct SettingsOverviewSection: View {
    @EnvironmentObject private var globalSettings: GlobalSettingsManager
    @EnvironmentObject private var ratesViewModel: RatesViewModel
    @State private var lastAgileCode: String = ""

    private var regionText: String {
        let input = globalSettings.settings.regionInput.trimmingCharacters(
            in: .whitespacesAndNewlines
        ).uppercased()
        return input.isEmpty ? "Not Set" : input
    }

    private var activeCardsCount: Int {
        globalSettings.settings.cardSettings.filter { $0.isEnabled }.count
    }

    private var agileStatusText: String {
        print("Debug - currentAgileCode: \(ratesViewModel.currentAgileCode)")
        print("Debug - accountData exists: \(globalSettings.settings.accountData != nil)")
        print("Debug - lastAgileCode: \(lastAgileCode)")

        if ratesViewModel.currentAgileCode.isEmpty {
            return "Not Set"
        }

        // Check if we have account data
        if let accountData = globalSettings.settings.accountData,
            !accountData.isEmpty
        {
            return "\(ratesViewModel.currentAgileCode) (Account Based)"
        } else {
            return "\(ratesViewModel.currentAgileCode) (Default)"
        }
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
                    Text("AGILE Plan")
                        .foregroundStyle(Theme.secondaryTextColor)
                }

                // Right side values
                VStack(alignment: .trailing, spacing: 12) {
                    Text(regionText)
                        .foregroundStyle(.primary)

                    Text(!globalSettings.settings.apiKey.isEmpty ? "Configured" : "Not Configured")
                        .foregroundStyle(
                            !globalSettings.settings.apiKey.isEmpty ? .primary : Color.red)

                    Text(
                        globalSettings.settings.electricityMPAN != nil
                            ? (globalSettings.settings.electricityMPAN ?? "Not Set")
                            : "Not Configured"
                    )
                    .foregroundStyle(
                        globalSettings.settings.electricityMPAN != nil ? .primary : Color.red)

                    Text(
                        globalSettings.settings.electricityMeterSerialNumber != nil
                            ? (globalSettings.settings.electricityMeterSerialNumber ?? "Not Set")
                            : "Not Configured"
                    )
                    .foregroundStyle(
                        globalSettings.settings.electricityMeterSerialNumber != nil
                            ? .primary : Color.red)

                    Text("\(activeCardsCount)")
                        .foregroundStyle(.primary)

                    Text(globalSettings.settings.showRatesInPounds ? "Pounds (£)" : "Pence (p)")
                        .foregroundStyle(.primary)

                    Text(globalSettings.settings.selectedLanguage.displayNameWithAutonym)
                        .foregroundStyle(.primary)

                    Text(agileStatusText)
                        .foregroundStyle(.primary)
                }
                .frame(maxWidth: .infinity, alignment: .trailing)
            }
            .padding(.vertical, 8)
            .onChange(of: ratesViewModel.currentAgileCode) { _, newCode in
                print("Debug - AGILE code changed to: \(newCode)")
                lastAgileCode = newCode
            }
            .onAppear {
                print("Debug - SettingsOverviewSection appeared")
                print("Debug - API Key exists: \(!globalSettings.settings.apiKey.isEmpty)")
                print("Debug - MPAN exists: \(globalSettings.settings.electricityMPAN != nil)")
                print(
                    "Debug - Meter Serial exists: \(globalSettings.settings.electricityMeterSerialNumber != nil)"
                )
                print("Debug - Current AGILE Code: \(ratesViewModel.currentAgileCode)")
                lastAgileCode = ratesViewModel.currentAgileCode
            }
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

// MARK: - RatesTimeWindowTestSection
struct RatesTimeWindowTestSection: View {
    @EnvironmentObject private var globalSettings: GlobalSettingsManager
    @EnvironmentObject private var ratesViewModel: RatesViewModel
    @State private var pastHours: Int = 21
    @State private var timeWindowRates: [NSManagedObject] = []
    @State private var isLoading = false
    @State private var errorMessage: String?
    @State private var isSettingAgile = false

    private let repository = RatesRepository.shared

    var body: some View {
        Section {
            VStack(alignment: .leading, spacing: 12) {
                // Debug Info
                Group {
                    Text("Debug Info:")
                        .font(.caption)
                        .foregroundColor(.secondary)
                    Text("• Has AGILE Code: \(!globalSettings.settings.currentAgileCode.isEmpty)")
                        .font(.caption)
                        .foregroundColor(.secondary)
                    Text("• AGILE Code: '\(globalSettings.settings.currentAgileCode)'")
                        .font(.caption)
                        .foregroundColor(.secondary)
                    Text("• Is Loading: \(isLoading)")
                        .font(.caption)
                        .foregroundColor(.secondary)
                    Text("• RatesVM AGILE Code: '\(ratesViewModel.currentAgileCode)'")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }

                // Set AGILE Button
                Button(action: {
                    Task {
                        isSettingAgile = true
                        await ratesViewModel.setAgileProductFromAccountOrFallback(
                            globalSettings: globalSettings)
                        isSettingAgile = false
                    }
                }) {
                    HStack {
                        if isSettingAgile {
                            ProgressView()
                                .progressViewStyle(CircularProgressViewStyle())
                        }
                        Text("Set AGILE Product")
                    }
                }
                .buttonStyle(.bordered)
                .disabled(isSettingAgile)

                Divider()

                // Past Hours Stepper
                Stepper(value: $pastHours, in: 1...48) {
                    Text("Past Hours: \(pastHours)")
                        .font(.subheadline)
                }

                // Current AGILE Code Display
                Text("Using AGILE Code: \(globalSettings.settings.currentAgileCode)")
                    .font(.caption)
                    .foregroundColor(.secondary)

                // Fetch Button
                Button(action: {
                    Task {
                        await fetchTimeWindowRates()
                    }
                }) {
                    HStack {
                        if isLoading {
                            ProgressView()
                                .progressViewStyle(CircularProgressViewStyle())
                        }
                        Text("Fetch Time Window Rates")
                    }
                }
                .buttonStyle(.bordered)
                .disabled(isLoading || globalSettings.settings.currentAgileCode.isEmpty)

                // Error Message
                if let error = errorMessage {
                    Text(error)
                        .foregroundColor(.red)
                        .font(.caption)
                }

                // Results
                if !timeWindowRates.isEmpty {
                    Divider()

                    Text("Found \(timeWindowRates.count) rates")
                        .font(.headline)
                        .padding(.vertical, 4)

                    ScrollView {
                        VStack(alignment: .leading, spacing: 8) {
                            ForEach(timeWindowRates.indices, id: \.self) { index in
                                let rate = timeWindowRates[index]
                                if let validFrom = rate.value(forKey: "valid_from") as? Date,
                                    let valueInc = rate.value(forKey: "value_including_vat")
                                        as? Double
                                {
                                    HStack {
                                        Text(validFrom.formatted(date: .omitted, time: .shortened))
                                        Spacer()
                                        Text(String(format: "%.2fp", valueInc))
                                            .bold()
                                    }
                                    .font(.caption)

                                    if index < timeWindowRates.count - 1 {
                                        Divider()
                                    }
                                }
                            }
                        }
                    }
                    .frame(maxHeight: 200)
                }
            }
            .padding(.vertical, 8)
        } header: {
            Text("Time Window Test")
                .font(Theme.subFont())
                .foregroundStyle(Theme.secondaryTextColor)
                .textCase(.none)
        }
    }

    private func fetchTimeWindowRates() async {
        isLoading = true
        errorMessage = nil
        timeWindowRates = []

        do {
            let rates = try await repository.fetchRatesByTariffCode(
                globalSettings.settings.currentAgileCode,
                pastHours: pastHours
            )
            await MainActor.run {
                timeWindowRates = rates
            }
        } catch {
            await MainActor.run {
                errorMessage = "Error: \(error.localizedDescription)"
            }
        }

        await MainActor.run {
            isLoading = false
        }
    }
}

// MARK: - DateRangeCalculationSection
struct DateRangeCalculationSection: View {
    @EnvironmentObject private var globalSettings: GlobalSettingsManager
    @Binding var selectedTariffCode: String?
    let tariffVM: TariffViewModel

    // Add task cancellation support
    @State private var currentCalculationTask: Task<Void, Never>?

    // Add state tracking
    @State private var needsCalculation = false
    @State private var lastCalculationDate = Date()

    enum IntervalType: String, CaseIterable {
        case daily = "DAILY"
        case weekly = "WEEKLY"
        case monthly = "MONTHLY"

        var displayName: String {
            rawValue.capitalized
        }

        var viewModelInterval: TariffViewModel.IntervalType {
            switch self {
            case .daily: return .daily
            case .weekly: return .weekly
            case .monthly: return .monthly
            }
        }
    }

    @State private var calculationType = "single"  // "single" or "account"
    @State private var selectedInterval: IntervalType = .daily
    @State private var currentDate = Date()
    @State private var calculationResults: [NSManagedObject] = []
    @State private var errorMessage: String?

    private var dateRange: (start: Date, end: Date) {
        let calendar = Calendar.current
        let startOfDay = calendar.startOfDay(for: currentDate)

        switch selectedInterval {
        case .daily:
            let endDate = calendar.date(byAdding: .day, value: 1, to: startOfDay)!
            return (start: startOfDay, end: endDate)

        case .weekly:
            let weekStart = calendar.date(
                from: calendar.dateComponents([.yearForWeekOfYear, .weekOfYear], from: startOfDay))!
            let weekEnd = calendar.date(byAdding: .weekOfYear, value: 1, to: weekStart)!
            return (start: weekStart, end: weekEnd)

        case .monthly:
            let monthStart = calendar.date(
                from: calendar.dateComponents([.year, .month], from: startOfDay))!
            let monthEnd = calendar.date(byAdding: .month, value: 1, to: monthStart)!
            return (start: monthStart, end: monthEnd)
        }
    }

    // Helper to decode account data
    private var accountResponse: OctopusAccountResponse? {
        guard let accountData = globalSettings.settings.accountData,
            let decoded = try? JSONDecoder().decode(OctopusAccountResponse.self, from: accountData)
        else {
            return nil
        }
        return decoded
    }

    private func cancelExistingCalculation() {
        currentCalculationTask?.cancel()
        currentCalculationTask = nil
    }

    private func triggerCalculation() {
        // Cancel any existing calculation
        cancelExistingCalculation()

        // Start new calculation task
        currentCalculationTask = Task {
            // Skip if too soon since last calculation (debounce)
            let now = Date()
            if now.timeIntervalSince(lastCalculationDate) < 0.3 {  // 300ms debounce
                return
            }

            await calculateCosts()

            if !Task.isCancelled {
                await MainActor.run {
                    lastCalculationDate = now
                }
            }
        }
    }

    private func navigateDate(forward: Bool) {
        let calendar = Calendar.current
        var newDate: Date?

        switch selectedInterval {
        case .daily:
            newDate = calendar.date(byAdding: .day, value: forward ? 1 : -1, to: currentDate)
        case .weekly:
            newDate = calendar.date(byAdding: .weekOfYear, value: forward ? 1 : -1, to: currentDate)
        case .monthly:
            newDate = calendar.date(byAdding: .month, value: forward ? 1 : -1, to: currentDate)
        }

        if let newDate = newDate {
            currentDate = newDate
            triggerCalculation()
        }
    }

    var body: some View {
        Section {
            VStack(alignment: .leading, spacing: 12) {
                // Calculation Type Picker
                Picker("Calculation Type", selection: $calculationType) {
                    Text("Single Tariff").tag("single")
                    Text("Account Based").tag("account")
                }
                .pickerStyle(.segmented)
                .padding(.bottom, 8)
                .onChange(of: calculationType) { _, _ in
                    triggerCalculation()
                }

                // Interval Type Picker
                Picker("Interval", selection: $selectedInterval) {
                    ForEach(IntervalType.allCases, id: \.self) { interval in
                        Text(interval.displayName).tag(interval)
                    }
                }
                .pickerStyle(.segmented)
                .padding(.bottom, 8)
                .onChange(of: selectedInterval) { _, _ in
                    triggerCalculation()
                }

                // Date Navigation
                HStack {
                    Button(action: {
                        navigateDate(forward: false)
                    }) {
                        Image(systemName: "chevron.left")
                            .imageScale(.large)
                            .foregroundColor(.blue)
                            .padding()
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.borderless)
                    .disabled(tariffVM.isCalculating)

                    Spacer()

                    VStack(alignment: .center) {
                        Text(formatDateRange())
                            .font(.headline)
                        if tariffVM.isCalculating {
                            ProgressView()
                                .progressViewStyle(CircularProgressViewStyle())
                        } else {
                            Text(selectedInterval.displayName)
                                .font(.subheadline)
                                .foregroundColor(.secondary)
                        }
                    }

                    Spacer()

                    Button(action: {
                        navigateDate(forward: true)
                    }) {
                        Image(systemName: "chevron.right")
                            .imageScale(.large)
                            .foregroundColor(.blue)
                            .padding()
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.borderless)
                    .disabled(tariffVM.isCalculating)
                }
                .padding(.vertical, 4)

                // Requirements Notice
                if calculationType == "single" && selectedTariffCode == nil {
                    Text("Please select a tariff code above to calculate costs")
                        .font(.caption)
                        .foregroundColor(.secondary)
                } else if calculationType == "account" && accountResponse == nil {
                    Text(
                        "Please configure your Octopus account in settings to use account-based calculations"
                    )
                    .font(.caption)
                    .foregroundColor(.secondary)
                }

                // Error Message
                if let error = errorMessage {
                    Text(error)
                        .foregroundColor(.red)
                        .font(.caption)
                }

                // Results Display
                if let calculation = tariffVM.currentCalculation {
                    Divider()
                    Text("Calculation Results")
                        .font(.headline)
                        .padding(.vertical, 4)

                    ScrollView {
                        VStack(alignment: .leading, spacing: 12) {
                            // Display the calculation result
                            VStack(alignment: .leading, spacing: 4) {
                                if calculationType == "single", let tariffCode = selectedTariffCode
                                {
                                    Text(tariffCode)
                                        .font(.headline)
                                }

                                Text(
                                    "Period: \(calculation.periodStart.formatted()) to \(calculation.periodEnd.formatted())"
                                )
                                .font(.caption)
                                .foregroundColor(.secondary)

                                Text(
                                    "Total Usage: \(String(format: "%.2f kWh", calculation.totalKWh))"
                                )

                                Text(
                                    "Cost (exc. VAT): £\(String(format: "%.2f", calculation.costExcVAT/100))"
                                )
                                Text(
                                    "Cost (inc. VAT): £\(String(format: "%.2f", calculation.costIncVAT/100))"
                                )
                                .font(.subheadline)

                                Text(
                                    "Standing Charge (exc. VAT): £\(String(format: "%.2f", calculation.standingChargeExcVAT/100))"
                                )
                                Text(
                                    "Standing Charge (inc. VAT): £\(String(format: "%.2f", calculation.standingChargeIncVAT/100))"
                                )
                                .font(.caption)
                                .foregroundColor(.secondary)

                                Text(
                                    "Avg. Rate (exc. VAT): \(String(format: "%.2f p/kWh", calculation.averageUnitRateExcVAT))"
                                )
                                Text(
                                    "Avg. Rate (inc. VAT): \(String(format: "%.2f p/kWh", calculation.averageUnitRateIncVAT))"
                                )
                                .font(.caption)
                                .foregroundColor(.secondary)
                            }
                            .padding(.vertical, 4)
                        }
                    }
                    .frame(maxHeight: 300)
                }
            }
            .padding(.vertical, 8)
        } header: {
            Text("Date Range Calculation")
                .font(Theme.subFont())
                .foregroundStyle(Theme.secondaryTextColor)
                .textCase(.none)
        }
        .onDisappear {
            cancelExistingCalculation()
        }
    }

    private func formatDateRange() -> String {
        let dateRange = self.dateRange
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .none

        switch selectedInterval {
        case .daily:
            return formatter.string(from: dateRange.start)
        case .weekly, .monthly:
            return
                "\(formatter.string(from: dateRange.start)) - \(formatter.string(from: dateRange.end))"
        }
    }

    private func calculateCosts() async {
        if calculationType == "single" {
            // Single tariff calculation
            if let tariffCode = selectedTariffCode {
                await tariffVM.calculateCosts(
                    for: currentDate,
                    tariffCode: tariffCode,
                    intervalType: selectedInterval.viewModelInterval
                )
            }
        } else {
            // Account-based calculation
            if let accountData = accountResponse {
                await tariffVM.calculateCosts(
                    for: currentDate,
                    tariffCode: "savedAccount",
                    intervalType: selectedInterval.viewModelInterval,
                    accountData: accountData
                )
            }
        }
    }
}

// MARK: - Previews
struct TestView_Previews: PreviewProvider {
    static let globalTimer = GlobalTimer()
    static let globalSettings: GlobalSettingsManager = {
        let settings = GlobalSettingsManager()
        settings.settings.currentAgileCode = "E-1R-AGILE-FLEX-22-11-25-H"
        return settings
    }()
    static let ratesViewModel = RatesViewModel(globalTimer: globalTimer)

    static var previews: some View {
        TestView(ratesViewModel: ratesViewModel)
            .environment(
                \.managedObjectContext, PersistenceController.preview.container.viewContext
            )
            .environmentObject(globalSettings)
            .environmentObject(ratesViewModel)
    }
}
