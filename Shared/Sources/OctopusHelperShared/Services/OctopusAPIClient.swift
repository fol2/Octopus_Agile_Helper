//
//  OctopusAPIClient.swift
//  Example of consolidated, future-proof client
//
//  IMPORTANT:
//    - Retains existing consumption API calls WITHOUT modifications
//    - Adds new product & tariff fetch logic
//    - Leaves all Core Data or repository storage outside this file
//

import Foundation

// MARK: - Public Error Types
public enum OctopusAPIError: Error {
    case invalidURL
    case invalidResponse
    case networkError(Error)
    case decodingError(Error)
    case invalidAPIKey
}

// MARK: - Public Models
// (You can place them here or in separate Swift files, as you prefer.)

/// Minimal product list item returned by `GET /products/`.
public struct OctopusProductItem: Decodable {
    public let code: String
    public let direction: String
    public let full_name: String
    public let display_name: String
    public let description: String
    public let is_variable: Bool
    public let is_green: Bool
    public let is_tracker: Bool
    public let is_prepay: Bool
    public let is_business: Bool
    public let is_restricted: Bool
    public let term: Int?
    public let available_from: Date?
    public let available_to: Date?
    public let links: [OctopusLinkItem]
    public let brand: String?
}

/// A link item, e.g. `{"href": "...", "method": "GET", "rel": "standard_unit_rates"}`
public struct OctopusLinkItem: Decodable {
    public let href: String
    public let method: String
    public let rel: String
}

/// Full product detail returned by `GET /products/<code>/`.
public struct OctopusSingleProductDetail: Decodable {
    public let code: String
    public let full_name: String
    public let display_name: String
    public let description: String

    // These dictionaries map region strings (e.g. "_H") to some structured object.
    // We decode them if we need them to discover links for day/night/standard-unit-rates, etc.
    public let single_register_electricity_tariffs: [String: OctopusRegionData]?
    public let dual_register_electricity_tariffs: [String: OctopusRegionData]?
    public let single_register_gas_tariffs: [String: OctopusRegionData]?
    public let dual_register_gas_tariffs: [String: OctopusRegionData]?

    public let brand: String?
}

/// Nested object containing direct info about the tariff in that region.
public struct OctopusRegionData: Decodable {
    // Depending on the product, you might see "varying", "direct_debit_monthly", etc.
    // We'll parse them generically or skip if we only want the links array.
    // Example:
    //  {
    //    "varying": { "code": "E-1R-VAR-22-11-01-A", ... },
    //    "links": [
    //      { "href": ".../standard-unit-rates/", "rel": "standard_unit_rates" },
    //      { "href": ".../standing-charges/", "rel": "standing_charges" }
    //    ]
    //  }
    public let varying: OctopusTariffDefinition?
    public let direct_debit_monthly: OctopusTariffDefinition? // If needed
}

/// The "varying" or "direct_debit_monthly" object
public struct OctopusTariffDefinition: Decodable {
    public let code: String
    public let links: [OctopusLinkItem]?
}

/// Tariff Rate item returned by e.g. `GET .../standard-unit-rates/?page=1`.
/// This is also used for day_unit_rates, night_unit_rates, and (with different naming) Agile intervals.
public struct OctopusTariffRate: Decodable {
    public let value_exc_vat: Double
    public let value_inc_vat: Double
    public let valid_from: Date
    public let valid_to: Date?
    public let payment_method: String?
}

// For "standing-charges/", the JSON schema is nearly identical: "value_exc_vat", "value_inc_vat", "valid_from", "valid_to", "payment_method".
// We can decode them with the same `OctopusTariffRate` struct.

// MARK: - Consumption Models (Unchanged from your current code)
public struct OctopusConsumptionResponse: Codable {
    public let count: Int
    public let next: String?
    public let previous: String?
    public let results: [ConsumptionRecord]
}

public struct ConsumptionRecord: Codable {
    public let consumption: Double
    public let interval_start: Date
    public let interval_end: Date
}

// MARK: - Account Models
/// Account-level response structures (sketch)
public struct OctopusAccountResponse: Codable {
    public let number: String
    public let properties: [OctopusProperty]
}

public struct OctopusProperty: Codable {
    public let id: Int
    public let electricity_meter_points: [OctopusElectricityMP]?
    public let gas_meter_points: [OctopusGasMP]?
    // plus fields like address_line_1, moved_in_at, etc.
}

public struct OctopusElectricityMP: Codable {
    public let mpan: String
    public let meters: [OctopusElecMeter]?
    public let agreements: [OctopusAgreement]?
}

public struct OctopusElecMeter: Codable {
    public let serial_number: String
}

public struct OctopusAgreement: Codable {
    public let tariff_code: String
    public let valid_from: String?
    public let valid_to: String?
}

public struct OctopusGasMP: Codable {
    public let mprn: String
    public let meters: [OctopusGasMeter]?
    public let agreements: [OctopusAgreement]?
}

public struct OctopusGasMeter: Codable {
    public let serial_number: String
}

// MARK: - Client
public final class OctopusAPIClient {
    // MARK: Singleton
    public static let shared = OctopusAPIClient()

    // MARK: - Internal Config
    private let baseURL = "https://api.octopus.energy/v1"
    private let session: URLSession

    // MARK: - Init
    private init() {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 30
        config.waitsForConnectivity = true
        self.session = URLSession(configuration: config)
    }
}

