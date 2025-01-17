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
    case invalidTariffCode
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
    public let direction: String?
    public let full_name: String
    public let display_name: String
    public let description: String
    public let is_variable: Bool?
    public let is_green: Bool?
    public let is_tracker: Bool?
    public let is_prepay: Bool?
    public let is_business: Bool?
    public let is_restricted: Bool?
    public let term: Int?
    public let available_from: Date?
    public let available_to: Date?
    public let brand: String?
    
    public let tariffs_active_at: Date?
    public let links: [OctopusLinkItem]?
    
    public let single_register_electricity_tariffs: [String: OctopusRegionData]?
    public let dual_register_electricity_tariffs: [String: OctopusRegionData]?
    public let single_register_gas_tariffs: [String: OctopusRegionData]?
    public let dual_register_gas_tariffs: [String: OctopusRegionData]?
    
    enum CodingKeys: String, CodingKey {
        case code
        case direction
        case full_name
        case display_name
        case description
        case is_variable
        case is_green
        case is_tracker
        case is_prepay
        case is_business
        case is_restricted
        case term
        case available_from
        case available_to
        case brand
        case tariffs_active_at
        case links
        case single_register_electricity_tariffs
        case dual_register_electricity_tariffs
        case single_register_gas_tariffs
        case dual_register_gas_tariffs
    }
}

/// Nested object containing direct info about the tariff in that region.
public struct OctopusRegionData: Decodable {
    public let direct_debit_monthly: OctopusTariffDefinition?
}

/// The "varying" or "direct_debit_monthly" object
public struct OctopusTariffDefinition: Decodable {
    public let code: String
    public let links: [OctopusLinkItem]?
    public let online_discount_exc_vat: Double?
    public let online_discount_inc_vat: Double?
    public let dual_fuel_discount_exc_vat: Double?
    public let dual_fuel_discount_inc_vat: Double?
    public let exit_fees_exc_vat: Double?
    public let exit_fees_inc_vat: Double?
    public let exit_fees_type: String?
}

/// Tariff Rate item returned by e.g. `GET .../standard-unit-rates/?page=1`.
/// This is also used for day_unit_rates, night_unit_rates, and (with different naming) Agile intervals.
public struct OctopusTariffRate: Decodable {
    public let value_exc_vat: Double
    public let value_inc_vat: Double
    public let valid_from: Date
    public let valid_to: Date
    public let payment_method: String?
}

/// Standing Charge item returned by e.g. `GET .../standing-charges/`.
public struct OctopusStandingCharge: Decodable {
    public let value_excluding_vat: Double
    public let value_including_vat: Double
    public let valid_from: Date
    public let valid_to: Date?
    
    enum CodingKeys: String, CodingKey {
        case value_excluding_vat = "value_exc_vat"
        case value_including_vat = "value_inc_vat"
        case valid_from
        case valid_to
    }
}

/// Response wrapper for paginated results.
public struct OctopusPagedResponse<T: Decodable>: Decodable {
    public let count: Int
    public let next: String?
    public let previous: String?
    public let results: [T]
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
    public let address_line_1: String?
    public let moved_in_at: String?
    public let postcode: String?
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
    /// Returns the full URL for a product
    /// e.g. "https://api.octopus.energy/v1/products/SILVER-24-12-31/"
    public func getProductURL(_ productCode: String) -> String {
        return "\(baseURL)/products/\(productCode)/"
    }

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

    /// Fetches tariff rates from a specific URL.
    public func fetchTariffRates(url: String) async throws -> (totalCount: Int, results: [OctopusTariffRate]) {
        print("🔍 Fetching tariff rates from URL: \(url)")
        guard let url = URL(string: url) else {
            print("❌ Invalid URL: \(url)")
            throw OctopusAPIError.invalidURL
        }
        
        let response: OctopusPagedResponse<OctopusTariffRate> = try await fetchDecodable(OctopusPagedResponse<OctopusTariffRate>.self, from: url)
        print("✅ Successfully fetched \(response.results.count) rates (Total available: \(response.count))")
        return (totalCount: response.count, results: response.results)
    }
    
