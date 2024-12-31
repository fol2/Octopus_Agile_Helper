import Foundation

// All types are in the same module, so no need for additional imports
public class RatesRepository {
    public static let shared = RatesRepository()
    private var cachedRates: [RateEntity] = []
    private let urlSession = URLSession.shared
    
    public init() {}
    
    public func updateRates(force: Bool = false) async throws {
        // Fetch rates from Octopus API
        let url = URL(string: "https://api.octopus.energy/v1/products/AGILE-FLEX-22-11-25/electricity-tariffs/E-1R-AGILE-FLEX-22-11-25-H/standard-unit-rates/")!
        let (data, _) = try await urlSession.data(from: url)
        
        struct OctopusRate: Codable {
            let value_inc_vat: Double
            let valid_from: String
            let valid_to: String
        }
        
        struct OctopusRatesResponse: Codable {
            let results: [OctopusRate]
        }
        
        let response = try JSONDecoder().decode(OctopusRatesResponse.self, from: data)
        
        let dateFormatter = ISO8601DateFormatter()
        dateFormatter.formatOptions = [.withInternetDateTime]
        
        cachedRates = response.results.map { rate in
            RateEntity(
                validFrom: dateFormatter.date(from: rate.valid_from),
                validTo: dateFormatter.date(from: rate.valid_to),
                valueIncludingVAT: rate.value_inc_vat
            )
        }
    }
    
    public func fetchAllRates() async throws -> [RateEntity] {
        if cachedRates.isEmpty {
            try await updateRates()
        }
        return cachedRates
    }
    
    public func hasDataThroughExpectedEndUKTime() -> Bool {
        // Simplified check - just see if we have any rates
        return !cachedRates.isEmpty
    }
} 