import Foundation
import SwiftUI

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
    private let persistence = RatesPersistence.shared
    
    private init() {}
    
    func updateRates() async throws {
        let rates = try await apiClient.fetchRates()
        try await persistence.saveRates(rates)
    }
    
    func loadStoredRates() async throws -> [RateEntity] {
        return try await persistence.fetchAllRates()
    }
} 