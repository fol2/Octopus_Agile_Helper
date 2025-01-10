import Combine
import CoreData
import Foundation
import SwiftUI

/// Manages Octopus rate data in Core Data (both normal + Agile),
/// including standing charges, caching, etc.
@MainActor
public final class RatesRepository: ObservableObject {
    // MARK: - Singleton
    public static let shared = RatesRepository()

    // MARK: - Published
    /// This property is maintained primarily for Agile logic / UI usage.
    /// We'll set it after we finish storing data in Core Data.
    @Published public private(set) var currentCachedRates: [NSManagedObject] = []

    // MARK: - Dependencies
    private let apiClient = OctopusAPIClient.shared
    private let context: NSManagedObjectContext
    @AppStorage("postcode") private var postcode: String = ""

    // If you had an existing URLSession for manual calls, keep it:
    private let urlSession: URLSession
    private let maxRetries = 3

    // MARK: - Init
    private init() {
        context = PersistenceController.shared.container.viewContext
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 30
        config.waitsForConnectivity = true
        urlSession = URLSession(configuration: config)
    }

    // MARK: - Public API

    /// (1) High-level entry point: updates the rates
    /// in the database if needed or if `force` is true.
    /// This is used for "non-Agile" or generic scenarios
    /// where you want to fetch some known product & region.
    ///
    /// If you want fully flexible usage, you might replace
    /// this with a method that fetches product code, region, etc.
    public func updateRates(force: Bool = false) async throws {
        // For demonstration, let's assume "AGILE" style logic
        // only if forced or if lacking coverage. In real usage,
        // you might refactor to handle multiple product codes.
        if force || !hasDataThroughExpectedEndUKTime() {
            try await performFetch()
        }
    }

    /// (2) For your existing Agile logic: checks whether
    /// we have coverage through the expected end (in UK time).
    public func hasDataThroughExpectedEndUKTime() -> Bool {
        // We'll do a quick local check by reading
        // the max valid_to from "RateEntity".
        // Because "currentCachedRates" may not
        // reflect the entire DB (especially if the user pulled fresh),
        // we might rely on a local query. But for now, do a quick approach:
        guard let maxValidTo = currentCachedRates
            .compactMap({ $0.value(forKey: "valid_to") as? Date })
            .max()
        else {
            return false
        }
        guard let endOfDayUTC = expectedEndOfDayInUTC() else {
            return false
        }
        return maxValidTo >= endOfDayUTC
    }

    /// (3) A general method to fetch **all** stored rates
    /// from Core Data (sorted by `valid_from` ascending).
    /// Also updates `currentCachedRates` so existing
    /// Agile UI can keep using it.
    @discardableResult
    public func fetchAllRates() async throws -> [NSManagedObject] {
        try await context.perform {
            let request = NSFetchRequest<NSManagedObject>(entityName: "RateEntity")
            request.sortDescriptors = [NSSortDescriptor(key: "valid_from", ascending: true)]
            let results = try self.context.fetch(request)
            // For agile UI usage:
            self.currentCachedRates = results
            return results
        }
    }

    /// (4) Removes *all* RateEntity rows (useful for debugging).
    /// Also clears currentCachedRates in memory.
    public func deleteAllRates() async throws {
        let fetchRequest = NSFetchRequest<NSFetchRequestResult>(entityName: "RateEntity")
        let deleteRequest = NSBatchDeleteRequest(fetchRequest: fetchRequest)

        try await context.perform {
            try self.context.execute(deleteRequest)
            try self.context.save()
        }

        currentCachedRates = []
    }

    /// (5) Equivalent fetch for a single "page" of RateEntity results.
    /// The old version returned [RateEntity], but we'll return [NSManagedObject].
    public func fetchRatesPage(offset: Int, limit: Int, ascending: Bool = true) async throws -> [NSManagedObject] {
        try await context.perform {
            let request = NSFetchRequest<NSManagedObject>(entityName: "RateEntity")
            let sortKey = "valid_from" // or "valid_to" if you prefer
            request.sortDescriptors = [NSSortDescriptor(key: sortKey, ascending: ascending)]
            request.fetchOffset = offset
            request.fetchLimit = limit
            return try self.context.fetch(request)
        }
    }

    /// (6) Returns total count of RateEntity in DB.
    public func countAllRates() async throws -> Int {
        try await context.perform {
            let request = NSFetchRequest<NSManagedObject>(entityName: "RateEntity")
            return try self.context.count(for: request)
        }
    }

