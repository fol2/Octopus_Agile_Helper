import Foundation
import SwiftUI
import CoreData

struct OctopusRatesResponse: Codable {
    let results: [OctopusRate]
}

struct OctopusRate: Codable, Identifiable {
    let id = UUID()
    let valid_from: Date
    let valid_to: Date
    let value_exc_vat: Double
    let value_inc_vat: Double
    
    enum CodingKeys: String, CodingKey {
        case valid_from
        case valid_to
        case value_exc_vat
        case value_inc_vat
    }
    
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        
        let dateFormatter = ISO8601DateFormatter()
        
        let validFromString = try container.decode(String.self, forKey: .valid_from)
        guard let validFrom = dateFormatter.date(from: validFromString) else {
            throw DecodingError.dataCorruptedError(forKey: .valid_from, in: container, debugDescription: "Invalid date format")
        }
        self.valid_from = validFrom
        
        let validToString = try container.decode(String.self, forKey: .valid_to)
        guard let validTo = dateFormatter.date(from: validToString) else {
            throw DecodingError.dataCorruptedError(forKey: .valid_to, in: container, debugDescription: "Invalid date format")
        }
        self.valid_to = validTo
        
        self.value_exc_vat = try container.decode(Double.self, forKey: .value_exc_vat)
        self.value_inc_vat = try container.decode(Double.self, forKey: .value_inc_vat)
    }
}

enum OctopusAPIError: Error {
    case invalidURL
    case invalidResponse
    case networkError(Error)
    case decodingError(Error)
    case invalidAPIKey
}

class OctopusAPIClient {
    static let shared = OctopusAPIClient()
    private let baseURL = "https://api.octopus.energy/v1"
    private let session: URLSession
    
    @AppStorage("apiKey") private var apiKey: String = ""
    
    private init() {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 30
        self.session = URLSession(configuration: config)
    }
    
    func fetchRates() async throws -> [OctopusRate] {
        guard !apiKey.isEmpty else {
            throw OctopusAPIError.invalidAPIKey
        }
        
        // Note: This URL needs to be updated with the correct endpoint for Agile rates
        guard let url = URL(string: "\(baseURL)/products/AGILE-FLEX-22-11-25/electricity-tariffs/E-1R-AGILE-FLEX-22-11-25-H/standard-unit-rates/") else {
            throw OctopusAPIError.invalidURL
        }
        
        var request = URLRequest(url: url)
        request.setValue("Basic \(Data("\(apiKey):".utf8).base64EncodedString())", forHTTPHeaderField: "Authorization")
        
        do {
            let (data, response) = try await session.data(for: request)
            
            guard let httpResponse = response as? HTTPURLResponse,
                  (200...299).contains(httpResponse.statusCode) else {
                throw OctopusAPIError.invalidResponse
            }
            
            let decoder = JSONDecoder()
            let ratesResponse = try decoder.decode(OctopusRatesResponse.self, from: data)
            return ratesResponse.results
            
        } catch let error as DecodingError {
            throw OctopusAPIError.decodingError(error)
        } catch {
            throw OctopusAPIError.networkError(error)
        }
    }
}

// MARK: - Rate Manager
class RatesManager {
    static let shared = RatesManager()
    private let apiClient = OctopusAPIClient.shared
    private let persistence: NSPersistentContainer
    
    private init() {
        self.persistence = NSPersistentContainer(name: "Octopus_Agile_Helper")
        persistence.loadPersistentStores { description, error in
            if let error = error {
                fatalError("Core Data store failed to load: \(error.localizedDescription)")
            }
        }
    }
    
    func updateRates() async throws {
        let rates = try await apiClient.fetchRates()
        let context = persistence.viewContext
        
        try await context.perform {
            // First, fetch existing rates to avoid duplicates
            let fetchRequest = NSFetchRequest<NSManagedObject>(entityName: "RateEntity")
            let existingRates = try context.fetch(fetchRequest)
            
            // Create a dictionary of existing rates by their valid_from date for quick lookup
            let existingRatesByDate = Dictionary(uniqueKeysWithValues: existingRates.map { ($0.value(forKey: "validFrom") as! Date, $0) })
            
            // Update or insert rates
            for rate in rates {
                if let existingRate = existingRatesByDate[rate.valid_from] {
                    // Update existing rate
                    existingRate.setValue(rate.valid_to, forKey: "validTo")
                    existingRate.setValue(rate.value_exc_vat, forKey: "valueExcludingVAT")
                    existingRate.setValue(rate.value_inc_vat, forKey: "valueIncludingVAT")
                } else {
                    // Create new rate
                    let newRate = NSEntityDescription.insertNewObject(forEntityName: "RateEntity", into: context)
                    newRate.setValue(rate.id.uuidString, forKey: "id")
                    newRate.setValue(rate.valid_from, forKey: "validFrom")
                    newRate.setValue(rate.valid_to, forKey: "validTo")
                    newRate.setValue(rate.value_exc_vat, forKey: "valueExcludingVAT")
                    newRate.setValue(rate.value_inc_vat, forKey: "valueIncludingVAT")
                }
            }
            
            // Save changes
            try context.save()
        }
    }
    
    func loadStoredRates() async throws -> [NSManagedObject] {
        let context = persistence.viewContext
        return try await context.perform {
            let fetchRequest = NSFetchRequest<NSManagedObject>(entityName: "RateEntity")
            fetchRequest.sortDescriptors = [NSSortDescriptor(key: "validFrom", ascending: true)]
            return try context.fetch(fetchRequest)
        }
    }
} 