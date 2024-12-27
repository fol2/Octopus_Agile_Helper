import Foundation
import CoreData
import SwiftUI

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
class RatesRepository {
    static let shared = RatesRepository()
    private let apiClient = OctopusAPIClient.shared
    private let context: NSManagedObjectContext
    @AppStorage("postcode") private var postcode: String = ""
    
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
        print("DEBUG: Starting region lookup for postcode: \(postcode) (attempt \(retryCount + 1))")
        
        // Clean and validate postcode
        let cleanedPostcode = postcode.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanedPostcode.isEmpty else {
            print("DEBUG: Empty postcode provided")
            return nil
        }
        
        // URL encode the postcode
        guard let encodedPostcode = cleanedPostcode.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) else {
            print("DEBUG: Failed to encode postcode")
            return nil
        }
        
        let urlString = "https://api.octopus.energy/v1/industry/grid-supply-points/?postcode=\(encodedPostcode)"
        guard let url = URL(string: urlString) else {
            print("DEBUG: Failed to create URL with postcode: \(cleanedPostcode)")
            return nil
        }
        
        print("DEBUG: Fetching region from URL: \(url.absoluteString)")
        
        // Create a URLRequest with a timeout
        var request = URLRequest(url: url)
        request.timeoutInterval = 30
        request.httpMethod = "GET"
        
        do {
            let (data, response) = try await urlSession.data(for: request)
            
            guard let httpResponse = response as? HTTPURLResponse else {
                print("DEBUG: Invalid response type")
                return nil
            }
            
            print("DEBUG: Region lookup response status: \(httpResponse.statusCode)")
            
            guard (200...299).contains(httpResponse.statusCode) else {
                print("DEBUG: Error response: \(httpResponse.statusCode)")
                if let errorText = String(data: data, encoding: .utf8) {
                    print("DEBUG: Error details: \(errorText)")
                }
                return nil
            }
            
            let decoder = JSONDecoder()
            let supplyPoints = try decoder.decode(SupplyPointsResponse.self, from: data)
            
            if let groupId = supplyPoints.results.first?.group_id {
                let cleanGroupId = groupId.replacingOccurrences(of: "_", with: "")
                print("DEBUG: Successfully found region: \(groupId), using: \(cleanGroupId)")
                return cleanGroupId
            } else {
                print("DEBUG: No region found in response")
                return nil
            }
            
        } catch let urlError as URLError where urlError.code == .cancelled {
            print("DEBUG: Request was cancelled (attempt \(retryCount + 1))")
            
            // Retry if we haven't exceeded max retries
            if retryCount < maxRetries {
                print("DEBUG: Retrying request (attempt \(retryCount + 2))")
                try await Task.sleep(nanoseconds: UInt64(1_000_000_000 * (retryCount + 1))) // Exponential backoff
                return try await fetchRegionID(for: postcode, retryCount: retryCount + 1)
            } else {
                print("DEBUG: Max retries exceeded")
                throw urlError
            }
        } catch {
            print("DEBUG: Region lookup failed with error: \(error.localizedDescription)")
            if let urlError = error as? URLError {
                print("DEBUG: URL Error code: \(urlError.code.rawValue)")
                print("DEBUG: URL Error description: \(urlError.localizedDescription)")
            }
            throw error
        }
    }
    
    func updateRates() async throws {
        print("DEBUG: Starting rate update")
        
        // Validate postcode
        let cleanedPostcode = postcode.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanedPostcode.isEmpty else {
            print("DEBUG: No postcode set in settings")
            throw OctopusAPIError.invalidResponse
        }
        
        print("DEBUG: Using postcode: \(cleanedPostcode)")
        
        // Create a task that won't be cancelled when the view disappears
        let task = Task {
            do {
                // Fetch region ID from postcode with retries
                guard let regionID = try await fetchRegionID(for: cleanedPostcode) else {
                    print("DEBUG: Could not determine region for postcode \(cleanedPostcode)")
                    throw OctopusAPIError.invalidResponse
                }
                
                print("DEBUG: Found region ID: \(regionID) for postcode: \(cleanedPostcode)")
                
                // Fetch rates using the region ID
                let rates = try await apiClient.fetchRates(regionID: regionID)
                print("DEBUG: Fetched \(rates.count) rates from API, saving to Core Data")
                
                // Save the rates
                try await saveRates(rates)
                print("DEBUG: Completed saving rates to Core Data")
                
            } catch let urlError as URLError where urlError.code == .cancelled {
                print("DEBUG: Region lookup was cancelled after all retries")
                throw OctopusAPIError.networkError(urlError)
            } catch {
                print("DEBUG: Error during rate update: \(error.localizedDescription)")
                throw error
            }
        }
        
        // Wait for the task to complete, but don't cancel it if the view disappears
        try await task.value
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
    }
    
    func fetchAllRates() async throws -> [RateEntity] {
        try await context.performAsync {
            let fetchRequest: NSFetchRequest<RateEntity> = RateEntity.fetchRequest()
            fetchRequest.sortDescriptors = [NSSortDescriptor(keyPath: \RateEntity.validFrom, ascending: true)]
            let rates = try self.context.fetch(fetchRequest)
            print("DEBUG: Fetched \(rates.count) rates from Core Data")
            
            // Debug upcoming rates
            let now = Date()
            let upcomingRates = rates.filter { ($0.validFrom ?? .distantPast) > now }
            print("DEBUG: Of which \(upcomingRates.count) are upcoming (validFrom > now)")
            
            return rates
        }
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