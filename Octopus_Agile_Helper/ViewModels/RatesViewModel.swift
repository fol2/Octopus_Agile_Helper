import Foundation
import SwiftUI
import CoreData
import Combine

struct ThreeHourAverageEntry: Identifiable {
    let id = UUID()
    let start: Date
    let end: Date
    let average: Double
}

@MainActor
class RatesViewModel: ObservableObject {
    private let repository = RatesRepository.shared
    private var cancellables = Set<AnyCancellable>()
    private var currentTimer: GlobalTimer?
    
    @Published private(set) var isLoading = false
    @Published private(set) var error: Error?
    @Published private(set) var upcomingRates: [RateEntity] = []
    @Published private(set) var allRates: [RateEntity] = []
    
    init(globalTimer: GlobalTimer) {
        setupTimer(globalTimer)
    }
    
    func updateTimer(_ newTimer: GlobalTimer) {
        // Cancel existing subscription
        cancellables.removeAll()
        // Set up with new timer
        setupTimer(newTimer)
    }
    
    private func setupTimer(_ timer: GlobalTimer) {
        currentTimer = timer
        timer.$currentTime
            .receive(on: RunLoop.main)
            .sink { [weak self] newTime in
                self?.handleTimerTick(newTime)
            }
            .store(in: &cancellables)
    }
    
    private func handleTimerTick(_ now: Date) {
        // Re-filter upcoming rates based on the new current time
        upcomingRates = allRates.filter {
            guard let _ = $0.validFrom, let end = $0.validTo else { return false }
            return end > now  // Include any rate that hasn't ended yet
        }
        
        // Check if we need to fetch new data (at 4 PM)
        Task {
            do {
                try await repository.updateRates()
            } catch {
                self.error = error
                print("DEBUG: Error updating rates: \(error)")
            }
        }
    }
    
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
    
