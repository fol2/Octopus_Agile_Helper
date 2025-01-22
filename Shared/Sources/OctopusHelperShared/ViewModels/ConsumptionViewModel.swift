import Combine
import CoreData
import Foundation
import SwiftUI

/// We'll remove all references to local/combined enums and adopt DataFetchState
public protocol ConsumptionViewModeling: ObservableObject {
    var isLoading: Bool { get }
    var consumptionRecords: [NSManagedObject] { get }
    var minInterval: Date? { get }
    var maxInterval: Date? { get }
    var fetchState: DataFetchState { get }
    var error: Error? { get }

    func loadData() async
    func refreshDataFromAPI(force: Bool) async
}

/// Main view model for electricity consumption data
@MainActor
public final class ConsumptionViewModel: ObservableObject, ConsumptionViewModeling {
    @Published public private(set) var isLoading: Bool = false
    @Published public private(set) var consumptionRecords: [NSManagedObject] = []
    @Published public private(set) var minInterval: Date?
    @Published public private(set) var maxInterval: Date?
    @Published public private(set) var fetchState: DataFetchState = .idle
    @Published public private(set) var error: Error?

    private let repository: ElectricityConsumptionRepository
    private var globalSettingsManager: GlobalSettingsManager

    public init(globalSettingsManager: GlobalSettingsManager) {
        self.repository = ElectricityConsumptionRepository.shared
        self.globalSettingsManager = globalSettingsManager
    }

    /// Updates the GlobalSettingsManager instance to use the environment object
    public func updateGlobalSettingsManager(_ newManager: GlobalSettingsManager) {
        self.globalSettingsManager = newManager
        self.repository.updateGlobalSettingsManager(newManager)
    }

    /// Checks if we have the necessary account information to fetch consumption data
    public var hasValidAccountInfo: Bool {
        let settings = globalSettingsManager.settings
        return !settings.apiKey.isEmpty && !(settings.electricityMPAN ?? "").isEmpty
            && !(settings.electricityMeterSerialNumber ?? "").isEmpty
    }

