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

    /// New approach: we accept a known link + known tariffCode
    public func fetchAndStoreRates(tariffCode: String, url: String) async throws {
        let rates = try await apiClient.fetchTariffRates(url: url)
        try await upsertRates(rates, tariffCode: tariffCode)
        _ = try await fetchAllRates() // refresh local cache
    }

    /// Now we identify by `tariff_code`:
    private func upsertRates(_ rates: [OctopusTariffRate], tariffCode: String) async throws {
        try await context.perform {
            let request = NSFetchRequest<NSManagedObject>(entityName: "RateEntity")
            let existingRates = try self.context.fetch(request)
            var mapByFromDate = [Date: NSManagedObject]()
            for r in existingRates {
                if let fromDate = r.value(forKey: "valid_from") as? Date {
                    mapByFromDate[fromDate] = r
                }
            }

            for apiRate in rates {
                let validFrom = apiRate.valid_from
                if let found = mapByFromDate[validFrom] {
                    // update
                    found.setValue(apiRate.valid_to, forKey: "valid_to")
                    found.setValue(apiRate.value_exc_vat, forKey: "value_excluding_vat")
                    found.setValue(apiRate.value_inc_vat, forKey: "value_including_vat")
                    found.setValue(tariffCode, forKey: "tariff_code")
                } else {
                    // insert
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