    /// Dedicated function for fetching Agile rates with enhanced debugging
    /// - Parameters:
    ///   - productCode: Optional product code. If nil, will be derived from tariffCode
    ///   - tariffCode: Full tariff code (e.g. "E-1R-AGILE-24-04-03-H")
    public func fetchAgileRates(productCode: String? = nil, tariffCode: String) async throws -> [OctopusTariffRate] {
        print("\n🔄 Fetching Agile rates:")
        print("🏷️ Tariff Code: \(tariffCode)")
        
        // Determine product code
        let effectiveProductCode: String
        if let providedCode = productCode {
            effectiveProductCode = providedCode
            print("📦 Using provided Product Code: \(effectiveProductCode)")
        } else {
            // Extract product code from tariff code (e.g. "E-1R-AGILE-24-04-03-H" -> "AGILE-24-04-03")
            let parts = tariffCode.components(separatedBy: "-")
            guard parts.count >= 6 else {
                throw OctopusAPIError.invalidTariffCode
            }
            effectiveProductCode = parts[2...5].joined(separator: "-")
            print("📦 Derived Product Code: \(effectiveProductCode)")
        }
        
        // Construct the Agile rates URL
        let baseRatesURL = "\(baseURL)/products/\(effectiveProductCode)/electricity-tariffs/\(tariffCode)/standard-unit-rates/"
        print("🌐 Constructed URL: \(baseRatesURL)")
        
        // 1. Fetch first page to get total count and initial rates
        print("📥 Fetching first page to determine total records...")
        let firstPageResponse = try await fetchTariffRates(url: baseRatesURL)
        let totalRecords = firstPageResponse.totalCount
        print("📊 Total records available: \(totalRecords)")
        
        if totalRecords == 0 {
            print("❌ No Agile rates available")
            return []
        }
        
        // 2. Calculate total pages
        let recordsPerPage = 100 // Octopus API standard
        let totalPages = Int(ceil(Double(totalRecords) / Double(recordsPerPage)))
        print("📚 Total pages to fetch: \(totalPages)")
        
        // 3. Fetch remaining pages in parallel for efficiency
        print("📥 Starting parallel page fetches...")
        var allRates = firstPageResponse.results // Start with first page results
        
        if totalPages > 1 {
            // Use async let for concurrent fetches of remaining pages
            try await withThrowingTaskGroup(of: [OctopusTariffRate].self) { group in
                for page in 2...totalPages {
                    group.addTask {
                        let pageUrl = baseRatesURL + (baseRatesURL.contains("?") ? "&" : "?") + "page=\(page)"
                        print("📄 Fetching page \(page)/\(totalPages)")
                        let response = try await self.fetchTariffRates(url: pageUrl)
                        return response.results
                    }
                }
                
                // Collect results as they complete
                for try await pageRates in group {
                    allRates.append(contentsOf: pageRates)
                }
            }
        }
        
        // 4. Sort rates by valid_from to ensure chronological order
        allRates.sort { $0.valid_from > $1.valid_from }
        
        print("✅ Successfully fetched \(allRates.count) Agile rates")
        if let firstRate = allRates.first,
           let lastRate = allRates.last {
            print("📊 Rate Coverage:")
            print("   First rate valid from: \(firstRate.valid_from)")
            print("   Last rate valid to: \(lastRate.valid_to)")
        }
        
        return allRates
    }
    
