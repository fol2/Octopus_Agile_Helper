//
//  RatesRepository.swift
//  Octopus_Agile_Helper
//  Full Example (adjusted to avoid name collisions and missing extensions)
//
//  Description:
//    - Manages all electricity rates & standing charges in Core Data
//      via NSManagedObject for RateEntity, StandingChargeEntity.
//    - Preserves Agile logic: multi-page fetch, coverage checks, aggregator queries.
//
//  Principles:
//    - SOLID: One class controlling rate/standing-charge data
//    - KISS, DRY, YAGNI: Minimal duplication, straightforward upserts
//    - Fully scalable: can handle Agile or other product codes
//

import Combine
import CoreData
import Foundation
import SwiftUI

@MainActor
public final class RatesRepository: ObservableObject {
    // MARK: - Singleton
    public static let shared = RatesRepository()

    // MARK: - Published
    /// Local cache if your UI or logic needs quick reference
    @Published public private(set) var currentCachedRates: [NSManagedObject] = []

    // MARK: - Dependencies
    private let apiClient = OctopusAPIClient.shared
    private let context: NSManagedObjectContext
    @AppStorage("postcode") private var postcode: String = ""

    // Networking (for older agile logic if needed)
    private let urlSession: URLSession
    private let maxRetries = 3

    // MARK: - Init
    private init() {
        self.context = PersistenceController.shared.container.viewContext
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 30
        config.waitsForConnectivity = true
        self.urlSession = URLSession(configuration: config)
    }

    // MARK: - Public API

