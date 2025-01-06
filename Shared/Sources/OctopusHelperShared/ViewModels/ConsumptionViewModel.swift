import Combine
import CoreData
import Foundation
import SwiftUI

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
    
    public init() {
        self.repository = ElectricityConsumptionRepository.shared
    }
    
    /// Loads existing data from Core Data
    public func loadData() async {
        error = nil
        
        do {
            let allData = try await repository.fetchAllRecords()
            consumptionRecords = allData
            minInterval = allData.compactMap { $0.value(forKey: "interval_start") as? Date }.min()
            maxInterval = allData.compactMap { $0.value(forKey: "interval_end") as? Date }.max()
            
            // Only show pending if:
            // 1. After noon AND
            // 2. Missing data through previous midnight
            let calendar = Calendar.current
            let hour = calendar.component(.hour, from: Date())
            
            if hour >= 12 && !repository.hasDataThroughExpectedTime() {
                fetchStatus = .pending
                // Don't auto-refresh here - let the UI handle that
            } else {
                fetchStatus = .none
            }
        } catch {
            self.error = error
            print("DEBUG: Error loading consumption data: \(error)")
            fetchStatus = .failed
            DispatchQueue.main.asyncAfter(deadline: .now() + 10) {
                if self.fetchStatus == .failed {
                    withAnimation(.easeInOut(duration: 0.35)) {
                        self.fetchStatus = .none  // Don't show pending after failure
                    }
                }
            }
        }
    }
    
    /// Manually triggers an update from the Octopus API
    public func refreshDataFromAPI(force: Bool = false) async {
        let calendar = Calendar.current
        let hour = calendar.component(.hour, from: Date())

        // 1) If user pulls-to-refresh, skip "pending" and go straight to "fetching"
        // 2) If it's after noon AND missing data, then use "pending" -> "fetching"
        if force {
            fetchStatus = .fetching
            isLoading = true
            error = nil
        } else if hour >= 12 && !repository.hasDataThroughExpectedTime() {
            fetchStatus = .pending
            isLoading = true
            error = nil
        }

        if fetchStatus == .pending || fetchStatus == .fetching {
            do {
                // If forced, we're already in .fetching
                if fetchStatus == .pending {
                    fetchStatus = .fetching
                }
                try await repository.updateConsumptionData()
                let allData = try await repository.fetchAllRecords()
                consumptionRecords = allData
                minInterval = allData.compactMap { $0.value(forKey: "interval_start") as? Date }.min()
                maxInterval = allData.compactMap { $0.value(forKey: "interval_end") as? Date }.max()
                
                fetchStatus = .done
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
                DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
                    if self.fetchStatus == .failed {
                        withAnimation(.easeInOut(duration: 0.35)) {
                            // If we still have data, revert to .none, not .pending
                            if !self.consumptionRecords.isEmpty {
                                self.fetchStatus = .none
                            } else {
                                // If we truly have no data, revert to .pending
                                self.fetchStatus = .pending
                            }
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