    /// Fetches standing charges from a specific URL.
    public func fetchStandingCharges(url: String) async throws -> [OctopusStandingCharge] {
        guard let url = URL(string: url) else {
            throw OctopusAPIError.invalidURL
        }
        
        do {
            let response: OctopusPagedResponse<OctopusStandingCharge> = try await fetchDecodable(OctopusPagedResponse<OctopusStandingCharge>.self, from: url)
            print("📊 Standing Charges Response: count=\(response.results.count)")
            if let first = response.results.first {
                print("First charge: \(first.value_excluding_vat)p exc VAT, \(first.value_including_vat)p inc VAT, from \(first.valid_from) to \(first.valid_to ?? Date.distantPast)")
            }
            return response.results
        } catch {
            print("❌ Standing Charges Error: \(error)")
            throw error
        }
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
    
    /// Information about rate pages for AGILE products
    private struct RatesPageInfo {
        let totalCount: Int
        let recordsPerPage: Int = 100  // Octopus API standard
        let hoursPerPage: Int = 50     // Each page contains 50 hours (100 half-hour records)
        let firstRecordDate: Date      // From first result's valid_from
        
        var totalPages: Int {
            Int(ceil(Double(totalCount) / Double(recordsPerPage)))
        }
        
        /// Calculate which pages we need to fetch based on what's in CoreData
        func determinePagesToFetch(existingRates: [OctopusTariffRate]) -> [Int] {
            var pagesToFetch: [Int] = []
            
            // Create a set of dates we already have
            let existingDates = Set(existingRates.map { $0.valid_from })
            
            // For each page, check if we have all its dates
            for pageNum in 1...totalPages {
                let pageStartDate = Calendar.current.date(
                    byAdding: .hour,
                    value: -((pageNum - 1) * hoursPerPage),
                    to: firstRecordDate
                )!
                
                let pageEndDate = Calendar.current.date(
                    byAdding: .hour,
                    value: -(pageNum * hoursPerPage),
                    to: firstRecordDate
                )!
                
                // Generate expected dates for this page (every 30 minutes)
                var currentDate = pageStartDate
                var hasAllDates = true
                
                while currentDate > pageEndDate {
                    if !existingDates.contains(currentDate) {
                        hasAllDates = false
                        break
                    }
                    currentDate = Calendar.current.date(byAdding: .minute, value: -30, to: currentDate)!
                }
                
                if !hasAllDates {
                    pagesToFetch.append(pageNum)
                }
            }
            
            return pagesToFetch
        }
    }

    /// Fetches all rates from a given URL, handling pagination if needed
    public func fetchAllRatesPaginated(baseURL: String, isAgile: Bool = false) async throws -> [OctopusTariffRate] {
        print("🔄 Starting paginated rate fetch from \(baseURL)")
        
        // Fetch first page to get metadata
        guard let url = URL(string: baseURL) else {
            print("❌ Invalid URL: \(baseURL)")
            throw OctopusAPIError.invalidURL
        }
        
        let firstPageResponse = try await fetchDecodable(OctopusRatesResponse.self, from: url)
        var allRates = firstPageResponse.results
        
        if isAgile {
            // AGILE optimization: Only fetch pages we need
            guard let firstRate = firstPageResponse.results.first,
                  let totalCount = firstPageResponse.count else {
                return allRates
            }
            
            let pageInfo = RatesPageInfo(
                totalCount: totalCount,
                firstRecordDate: firstRate.valid_from
            )
            
            let pagesToFetch = pageInfo.determinePagesToFetch(existingRates: allRates)
            print("📊 Need to fetch \(pagesToFetch.count) pages out of \(pageInfo.totalPages) total pages")
            
            for pageNum in pagesToFetch where pageNum > 1 {  // Skip page 1 as we already have it
                let pageUrl = "\(baseURL)&page=\(pageNum)"
                guard let url = URL(string: pageUrl) else { continue }
                
                print("📥 Fetching AGILE rates page \(pageNum)")
                let response = try await fetchDecodable(OctopusRatesResponse.self, from: url)
                allRates.append(contentsOf: response.results)
            }
        } else {
            // Non-AGILE: Simple fetch all pages
            var nextURL = firstPageResponse.next
            
            while let next = nextURL {
                guard let url = URL(string: next) else { break }
                
                print("📥 Fetching rates page: \(next)")
                let response = try await fetchDecodable(OctopusRatesResponse.self, from: url)
                allRates.append(contentsOf: response.results)
                nextURL = response.next
            }
        }
        
        print("✅ Fetch complete, total rates: \(allRates.count)")
        return allRates
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
        let decoder = JSONDecoder()
        
        // Custom date decoding strategy that handles both ISO8601 and null values
        decoder.dateDecodingStrategy = .custom { decoder in
            let container = try decoder.singleValueContainer()
            if container.decodeNil() {
                return Date.distantPast // Return a default date for null values
            }
            
            let dateStr = try container.decode(String.self)
            
            // Try formatters in order of most to least precise
            let formatters = [
                { () -> ISO8601DateFormatter in
                    let formatter = ISO8601DateFormatter()
                    formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
                    return formatter
                }(),
                { () -> ISO8601DateFormatter in
                    let formatter = ISO8601DateFormatter()
                    formatter.formatOptions = [.withInternetDateTime]
                    return formatter
                }()
            ]
            
            for formatter in formatters {
                if let date = formatter.date(from: dateStr) {
                    return date
                }
            }
            
            throw DecodingError.dataCorruptedError(
                in: container,
                debugDescription: "Could not parse date string: \(dateStr)"
            )
        }
        
        do {
            let (data, response) = try await session.data(for: request)
            guard let httpResponse = response as? HTTPURLResponse,
                  httpResponse.statusCode == 200
            else {
                throw OctopusAPIError.invalidResponse
            }
            return try decoder.decode(T.self, from: data)
        } catch let urlError as URLError {
            throw OctopusAPIError.networkError(urlError)
        } catch let decodingError as DecodingError {
            throw OctopusAPIError.decodingError(decodingError)
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
    
    /// The "GET /...-unit-rates/" or "...standing-charges/" pagination wrapper
    private struct OctopusRatesResponse: Decodable {
        let count: Int?
        let next: String?
        let previous: String?
        let results: [OctopusTariffRate]
    }
}
