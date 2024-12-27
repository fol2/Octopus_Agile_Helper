import Foundation
import CoreData
import SwiftUI
import Combine

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
        print("DEBUG: Starting rate update (force: \(force))")
        
        if force {
            try await doActualFetch()
            return
        }
        
        // Check if it's 4 PM UK time
        let now = Date()
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Europe/London") ?? .current
        let hour = calendar.component(.hour, from: now)
        let minute = calendar.component(.minute, from: now)
        let is4pm = (hour == 16 && minute == 0)
        
        // Check if we have tomorrow's rates
        let hasNextDay = hasRatesForTomorrow()
        
        if is4pm && !hasNextDay {
            print("DEBUG: It's 4pm and we don't have tomorrow's data. Fetching...")
            try await doActualFetch()
        } else if currentCachedRates.isEmpty {
            print("DEBUG: No data found. Fetching at app open.")
            try await doActualFetch()
        } else {
            print("DEBUG: No fetch needed.")
        }
    }
    
    private func doActualFetch() async throws {
        let regionID = try await fetchRegionID(for: postcode) ?? "H"
        print("DEBUG: Using region ID: \(regionID)")
        let newRates = try await apiClient.fetchRates(regionID: regionID)
        try await saveRates(newRates)
    }
    
    private func hasRatesForTomorrow() -> Bool {
        let tomorrow = Calendar.current.date(byAdding: .day, value: 1, to: Date())!
        let midnight = Calendar.current.startOfDay(for: tomorrow)
        return currentCachedRates.contains { $0.validFrom ?? .distantPast >= midnight }
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