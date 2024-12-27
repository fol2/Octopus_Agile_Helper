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
        let upcoming = upcomingRates
            .filter { ($0.validFrom ?? .distantPast) > Date() }
        print("DEBUG: Found \(upcoming.count) upcoming rates for lowest rate calculation")
        return upcoming.min { $0.valueIncludingVAT < $1.valueIncludingVAT }
    }
    
    var highestUpcomingRate: RateEntity? {
        let upcoming = upcomingRates
            .filter { ($0.validFrom ?? .distantPast) > Date() }
        print("DEBUG: Found \(upcoming.count) upcoming rates for highest rate calculation")
        return upcoming.max { $0.valueIncludingVAT < $1.valueIncludingVAT }
    }
    
    var averageUpcomingRate: Double? {
        let now = Date()
        let endDate = now.addingTimeInterval(averageHours * 3600) // Convert hours to seconds
        
        let relevantRates = upcomingRates.filter { rate in
            guard let validFrom = rate.validFrom, let validTo = rate.validTo else { return false }
            return validFrom >= now && validTo <= endDate
        }
        
        print("DEBUG: Found \(relevantRates.count) rates for average calculation over \(averageHours) hours")
        
        guard !relevantRates.isEmpty else { return nil }
        
        let totalValue = relevantRates.reduce(0.0) { $0 + $1.valueIncludingVAT }
        return totalValue / Double(relevantRates.count)
    }
    
    var lowestTenAverageRate: Double? {
        let now = Date()
        // 1) Filter upcoming rates
        let upcoming = upcomingRates.filter { 
            guard let validFrom = $0.validFrom else { return false }
            return validFrom > now 
        }
        
        // 2) Sort ascending by cost
        let sorted = upcoming.sorted { $0.valueIncludingVAT < $1.valueIncludingVAT }
        
        // 3) Take up to 10
        let topTen = Array(sorted.prefix(10))
        guard !topTen.isEmpty else { return nil }
        
        print("DEBUG: Found \(topTen.count) rates for lowest 10 average calculation")
        
        // 4) Calculate average
        let sum = topTen.reduce(0.0) { $0 + $1.valueIncludingVAT }
        return sum / Double(topTen.count)
    }
    
    // MARK: - Methods
    
    func loadRates() async {
        print("DEBUG: Starting to load rates")
        isLoading = true
        error = nil
        
        do {
            upcomingRates = try await repository.fetchAllRates()
            print("DEBUG: Successfully loaded \(upcomingRates.count) rates")
        } catch {
            self.error = error
            print("DEBUG: Error loading rates: \(error)")
        }
        
        isLoading = false
    }
    
    func refreshRates() async {
        print("DEBUG: Starting to refresh rates")
        isLoading = true
        error = nil
        
        do {
            try await repository.updateRates()
            upcomingRates = try await repository.fetchAllRates()
            print("DEBUG: Successfully refreshed rates, now have \(upcomingRates.count) rates")
        } catch {
            self.error = error
            print("DEBUG: Error refreshing rates: \(error)")
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