    /// (7) Fetch rates for a specific day
    /// (similar to old code, but returns [NSManagedObject]).
    public func fetchRatesForDay(_ day: Date) async throws -> [NSManagedObject] {
        let calendar = Calendar(identifier: .gregorian)
        guard let dayStart = calendar.dateInterval(of: .day, for: day)?.start,
              let dayEnd = calendar.date(byAdding: .day, value: 1, to: dayStart)
        else { return [] }

        return try await context.perform {
            let request = NSFetchRequest<NSManagedObject>(entityName: "RateEntity")
            request.sortDescriptors = [NSSortDescriptor(key: "valid_from", ascending: true)]
            request.predicate = NSPredicate(
                format: "(valid_from < %@) AND (valid_to > %@)",
                dayEnd as NSDate,
                dayStart as NSDate
            )
            return try self.context.fetch(request)
        }
    }

    /// (8) Helpers to find earliest / latest "valid_from" in RateEntity.
    public func earliestRateDate() async throws -> Date? {
        try await context.perform {
            let request = NSFetchRequest<NSManagedObject>(entityName: "RateEntity")
            request.sortDescriptors = [NSSortDescriptor(key: "valid_from", ascending: true)]
            request.fetchLimit = 1
            let results = try self.context.fetch(request)
            return results.first?.value(forKey: "valid_from") as? Date
        }
    }

    public func latestRateDate() async throws -> Date? {
        try await context.perform {
            let request = NSFetchRequest<NSManagedObject>(entityName: "RateEntity")
            request.sortDescriptors = [NSSortDescriptor(key: "valid_from", ascending: false)]
            request.fetchLimit = 1
            let results = try self.context.fetch(request)
            return results.first?.value(forKey: "valid_from") as? Date
        }
    }

    // MARK: - Agile Logic / Additional “syncAllRates()”

    /// If you want to preserve your existing "Agile" half-hour logic,
    /// you can keep it here. We'll unify the final storing step
    /// into the new upsert approach (storeRateObject).
    public func syncAllRates() async throws {
        // 1) Figure out user region from the postcode
        let regionID = try await fetchRegionID(for: postcode) ?? "H"

        // 2) Query local DB
        let localRates = try await fetchAllRates() // returns [NSManagedObject]
        let localMinDate = localRates.compactMap { $0.value(forKey: "valid_from") as? Date }.min()
        let localMaxDate = localRates.compactMap { $0.value(forKey: "valid_to") as? Date }.max()

        // 3) The rest is your existing page-based logic to fetch agile data, e.g.:
        let firstPageResponse = try await fetchAllRatesPageAgile(regionID: regionID, page: 1)
        let totalRecordsOnServer = firstPageResponse.count ?? 0
        if totalRecordsOnServer == 0 { return }

        // newest data first
        if localMaxDate == nil
            || firstPageResponse.results.first?.valid_from.timeIntervalSince(localMaxDate!) ?? 0 > 0
        {
            var currentPage = 1
            var hasMore = true
            while hasMore {
                if currentPage > 1 {
                    let pageResponse = try await fetchAllRatesPageAgile(regionID: regionID, page: currentPage)
                    if let oldestInPage = pageResponse.results.last,
                       let localMax = localMaxDate,
                       oldestInPage.valid_from <= localMax
                    {
                        let newRates = pageResponse.results.filter { $0.valid_from > localMax }
                        if !newRates.isEmpty {
                            try await storeAgileRates(newRates)
                        }
                        hasMore = false
                        break
                    }
                    try await storeAgileRates(pageResponse.results)
                    hasMore = pageResponse.next != nil
                } else {
                    try await storeAgileRates(firstPageResponse.results)
                    hasMore = firstPageResponse.next != nil
                }
                currentPage += 1
            }
        }

        // older data
        if let localMin = localMinDate {
            let pageSize = firstPageResponse.results.count
            let totalPages = Int(ceil(Double(totalRecordsOnServer) / Double(pageSize)))
            var currentPage = totalPages
            var hasMore = true
            while hasMore && currentPage > 1 {
                let pageResponse = try await fetchAllRatesPageAgile(regionID: regionID, page: currentPage)
                if let newestInPage = pageResponse.results.first,
                   newestInPage.valid_from <= localMin
                {
                    let oldRates = pageResponse.results.filter { $0.valid_from < localMin }
                    if !oldRates.isEmpty {
                        try await storeAgileRates(oldRates)
                    }
                    hasMore = false
                    break
                }
                try await storeAgileRates(pageResponse.results)
                currentPage -= 1
                hasMore = pageResponse.previous != nil
            }
        }

        // final reload
        let final = try await fetchAllRates()
        let newEarliest = final.compactMap { $0.value(forKey: "valid_from") as? Date }.min() ?? localMinDate
        let newLatest = final.compactMap { $0.value(forKey: "valid_to") as? Date }.max() ?? localMaxDate
        print("Synced rates: earliest=\(String(describing: newEarliest)) latest=\(String(describing: newLatest))")
    }

