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
    /// 1) Check local min/max date
    /// 2) Determine how many pages to fetch from the API
    /// 3) Fetch all missing data
    /// 4) Insert or skip duplicates
    public func updateConsumptionData() async throws {
        let settings = globalSettingsManager.settings
        let mpan = settings.electricityMPAN ?? ""
        let serial = settings.electricityMeterSerialNumber ?? ""
        let apiKey = settings.apiKey

        guard !apiKey.isEmpty else { return }

        // 1) Query local DB
        let localData = try await fetchAllRecords()
        let localMinDate = localData.compactMap { $0.value(forKey: "interval_start") as? Date }.min()
        let localMaxDate = localData.compactMap { $0.value(forKey: "interval_end") as? Date }.max()
        let localCount = localData.count

        // 2) We fetch the first page => get total count, figure out how many pages
        let firstPageResponse = try await apiClient.fetchConsumptionData(mpan: mpan, serialNumber: serial, apiKey: apiKey, page: 1)
        let totalRecordsOnServer = firstPageResponse.count
        if totalRecordsOnServer == 0 {
            return // no data
        }

        // 2.1) Calculate total pages
        let totalPages = Int(ceil(Double(totalRecordsOnServer) / Double(recordsPerPage)))

        // 3) Fetch all pages and store data
        // For a simpler approach: we fetch from page=1 all the way to page=totalPages 
        // and skip duplicates during insertion
        for page in 1...totalPages {
            let pageResponse = try await apiClient.fetchConsumptionData(mpan: mpan, serialNumber: serial, apiKey: apiKey, page: page)
            
            // 4) Insert or skip duplicates
            try await storeConsumptionRecords(pageResponse.results)
            
            // If there's no `next`, we can break early
            if pageResponse.next == nil {
                break
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