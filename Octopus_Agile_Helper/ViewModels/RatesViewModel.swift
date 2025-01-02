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

/// Represents the high-level fetch status:
/// - `.none`:  no indicator
/// - `.fetching`: "fetching data" + green dot
/// - `.done`: after success, show "fetch done" + green dot for ~3s
/// - `.failed`: show "failed to fetch" + red dot for ~10s (or until we confirm we can't fetch)
/// - `.pending`: waiting to fetch (blue dot)
enum FetchStatus {
    case none
    case fetching
    case done
    case failed
    case pending
}

@MainActor
class RatesViewModel: ObservableObject {
    /// The current status for a small top-bar indicator.
    @Published var fetchStatus: FetchStatus = .none
    
    /// The earliest time we can attempt another fetch if we fail. Nil means "no cooldown."
    private var nextFetchEarliestTime: Date? = nil

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
            // Skip the very first emission when the app/view appears.
            // Otherwise, handleTimerTick(...) runs immediately and calls updateRates()
            // even if we already have the data we need.
            .dropFirst()
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
        
        // If we have a cooldown in effect, check if it's time to try fetching again
        if let earliest = nextFetchEarliestTime {
            if now >= earliest {
                // Reset cooldown and try an update
                print("DEBUG: 10-minute cooldown ended, attempting fetch again.")
                nextFetchEarliestTime = nil
                Task {
                    do {
                        try await repository.updateRates()
                    } catch {
                        self.error = error
                        print("DEBUG: Error updating rates: \(error)")
                    }
                }
            }
        } else {
            // Otherwise do normal logic if you still want to check every minute
            Task {
                do {
                    try await repository.updateRates()
                } catch {
                    self.error = error
                    print("DEBUG: Error updating rates: \(error)")
                }
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
        error = nil
        
        // 1) Check if we already have enough data.
        if repository.hasDataThroughExpectedEndUKTime() {
            print("DEBUG: We have expected data on app start. No fetch needed.")
            do {
                // Don't set isLoading since we're just reading from CoreData
                allRates = try await repository.fetchAllRates()
                upcomingRates = allRates.filter { rate in
                    guard let _ = rate.validFrom, let end = rate.validTo else { return false }
                    return end > Date()
                }
                fetchStatus = .none
            } catch {
                self.error = error
                print("DEBUG: Error loading existing rates: \(error)")
                fetchStatus = .failed
                DispatchQueue.main.asyncAfter(deadline: .now() + 10) {
                    if self.fetchStatus == .failed {
                        withAnimation(.easeInOut(duration: 0.35)) {
                            self.fetchStatus = .pending
                        }
                    }
                }
            }
        } else {
            // 2) We don't have enough data => do the normal fetch
            isLoading = true
            fetchStatus = .fetching
            
            do {
                try await repository.updateRates(force: true)
                allRates = try await repository.fetchAllRates()
                upcomingRates = allRates.filter { rate in
                    guard let _ = rate.validFrom, let end = rate.validTo else { return false }
                    return end > Date()
                }
                print("DEBUG: Successfully loaded \(upcomingRates.count) rates")
                fetchStatus = .none
                isLoading = false
            } catch {
                self.error = error
                print("DEBUG: Error loading rates: \(error)")
                
                fetchStatus = .failed
                DispatchQueue.main.asyncAfter(deadline: .now() + 10) {
                    if self.fetchStatus == .failed {
                        withAnimation(.easeInOut(duration: 0.35)) {
                            self.fetchStatus = .pending
                        }
                    }
                }
                isLoading = false
            }
        }
    }
    
    func refreshRates(force: Bool = false) async {
        if !force && repository.hasDataThroughExpectedEndUKTime() {
            // We have enough data and this isn't a forced refresh
            // => Don't show any status changes
            return
        }
        
        // Otherwise continue with normal fetch status progression
        fetchStatus = .pending
        
        print("DEBUG: Starting to refresh rates (force: \(force))")
        isLoading = true
        error = nil
        
        do {
            // Actual fetch is starting now
            fetchStatus = .fetching
            
            try await repository.updateRates(force: force)
            allRates = try await repository.fetchAllRates()
            upcomingRates = allRates.filter { rate in
                guard let _ = rate.validFrom, let end = rate.validTo else { return false }
                return end > Date()  // Include any rate that hasn't ended yet
            }
            print("DEBUG: Successfully refreshed rates, now have \(upcomingRates.count) rates")
            
            // If we succeed:
            fetchStatus = .done
            // Show "fetch done" for 3 seconds, then revert to .none
            DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
                // Only reset if we're *still* in .done
                if self.fetchStatus == .done {
                    withAnimation(.easeInOut(duration: 0.35)) {
                        self.fetchStatus = .none
                    }
                }
            }
            
        } catch {
            self.error = error
            print("DEBUG: Error refreshing rates: \(error)")
            
            fetchStatus = .failed
            
            // NEW: Check if we actually still have enough data
            let hasExpectedData = repositoryHasExpectedData()
            
            // If the error is URLError with code == -999, that often means "cancelled request"
            if let urlError = error as? URLError, urlError.code == .cancelled {
                print("DEBUG: This likely means too many rapid fetches (code -999).")
            }
            
            // If we DO have expected data, fade out quickly and revert to .none
            if hasExpectedData {
                print("DEBUG: We have enough data in CoreData; ignoring fetch error.")
                DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
                    if self.fetchStatus == .failed {
                        withAnimation(.easeInOut(duration: 0.35)) {
                            self.fetchStatus = .none
                        }
                    }
                }
            } else {
                // We do NOT have the expected data => set a 10-min cooldown
                // Then we revert to .pending so user sees we plan to fetch again
                nextFetchEarliestTime = Date().addingTimeInterval(10 * 60)  // 10 mins
                print("DEBUG: No expected data. Next attempt after \(String(describing: nextFetchEarliestTime))")
                
                DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
                    // Only reset if we're still in .failed
                    if self.fetchStatus == .failed {
                        withAnimation(.easeInOut(duration: 0.35)) {
                            self.fetchStatus = .pending
                        }
                    }
                }
            }
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
    