    // MARK: - Private Methods

    /// Private helper for the "updateRates(force:)" scenario above.
    /// In a real scenario, you'd likely specify which product code or
    /// how to fetch them. For demonstration, we do a minimal approach
    /// that's effectively the "Agile" path.
    private func performFetch() async throws {
        try await syncAllRates()
    }

    /// Actually store newly fetched half-hour Agile rates into Core Data,
    /// using the new upsert approach (RateEntity with the new columns).
    private func storeAgileRates(_ rates: [OctopusRate]) async throws {
        try await context.perform {
            // fetch existing RateEntity
            let request = NSFetchRequest<NSManagedObject>(entityName: "RateEntity")
            let existingRecords = try self.context.fetch(request)

            // build a dictionary by (valid_from) => NSManagedObject
            var existingMap = [Date: NSManagedObject]()
            for obj in existingRecords {
                if let fromDate = obj.value(forKey: "valid_from") as? Date {
                    existingMap[fromDate] = obj
                }
            }

            // Upsert each newly fetched rate
            for octopusRate in rates {
                if let match = existingMap[octopusRate.valid_from] {
                    // update
                    match.setValue(octopusRate.valid_to, forKey: "valid_to")
                    match.setValue("AGILE-24-10-01", forKey: "product_code")
                    match.setValue("H", forKey: "region") // or your real region
                    match.setValue("standard_unit_rate", forKey: "rate_type")
                    match.setValue("", forKey: "payment_method") // Agile might not define it
                    match.setValue(octopusRate.value_exc_vat, forKey: "value_excluding_vat")
                    match.setValue(octopusRate.value_inc_vat, forKey: "value_including_vat")
                    // keep old "id" if it exists
                } else {
                    // insert new
                    let newObj = NSEntityDescription.insertNewObject(
                        forEntityName: "RateEntity",
                        into: self.context
                    )
                    newObj.setValue(UUID().uuidString, forKey: "id")
                    newObj.setValue(octopusRate.valid_from, forKey: "valid_from")
                    newObj.setValue(octopusRate.valid_to, forKey: "valid_to")
                    newObj.setValue("AGILE-24-10-01", forKey: "product_code")
                    newObj.setValue("H", forKey: "region") // or your real region
                    newObj.setValue("standard_unit_rate", forKey: "rate_type")
                    newObj.setValue("", forKey: "payment_method") // if you prefer
                    newObj.setValue(octopusRate.value_exc_vat, forKey: "value_excluding_vat")
                    newObj.setValue(octopusRate.value_inc_vat, forKey: "value_including_vat")
                }
            }

            try self.context.save()
        }

        // Optionally refresh the in-memory cache
        let fresh = try await fetchAllRates()
        self.currentCachedRates = fresh
    }

    /// Example for storing standing charges (if you want them).
    /// This is analogous to storeAgileRates but for “StandingChargeEntity”.
    /// You might call it after fetching `GET /products/<code>/electricity-tariffs/<tariff_code>/standing-charges`.
    private func storeStandingCharges(_ charges: [OctopusTariffRate], productCode: String, region: String) async throws {
        try await context.perform {
            let request = NSFetchRequest<NSManagedObject>(entityName: "StandingChargeEntity")
            let existingRecords = try self.context.fetch(request)

            // build dictionary by (valid_from + payment_method), for example
            var existingMap = [String: NSManagedObject]()
            for obj in existingRecords {
                if let fromDate = obj.value(forKey: "valid_from") as? Date,
                   let payMethod = obj.value(forKey: "payment_method") as? String
                {
                    existingMap["\(fromDate.timeIntervalSince1970)|\(payMethod)"] = obj
                }
            }

            for item in charges {
                let fromDate = item.valid_from
                let payMethod = item.payment_method ?? ""
                let key = "\(fromDate.timeIntervalSince1970)|\(payMethod)"
                if let match = existingMap[key] {
                    // update
                    match.setValue(productCode, forKey: "product_code")
                    match.setValue(region, forKey: "region")
                    match.setValue(payMethod, forKey: "payment_method")
                    match.setValue(item.value_exc_vat, forKey: "value_excluding_vat")
                    match.setValue(item.value_inc_vat, forKey: "value_including_vat")
                    match.setValue(item.valid_to, forKey: "valid_to")
                } else {
                    // insert new
                    let newObj = NSEntityDescription.insertNewObject(
                        forEntityName: "StandingChargeEntity",
                        into: self.context
                    )
                    newObj.setValue(UUID().uuidString, forKey: "id")
                    newObj.setValue(productCode, forKey: "product_code")
                    newObj.setValue(region, forKey: "region")
                    newObj.setValue(payMethod, forKey: "payment_method")
                    newObj.setValue(item.value_exc_vat, forKey: "value_excluding_vat")
                    newObj.setValue(item.value_inc_vat, forKey: "value_including_vat")
                    newObj.setValue(fromDate, forKey: "valid_from")
                    newObj.setValue(item.valid_to, forKey: "valid_to")
                }
            }

            try self.context.save()
        }
    }

