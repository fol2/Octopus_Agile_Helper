import Combine
import CoreData
import Foundation
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
        guard !mpan.isEmpty, !serial.isEmpty else { return }

        print("🔄 Starting consumption data update")
        print("Debug - MPAN: \(mpan)")
        print("Debug - Serial: \(serial)")

        // 1. Query local DB state
        let localData = try await fetchAllRecords()
        let localMinDate = localData.compactMap { $0.value(forKey: "interval_start") as? Date }
            .min()
        let localMaxDate = localData.compactMap { $0.value(forKey: "interval_end") as? Date }.max()
        let localCount = localData.count

        print("Debug - Local data state:")
        print("Debug - Record count: \(localCount)")
        if let minDate = localMinDate {
            print("Debug - Earliest record: \(minDate.formatted())")
        }
        if let maxDate = localMaxDate {
            print("Debug - Latest record: \(maxDate.formatted())")
        }

        // 2. Get server's data range by fetching first and last pages
        print("Debug - Fetching first and last pages to determine server data range")
        let firstPageResponse = try await apiClient.fetchConsumptionData(
            mpan: mpan, serialNumber: serial, apiKey: apiKey, page: 1)
        let totalRecordsOnServer = firstPageResponse.count
        if totalRecordsOnServer == 0 {
            print("Debug - No records available on server")
            return
        }

        let totalPages = Int(ceil(Double(totalRecordsOnServer) / Double(recordsPerPage)))
        print("Debug - Total pages available: \(totalPages)")

        let lastPageResponse = try await apiClient.fetchConsumptionData(
            mpan: mpan, serialNumber: serial, apiKey: apiKey, page: totalPages)

        guard let serverNewestRecord = firstPageResponse.results.first,
            let serverOldestRecord = lastPageResponse.results.last
        else {
            print("Debug - Could not determine server data range")
            return
        }

        print("Debug - Server data range:")
        print("Debug - Newest record: \(serverNewestRecord.interval_end.formatted())")
        print("Debug - Oldest record: \(serverOldestRecord.interval_start.formatted())")

        // 3. Determine what data we need to fetch
        var needNewerData = false
        var needOlderData = false

        if localData.isEmpty {
            // If we have no data, just do forward pagination from newest data
            needNewerData = true
            needOlderData = false
            print("Debug - No local data, fetching all data from newest to oldest")
        } else {
            // Normal logic for incremental updates when we have existing data
            if let localMax = localMaxDate {
                needNewerData = serverNewestRecord.interval_end > localMax
                print("Debug - Need newer data: \(needNewerData)")
                if needNewerData {
                    print(
                        "Debug - Server has \(serverNewestRecord.interval_end.timeIntervalSince(localMax) / 3600) hours of newer data"
                    )
                }
            }

            if let localMin = localMinDate {
                needOlderData = serverOldestRecord.interval_start < localMin
                print("Debug - Need older data: \(needOlderData)")
                if needOlderData {
                    print(
                        "Debug - Server has \(localMin.timeIntervalSince(serverOldestRecord.interval_start) / 3600) hours of older data"
                    )
                }
            }

            if !needNewerData && !needOlderData {
                print("Debug - Local data covers the entire server range, checking for gaps")
                if let localMin = localMinDate,
                    let localMax = localMaxDate,
                    hasMissingRecords(from: localMin, to: localMax, localData: localData)
                {
                    print("Debug - Found gaps in local data, will fetch full range")
                    needNewerData = true
                    needOlderData = true
                } else {
                    print("Debug - No gaps found, data is complete")
                    return
                }
            }
        }

        // 4. Process newest data first (page 1 onwards) if needed
        if needNewerData {
            print("Debug - Fetching newer data (forward pagination)")
            var currentPage = 1
            var hasMore = true

            while hasMore {
                if currentPage > 1 {
                    print("Debug - Fetching forward page \(currentPage)")
                    let pageResponse = try await apiClient.fetchConsumptionData(
                        mpan: mpan, serialNumber: serial, apiKey: apiKey, page: currentPage)

                    // Stop if we hit existing data
                    if let oldestInPage = pageResponse.results.last,
                        let localMax = localMaxDate,
                        oldestInPage.interval_end <= localMax
                    {
                        // Only store records newer than our local max
                        let newRecords = pageResponse.results.filter { $0.interval_end > localMax }
                        print(
                            "Debug - Found \(newRecords.count) new records in page \(currentPage)")
                        if !newRecords.isEmpty {
                            try await storeConsumptionRecords(newRecords)
                        }
                        hasMore = false
                        break
                    }

                    print(
                        "Debug - Storing \(pageResponse.results.count) records from page \(currentPage)"
                    )
                    try await storeConsumptionRecords(pageResponse.results)
                    hasMore = pageResponse.next != nil
                } else {
                    // Store first page results
                    print(
                        "Debug - Storing \(firstPageResponse.results.count) records from first page"
                    )
                    try await storeConsumptionRecords(firstPageResponse.results)
                    hasMore = firstPageResponse.next != nil
                }
                currentPage += 1
            }
            print("Debug - Completed forward pagination")
        }

        // 5. Process older data if needed
        if needOlderData {
            print("Debug - Fetching older data (backward pagination)")
            var currentPage = totalPages
            var hasMore = true

            while hasMore && currentPage > 1 {
                if currentPage == totalPages {
                    // We already have the last page response
                    print("Debug - Using existing last page response")
                    try await storeConsumptionRecords(lastPageResponse.results)
                } else {
                    print("Debug - Fetching backward page \(currentPage)")
                    let pageResponse = try await apiClient.fetchConsumptionData(
                        mpan: mpan, serialNumber: serial, apiKey: apiKey, page: currentPage)

                    // Stop if we hit existing data and have no gaps
                    if let newestInPage = pageResponse.results.first,
                        let localMin = localMinDate,
                        newestInPage.interval_start <= localMin
                    {
                        // Check for gaps before deciding to store
                        let oldestInPage =
                            pageResponse.results.last?.interval_start ?? newestInPage.interval_start
                        if !hasMissingRecords(
                            from: oldestInPage, to: localMin, localData: localData)
                        {
                            print(
                                "Debug - No gaps found in this page range, stopping backward pagination"
                            )
                            hasMore = false
                            break
                        }
                        // Only store records older than our local min
                        let newRecords = pageResponse.results.filter {
                            $0.interval_start < localMin
                        }
                        print(
                            "Debug - Found \(newRecords.count) older records in page \(currentPage)"
                        )
                        if !newRecords.isEmpty {
                            try await storeConsumptionRecords(newRecords)
                        }
                        hasMore = false
                        break
                    }

                    print(
                        "Debug - Storing \(pageResponse.results.count) records from page \(currentPage)"
                    )
                    try await storeConsumptionRecords(pageResponse.results)
                }
                currentPage -= 1
                hasMore = currentPage > 1
            }
            print("Debug - Completed backward pagination")
        }

        // Final status
        let finalData = try await fetchAllRecords()
        print("✅ Consumption update complete")
        print("Debug - Final record count: \(finalData.count)")
        if let minDate = finalData.compactMap({ $0.value(forKey: "interval_start") as? Date })
            .min(),
            let maxDate = finalData.compactMap({ $0.value(forKey: "interval_end") as? Date }).max()
        {
            print("Debug - Final date range: \(minDate.formatted()) to \(maxDate.formatted())")
        }
    }

    /// Clears all consumption data (useful for debugging or manual resets)
    public func deleteAllRecords() async throws {
        let fetchReq: NSFetchRequest<NSFetchRequestResult> = NSFetchRequest(
            entityName: "EConsumAgile")
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
            let maxDate = latestRecord.value(forKey: "interval_end") as? Date
        else {
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
                    let existingMap = Dictionary(
                        uniqueKeysWithValues: existing.compactMap {
                            record -> (Date, NSManagedObject)? in
                            guard let start = record.value(forKey: "interval_start") as? Date else {
                                return nil
                            }
                            return (start, record)
                        })

                    var updatedCount = 0
                    var insertedCount = 0

                    for c in records {
                        // Check if we already have data for c.interval_start
                        if let found = existingMap[c.interval_start] {
                            // Update if needed
                            found.setValue(c.interval_end, forKey: "interval_end")
                            found.setValue(c.consumption, forKey: "consumption")
                            updatedCount += 1
                        } else {
                            // Insert new
                            let newItem = NSEntityDescription.insertNewObject(
                                forEntityName: "EConsumAgile", into: self.context)
                            newItem.setValue(c.interval_start, forKey: "interval_start")
                            newItem.setValue(c.interval_end, forKey: "interval_end")
                            newItem.setValue(c.consumption, forKey: "consumption")
                            insertedCount += 1
                        }
                    }

                    print(
                        "Debug - Storage update: \(updatedCount) updated, \(insertedCount) inserted"
                    )
                    try self.context.save()
                    continuation.resume()
                } catch {
                    print("Debug - Error storing records: \(error)")
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    /// Calculate the expected number of half-hour records between two dates
    private func expectedRecordCount(from startDate: Date, to endDate: Date) -> Int {
        let timeInterval = endDate.timeIntervalSince(startDate)
        // Each record is 30 minutes (1800 seconds)
        return Int(ceil(timeInterval / 1800.0))
    }

    /// Check if we have any gaps in our local data between the given dates
    private func hasMissingRecords(
        from startDate: Date, to endDate: Date, localData: [NSManagedObject]
    ) -> Bool {
        let expected = expectedRecordCount(from: startDate, to: endDate)

        // Filter records within this date range
        let recordsInRange = localData.filter { record in
            guard let recordStart = record.value(forKey: "interval_start") as? Date,
                let recordEnd = record.value(forKey: "interval_end") as? Date
            else {
                return false
            }
            return recordStart >= startDate && recordEnd <= endDate
        }

        print("Debug - Date range check:")
        print("Debug - Start: \(startDate.formatted())")
        print("Debug - End: \(endDate.formatted())")
        print("Debug - Expected records: \(expected)")
        print("Debug - Actual records: \(recordsInRange.count)")

        return recordsInRange.count < expected
    }
}
