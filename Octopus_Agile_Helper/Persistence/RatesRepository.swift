import Foundation
import CoreData
import SwiftUI
import Combine
import Darwin

// Response models for region lookup
struct SupplyPointsResponse: Codable {
    let count: Int
    let results: [SupplyPoint]
}

struct SupplyPoint: Codable {
    let group_id: String
}

// Extend NSManagedObjectContext with async support
extension NSManagedObjectContext {
    func performAsync<T>(_ block: @escaping () throws -> T) async throws -> T {
        try await withCheckedThrowingContinuation { continuation in
            perform {
                do {
                    let result = try block()
                    continuation.resume(returning: result)
                } catch let error {
                    continuation.resume(throwing: error)
                }
            }
        }
    }
}

@MainActor
extension Date {
    /// Convert a Date (interpreted as Europe/London local time) to its equivalent in UTC.
    /// - Warning: This makes sense only if `self` was constructed with a London-based Calendar/time zone.
    func toUTC(from timeZone: TimeZone) -> Date? {
        // TimeZone.secondsFromGMT(for:) gives the offset (in seconds) from GMT at this date
        let offset = timeZone.secondsFromGMT(for: self)
        return Calendar(identifier: .gregorian).date(byAdding: .second, value: -offset, to: self)
    }
}

@MainActor
class RatesRepository: ObservableObject {
    static let shared = RatesRepository()
    private let apiClient = OctopusAPIClient.shared
    private let context: NSManagedObjectContext
    @AppStorage("postcode") private var postcode: String = ""
    @Published var currentCachedRates: [RateEntity] = []
    
    // Dedicated URLSession for region lookups
    private let urlSession: URLSession
    private let maxRetries = 3
    
    private init() {
        self.context = PersistenceController.shared.container.viewContext
        
        // Configure a dedicated session for region lookups
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 30
        config.waitsForConnectivity = true  // Wait for connectivity if offline
        self.urlSession = URLSession(configuration: config)
    }
    
    func fetchRegionID(for postcode: String, retryCount: Int = 0) async throws -> String? {
        // Clean and validate postcode
        let cleanedPostcode = postcode.trimmingCharacters(in: .whitespacesAndNewlines)
        if cleanedPostcode.isEmpty {
            print("DEBUG: No postcode provided, using default region 'H'")
            return "H"
        }
        
        print("DEBUG: Starting region lookup for postcode: \(cleanedPostcode) (attempt \(retryCount + 1))")
        
        // URL encode the postcode
        guard let encodedPostcode = cleanedPostcode.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) else {
            print("DEBUG: Failed to encode postcode, using default region 'H'")
            return "H"
        }
        
        let urlString = "https://api.octopus.energy/v1/industry/grid-supply-points/?postcode=\(encodedPostcode)"
        guard let url = URL(string: urlString) else {
            print("DEBUG: Failed to create URL with postcode: \(cleanedPostcode), using default region 'H'")
            return "H"
        }
        
        print("DEBUG: Fetching region from URL: \(url.absoluteString)")
        
        // Create a URLRequest with a timeout
        var request = URLRequest(url: url)
        request.timeoutInterval = 30
        request.httpMethod = "GET"
        