    /// New approach: we accept a known link + known tariffCode, with pagination support
    public func fetchAndStoreRates(tariffCode: String, url: String) async throws {
        print("🔄 Starting rate update for tariff: \(tariffCode)")
        
        // 1. Query local DB state
        let request = NSFetchRequest<NSManagedObject>(entityName: "RateEntity")
        request.predicate = NSPredicate(format: "tariff_code == %@", tariffCode)
        let localData = try await context.perform {
            try self.context.fetch(request)
        }
        let localMinDate = localData.compactMap { $0.value(forKey: "valid_from") as? Date }.min()
        let localMaxDate = localData.compactMap { $0.value(forKey: "valid_to") as? Date }.max()
        let localCount = localData.count

        print("Debug - Local data state:")
        print("Debug - Record count: \(localCount)")
        if let minDate = localMinDate {
            print("Debug - Earliest rate: \(minDate.formatted())")
        }
        if let maxDate = localMaxDate {
            print("Debug - Latest rate: \(maxDate.formatted())")
        }

        // 2. Get server's data range by fetching first and last pages
        print("Debug - Fetching first and last pages to determine server data range")
        guard let firstPageUrl = URL(string: url) else {
            throw OctopusAPIError.invalidURL
        }
        
        let firstPageRates = try await apiClient.fetchTariffRates(url: url)
        if firstPageRates.isEmpty { 
            print("Debug - No rates available on server")
            return 
        }
        
        let totalRecordsOnServer = firstPageRates.count
        let recordsPerPage = 100 // Octopus API standard
        let totalPages = Int(ceil(Double(totalRecordsOnServer) / Double(recordsPerPage)))
        print("Debug - Total pages available: \(totalPages)")

        // Get last page to determine full date range
        let lastPageUrl = "\(url)&page=\(totalPages)"
        let lastPageRates = try await apiClient.fetchTariffRates(url: lastPageUrl)
        
        guard let serverNewestRate = firstPageRates.first,
              let serverOldestRate = lastPageRates.last else {
            print("Debug - Could not determine server data range")
            return
        }

        print("Debug - Server data range:")
        print("Debug - Newest rate: \(serverNewestRate.valid_to.formatted())")
        print("Debug - Oldest rate: \(serverOldestRate.valid_from.formatted())")

        // 3. Determine what data we need to fetch
        var needNewerData = false
        var needOlderData = false

        if let localMax = localMaxDate {
            needNewerData = serverNewestRate.valid_to > localMax
            print("Debug - Need newer data: \(needNewerData)")
            if needNewerData {
                print("Debug - Server has \(serverNewestRate.valid_to.timeIntervalSince(localMax) / 3600) hours of newer rates")
            }
        } else {
            needNewerData = true
            print("Debug - No local data, need newer data: true")
        }

        if let localMin = localMinDate {
            needOlderData = serverOldestRate.valid_from < localMin
            print("Debug - Need older data: \(needOlderData)")
            if needOlderData {
                print("Debug - Server has \(localMin.timeIntervalSince(serverOldestRate.valid_from) / 3600) hours of older rates")
            }
        } else {
            needOlderData = true
            print("Debug - No local data, need older data: true")
        }

        if !needNewerData && !needOlderData {
            print("Debug - Local data covers the entire server range, checking for gaps")
            if let localMin = localMinDate,
               let localMax = localMaxDate,
               hasMissingRecords(from: localMin, to: localMax, localData: localData) {
                print("Debug - Found gaps in local data, will fetch full range")
                needNewerData = true
                needOlderData = true
            } else {
                print("Debug - No gaps found, data is complete")
                return
            }
        }

        // 4. Process newest data first (page 1 onwards) if needed
        if needNewerData {
            print("Debug - Fetching newer data (forward pagination)")
            var currentPage = 1
            var hasMore = true
            
            while hasMore {
                if currentPage > 1 {
                    let nextPageUrl = "\(url)&page=\(currentPage)"
                    let pageRates = try await apiClient.fetchTariffRates(url: nextPageUrl)
                    
                    // Stop if we hit existing data
                    if let oldestInPage = pageRates.last,
                       let localMax = localMaxDate,
                       oldestInPage.valid_to <= localMax {
                        // Only store records newer than our local max
                        let newRecords = pageRates.filter { $0.valid_to > localMax }
                        print("Debug - Found \(newRecords.count) new rates in page \(currentPage)")
                        if !newRecords.isEmpty {
                            try await upsertRates(newRecords, tariffCode: tariffCode)
                        }
                        hasMore = false
                        break
                    }
                    
                    print("Debug - Storing \(pageRates.count) rates from page \(currentPage)")
                    try await upsertRates(pageRates, tariffCode: tariffCode)
                    hasMore = !pageRates.isEmpty && pageRates.count == recordsPerPage
                } else {
                    // Store first page results
                    print("Debug - Storing \(firstPageRates.count) rates from first page")
                    try await upsertRates(firstPageRates, tariffCode: tariffCode)
                    hasMore = firstPageRates.count == recordsPerPage
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
                    try await upsertRates(lastPageRates, tariffCode: tariffCode)
                } else {
                    let pageUrl = "\(url)&page=\(currentPage)"
                    let pageRates = try await apiClient.fetchTariffRates(url: pageUrl)
                    
                    // Stop if we hit existing data and have no gaps
                    if let newestInPage = pageRates.first,
                       let localMin = localMinDate,
                       newestInPage.valid_from <= localMin {
                        // Check for gaps before deciding to store
                        let oldestInPage = pageRates.last?.valid_from ?? newestInPage.valid_from
                        if !hasMissingRecords(from: oldestInPage, to: localMin, localData: localData) {
                            print("Debug - No gaps found in this page range, stopping backward pagination")
                            hasMore = false
                            break
                        }
                        // Only store records older than our local min
                        let newRecords = pageRates.filter { $0.valid_from < localMin }
                        print("Debug - Found \(newRecords.count) older rates in page \(currentPage)")
                        if !newRecords.isEmpty {
                            try await upsertRates(newRecords, tariffCode: tariffCode)
                        }
                        hasMore = false
                        break
                    }
                    
                    print("Debug - Storing \(pageRates.count) rates from page \(currentPage)")
                    try await upsertRates(pageRates, tariffCode: tariffCode)
                }
                currentPage -= 1
                hasMore = currentPage > 1
            }
            print("Debug - Completed backward pagination")
        }

        // Final status
        let finalData = try await context.perform {
            let req = NSFetchRequest<NSManagedObject>(entityName: "RateEntity")
            req.predicate = NSPredicate(format: "tariff_code == %@", tariffCode)
            return try self.context.fetch(req)
        }
        print("✅ Rate update complete")
        print("Debug - Final record count: \(finalData.count)")
        if let minDate = finalData.compactMap({ $0.value(forKey: "valid_from") as? Date }).min(),
           let maxDate = finalData.compactMap({ $0.value(forKey: "valid_to") as? Date }).max() {
            print("Debug - Final date range: \(minDate.formatted()) to \(maxDate.formatted())")
        }
    }

    /// Calculate the expected number of half-hour records between two dates
    private func expectedRecordCount(from startDate: Date, to endDate: Date) -> Int {
        let timeInterval = endDate.timeIntervalSince(startDate)
        // Each record is 30 minutes (1800 seconds)
        return Int(ceil(timeInterval / 1800.0))
    }