    func getLowestAveragesIncludingPastHour(hours: Double, maxCount: Int) -> [ThreeHourAverageEntry] {
        // 1) Gather all rates from 1 hour before now
        let now = Date()
        let start = now.addingTimeInterval(-3600) // 1 hour before
        let slots = allRates
            .filter { rate in
                guard let validFrom = rate.validFrom else { return false }
                return validFrom >= start
            }
            .sorted { ($0.validFrom ?? .distantPast) < ($1.validFrom ?? .distantPast) }
        
        // 2) Calculate how many 30-minute slots we need for the user's chosen hours
        let slotsNeeded = Int(hours * 2) // 2 slots per hour
        
        // 3) We'll iterate over each half-hour slot as a potential "start"
        var results = [ThreeHourAverageEntry]()
        let slotCount = slots.count
        
        for (index, slot) in slots.enumerated() {
            let endIndex = index + (slotsNeeded - 1)
            guard endIndex < slotCount else {
                // Not enough slots to make a full window
                break
            }
            // gather the slots
            let windowSlots = slots[index...endIndex]
            
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
            return String(format: "£%.4f /kWh", poundsValue)
        } else {
            return String(format: "%.2fp /kWh", value)
        }
    }
    
    func formatTime(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateStyle = .none
        formatter.timeStyle = .short
        return formatter.string(from: date)
    }
    
    /// Quick helper to see if we have "enough" data in our repository.
    /// We re-use the hasDataThroughExpectedEndUKTime() from RatesRepository
    private func repositoryHasExpectedData() -> Bool {
        return repository.hasDataThroughExpectedEndUKTime()
    }
}