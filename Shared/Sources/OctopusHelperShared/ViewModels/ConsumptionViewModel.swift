import Combine
import CoreData
import Foundation
import SwiftUI

// --------------------------------------------
// FIX #1: Provide a local FetchStatus for consumption
// If you prefer to share RatesViewModel's enum, you'll need to import it or
// define a separate file. This local enum matches your usage:
public enum FetchStatus {
    case none
    case fetching
    case done
    case failed
    case pending
}
// --------------------------------------------

/// Represents the combined fetch status of all data sources
public enum CombinedFetchStatus: Equatable {
    case none
    case fetching(sources: Set<String>)
    case done(source: String)
    case failed(source: String, error: Error?)
    case pending(sources: Set<String>)
    
    public var displayText: String {
        switch self {
        case .none:
            return ""
        case .fetching(let sources):
            return sources.count > 1 ? "Updating Multiple..." : "Updating \(sources.first!)..."
        case .done(let source):
            return "\(source) Updated"
        case .failed(let source, _):
            return "\(source) Failed"
        case .pending(let sources):
            return sources.count > 1 ? "Pending Updates..." : "Pending \(sources.first!)..."
        }
    }
    
    public var color: Color {
        switch self {
        case .none: return .clear
        case .fetching: return .blue
        case .done: return .green
        case .failed: return .red
        case .pending: return .orange
        }
    }
    
    public static func == (lhs: CombinedFetchStatus, rhs: CombinedFetchStatus) -> Bool {
        switch (lhs, rhs) {
        case (.none, .none):
            return true
        case (.fetching(let s1), .fetching(let s2)):
            return s1 == s2
        case (.done(let s1), .done(let s2)):
            return s1 == s2
        case (.failed(let s1, _), .failed(let s2, _)):
            return s1 == s2
        case (.pending(let s1), .pending(let s2)):
            return s1 == s2
        default:
            return false
        }
    }
}

/// Protocol defining the interface for consumption view models
public protocol ConsumptionViewModeling: ObservableObject {
    var isLoading: Bool { get }
    var consumptionRecords: [NSManagedObject] { get }
    var minInterval: Date? { get }
    var maxInterval: Date? { get }
    var fetchStatus: FetchStatus { get }
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
    @Published public private(set) var fetchStatus: FetchStatus = .none
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
        error = nil
        
        // Skip if we don't have account info
        guard hasValidAccountInfo else {
            fetchStatus = .none
            return
        }
        
        do {
            let allData = try await repository.fetchAllRecords()
            consumptionRecords = allData
            minInterval = allData.compactMap { $0.value(forKey: "interval_start") as? Date }.min()
            maxInterval = allData.compactMap { $0.value(forKey: "interval_end") as? Date }.max()
            
            let calendar = Calendar.current
            let hour = calendar.component(.hour, from: Date())
            
            // If after noon AND missing data, immediately try to fetch
            if hour >= 12 && !repository.hasDataThroughExpectedTime() {
                // Directly call refreshDataFromAPI instead of just setting pending
                await refreshDataFromAPI(force: true)  // Force fetch immediately
            } else {
                fetchStatus = .none
            }
        } catch {
            self.error = error
            print("DEBUG: Error loading consumption data: \(error)")
            fetchStatus = .failed
            
            // If we fail to load data, set to pending after delay
            DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
                if self.fetchStatus == .failed {
                    withAnimation(.easeInOut(duration: 0.35)) {
                        self.fetchStatus = .pending  // Set to pending if we failed
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
            fetchStatus = .none
            return
        }

        // Set to fetching state immediately if forcing or conditions require
        if force || (hour >= 12 && !repository.hasDataThroughExpectedTime()) {
            fetchStatus = .fetching
            isLoading = true
            error = nil
            
            do {
                try await repository.updateConsumptionData()
                let allData = try await repository.fetchAllRecords()
                consumptionRecords = allData
                minInterval = allData.compactMap { $0.value(forKey: "interval_start") as? Date }.min()
                maxInterval = allData.compactMap { $0.value(forKey: "interval_end") as? Date }.max()
                
                fetchStatus = .done
                
                // After success, return to none after delay
                DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
                    if self.fetchStatus == .done {
                        withAnimation(.easeInOut(duration: 0.35)) {
                            self.fetchStatus = .none
                        }
                    }
                }
            } catch {
                self.error = error
                fetchStatus = .failed
                
                // If fetch fails, set to pending after delay
                DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
                    if self.fetchStatus == .failed {
                        withAnimation(.easeInOut(duration: 0.35)) {
                            self.fetchStatus = .pending  // Always go to pending after failure
                        }
                    }
                }
            }
            
            isLoading = false
        }
    }
    
    public var hasData: Bool {
        !consumptionRecords.isEmpty
    }
}
