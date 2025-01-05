import Combine
import CoreData
import Foundation
import SwiftUI

// MARK: - AgileRatesPageResponse (For full historical pagination)
private struct AgileRatesPageResponse: Codable {
    let count: Int?
    let next: String?
    let previous: String?
    let results: [OctopusRate]
}

/// Manages Octopus Agile rate data in Core Data, including fetching and caching.
@MainActor
public final class RatesRepository: ObservableObject {
    // MARK: - Singleton
    public static let shared = RatesRepository()

    // MARK: - Public Published State
    @Published public private(set) var currentCachedRates: [RateEntity] = []

    // MARK: - Dependencies
    private let apiClient = OctopusAPIClient.shared
    private let context: NSManagedObjectContext
    @AppStorage("postcode") private var postcode: String = ""

    // MARK: - Networking
    private let urlSession: URLSession
    private let maxRetries = 3

    // MARK: - Initializer
    private init() {
        context = PersistenceController.shared.container.viewContext
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 30
        config.waitsForConnectivity = true
        urlSession = URLSession(configuration: config)
    }

    // MARK: - Public Methods

    /// Updates the rates in the database, only fetching if needed or if `force` is `true`.
    /// - Parameter force: Forces a fresh fetch even if we have enough data.
    /// - Throws: Possible network or data errors.
    public func updateRates(force: Bool = false) async throws {
        if force || !hasDataThroughExpectedEndUKTime() {
            try await performFetch()
        }
    }

    /// Checks whether we have coverage through the expected end (in UK time).
    /// - Returns: `true` if data extends past “tonight at 23:00” (if before 16:00)
    ///   or “tomorrow at 23:00” (if after 16:00).
    public func hasDataThroughExpectedEndUKTime() -> Bool {
        guard let maxValidTo = currentCachedRates.compactMap(\.validTo).max() else { return false }
        guard let endOfDayUTC = expectedEndOfDayInUTC() else { return false }
        return maxValidTo >= endOfDayUTC
    }

    /// Fetches **all** stored rates from Core Data (sorted by `validFrom`) and
    /// updates `currentCachedRates`.
    /// - Returns: All fetched `RateEntity`.
    public func fetchAllRates() async throws -> [RateEntity] {
        let request: NSFetchRequest<RateEntity> = RateEntity.fetchRequest()
        request.sortDescriptors = [NSSortDescriptor(keyPath: \RateEntity.validFrom, ascending: true)]

        let results = try await self.context.performAsync { try self.context.fetch(request) }
        currentCachedRates = results
        return results
    }

    /// Deletes *all* rates from the database. Useful for debugging or manual resets.
    public func deleteAllRates() async throws {
        let fetchRequest: NSFetchRequest<NSFetchRequestResult> = RateEntity.fetchRequest()
        let deleteRequest = NSBatchDeleteRequest(fetchRequest: fetchRequest)

        try await self.context.performAsync {
            try self.context.execute(deleteRequest)
            try self.context.save()
        }
        currentCachedRates = []
    }

    /// Attempts to fetch the user’s electricity region from the provided postcode.
    /// - Parameter postcode: The user’s postcode. Fallback to `'H'` if empty or invalid.
    /// - Returns: A region ID string like "H" or "L".
    /// - Throws: Network or decoding errors. Retries on `.cancelled` up to `maxRetries`.
    public func fetchRegionID(for postcode: String, retryCount: Int = 0) async throws -> String? {
        let cleanedPostcode = postcode.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanedPostcode.isEmpty else { return "H" }

        let encoded = cleanedPostcode.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed)
        guard let encodedPostcode = encoded,
              let url = URL(string: "https://api.octopus.energy/v1/industry/grid-supply-points/?postcode=\(encodedPostcode)")
        else { return "H" }

