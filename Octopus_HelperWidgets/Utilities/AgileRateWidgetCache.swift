import Foundation
import CoreData
import OctopusHelperShared

/// Errors that can occur during agile cache operations
public enum AgileRateWidgetCacheError: Error {
    case fetchFailed(Error)
    case invalidTariffCode
    case noDataAvailable
    case localDataIncomplete
}

/// Cache for Agile widget agile rate
public class AgileRateWidgetCache {
    public static let shared = AgileRateWidgetCache()
    
    // MARK: - Properties
    
    private struct CacheEntry {
        let rates: [NSManagedObject]
        let timestamp: Date
        let tariffCode: String
        let nextUpdateTime: Date  // When we expect new data
    }
    
    private var cache: CacheEntry?
    
    // Track the current fetch task
    private var currentFetchTask: Task<[NSManagedObject], Error>?
    
    // Repository reference
    private var repository: RatesRepository {
        get async { await MainActor.run { RatesRepository.shared } }
    }
    
    // Public getter for nextUpdateTime
    public var nextUpdateTime: Date {
        cache?.nextUpdateTime ?? Date().addingTimeInterval(15 * 60) // Fallback to 15 minutes if no cache
    }
    
    private init() {
        // Empty init
    }
    
    // MARK: - Public Methods
    
    /// Clear cache (only used when tariff code changes)
    private func clearCache() {
        cache = nil
    }
    
    // MARK: - Private Methods
    
    private func isCacheDataSufficient(rates: [NSManagedObject]) -> Bool {
        let calendar = Calendar.current
        let timeZone = TimeZone(identifier: "Europe/London") ?? .current
        let now = Date()
        
        // Get 4 PM today in UK time
        var components = calendar.dateComponents([.year, .month, .day], from: now)
        components.hour = 16 // 4 PM
        components.minute = 0
        components.second = 0
        components.timeZone = timeZone
        
        guard let fourPMToday = calendar.date(from: components) else { return false }
        
        // Calculate expected end time for rates
        // If after 4 PM, we should have rates until 11 PM tomorrow
        // If before 4 PM, we should have rates until 11 PM today
        let expectedEndDay = now > fourPMToday ? 1 : 0
        components.hour = 22 // 10 PM
        components.day! += expectedEndDay
        
        guard let expectedEndTime = calendar.date(from: components) else { return false }
        
        // Check if we have rates up to the expected end time
        return rates.contains { rate in
            guard let validFrom = rate.value(forKey: "valid_from") as? Date else { return false }
            // Consider rate sufficient if it starts within 30 minutes of expected end time
            return abs(validFrom.timeIntervalSince(expectedEndTime)) <= 1800
        }
    }
    
    private func calculateNextUpdateTime() -> Date {
        let calendar = Calendar.current
        let timeZone = TimeZone(identifier: "Europe/London") ?? .current
        let now = Date()
        
        // Create 4 PM today in UK time
        var components = calendar.dateComponents([.year, .month, .day], from: now)
        components.hour = 16 // 4 PM
        components.minute = 0
        components.second = 0
        components.timeZone = timeZone
        
        guard let fourPMToday = calendar.date(from: components) else {
            return now.addingTimeInterval(3600) // Fallback to 1 hour if date creation fails
        }
        
        // If it's past 4 PM UK time, set for tomorrow
        if now > fourPMToday {
            return calendar.date(byAdding: .day, value: 1, to: fourPMToday) ?? now.addingTimeInterval(3600)
        }
        
        return fourPMToday
    }
    
    private func updateCache(rates: [NSManagedObject], tariffCode: String, nextUpdateTime: Date) {
        cache = CacheEntry(
            rates: rates,
            timestamp: Date(),
            tariffCode: tariffCode,
            nextUpdateTime: nextUpdateTime
        )
    }
    