        do {
            let (data, response) = try await urlSession.data(for: request)
            
            guard let httpResponse = response as? HTTPURLResponse else {
                print("DEBUG: Invalid response type, using default region 'H'")
                return "H"
            }
            
            print("DEBUG: Region lookup response status: \(httpResponse.statusCode)")
            
            guard (200...299).contains(httpResponse.statusCode) else {
                print("DEBUG: Error response: \(httpResponse.statusCode), using default region 'H'")
                if let errorText = String(data: data, encoding: .utf8) {
                    print("DEBUG: Error details: \(errorText)")
                }
                return "H"
            }
            
            let decoder = JSONDecoder()
            let supplyPoints = try decoder.decode(SupplyPointsResponse.self, from: data)
            
            if let groupId = supplyPoints.results.first?.group_id {
                let cleanGroupId = groupId.replacingOccurrences(of: "_", with: "")
                print("DEBUG: Successfully found region: \(groupId), using: \(cleanGroupId)")
                return cleanGroupId
            } else {
                print("DEBUG: No region found in response, using default region 'H'")
                return "H"
            }
            
        } catch let urlError as URLError where urlError.code == .cancelled {
            print("DEBUG: Request was cancelled (attempt \(retryCount + 1))")
            
            // Retry if we haven't exceeded max retries
            if retryCount < maxRetries {
                print("DEBUG: Retrying request (attempt \(retryCount + 2))")
                try await Task.sleep(nanoseconds: UInt64(1_000_000_000 * (retryCount + 1))) // Exponential backoff
                return try await fetchRegionID(for: postcode, retryCount: retryCount + 1)
            } else {
                print("DEBUG: Max retries exceeded, using default region 'H'")
                return "H"
            }
        } catch {
            print("DEBUG: Region lookup failed with error: \(error.localizedDescription), using default region 'H'")
            if let urlError = error as? URLError {
                print("DEBUG: URL Error code: \(urlError.code.rawValue)")
                print("DEBUG: URL Error description: \(urlError.localizedDescription)")
            }
            return "H"
        }
    }
    
    func updateRates(force: Bool = false) async throws {
        print("DEBUG: Starting rate update with UK-time logic (force: \(force))")
        
        if force {
            try await doActualFetch()
            return
        }
        
        // Check if we have data through the "expected end date" in UK time.
        // If not, we do an actual fetch.
        if !hasDataThroughExpectedEndUKTime() {
            print("DEBUG: We do NOT have data through the expected end date. Fetching now...")
            try await doActualFetch()
        } else {
            print("DEBUG: We have enough data through the expected end date. No fetch needed.")
        }
    }
    
    /// Check if we already have data extending through the "expected end" based on UK time:
    /// - If now < 16:00 UK => we want data up to "today at 23:00" UK time
    /// - If now >= 16:00 UK => we want data up to "tomorrow at 23:00" UK time
    ///
    /// Compare that final time (in UTC) to the maximum validTo in our currentCachedRates.
    func hasDataThroughExpectedEndUKTime() -> Bool {
        // 1) Get "now" in the UK time zone
        guard let londonTimeZone = TimeZone(identifier: "Europe/London") else {
            // Fallback: if we can't get the zone, let's force a fetch
            return false
        }
        var londonCalendar = Calendar(identifier: .gregorian)
        londonCalendar.timeZone = londonTimeZone
        
        let now = Date() // "raw" Date is in UTC reference, but we'll interpret hour using londonCalendar
        let hour = londonCalendar.component(.hour, from: now)
        
        // 2) Decide if we want "today" or "tomorrow" at 23:00 UK time
        let dayOffset = (hour < 16) ? 0 : 1
        
        // Build a date (in London time) that is "today/tomorrow at 23:00"
        guard
            let base = londonCalendar.date(byAdding: .day, value: dayOffset, to: now),
            let endOfDayLondon = londonCalendar.date(
                bySettingHour: 23,
                minute: 0,
                second: 0,
                of: base
            )
        else {
            print("DEBUG: Could not compute endOfDayLondon.")
            return false
        }
        
        // 3) Convert endOfDayLondon to UTC, because typically `validTo` is stored as UTC
        guard let endOfDayUTC = endOfDayLondon.toUTC(from: londonTimeZone) else {
            print("DEBUG: Could not convert endOfDayLondon to UTC.")
            return false
        }
        
        // 4) Check if our currentCachedRates contain at least one entry with `validTo >= endOfDayUTC`
        //    i.e., do we have coverage through that time?
        guard let maxValidTo = currentCachedRates.compactMap({ $0.validTo }).max() else {
            // If we have no rates at all, obviously we don't meet the requirement
            return false
        }
        
        let hasCoverage = maxValidTo >= endOfDayUTC
        print("DEBUG: endOfDayUTC = \(endOfDayUTC), maxValidTo = \(maxValidTo), hasCoverage = \(hasCoverage)")
        return hasCoverage
    }
    
    private func doActualFetch() async throws {
        let regionID = try await fetchRegionID(for: postcode) ?? "H"
        print("DEBUG: Using region ID: \(regionID)")
        let newRates = try await apiClient.fetchRates(regionID: regionID)
        try await saveRates(newRates)
    }
    
    func fetchAllRates() async throws -> [RateEntity] {
        let rates = try await context.performAsync {
            let fetchRequest: NSFetchRequest<RateEntity> = RateEntity.fetchRequest()
            fetchRequest.sortDescriptors = [NSSortDescriptor(keyPath: \RateEntity.validFrom, ascending: true)]
            return try self.context.fetch(fetchRequest)
        }
        currentCachedRates = rates // Update the cached rates
        return rates
    }
    
    private func saveRates(_ rates: [OctopusRate]) async throws {
        try await context.performAsync {
            print("DEBUG: Starting Core Data save operation")
            // First, fetch existing rates to avoid duplicates
            let fetchRequest: NSFetchRequest<RateEntity> = RateEntity.fetchRequest()
            let existingRates = try self.context.fetch(fetchRequest)
            print("DEBUG: Found \(existingRates.count) existing rates in Core Data")
            
            // Create a dictionary of existing rates by their valid_from date for quick lookup
            let existingRatesByDate = Dictionary(uniqueKeysWithValues: existingRates.map { ($0.validFrom!, $0) })
            
            var updatedCount = 0
            var insertedCount = 0
            
            // Update or insert rates
            for rate in rates {
                if let existingRate = existingRatesByDate[rate.valid_from] {
                    // Update existing rate
                    existingRate.validTo = rate.valid_to
                    existingRate.valueExcludingVAT = rate.value_exc_vat
                    existingRate.valueIncludingVAT = rate.value_inc_vat
                    updatedCount += 1
                } else {
                    // Create new rate
                    let newRate = RateEntity(context: self.context)
                    newRate.id = rate.id.uuidString
                    newRate.validFrom = rate.valid_from
                    newRate.validTo = rate.valid_to
                    newRate.valueExcludingVAT = rate.value_exc_vat
                    newRate.valueIncludingVAT = rate.value_inc_vat
                    insertedCount += 1
                }
            }
            
            print("DEBUG: Updated \(updatedCount) rates, inserted \(insertedCount) new rates")
            
            // Save changes
            try self.context.save()
            print("DEBUG: Successfully saved all changes to Core Data")
        }
        // After saving, update the cached rates
        currentCachedRates = try await fetchAllRates()
    }
    
    func deleteAllRates() async throws {
        try await context.performAsync {
            let fetchRequest: NSFetchRequest<NSFetchRequestResult> = RateEntity.fetchRequest()
            let deleteRequest = NSBatchDeleteRequest(fetchRequest: fetchRequest)
            try self.context.execute(deleteRequest)
            try self.context.save()
        }
    }
} 