        do {
            let (data, response) = try await urlSession.data(for: URLRequest(url: url))
            guard let httpResponse = response as? HTTPURLResponse,
                  (200...299).contains(httpResponse.statusCode)
            else {
                // If not successful, fallback to 'H'
                return "H"
            }

            let supplyPoints = try JSONDecoder().decode(SupplyPointsResponse.self, from: data)
            if let first = supplyPoints.results.first {
                // Strip underscores from group_id => region
                let region = first.group_id.replacingOccurrences(of: "_", with: "")
                return region
            }
            return "H"

        } catch let urlError as URLError where urlError.code == .cancelled {
            if retryCount < maxRetries {
                // Simple exponential-ish backoff
                try await Task.sleep(nanoseconds: UInt64(1_000_000_000 * (retryCount + 1)))
                return try await fetchRegionID(for: cleanedPostcode, retryCount: retryCount + 1)
            }
            return "H"
        } catch {
            return "H"
        }
    }

    // MARK: - Private Internal Logic

    /// Actually performs a fetch from the network if needed.
    ///  1. Determine region from user’s postcode.
    ///  2. Pull fresh rates from the Octopus API.
    ///  3. Save them to Core Data.
    ///  4. Refresh `currentCachedRates`.
    private func performFetch() async throws {
        let regionID = try await fetchRegionID(for: postcode) ?? "H"
        let newRates = try await apiClient.fetchRates(regionID: regionID)
        try await saveRates(newRates)
    }

    /// Stores the fetched data into Core Data. Updates `currentCachedRates`.
    private func saveRates(_ rates: [OctopusRate]) async throws {
        try await self.context.performAsync {
            // Use 'self.context' explicitly
            let existing = try self.context
                .fetch(RateEntity.fetchRequest()) as? [RateEntity] ?? []

            let existingMap = Dictionary(
                uniqueKeysWithValues: existing.compactMap { rate -> (Date, RateEntity)? in
                    guard let from = rate.validFrom else { return nil }
                    return (from, rate)
                }
            )

            for octopusRate in rates {
                if let match = existingMap[octopusRate.valid_from] {
                    match.validTo = octopusRate.valid_to
                    match.valueExcludingVAT = octopusRate.value_exc_vat
                    match.valueIncludingVAT = octopusRate.value_inc_vat
                } else {
                    let newEntity = RateEntity(context: self.context)
                    newEntity.id = octopusRate.id.uuidString
                    newEntity.validFrom = octopusRate.valid_from
                    newEntity.validTo = octopusRate.valid_to
                    newEntity.valueExcludingVAT = octopusRate.value_exc_vat
                    newEntity.valueIncludingVAT = octopusRate.value_inc_vat
                }
            }
            try self.context.save()
        }

        // Refresh the local cache
        currentCachedRates = try await fetchAllRates()
    }

    /// Returns the "expected end" time in UTC based on whether it's before or after 16:00 UK time.
    /// If before 16:00 => we want coverage up to "today at 23:00" (UK).
    /// If after 16:00 => "tomorrow at 23:00" (UK).
    private func expectedEndOfDayInUTC() -> Date? {
        guard let ukTimeZone = TimeZone(identifier: "Europe/London") else { return nil }
        var ukCalendar = Calendar(identifier: .gregorian)
        ukCalendar.timeZone = ukTimeZone

        let now = Date()
        let hour = ukCalendar.component(.hour, from: now)
        let offsetDay = (hour < 16) ? 0 : 1

        guard let baseDay = ukCalendar.date(byAdding: .day, value: offsetDay, to: now),
              let endOfDayLocal = ukCalendar.date(bySettingHour: 23, minute: 0, second: 0, of: baseDay)
        else {
            return nil
        }

        return endOfDayLocal.toUTC(from: ukTimeZone)
    }

    /// Helper function that fetches a *single* page of Agile rates with pagination metadata
    /// - Parameters:
    ///   - regionID: The region ID to fetch rates for
    ///   - page: The page number to fetch
    /// - Returns: A specialized `AgileRatesPageResponse` that includes pagination metadata
    /// - Throws: Network, decoding, or other errors
    private func fetchAllRatesPage(regionID: String, page: Int) async throws -> AgileRatesPageResponse {
        let productCode = "AGILE-24-10-01"  // This matches what's used in OctopusAPIClient
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
            
            // Use the same date formatter as OctopusRate for consistency
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

    /// Fetches *all* Agile rates from the Octopus API, ensuring we have both earliest and latest data.
    /// Uses the paging logic from the server's JSON response: `count`, `next`, `results`.
    /// - Throws: Network, decoding, or Core Data errors.
    public func syncAllRates() async throws {
        // 1) Determine region from user's postcode or fallback
        let regionID = try await fetchRegionID(for: postcode) ?? "H"
        
        // 2) Query local DB to find earliest & latest in Core Data
        let localRates = try await fetchAllRates()
        let localEarliest = localRates.compactMap(\.validFrom).min()
        let localLatest = localRates.compactMap(\.validTo).max()
        
        // 3) First page fetch to get pagination info
        let firstPage = try await fetchAllRatesPage(regionID: regionID, page: 1)
        guard let totalCount = firstPage.count, totalCount > 0 else {
            print("No rate records found on server.")
            return
        }
        
        // Store the first page's data
        try await saveRates(firstPage.results)
        
        // 4) Calculate total pages needed (typically 100 results per page)
        let pageSize = firstPage.results.count
        let totalPages = Int(ceil(Double(totalCount) / Double(pageSize)))
        print("Total rate records = \(totalCount), pageSize = \(pageSize), totalPages = \(totalPages)")
        
        // 5) Fetch remaining pages
        for pg in 2...totalPages {
            let pageResponse = try await fetchAllRatesPage(regionID: regionID, page: pg)
            try await saveRates(pageResponse.results)
        }
        
        // 6) Reload from DB to confirm we have everything
        let final = try await fetchAllRates()
        let newEarliest = final.compactMap(\.validFrom).min() ?? localEarliest
        let newLatest = final.compactMap(\.validTo).max() ?? localLatest
        print("Synced all rates: earliest=\(String(describing: newEarliest)) latest=\(String(describing: newLatest))")
    }
}

// MARK: - SupplyPointsResponse (Region lookup)
fileprivate struct SupplyPointsResponse: Codable {
    let count: Int
    let results: [SupplyPoint]
}

fileprivate struct SupplyPoint: Codable {
    let group_id: String
}

// MARK: - NSManagedObjectContext async helper
extension NSManagedObjectContext {
    /// Convenience wrapper for async operations on the context’s queue.
    func performAsync<T>(_ block: @escaping () throws -> T) async throws -> T {
        try await withCheckedThrowingContinuation { continuation in
            perform {
                do {
                    continuation.resume(returning: try block())
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }
}

extension Date {
    /// Interprets this `Date` as local to `timeZone` and returns an equivalent UTC `Date`.
    func toUTC(from timeZone: TimeZone) -> Date? {
        let offset = timeZone.secondsFromGMT(for: self)
        return Calendar(identifier: .gregorian)
            .date(byAdding: .second, value: -offset, to: self)
    }
}