    /// Loads existing data from Core Data
    public func loadData() async {
        print("📊 ConsumptionVM.loadData: Starting...")
        self.error = nil

        // Skip if we don't have account info
        guard hasValidAccountInfo else {
            print("⚠️ ConsumptionVM.loadData: Missing account info")
            print("  - API Key present: \(!globalSettingsManager.settings.apiKey.isEmpty)")
            print(
                "  - MPAN present: \(!(globalSettingsManager.settings.electricityMPAN ?? "").isEmpty)"
            )
            print(
                "  - Serial present: \(!(globalSettingsManager.settings.electricityMeterSerialNumber ?? "").isEmpty)"
            )
            fetchState = .idle
            return
        }

        print("✅ ConsumptionVM.loadData: Account info valid")
        print("  - MPAN: \(globalSettingsManager.settings.electricityMPAN ?? "nil")")
        print("  - Serial: \(globalSettingsManager.settings.electricityMeterSerialNumber ?? "nil")")

        withAnimation(.easeInOut(duration: 0.2)) {
            fetchState = .loading
            isLoading = true
        }

        do {
            print("🔍 ConsumptionVM.loadData: Fetching records from Core Data...")
            let allData = try await repository.fetchAllRecords()
            consumptionRecords = allData
            minInterval = allData.compactMap { $0.value(forKey: "interval_start") as? Date }.min()
            maxInterval = allData.compactMap { $0.value(forKey: "interval_end") as? Date }.max()
            print("📊 ConsumptionVM.loadData: Found \(allData.count) records")
            if let min = minInterval, let max = maxInterval {
                print("  - Date range: \(min) to \(max)")
            }

            // If we have no data but have account info, immediately try to fetch
            if allData.isEmpty {
                print("🔄 ConsumptionVM.loadData: No records found, initiating API fetch")
                await refreshDataFromAPI(force: true)
                return
            }

            let calendar = Calendar.current
            let hour = calendar.component(.hour, from: Date())
            let hasExpectedData = repository.hasDataThroughExpectedTime()

            print("⏰ ConsumptionVM.loadData: Time check")
            print("  - Current hour: \(hour)")
            print("  - Has data through expected time: \(hasExpectedData)")

            // If after noon AND missing data, immediately try to fetch
            if hour >= 12 && !hasExpectedData {
                print("🔄 ConsumptionVM.loadData: Missing expected data, initiating API fetch")
                await refreshDataFromAPI(force: true)
            } else {
                print("✅ ConsumptionVM.loadData: Data is current, no fetch needed")
                withAnimation(.easeInOut(duration: 0.2)) {
                    fetchState = .success
                    isLoading = false
                }

                // After success, return to idle after delay
                DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
                    if case .success = self.fetchState {
                        withAnimation(.easeInOut(duration: 0.35)) {
                            self.fetchState = .idle
                        }
                    }
                }
            }
        } catch {
            self.error = error
            print("❌ ConsumptionVM.loadData: Error loading data: \(error)")
            withAnimation(.easeInOut(duration: 0.2)) {
                fetchState = .failure(error)
                isLoading = false
            }

            // If we fail to load data, set to partial after delay
            DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
                if self.fetchState.isFailure {
                    withAnimation(.easeInOut(duration: 0.35)) {
                        self.fetchState = .partial
                    }
                }
            }
        }
    }

    /// Manually triggers an update from the Octopus API
    public func refreshDataFromAPI(force: Bool = false) async {
        print("🔄 ConsumptionVM.refreshDataFromAPI: Starting (force: \(force))")
        let calendar = Calendar.current
        let hour = calendar.component(.hour, from: Date())

        // Skip if we don't have account info
        guard hasValidAccountInfo else {
            print("⚠️ ConsumptionVM.refreshDataFromAPI: Missing account info")
            print("  - API Key present: \(!globalSettingsManager.settings.apiKey.isEmpty)")
            print(
                "  - MPAN present: \(!(globalSettingsManager.settings.electricityMPAN ?? "").isEmpty)"
            )
            print(
                "  - Serial present: \(!(globalSettingsManager.settings.electricityMeterSerialNumber ?? "").isEmpty)"
            )
            fetchState = .idle
            return
        }

        let hasExpectedData = repository.hasDataThroughExpectedTime()
        print("⏰ ConsumptionVM.refreshDataFromAPI: Time check")
        print("  - Current hour: \(hour)")
        print("  - Has data through expected time: \(hasExpectedData)")
        print("  - Will fetch: \(force || (hour >= 12 && !hasExpectedData))")

        // Always set loading status when starting a refresh
        if force || (hour >= 12 && !hasExpectedData) {
            withAnimation(.easeInOut(duration: 0.2)) {
                fetchState = .loading
                if self.fetchState.isFailure {
                    fetchState = .loading
                }
                isLoading = true
            }
            error = nil

            do {
                print("🔄 ConsumptionVM.refreshDataFromAPI: Updating consumption data from API...")
                try await repository.updateConsumptionData()
                print("🔍 ConsumptionVM.refreshDataFromAPI: Fetching updated records...")
                let allData = try await repository.fetchAllRecords()
                consumptionRecords = allData
                minInterval = allData.compactMap { $0.value(forKey: "interval_start") as? Date }
                    .min()
                maxInterval = allData.compactMap { $0.value(forKey: "interval_end") as? Date }.max()

                print("📊 ConsumptionVM.refreshDataFromAPI: Found \(allData.count) records")
                if let min = minInterval, let max = maxInterval {
                    print("  - Date range: \(min) to \(max)")
                }

                withAnimation(.easeInOut(duration: 0.2)) {
                    fetchState = .success
                }

                // After success, return to idle after delay
                DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
                    if case .success = self.fetchState {
                        withAnimation(.easeInOut(duration: 0.35)) {
                            self.fetchState = .idle
                        }
                    }
                }
            } catch {
                self.error = error
                print("❌ ConsumptionVM.refreshDataFromAPI: Error updating data: \(error)")
                withAnimation(.easeInOut(duration: 0.2)) {
                    fetchState = .failure(error)
                }

                // If fetch fails, set to idle after delay
                DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
                    if self.fetchState.isFailure {
                        withAnimation(.easeInOut(duration: 0.35)) {
                            self.fetchState = .idle  // or .partial
                        }
                    }
                }
            }

            withAnimation(.easeInOut(duration: 0.2)) {
                isLoading = false
            }
        } else {
            print(
                "⏭️ ConsumptionVM.refreshDataFromAPI: Skipping fetch (not forced, before noon, or has expected data)"
            )
        }
    }

    public var hasData: Bool {
        !consumptionRecords.isEmpty
    }

    /// Checks if we have complete data through the expected time
    public var hasCompleteData: Bool {
        repository.hasDataThroughExpectedTime()
    }
}