    /// Check if we have any gaps in our local data between the given dates
    private func hasMissingRecords(from startDate: Date, to endDate: Date, localData: [NSManagedObject]) -> Bool {
        let expected = expectedRecordCount(from: startDate, to: endDate)
        
        // Filter records within this date range
        let recordsInRange = localData.filter { record in
            guard let recordStart = record.value(forKey: "valid_from") as? Date,
                  let recordEnd = record.value(forKey: "valid_to") as? Date else {
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
    
    /// Fetch and store standing charges
    public func fetchAndStoreStandingCharges(tariffCode: String, url: String) async throws {
        let charges = try await apiClient.fetchStandingCharges(url: url)
        try await upsertStandingCharges(charges, tariffCode: tariffCode)
    }
    
    /// Store standing charges in CoreData
    private func upsertStandingCharges(_ charges: [OctopusStandingCharge], tariffCode: String) async throws {
        try await context.perform {
            print("🔄 Upserting \(charges.count) standing charges for tariff \(tariffCode)")
            
            // Fetch only existing charges for this tariff code
            let request = NSFetchRequest<NSManagedObject>(entityName: "StandingChargeEntity")
            request.predicate = NSPredicate(format: "tariff_code == %@", tariffCode)
            let existingCharges = try self.context.fetch(request)
            print("📦 Found \(existingCharges.count) existing standing charges for tariff \(tariffCode)")
            
            // Create composite key map using both date and tariff code
            var mapByKey = [String: NSManagedObject]()
            for c in existingCharges {
                if let fromDate = c.value(forKey: "valid_from") as? Date,
                   let code = c.value(forKey: "tariff_code") as? String {
                    let key = "\(code)_\(fromDate.timeIntervalSince1970)"
                    mapByKey[key] = c
                }
            }
            
            for charge in charges {
                let validFrom = charge.valid_from
                let key = "\(tariffCode)_\(validFrom.timeIntervalSince1970)"
                
                if let found = mapByKey[key] {
                    // update
                    print("🔄 Updating standing charge for \(validFrom)")
                    if let validTo = charge.valid_to {
                        found.setValue(validTo, forKey: "valid_to")
                    } else {
                        found.setValue(nil, forKey: "valid_to")
                    }
                    found.setValue(charge.value_excluding_vat, forKey: "value_excluding_vat")
                    found.setValue(charge.value_including_vat, forKey: "value_including_vat")
                } else {
                    // insert
                    print("➕ Inserting new standing charge for \(validFrom)")
                    let newCharge = NSEntityDescription.insertNewObject(forEntityName: "StandingChargeEntity", into: self.context)
                    newCharge.setValue(UUID().uuidString, forKey: "id")
                    newCharge.setValue(charge.valid_from, forKey: "valid_from")
                    if let validTo = charge.valid_to {
                        newCharge.setValue(validTo, forKey: "valid_to")
                    }
                    newCharge.setValue(charge.value_excluding_vat, forKey: "value_excluding_vat")
                    newCharge.setValue(charge.value_including_vat, forKey: "value_including_vat")
                    newCharge.setValue(tariffCode, forKey: "tariff_code")
                }
            }
            
            try self.context.save()
        }
    }

    /// Now we identify by `tariff_code`:
    private func upsertRates(_ rates: [OctopusTariffRate], tariffCode: String) async throws {
        try await context.perform {
            // Fetch only existing rates for this tariff code
            let request = NSFetchRequest<NSManagedObject>(entityName: "RateEntity")
            request.predicate = NSPredicate(format: "tariff_code == %@", tariffCode)
            let existingRates = try self.context.fetch(request)
            
            // Create composite key map using both date and tariff code
            var mapByKey = [String: NSManagedObject]()
            for r in existingRates {
                if let fromDate = r.value(forKey: "valid_from") as? Date,
                   let code = r.value(forKey: "tariff_code") as? String {
                    let key = "\(code)_\(fromDate.timeIntervalSince1970)"
                    mapByKey[key] = r
                }
            }

            for apiRate in rates {
                let validFrom = apiRate.valid_from
                let key = "\(tariffCode)_\(validFrom.timeIntervalSince1970)"
                
                if let found = mapByKey[key] {
                    // update existing rate
                    found.setValue(apiRate.valid_to, forKey: "valid_to")
                    found.setValue(apiRate.value_exc_vat, forKey: "value_excluding_vat")
                    found.setValue(apiRate.value_inc_vat, forKey: "value_including_vat")
                } else {
                    // insert new rate
                    let newRate = NSEntityDescription.insertNewObject(forEntityName: "RateEntity", into: self.context)
                    newRate.setValue(UUID().uuidString, forKey: "id")
                    newRate.setValue(apiRate.valid_from, forKey: "valid_from")
                    newRate.setValue(apiRate.valid_to, forKey: "valid_to")
                    newRate.setValue(apiRate.value_exc_vat, forKey: "value_excluding_vat")
                    newRate.setValue(apiRate.value_inc_vat, forKey: "value_including_vat")
                    newRate.setValue(tariffCode, forKey: "tariff_code")
                }
            }
            try self.context.save()
        }
    }

    /// Example fetchAllRates returning NSManagedObject
    public func fetchAllRates() async throws -> [NSManagedObject] {
        try await context.perform {
            let req = NSFetchRequest<NSManagedObject>(entityName: "RateEntity")
            req.sortDescriptors = [NSSortDescriptor(key: "valid_from", ascending: true)]
            let list = try self.context.fetch(req)
            self.currentCachedRates = list
            return list
        }
    }

    /// Fetch all standing charges from CoreData
    public func fetchAllStandingCharges() async throws -> [NSManagedObject] {
        try await context.perform {
            let request = NSFetchRequest<NSManagedObject>(entityName: "StandingChargeEntity")
            request.sortDescriptors = [NSSortDescriptor(key: "valid_from", ascending: true)]
            return try self.context.fetch(request)
        }
    }

    // MARK: - Additional "Agile" aggregator logic
    //   (some apps put these in the ViewModel, but you can keep them here.)

    /// Return the "lowest upcoming rate" from now onward.
    public func lowestUpcomingRate() async throws -> NSManagedObject? {
        let now = Date()
        return try await context.perform {
            let req = NSFetchRequest<NSManagedObject>(entityName: "RateEntity")
            req.predicate = NSPredicate(format: "valid_from > %@", now as NSDate)
            // sort by value_including_vat ascending
            req.sortDescriptors = [NSSortDescriptor(key: "value_including_vat", ascending: true)]
            req.fetchLimit = 1
            let results = try self.context.fetch(req)
            return results.first
        }
    }

    /// Return the "highest upcoming rate" from now onward.
    public func highestUpcomingRate() async throws -> NSManagedObject? {
        let now = Date()
        return try await context.perform {
            let req = NSFetchRequest<NSManagedObject>(entityName: "RateEntity")
            req.predicate = NSPredicate(format: "valid_from > %@", now as NSDate)
            req.sortDescriptors = [NSSortDescriptor(key: "value_including_vat", ascending: false)]
            req.fetchLimit = 1
            let results = try self.context.fetch(req)
            return results.first
        }
    }

    // ... you can add more aggregator methods as needed
    // (like averageUpcomingRate, etc.)

    // MARK: - Private Helpers

    /// Grabs the local maximum valid_to from Core Data
    private func getLocalMaxValidTo() -> Date? {
        let context = PersistenceController.shared.container.viewContext
        let request = NSFetchRequest<NSManagedObject>(entityName: "RateEntity")
        request.sortDescriptors = [NSSortDescriptor(key: "valid_to", ascending: false)]
        request.fetchLimit = 1
        
        do {
            let results = try context.fetch(request)
            return results.first?.value(forKey: "valid_to") as? Date
        } catch {
            print("❌ Error fetching max valid_to: \(error)")
            return nil
        }
    }

    private func expectedEndOfDayInUTC() -> Date? {
        // Remove "toUTC" calls or re-implement them if you have an extension in your codebase.
        // For demonstration, let's do a simpler approach:
        guard let ukTimeZone = TimeZone(identifier: "Europe/London") else { return nil }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = ukTimeZone

        let now = Date()
        let hour = calendar.component(.hour, from: now)
        let offsetDay = (hour < 16) ? 0 : 1
        guard
            let baseDay = calendar.date(byAdding: .day, value: offsetDay, to: now),
            let eodLocal = calendar.date(bySettingHour: 23, minute: 0, second: 0, of: baseDay)
        else {
            return nil
        }
        // Just return eodLocal (no .toUTC)
        return eodLocal
    }
}