    /// Internal fetch implementation
    private func fetchRates(tariffCode: String, pastHours: Int) async throws -> [NSManagedObject] {
        print("CACHE: Internal fetch for tariff: \(tariffCode)")
        
        // If tariff code changed, clear the cache and try immediate refresh
        if let cache = cache, cache.tariffCode != tariffCode {
            print("CACHE: Tariff code changed from \(cache.tariffCode) to \(tariffCode)")
            clearCache()
            
            // Try to fetch new data
            do {
                // First check CoreData
                print("CACHE: Checking CoreData after tariff change")
                let localRates = try await repository.fetchRatesForTimeWindow(
                    tariffCode: tariffCode,
                    pastHours: pastHours
                )
                
                if !localRates.isEmpty && isCacheDataSufficient(rates: localRates) {
                    print("CACHE: Found sufficient data in CoreData after tariff change")
                    updateCache(rates: localRates, tariffCode: tariffCode, nextUpdateTime: calculateNextUpdateTime())
                    return localRates
                }
                
                // If CoreData insufficient, try API
                print("CACHE: CoreData insufficient after tariff change, fetching from API")
                try await repository.fetchAndStoreRates(tariffCode: tariffCode)
                let rates = try await repository.fetchRatesForTimeWindow(
                    tariffCode: tariffCode,
                    pastHours: pastHours
                )
                
                if !rates.isEmpty && isCacheDataSufficient(rates: rates) {
                    print("CACHE: Caching \(rates.count) rates after tariff change")
                    updateCache(rates: rates, tariffCode: tariffCode, nextUpdateTime: calculateNextUpdateTime())
                    return rates
                }
                
                print("CACHE: New data after tariff change is insufficient")
                throw AgileRateWidgetCacheError.localDataIncomplete
            } catch {
                print("CACHE: Failed to fetch new data after tariff change: \(error)")
                throw AgileRateWidgetCacheError.fetchFailed(error)
            }
        }
        
        // Try cached data
        if let rates = cache?.rates {
            print("CACHE: Found cached data with \(rates.count) rates")
            let filteredRates = filterRatesForTimeWindow(rates: rates, pastHours: pastHours)
            if !filteredRates.isEmpty && isCacheDataSufficient(rates: rates) {
                print("CACHE: Using \(filteredRates.count) cached rates (sufficient)")
                return filteredRates
            }
            print("CACHE: Cached data insufficient, will check CoreData")
        } else {
            print("CACHE: No cached data available, checking CoreData")
        }
        
        // Try CoreData first
        do {
            print("CACHE: Fetching from CoreData")
            let localRates = try await repository.fetchRatesForTimeWindow(
                tariffCode: tariffCode,
                pastHours: pastHours
            )
            
            if !localRates.isEmpty && isCacheDataSufficient(rates: localRates) {
                print("CACHE: Found sufficient data in CoreData")
                updateCache(rates: localRates, tariffCode: tariffCode, nextUpdateTime: calculateNextUpdateTime())
                return localRates
            }
            
            print("CACHE: CoreData data insufficient, fetching from API")
        } catch {
            print("CACHE: Failed to fetch from CoreData: \(error)")
            print("CACHE: Will try API fetch")
        }
        
        // Only fetch from API if CoreData is insufficient
        do {
            print("CACHE: Fetching fresh data from API")
            try await repository.fetchAndStoreRates(tariffCode: tariffCode)
            
            print("CACHE: Fetching updated data from CoreData")
            let rates = try await repository.fetchRatesForTimeWindow(
                tariffCode: tariffCode,
                pastHours: pastHours
            )
            
            if !rates.isEmpty && isCacheDataSufficient(rates: rates) {
                print("CACHE: Caching \(rates.count) fresh rates")
                updateCache(rates: rates, tariffCode: tariffCode, nextUpdateTime: calculateNextUpdateTime())
                return rates
            }
            
            print("CACHE: Fresh data insufficient")
            throw AgileRateWidgetCacheError.noDataAvailable
            
        } catch {
            print("CACHE: Failed to fetch fresh data: \(error)")
            throw AgileRateWidgetCacheError.fetchFailed(error)
        }
    }
    
    /// Filter rates array for specific time window
    private func filterRatesForTimeWindow(rates: [NSManagedObject], pastHours: Int) -> [NSManagedObject] {
        let now = Date()
        let pastBoundary = now.addingTimeInterval(-Double(pastHours) * 3600)
        
        return rates.filter { rate in
            guard let validFrom = rate.value(forKey: "valid_from") as? Date else {
                return false
            }
            return validFrom >= pastBoundary
        }.sorted { a, b in
            guard let aDate = a.value(forKey: "valid_from") as? Date,
                  let bDate = b.value(forKey: "valid_from") as? Date else {
                return false
            }
            return aDate < bDate
        }
    }
    
    // MARK: - Widget Data Access
    
    /// Fetch rates for widgets, optimized for Agile tariff display
    public func widgetFetchAndCacheRates(
        tariffCode: String,
        pastHours: Int = 21  // Default to 21 hours (42 rates × 30min)
    ) async throws -> [NSManagedObject] {
        print("CACHE: Checking rates for tariff: \(tariffCode)")
        
        // If there's an existing fetch task, wait for it
        if let existingTask = currentFetchTask {
            print("CACHE: Waiting for existing fetch task")
            do {
                return try await existingTask.value
            } catch {
                print("CACHE: Existing task failed: \(error)")
                // Let it fall through to start a new task
            }
        }
        
        // Create new fetch task
        let task = Task { [weak self] in
            guard let self = self else { throw AgileRateWidgetCacheError.noDataAvailable }
            return try await self.fetchRates(tariffCode: tariffCode, pastHours: pastHours)
        }
        
        // Store the task
        currentFetchTask = task
        
        // Clean up task when we're done
        defer {
            // Clean up task reference if it's the current one
            if currentFetchTask?.isCancelled == false {
                currentFetchTask = nil
            }
        }
        
        do {
            // Wait for the task and get result
            let result = try await task.value
            print("CACHE: Fetch task completed successfully")
            return result
        } catch {
            print("CACHE: Fetch task failed: \(error)")
            throw error
        }
    }
} 