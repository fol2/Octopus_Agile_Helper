import Combine
import CoreData
import Foundation
import OctopusHelperShared
import SwiftUI

public enum FetchStatus {
    case none
    case fetching
    case done
    case failed
    case pending
}

public struct ThreeHourAverageEntry: Identifiable {
    public let id = UUID()
    public let start: Date
    public let end: Date
    public let average: Double
}

/// Protocol so the widget or other clients can create a `RatesViewModel` with minimal overhead
public protocol RatesViewModeling: ObservableObject {
    var fetchStatus: FetchStatus { get }
    var isLoading: Bool { get }
    var error: Error? { get }
    var upcomingRates: [RateEntity] { get }
    var allRates: [RateEntity] { get }
    
    func refreshRates(force: Bool) async
    func loadRates() async
    
    /// For widget usage: an initializer that takes an array of `RateEntity` (e.g., from direct fetch)
    init(rates: [RateEntity])
    
    // We keep a few essential read-only properties used by both widget & main app
    var lowestUpcomingRate: RateEntity? { get }
    var highestUpcomingRate: RateEntity? { get }
    
    // Also let the widget do minimal lookups:
    func formatRate(_ value: Double, showRatesInPounds: Bool) -> String
    func formatTime(_ date: Date) -> String
}

/// Our main ViewModel for rates—used across the app + widget
@MainActor
public final class RatesViewModel: ObservableObject, RatesViewModeling {
    // MARK: - Published State
    @Published public private(set) var fetchStatus: FetchStatus = .none
    @Published public private(set) var isLoading: Bool = false
    @Published public private(set) var error: Error?
    @Published public private(set) var upcomingRates: [RateEntity] = []
    @Published public private(set) var allRates: [RateEntity] = []

    // MARK: - Private
    private let repository = RatesRepository.shared
    private var cancellables = Set<AnyCancellable>()
    private var nextFetchEarliestTime: Date?
    private var currentTimer: GlobalTimer?

    // MARK: - Init (Main App)
    public init(globalTimer: GlobalTimer) {
        setupTimer(globalTimer)
    }
    
    // MARK: - Init (Widget / other modules)
    /// Minimal init for a scenario where we already have `[RateEntity]` in memory (e.g. widget)
    public init(rates: [RateEntity]) {
        // We skip setting up a timer if the widget doesn't need minute-by-minute updates
        // Instead, we simply store the rates:
        self.allRates = rates
        self.upcomingRates = filterUpcoming(rates: rates, now: Date())
        // fetchStatus remains .none; widget can call `refreshRates(force:)` if desired
    }

    // MARK: - Lifecycle from the main app
    public func updateTimer(_ newTimer: GlobalTimer) {
        // Cancel existing subscriptions
        cancellables.removeAll()
        setupTimer(newTimer)
    }

    // This is run once, to wire up the timer event
    private func setupTimer(_ timer: GlobalTimer) {
        currentTimer = timer
        timer.$currentTime
            .dropFirst()
            .receive(on: RunLoop.main)
            .sink { [weak self] newTime in
                self?.handleTimerTick(newTime)
            }
            .store(in: &cancellables)
    }