// MARK: - Public API (Consumption) - Unchanged
extension OctopusAPIClient {
    /// Fetch consumption data for a given meter/MPAN.
    /// This is your existing consumption call, left intact.
    public func fetchConsumptionData(
        mpan: String,
        serialNumber: String,
        apiKey: String,
        page: Int = 1
    ) async throws -> OctopusConsumptionResponse {
        guard !mpan.isEmpty, !serialNumber.isEmpty, !apiKey.isEmpty else {
            throw OctopusAPIError.invalidAPIKey
        }

        let urlString = "\(baseURL)/electricity-meter-points/\(mpan)/meters/\(serialNumber)/consumption/?page=\(page)"
        guard let url = URL(string: urlString) else {
            throw OctopusAPIError.invalidURL
        }

        var request = URLRequest(url: url)
        let authString = "\(apiKey):"
        let authData = authString.data(using: .utf8)!.base64EncodedString()
        request.setValue("Basic \(authData)", forHTTPHeaderField: "Authorization")

        return try await fetchDecodable(OctopusConsumptionResponse.self, from: request)
    }
}

// MARK: - Public API (Products & Tariffs)
extension OctopusAPIClient {
    /// Fetches the full list of products from Octopus.
    /// If you omit `brand`, it returns everything;
    /// if you pass brand="OCTOPUS_ENERGY", you get that brand only.
    public func fetchAllProducts(brand: String? = nil) async throws -> [OctopusProductItem] {
        var urlString = "\(baseURL)/products/"
        if let b = brand, !b.isEmpty {
            urlString += "?brand=\(b)"
        }
        guard let url = URL(string: urlString) else {
            throw OctopusAPIError.invalidURL
        }

        let productListResponse = try await fetchDecodable(OctopusProductListResponse.self, from: url)
        return productListResponse.results
    }

    /// Fetch detailed info about a single product (code).
    /// e.g. GET /products/AGILE-24-10-01/
    public func fetchSingleProductDetail(_ productCode: String) async throws -> OctopusSingleProductDetail {
        let urlString = "\(baseURL)/products/\(productCode)/"
        guard let url = URL(string: urlString) else {
            throw OctopusAPIError.invalidURL
        }
        return try await fetchDecodable(OctopusSingleProductDetail.self, from: url)
    }

    /// Fetch all rates (standard, day, night, Agile intervals) from a given endpoint,
    /// typically the "href" for "standard_unit_rates", "day_unit_rates", or "night_unit_rates".
    /// - Parameter url: A fully qualified URL string from the product detail links
    /// - Returns: An array of `OctopusTariffRate` (possibly spanning multiple pages).
    public func fetchTariffRates(url: String) async throws -> [OctopusTariffRate] {
        // We need to handle pagination if the JSON includes "count", "next", "previous".
        // We'll do a loop until "next" == nil.
        var allResults: [OctopusTariffRate] = []
        var nextURLString: String? = url

        while let nextURL = nextURLString {
            guard let realURL = URL(string: nextURL) else {
                throw OctopusAPIError.invalidURL
            }
            let pageResponse = try await fetchDecodable(OctopusTariffRatesPageResponse.self, from: realURL)
            allResults.append(contentsOf: pageResponse.results)
            nextURLString = pageResponse.next
        }
        return allResults
    }

    /// A convenience to fetch standing charges from its link
    /// (in practice, the same shape as Tariff Rates).
    public func fetchStandingCharges(url: String) async throws -> [OctopusTariffRate] {
        // The "standing-charges" endpoint returns the same structure:
        // { count, next, previous, results[...] } with "value_exc_vat", etc.
        // So we can reuse the same approach as fetchTariffRates.
        return try await fetchTariffRates(url: url)
    }

    /// Fetch the user's account data by account number.
    public func fetchAccountData(accountNumber: String, apiKey: String) async throws -> OctopusAccountResponse {
        guard !accountNumber.isEmpty, !apiKey.isEmpty else {
            throw OctopusAPIError.invalidAPIKey
        }
        let urlString = "\(baseURL)/accounts/\(accountNumber)/"
        guard let url = URL(string: urlString) else {
            throw OctopusAPIError.invalidURL
        }

        var request = URLRequest(url: url)
        let authString = "\(apiKey):"
        let authData = authString.data(using: .utf8)!.base64EncodedString()
        request.setValue("Basic \(authData)", forHTTPHeaderField: "Authorization")

        return try await fetchDecodable(OctopusAccountResponse.self, from: request)
    }
}

// MARK: - Private Helpers
extension OctopusAPIClient {
    /// Generic method to fetch any Decodable from an endpoint.
    private func fetchDecodable<T: Decodable>(_ type: T.Type, from url: URL) async throws -> T {
        try await fetchDecodable(type, from: URLRequest(url: url))
    }

    /// Overload for fetchDecodable with a custom URLRequest (auth headers, etc.).
    private func fetchDecodable<T: Decodable>(_ type: T.Type, from request: URLRequest) async throws -> T {
        do {
            let (data, response) = try await session.data(for: request)
            guard let httpResponse = response as? HTTPURLResponse,
                  (200...299).contains(httpResponse.statusCode)
            else {
                throw OctopusAPIError.invalidResponse
            }
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601  // works for most Octopus date formats
            return try decoder.decode(T.self, from: data)
        } catch let urlError as URLError {
            throw OctopusAPIError.networkError(urlError)
        } catch let decodeError as DecodingError {
            throw OctopusAPIError.decodingError(decodeError)
        } catch {
            throw OctopusAPIError.networkError(error)
        }
    }
}

// MARK: - Private Data Models for Pagination
extension OctopusAPIClient {
    /// The "GET /products/" list response
    private struct OctopusProductListResponse: Decodable {
        let count: Int
        let next: String?
        let previous: String?
        let results: [OctopusProductItem]
    }

    /// The "GET /...-unit-rates/" or "...standing-charges/" pagination wrapper
    private struct OctopusTariffRatesPageResponse: Decodable {
        let count: Int?
        let next: String?
        let previous: String?
        let results: [OctopusTariffRate]
    }
}