    // MARK: - Fetches for Agile usage only
    /// Example page-based fetch for Agile half-hour rates,
    /// adapted from your original `fetchAllRatesPage`.
    private func fetchAllRatesPageAgile(regionID: String, page: Int) async throws -> AgileRatesPageResponse {
        let productCode = "AGILE-24-10-01" // Hard-coded for demonstration
        let tariffCode = "E-1R-\(productCode)-\(regionID)"
        let urlString = "https://api.octopus.energy/v1/products/\(productCode)/electricity-tariffs/\(tariffCode)/standard-unit-rates/?page=\(page)"
        guard let url = URL(string: urlString) else {
            throw OctopusAPIError.invalidURL
        }
        do {
            let (data, response) = try await urlSession.data(for: URLRequest(url: url))
            guard let httpResponse = response as? HTTPURLResponse,
                  (200...299).contains(httpResponse.statusCode)
            else {
                throw OctopusAPIError.invalidResponse
            }

            let decoder = JSONDecoder()
            let dateFormatter = ISO8601DateFormatter()
            decoder.dateDecodingStrategy = .custom { decoder in
                let container = try decoder.singleValueContainer()
                let dateString = try container.decode(String.self)
                guard let date = dateFormatter.date(from: dateString) else {
                    throw DecodingError.dataCorruptedError(
                        in: container,
                        debugDescription: "Invalid date format"
                    )
                }
                return date
            }

            return try decoder.decode(AgileRatesPageResponse.self, from: data)
        } catch let urlError as URLError {
            throw OctopusAPIError.networkError(urlError)
        } catch let decodeError as DecodingError {
            throw OctopusAPIError.decodingError(decodeError)
        } catch {
            throw OctopusAPIError.networkError(error)
        }
    }

    // MARK: - Region Lookup
    /// Simplified version of region fetch.
    /// In real usage, you might call your `OctopusAPIClient` method.
    private func fetchRegionID(for postcode: String) async throws -> String? {
        // Example: fallback to "H"
        return "H"
    }

    // MARK: - Utility
    /// Figures out if we want coverage up to "today/tomorrow at 23:00" UK time.
    private func expectedEndOfDayInUTC() -> Date? {
        guard let ukTimeZone = TimeZone(identifier: "Europe/London") else { return nil }
        var ukCalendar = Calendar(identifier: .gregorian)
        ukCalendar.timeZone = ukTimeZone

        let now = Date()
        let hour = ukCalendar.component(.hour, from: now)
        let offsetDay = (hour < 16) ? 0 : 1
        guard
            let baseDay = ukCalendar.date(byAdding: .day, value: offsetDay, to: now),
            let endOfDayLocal = ukCalendar.date(bySettingHour: 23, minute: 0, second: 0, of: baseDay)
        else {
            return nil
        }
        return endOfDayLocal.toUTC(from: ukTimeZone)
    }
}

// MARK: - Data Models
/// For your half-hour Agile usage
private struct AgileRatesPageResponse: Codable {
    let count: Int?
    let next: String?
    let previous: String?
    let results: [OctopusRate]
}

/// Reuse your old `OctopusRate` with half-hour intervals.
public struct OctopusRate: Codable, Identifiable {
    public let id = UUID()  // ephemeral
    public let valid_from: Date
    public let valid_to: Date?
    public let value_exc_vat: Double
    public let value_inc_vat: Double
}

// MARK: - Extension for Date -> UTC
extension Date {
    func toUTC(from timeZone: TimeZone) -> Date? {
        let offset = timeZone.secondsFromGMT(for: self)
        return Calendar(identifier: .gregorian)
            .date(byAdding: .second, value: -offset, to: self)
    }
}
