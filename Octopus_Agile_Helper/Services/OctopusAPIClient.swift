import Foundation
import SwiftUI
import CoreData

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
    
    private init() {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 30
        self.session = URLSession(configuration: config)
    }
    
    func fetchRates(regionID: String) async throws -> [OctopusRate] {
        guard let url = URL(string: "\(baseURL)/products/AGILE-FLEX-22-11-25/electricity-tariffs/E-1R-AGILE-FLEX-22-11-25-\(regionID)/standard-unit-rates/") else {
            print("DEBUG: Invalid URL constructed")
            throw OctopusAPIError.invalidURL
        }
        
        print("DEBUG: Fetching rates from URL: \(url.absoluteString)")
        
        let request = URLRequest(url: url)
        
        do {
            let (data, response) = try await session.data(for: request)
            
            guard let httpResponse = response as? HTTPURLResponse else {
                print("DEBUG: Invalid response type")
                throw OctopusAPIError.invalidResponse
            }
            
            print("DEBUG: API Response Status Code: \(httpResponse.statusCode)")
            
            guard (200...299).contains(httpResponse.statusCode) else {
                print("DEBUG: Error response: \(httpResponse.statusCode)")
                throw OctopusAPIError.invalidResponse
            }
            
            let decoder = JSONDecoder()
            let ratesResponse = try decoder.decode(OctopusRatesResponse.self, from: data)
            print("DEBUG: Successfully decoded \(ratesResponse.results.count) rates")
            return ratesResponse.results
            
        } catch let error as DecodingError {
            print("DEBUG: Decoding error: \(error)")
            throw OctopusAPIError.decodingError(error)
        } catch {
            print("DEBUG: Network error: \(error)")
            throw OctopusAPIError.networkError(error)
        }
    }
} 
