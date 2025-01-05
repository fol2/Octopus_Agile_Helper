import Combine
import CoreData
import Foundation
import SwiftUI

/// Protocol defining the interface for consumption view models
public protocol ConsumptionViewModeling: ObservableObject {
    var isLoading: Bool { get }
    var consumptionRecords: [NSManagedObject] { get }
    var minInterval: Date? { get }
    var maxInterval: Date? { get }
    
    func loadData() async
    func refreshDataFromAPI() async
}

/// Main view model for electricity consumption data
@MainActor
public final class ConsumptionViewModel: ObservableObject, ConsumptionViewModeling {
    @Published public private(set) var isLoading: Bool = false
    @Published public private(set) var consumptionRecords: [NSManagedObject] = []
    @Published public private(set) var minInterval: Date?
    @Published public private(set) var maxInterval: Date?
    
    private var cancellables = Set<AnyCancellable>()
    private let repository: ElectricityConsumptionRepository
    
    public init() {
        self.repository = ElectricityConsumptionRepository.shared
    }
    
    /// Loads existing data from Core Data
    public func loadData() async {
        isLoading = true
        defer { isLoading = false }
        do {
            let allData = try await repository.fetchAllRecords()
            consumptionRecords = allData
            minInterval = allData.compactMap { $0.value(forKey: "interval_start") as? Date }.min()
            maxInterval = allData.compactMap { $0.value(forKey: "interval_end") as? Date }.max()
        } catch {
            // Handle errors if needed
        }
    }
    
    /// Manually triggers an update from the Octopus API
    public func refreshDataFromAPI() async {
        isLoading = true
        defer { isLoading = false }
        do {
            try await repository.updateConsumptionData()
            // Reload from Core Data
            let allData = try await repository.fetchAllRecords()
            consumptionRecords = allData
            minInterval = allData.compactMap { $0.value(forKey: "interval_start") as? Date }.min()
            maxInterval = allData.compactMap { $0.value(forKey: "interval_end") as? Date }.max()
        } catch {
            // Handle or show error
        }
    }
}