    // MARK: - Timer-based logic for main app
    private func handleTimerTick(_ now: Date) {
        // Re-filter upcoming rates
        upcomingRates = filterUpcoming(rates: allRates, now: now)

        // Check if we have a cooldown in effect
        if let earliest = nextFetchEarliestTime {
            if now >= earliest {
                // Reset cooldown, attempt to fetch again
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
            // Normal logic: fetch every minute if needed
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

    // MARK: - MAIN API Methods

    public func loadRates() async {
        print("DEBUG: Starting to load rates")
        error = nil

        // 1) If we already have coverage, just read from DB:
        if repository.hasDataThroughExpectedEndUKTime() {
            do {
                let fetchedRates = try await repository.fetchAllRates()
                allRates = fetchedRates
                upcomingRates = filterUpcoming(rates: fetchedRates, now: Date())
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
            // 2) No rates found => fetch them
            self.error = nil
            fetchStatus = .fetching
            isLoading = true
            do {
                try await repository.updateRates(force: false)
                allRates = try await repository.fetchAllRates()
                upcomingRates = filterUpcoming(rates: allRates, now: Date())
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

    public func refreshRates(force: Bool = false) async {
        if !force && repository.hasDataThroughExpectedEndUKTime() {
            // If we already have enough data and not forcing refresh, do nothing
            return
        }
        fetchStatus = .pending
        isLoading = true
        error = nil

        print("DEBUG: Starting to refresh rates (force: \(force))")

        do {
            fetchStatus = .fetching
            try await repository.updateRates(force: force)
            allRates = try await repository.fetchAllRates()
            upcomingRates = filterUpcoming(rates: allRates, now: Date())
            print("DEBUG: Successfully refreshed rates, now have \(upcomingRates.count) rates")

            fetchStatus = .done
            // Show "fetch done" for 3 seconds, then revert to .none
            DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
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

            let hasExpectedData = repository.hasDataThroughExpectedEndUKTime()
            if let urlError = error as? URLError, urlError.code == .cancelled {
                print("DEBUG: Possibly a cancelled request (too many rapid fetches).")
            }
            if hasExpectedData {
                // If we do have data, fade out quickly
                DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
                    if self.fetchStatus == .failed {
                        withAnimation(.easeInOut(duration: 0.35)) {
                            self.fetchStatus = .none
                        }
                    }
                }
            } else {
                // No data => set a 10-min cooldown
                nextFetchEarliestTime = Date().addingTimeInterval(10 * 60)
                DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
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

    // MARK: - Computed
    public var hasData: Bool {
        !upcomingRates.isEmpty
    }
    
    public var lowestUpcomingRate: RateEntity? {
        let future = upcomingRates.filter { ($0.validFrom ?? .distantPast) > Date() }
        return future.min { $0.valueIncludingVAT < $1.valueIncludingVAT }
    }
    
    public var highestUpcomingRate: RateEntity? {
        let future = upcomingRates.filter { ($0.validFrom ?? .distantPast) > Date() }
        return future.max { $0.valueIncludingVAT < $1.valueIncludingVAT }
    }

    // MARK: - Additional Helpers (same signatures as old code)
    public func averageUpcomingRate(hours: Double) -> Double? {
        let now = Date()
        let endDate = now.addingTimeInterval(hours * 3600)
        let relevantRates = upcomingRates.filter { rate in
            guard let validFrom = rate.validFrom, let validTo = rate.validTo else { return false }
            return validFrom >= now && validTo <= endDate
        }
        guard !relevantRates.isEmpty else { return nil }
        let totalValue = relevantRates.reduce(0.0) { $0 + $1.valueIncludingVAT }
        return totalValue / Double(relevantRates.count)
    }

    public var lowestTenAverageRate: Double? {
        let now = Date()
        let future = upcomingRates.filter {
            guard let validFrom = $0.validFrom else { return false }
            return validFrom > now
        }
        let sorted = future.sorted { $0.valueIncludingVAT < $1.valueIncludingVAT }
        let topTen = Array(sorted.prefix(10))
        guard !topTen.isEmpty else { return nil }
        let sum = topTen.reduce(0.0) { $0 + $1.valueIncludingVAT }
        return sum / Double(topTen.count)
    }

    public func lowestTenThreeHourAverages(hours: Double) -> [ThreeHourAverageEntry] {
        computeLowestAverages(upcomingRates, fromNow: true, hours: hours, maxCount: 10)
    }

    public func getLowestAverages(hours: Double, maxCount: Int) -> [ThreeHourAverageEntry] {
        computeLowestAverages(upcomingRates, fromNow: true, hours: hours, maxCount: maxCount)
    }

    public func getLowestAveragesIncludingPastHour(hours: Double, maxCount: Int) -> [ThreeHourAverageEntry] {
        let now = Date()
        let start = now.addingTimeInterval(-3600)
        let slots = allRates.filter { rate in
            guard let vf = rate.validFrom else { return false }
            return vf >= start
        }
        return computeLowestAverages(slots, fromNow: false, hours: hours, maxCount: maxCount)
    }

    /// Format the value in either p/kWh or £/kWh
    public func formatRate(_ value: Double, showRatesInPounds: Bool = false) -> String {
        if showRatesInPounds {
            let poundsValue = value / 100.0
            return String(format: "£%.4f /kWh", poundsValue)
        } else {
            return String(format: "%.2fp /kWh", value)
        }
    }

    public func formatTime(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.timeStyle = .short
        return formatter.string(from: date)
    }

    // MARK: - Private Helper
    private func filterUpcoming(rates: [RateEntity], now: Date) -> [RateEntity] {
        rates.filter {
            guard let validFrom = $0.validFrom, let validTo = $0.validTo else { return false }
            return validTo > now
        }
    }

    private func computeLowestAverages(
        _ inputRates: [RateEntity],
        fromNow: Bool,
        hours: Double,
        maxCount: Int
    ) -> [ThreeHourAverageEntry] {
        let now = Date()
        let sorted = inputRates
            .filter {
                if fromNow {
                    return ($0.validFrom ?? .distantPast) >= now
                } else {
                    return true
                }
            }
            .sorted { ($0.validFrom ?? .distantPast) < ($1.validFrom ?? .distantPast) }
        let neededSlots = Int(hours * 2)
        var results = [ThreeHourAverageEntry]()
        for (index, slot) in sorted.enumerated() {
            let endIndex = index + (neededSlots - 1)
            guard endIndex < sorted.count else { break }
            let window = sorted[index...endIndex]
            let sum = window.reduce(0.0) { $0 + $1.valueIncludingVAT }
            let avg = sum / Double(neededSlots)
            let startDate = slot.validFrom ?? now
            let lastSlot = window.last!
            let endDate = lastSlot.validTo ?? (startDate.addingTimeInterval(1800))
            let entry = ThreeHourAverageEntry(start: startDate, end: endDate, average: avg)
            results.append(entry)
        }
        results.sort { $0.average < $1.average }
        return Array(results.prefix(maxCount))
    }

    // Additional internal method, used in refresh logic
    private func repositoryHasExpectedData() -> Bool {
        repository.hasDataThroughExpectedEndUKTime()
    }
}