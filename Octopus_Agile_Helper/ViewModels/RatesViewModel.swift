import Foundation
import SwiftUI
import CoreData

@MainActor
class RatesViewModel: ObservableObject {
    private let repository = RatesRepository.shared
    @AppStorage("averageHours") private var averageHours: Double = 2.0
    
    @Published private(set) var isLoading = false
    @Published private(set) var error: Error?
    @Published private(set) var upcomingRates: [RateEntity] = []
    
    // MARK: - Computed Properties
    
    var hasData: Bool {
        !upcomingRates.isEmpty
    }
    
    var lowestUpcomingRate: RateEntity? {
        upcomingRates
            .filter { ($0.validFrom ?? .distantPast) > Date() }
            .min { $0.valueIncludingVAT < $1.valueIncludingVAT }
    }
    
    var highestUpcomingRate: RateEntity? {
        upcomingRates
            .filter { ($0.validFrom ?? .distantPast) > Date() }
            .max { $0.valueIncludingVAT < $1.valueIncludingVAT }
    }
    
    var averageUpcomingRate: Double? {
        let now = Date()
        let endDate = now.addingTimeInterval(averageHours * 3600) // Convert hours to seconds
        
        let relevantRates = upcomingRates.filter { rate in
            guard let validFrom = rate.validFrom, let validTo = rate.validTo else { return false }
            return validFrom >= now && validTo <= endDate
        }
        
        guard !relevantRates.isEmpty else { return nil }
        
        let totalValue = relevantRates.reduce(0.0) { $0 + $1.valueIncludingVAT }
        return totalValue / Double(relevantRates.count)
    }
    
    // MARK: - Methods
    
    func loadRates() async {
        isLoading = true
        error = nil
        
        do {
            upcomingRates = try await repository.fetchAllRates()
        } catch {
            self.error = error
        }
        
        isLoading = false
    }
    
    func refreshRates() async {
        isLoading = true
        error = nil
        
        do {
            try await repository.updateRates()
            upcomingRates = try await repository.fetchAllRates()
        } catch {
            self.error = error
        }
        
        isLoading = false
    }
    
    // MARK: - Formatting Helpers
    
    func formatRate(_ value: Double) -> String {
        String(format: "%.2f p/kWh", value)
    }
    
    func formatTime(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateStyle = .none
        formatter.timeStyle = .short
        return formatter.string(from: date)
    }
} 
