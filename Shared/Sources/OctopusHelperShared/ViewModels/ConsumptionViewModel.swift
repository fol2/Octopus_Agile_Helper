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
    private let globalSettingsManager = GlobalSettingsManager()
    
    public init() {
        self.repository = ElectricityConsumptionRepository.shared
    }
    
    /// Checks if we have the necessary account information to fetch consumption data
    private var hasValidAccountInfo: Bool {
        let settings = globalSettingsManager.settings
        return !settings.apiKey.isEmpty && 
               !(settings.electricityMPAN ?? "").isEmpty && 
               !(settings.electricityMeterSerialNumber ?? "").isEmpty
    }
    
    /// Loads existing data from Core Data
    public func loadData() async {
        self.error = nil
        
        // Skip if we don't have account info
        guard hasValidAccountInfo else {
            fetchState = .idle
            return
        }
        
        fetchState = .loading
        
        do {
            let allData = try await repository.fetchAllRecords()
            consumptionRecords = allData
            minInterval = allData.compactMap { $0.value(forKey: "interval_start") as? Date }.min()
            if self.fetchState.isFailure {
                fetchState = .loading
            }
            maxInterval = allData.compactMap { $0.value(forKey: "interval_end") as? Date }.max()
            
            let calendar = Calendar.current
            let hour = calendar.component(.hour, from: Date())
            
            // If after noon AND missing data, immediately try to fetch
            if hour >= 12 && !repository.hasDataThroughExpectedTime() {
                // Directly call refreshDataFromAPI instead of just setting partial
                await refreshDataFromAPI(force: true)  // Force fetch immediately
            } else {
                fetchState = .success
            }
        } catch {
            self.error = error
            print("DEBUG: Error loading consumption data: \(error)")
            fetchState = .failure(error)
            
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
        let calendar = Calendar.current
        let hour = calendar.component(.hour, from: Date())

        // Skip if we don't have account info
        guard hasValidAccountInfo else {
            fetchState = .idle
            return
        }

        // Always set loading status when starting a refresh
        if force || (hour >= 12 && !repository.hasDataThroughExpectedTime()) {
            withAnimation(.easeInOut(duration: 0.2)) {
                fetchState = .loading
                if self.fetchState.isFailure {
                    fetchState = .loading
                }
                isLoading = true
            }
            error = nil
            
            do {
                try await repository.updateConsumptionData()
                let allData = try await repository.fetchAllRecords()
                consumptionRecords = allData
                minInterval = allData.compactMap { $0.value(forKey: "interval_start") as? Date }.min()
                maxInterval = allData.compactMap { $0.value(forKey: "interval_end") as? Date }.max()
                
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
        }
    }
    
    public var hasData: Bool {
        !consumptionRecords.isEmpty
    }
}
