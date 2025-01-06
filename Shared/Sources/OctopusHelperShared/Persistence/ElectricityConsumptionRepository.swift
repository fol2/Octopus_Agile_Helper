import CoreData
import Foundation
import Combine
import SwiftUI

/// Manages Octopus electricity consumption data in Core Data, including fetching and caching.
@MainActor
public final class ElectricityConsumptionRepository: ObservableObject {
    // MARK: - Singleton
    public static let shared = ElectricityConsumptionRepository()

    // MARK: - Dependencies
    private let apiClient = OctopusAPIClient.shared
    private let globalSettingsManager = GlobalSettingsManager()
    private let context: NSManagedObjectContext
    
    // For pagination, each page typically has 100 records from Octopus.
    private let recordsPerPage = 100

    // MARK: - Initializer
    private init() {
        context = PersistenceController.shared.container.viewContext
    }

    // MARK: - Public Methods
    
    /// Fetch all records from Core Data, sorted by interval_end descending
    /// - Returns: Array of EConsumAgile entities
    public func fetchAllRecords() async throws -> [NSManagedObject] {
        let request = NSFetchRequest<NSManagedObject>(entityName: "EConsumAgile")
        request.sortDescriptors = [NSSortDescriptor(key: "interval_end", ascending: false)]
        
        return try await withCheckedThrowingContinuation { continuation in
            context.perform {
                do {
                    let results = try self.context.fetch(request)
                    continuation.resume(returning: results)
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    /// Main logic for updating consumption data from the Octopus API.
    /// Optimized to fetch only missing data based on local database state.
    public func updateConsumptionData() async throws {
        let settings = globalSettingsManager.settings
        let mpan = settings.electricityMPAN ?? ""
        let serial = settings.electricityMeterSerialNumber ?? ""
        let apiKey = settings.apiKey

        guard !apiKey.isEmpty else { return }

        // 1. Query local DB state
        let localData = try await fetchAllRecords()
        let localMinDate = localData.compactMap { $0.value(forKey: "interval_start") as? Date }.min()
        let localMaxDate = localData.compactMap { $0.value(forKey: "interval_end") as? Date }.max()
        let localCount = localData.count

        // 2. Get initial state from API (newest data)
        let firstPageResponse = try await apiClient.fetchConsumptionData(mpan: mpan, serialNumber: serial, apiKey: apiKey, page: 1)
        let totalRecordsOnServer = firstPageResponse.count
        if totalRecordsOnServer == 0 { return }

        // 3. Process newest data first (page 1 onwards)
        if localMaxDate == nil || firstPageResponse.results.first?.interval_end.timeIntervalSince(localMaxDate!) ?? 0 > 0 {
            var currentPage = 1
            var hasMore = true
            
            while hasMore {
                if currentPage > 1 {
                    let pageResponse = try await apiClient.fetchConsumptionData(mpan: mpan, serialNumber: serial, apiKey: apiKey, page: currentPage)
                    
                    // Stop if we hit existing data
                    if let oldestInPage = pageResponse.results.last,
                       let localMax = localMaxDate,
                       oldestInPage.interval_end <= localMax {
                        // Only store records newer than our local max
                        let newRecords = pageResponse.results.filter { $0.interval_end > localMax }
                        if !newRecords.isEmpty {
                            try await storeConsumptionRecords(newRecords)
                        }
                        hasMore = false
                        break
                    }
                    
                    try await storeConsumptionRecords(pageResponse.results)
                    hasMore = pageResponse.next != nil
                } else {
                    // Store first page results
                    try await storeConsumptionRecords(firstPageResponse.results)
                    hasMore = firstPageResponse.next != nil
                }
                currentPage += 1
            }
        }

        // 4. Calculate if we need older data
        if let localMin = localMinDate {
            let totalPages = Int(ceil(Double(totalRecordsOnServer) / Double(recordsPerPage)))
            var currentPage = totalPages
            var hasMore = true
            
            while hasMore && currentPage > 1 {
                let pageResponse = try await apiClient.fetchConsumptionData(mpan: mpan, serialNumber: serial, apiKey: apiKey, page: currentPage)
                
                // Stop if we hit existing data
                if let newestInPage = pageResponse.results.first,
                   newestInPage.interval_start <= localMin {
                    // Only store records older than our local min
                    let newRecords = pageResponse.results.filter { $0.interval_start < localMin }
                    if !newRecords.isEmpty {
                        try await storeConsumptionRecords(newRecords)
                    }
                    hasMore = false
                    break
                }
                
                try await storeConsumptionRecords(pageResponse.results)
                currentPage -= 1
                hasMore = pageResponse.previous != nil
            }
        }
    }

    /// Clears all consumption data (useful for debugging or manual resets)
    public func deleteAllRecords() async throws {
        let fetchReq: NSFetchRequest<NSFetchRequestResult> = NSFetchRequest(entityName: "EConsumAgile")
        let deleteReq = NSBatchDeleteRequest(fetchRequest: fetchReq)
        
        return try await withCheckedThrowingContinuation { continuation in
            context.perform {
                do {
                    try self.context.execute(deleteReq)
                    try self.context.save()
                    continuation.resume()
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }
    
    /// Checks whether we have consumption data through the expected latest time.
    /// Before noon: Don't expect today's data (not pending)
    /// After noon: Should have data through previous midnight (pending if missing)
    public func hasDataThroughExpectedTime() -> Bool {
        let request = NSFetchRequest<NSManagedObject>(entityName: "EConsumAgile")
        request.sortDescriptors = [NSSortDescriptor(key: "interval_end", ascending: false)]
        request.fetchLimit = 1
        
        guard let latestRecord = try? context.fetch(request).first,
              let maxDate = latestRecord.value(forKey: "interval_end") as? Date else {
            print("DEBUG: No consumption records found")
            return false
        }
        
        let calendar = Calendar.current
        let now = Date()
        let hour = calendar.component(.hour, from: now)
        let previousMidnight = calendar.startOfDay(for: now)
        
        // Detailed debug logging
        print("DEBUG: Consumption Data Check")
        print("Current time: \(now)")
        print("Current hour: \(hour)")
        print("Previous midnight: \(previousMidnight)")
        print("Latest record end: \(maxDate)")
        print("Time since latest record: \(now.timeIntervalSince(maxDate) / 3600) hours")
        print("Latest record >= midnight: \(maxDate >= previousMidnight)")
        
        return maxDate >= previousMidnight
    }
    
    /// Returns the date through which we expect to have consumption data
    /// Before noon: Previous midnight
    /// After noon: Previous midnight (same as before noon, but will trigger pending)
    private func expectedLatestConsumption() -> Date? {
        let calendar = Calendar.current
        let now = Date()
        return calendar.startOfDay(for: now)
    }
    
    // MARK: - Private Methods
    
    /// Inserts consumption data into Core Data. Skips duplicates based on the `interval_start`.
    private func storeConsumptionRecords(_ records: [ConsumptionRecord]) async throws {
        return try await withCheckedThrowingContinuation { continuation in
            context.perform {
                do {
                    // Build a dictionary of existing records keyed by interval_start
                    let fetchReq = NSFetchRequest<NSManagedObject>(entityName: "EConsumAgile")
                    let existing = try self.context.fetch(fetchReq)
                    let existingMap = Dictionary(uniqueKeysWithValues: existing.compactMap { record -> (Date, NSManagedObject)? in
                        guard let start = record.value(forKey: "interval_start") as? Date else { return nil }
                        return (start, record)
                    })

                    for c in records {
                        // Check if we already have data for c.interval_start
                        if let found = existingMap[c.interval_start] {
                            // Update if needed
                            found.setValue(c.interval_end, forKey: "interval_end")
                            found.setValue(c.consumption, forKey: "consumption")
                        } else {
                            // Insert new
                            let newItem = NSEntityDescription.insertNewObject(forEntityName: "EConsumAgile", into: self.context)
                            newItem.setValue(c.interval_start, forKey: "interval_start")
                            newItem.setValue(c.interval_end, forKey: "interval_end")
                            newItem.setValue(c.consumption, forKey: "consumption")
                        }
                    }
                    try self.context.save()
                    continuation.resume()
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }
} 