    func averageUpcomingRate(hours: Double) -> Double? {
        let now = Date()
        let endDate = now.addingTimeInterval(hours * 3600) // Convert hours to seconds
        
        let relevantRates = upcomingRates.filter { rate in
            guard let validFrom = rate.validFrom, let validTo = rate.validTo else { return false }
            return validFrom >= now && validTo <= endDate
        }
        
        print("DEBUG: Found \(relevantRates.count) rates for average calculation over \(hours) hours")
        
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
    
    func lowestTenThreeHourAverages(hours: Double) -> [ThreeHourAverageEntry] {
        // 1) Gather all *future* half-hour rate slots from upcomingRates,
        //    sorted by validFrom ascending
        let now = Date()
        let futureSlots = upcomingRates
            .filter { ($0.validFrom ?? .distantPast) >= now }
            .sorted { ($0.validFrom ?? .distantPast) < ($1.validFrom ?? .distantPast) }
        
        // 2) Calculate how many 30-minute slots we need for the user's chosen hours
        let slotsNeeded = Int(hours * 2) // 2 slots per hour
        
        // 3) We'll iterate over each future half-hour slot as a potential "start"
        var results = [ThreeHourAverageEntry]()
        let slotCount = futureSlots.count
        
        for (index, slot) in futureSlots.enumerated() {
            let endIndex = index + (slotsNeeded - 1)
            guard endIndex < slotCount else {
                // Not enough future slots to make a full window
                break
            }
            // gather the slots
            let windowSlots = futureSlots[index...endIndex]
            
            // Compute average
            let sum = windowSlots.reduce(0.0) { partial, rateEntity in
                partial + rateEntity.valueIncludingVAT
            }
            let avg = sum / Double(slotsNeeded)
            
            // The time range is from the validFrom of the first slot
            // to validTo of the last slot
            let startDate = slot.validFrom ?? now
            let lastSlot = windowSlots.last!
            let endDate = lastSlot.validTo ?? (startDate.addingTimeInterval(1800)) // fallback
            
            let entry = ThreeHourAverageEntry(start: startDate,
                                            end: endDate,
                                            average: avg)
            results.append(entry)
        }
        
        // 4) Sort by ascending average and return up to 10
        results.sort { $0.average < $1.average }
        return Array(results.prefix(10))
    }
    
    // MARK: - Methods
    
    func loadRates() async {
        print("DEBUG: Starting to load rates")
        isLoading = true
        error = nil
        
        do {
            allRates = try await repository.fetchAllRates()
            upcomingRates = allRates.filter { rate in
                guard let _ = rate.validFrom, let end = rate.validTo else { return false }
                return end > Date()  // Include any rate that hasn't ended yet
            }
            print("DEBUG: Successfully loaded \(upcomingRates.count) rates")
        } catch {
            self.error = error
            print("DEBUG: Error loading rates: \(error)")
        }
        
        isLoading = false
    }
    
    func refreshRates(force: Bool = false) async {
        print("DEBUG: Starting to refresh rates (force: \(force))")
        isLoading = true
        error = nil
        
        do {
            try await repository.updateRates(force: force)
            allRates = try await repository.fetchAllRates()
            upcomingRates = allRates.filter { rate in
                guard let _ = rate.validFrom, let end = rate.validTo else { return false }
                return end > Date()  // Include any rate that hasn't ended yet
            }
            print("DEBUG: Successfully refreshed rates, now have \(upcomingRates.count) rates")
        } catch {
            self.error = error
            print("DEBUG: Error refreshing rates: \(error)")
        }
        
        isLoading = false
    }
    
    func getLowestAverages(hours: Double, maxCount: Int) -> [ThreeHourAverageEntry] {
        // 1) Gather all *future* half-hour rate slots from upcomingRates,
        //    sorted by validFrom ascending
        let now = Date()
        let futureSlots = upcomingRates
            .filter { ($0.validFrom ?? .distantPast) >= now }
            .sorted { ($0.validFrom ?? .distantPast) < ($1.validFrom ?? .distantPast) }
        
        // 2) Calculate how many 30-minute slots we need for the user's chosen hours
        let slotsNeeded = Int(hours * 2) // 2 slots per hour
        
        // 3) We'll iterate over each future half-hour slot as a potential "start"
        var results = [ThreeHourAverageEntry]()
        let slotCount = futureSlots.count
        
        for (index, slot) in futureSlots.enumerated() {
            let endIndex = index + (slotsNeeded - 1)
            guard endIndex < slotCount else {
                // Not enough future slots to make a full window
                break
            }
            // gather the slots
            let windowSlots = futureSlots[index...endIndex]
            
            // Compute average
            let sum = windowSlots.reduce(0.0) { partial, rateEntity in
                partial + rateEntity.valueIncludingVAT
            }
            let avg = sum / Double(slotsNeeded)
            
            // The time range is from the validFrom of the first slot
            // to validTo of the last slot
            let startDate = slot.validFrom ?? now
            let lastSlot = windowSlots.last!
            let endDate = lastSlot.validTo ?? (startDate.addingTimeInterval(1800)) // fallback
            
            let entry = ThreeHourAverageEntry(start: startDate,
                                            end: endDate,
                                            average: avg)
            results.append(entry)
        }
        
        // 4) Sort by ascending average and return up to maxCount
        results.sort { $0.average < $1.average }
        return Array(results.prefix(maxCount))
    }
    
    // MARK: - Formatting Helpers
    
    /// Format the `value` (in pence) as either p/kWh or £/kWh, controlled by `showRatesInPounds`.
    func formatRate(_ value: Double, showRatesInPounds: Bool = false) -> String {
        if showRatesInPounds {
            // Convert pence to pounds: 100 pence = £1
            let poundsValue = value / 100.0
            return String(format: "%.2f £/kWh", poundsValue)
        } else {
            return String(format: "%.2f p/kWh", value)
        }
    }
    
    func formatTime(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateStyle = .none
        formatter.timeStyle = .short
        return formatter.string(from: date)
    }
} 
