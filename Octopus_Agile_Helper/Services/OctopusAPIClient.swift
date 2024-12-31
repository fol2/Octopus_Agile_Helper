//
//  OctopusAPIClient.swift
//

import Foundation

// MARK: - If not declared elsewhere, include your Error enum here:
enum OctopusAPIError: Error {
    case invalidURL
    case invalidResponse
    case networkError(Error)
    case decodingError(Error)
    case invalidAPIKey
}

// MARK: - Reference your existing models (do NOT redefine them here):
/*
 // In RateModel.swift you might have:
 struct OctopusRatesResponse: Codable {
     let count: Int?
     let next: String?
     let previous: String?
     let results: [OctopusRate]
 }

 struct OctopusRate: Codable {
     let value_exc_vat: Double
     let value_inc_vat: Double
     let valid_from: Date
     let valid_to: Date
 }
*/

// MARK: - The Client
class OctopusAPIClient {
    
    // Singleton
    static let shared = OctopusAPIClient()
    
    // Base URL
    private let baseURL = "https://api.octopus.energy/v1"
    
    // URLSession
    private let session: URLSession
    
    // Local static cache for last known Agile product metadata
    private static var cachedAgileFullName: String? = nil
    private static var cachedAgileDescription: String? = nil
    
    // Private init
    private init() {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 30
        self.session = URLSession(configuration: config)
    }
    
    // ----------------------------------------------------------
    // (A) EXISTING METHOD (Unchanged Signature):
    //     fetchRates(regionID:) -> [OctopusRate]
    //
    // Under the hood, we now dynamically find the latest Agile
    // product's tariff link, then fetch the rates.
    // ----------------------------------------------------------
    func fetchRates(regionID: String) async throws -> [OctopusRate] {
        do {
            // 1) Determine the region-based rates link + product metadata
            let (ratesURL, fullName, description) = try await getAgileRatesURLAndMetadata(regionID: regionID)
            
            // 2) Cache the product name & description
            Self.cachedAgileFullName = fullName
            Self.cachedAgileDescription = description
            
            // 3) Fetch the actual rates
            return try await fetchRatesFromDynamicURL(ratesURL)
            
        } catch {
            // Rethrow for the caller to handle
            throw error
        }
    }
    
    // ----------------------------------------------------------
    // (B) NEW METHOD:
    //     fetchAgileRegionInfo(regionID:) -> (regionCode, fullName, description)
    //
    // Returns the direct_debit_monthly.code (e.g. "E-1R-AGILE-24-10-01-H")
    // for the requested region, plus the tariff’s full name & description.
    //
    // If you only need product-level info (no region-specific code),
    // see also (C) fetchAgileProductMetadata().
    // ----------------------------------------------------------
    func fetchAgileRegionInfo(regionID: String) async throws -> (regionCode: String, fullName: String, description: String) {
        // 1) Get the single product detail & relevant region struct
        let (regionCode, fullName, description) = try await getAgileRegionCodeAndMetadata(regionID: regionID)
        
        // 2) Cache the product name & description
        Self.cachedAgileFullName = fullName
        Self.cachedAgileDescription = description
        
        // 3) Return them
        return (regionCode, fullName, description)
    }
    
    // ----------------------------------------------------------
    // (C) OPTIONAL METHOD:
    //     fetchAgileProductMetadata() -> (fullName, description)
    //
    // If you only want product-level data without region-specific code.
    // ----------------------------------------------------------
    func fetchAgileProductMetadata() async throws -> (fullName: String, description: String) {
        do {
            // Use skipRatesLink = true to avoid region scanning
            let (_, fullName, description) = try await getAgileRatesURLAndMetadata(
                regionID: "H",
                skipRatesLink: true
            )
            
            // Cache
            Self.cachedAgileFullName = fullName
            Self.cachedAgileDescription = description
            
            return (fullName, description)
        } catch {
            throw error
        }
    }
    
    // ----------------------------------------------------------
    // (D) OPTIONAL METHOD:
    //     getCachedAgileMetadata() -> (fullName, description)?
    //
    // Retrieve last known Agile product metadata without hitting
    // the network (if previously cached).
    // ----------------------------------------------------------
    func getCachedAgileMetadata() -> (fullName: String, description: String)? {
        guard
            let name = Self.cachedAgileFullName,
            let desc = Self.cachedAgileDescription
        else {
            return nil
        }
        return (name, desc)
    }
    
    // =================================================================
    // ==================== INTERNAL / PRIVATE HELPERS ==================
    // =================================================================
    
    // This function fully resolves the region-based "standard_unit_rates" URL,
    // plus the product's fullName & description.
    private func getAgileRatesURLAndMetadata(
        regionID: String,
        skipRatesLink: Bool = false
    ) async throws -> (ratesURL: String, fullName: String, description: String) {
        
        // 1) fetch the product list
        let products = try await fetchAllProducts()
        
        // 2) find the Agile product
        guard let agileProduct = findAgileProduct(in: products) else {
            throw OctopusAPIError.invalidResponse
        }
        
        // 3) get single product detail
        let detail = try await fetchSingleProductDetail(by: agileProduct)
        
        let productFullName = agileProduct.full_name
        let productDescription = agileProduct.description
        
        // if skipRatesLink, return empty for the ratesURL
        if skipRatesLink {
            return ("", productFullName, productDescription)
        }
        
        // 4) find region-based link
        guard let region = detail.single_register_electricity_tariffs?["_" + regionID] else {
            throw OctopusAPIError.invalidResponse
        }
        guard let ratesLink = region.direct_debit_monthly.links.first(where: { $0.rel == "standard_unit_rates" })?.href else {
            throw OctopusAPIError.invalidResponse
        }
        
        return (ratesLink, productFullName, productDescription)
    }
    
    // This private helper finds the region's direct_debit_monthly.code,
    // plus the fullName & description from the product.
    private func getAgileRegionCodeAndMetadata(
        regionID: String
    ) async throws -> (regionCode: String, fullName: String, description: String) {
        
        // 1) fetch products
        let products = try await fetchAllProducts()
        
        // 2) find agile
        guard let agileProduct = findAgileProduct(in: products) else {
            throw OctopusAPIError.invalidResponse
        }
        
        // 3) fetch detail
        let detail = try await fetchSingleProductDetail(by: agileProduct)
        
        // 4) get region object
        guard let region = detail.single_register_electricity_tariffs?["_" + regionID] else {
            throw OctopusAPIError.invalidResponse
        }
        
        // region code
        let regionCode = region.direct_debit_monthly.code
        
        return (
            regionCode,
            agileProduct.full_name,
            agileProduct.description
        )
    }
    
    // ----------------------------------------------------------------
    // fetchAllProducts() -> [OctopusProductItem]
    // ----------------------------------------------------------------
    private func fetchAllProducts() async throws -> [OctopusProductItem] {
        guard let url = URL(string: "\(baseURL)/products/") else {
            throw OctopusAPIError.invalidURL
        }
        
        let (data, response) = try await session.data(for: URLRequest(url: url))
        
        guard let httpResponse = response as? HTTPURLResponse,
              (200...299).contains(httpResponse.statusCode) else {
            throw OctopusAPIError.invalidResponse
        }
        
        let decoder = JSONDecoder()
        let result = try decoder.decode(OctopusProductListResponse.self, from: data)
        return result.results
    }
    
    // ----------------------------------------------------------------
    // findAgileProduct(in:) - picks the first "AGILE-" IMPORT product
    // ----------------------------------------------------------------
    private func findAgileProduct(in products: [OctopusProductItem]) -> OctopusProductItem? {
        return products.first {
            $0.code.uppercased().hasPrefix("AGILE-") &&
            $0.direction.uppercased() == "IMPORT"
        }
    }
    
    // ----------------------------------------------------------------
    // fetchSingleProductDetail(by:)
    // ----------------------------------------------------------------
    private func fetchSingleProductDetail(by product: OctopusProductItem) async throws -> OctopusSingleProductDetail {
        // get the product detail link (rel == "self")
        guard let link = product.links.first(where: { $0.rel == "self" })?.href,
              let url = URL(string: link) else {
            throw OctopusAPIError.invalidURL
        }
        
        let (data, response) = try await session.data(for: URLRequest(url: url))
        
        guard let httpResponse = response as? HTTPURLResponse,
              (200...299).contains(httpResponse.statusCode) else {
            throw OctopusAPIError.invalidResponse
        }
        
        let decoder = JSONDecoder()
        return try decoder.decode(OctopusSingleProductDetail.self, from: data)
    }
    
    // ----------------------------------------------------------------
    // fetchRatesFromDynamicURL(_:)
    //   Similar to your original fetch logic, but uses a dynamic URL
    // ----------------------------------------------------------------
    private func fetchRatesFromDynamicURL(_ urlString: String) async throws -> [OctopusRate] {
        guard let url = URL(string: urlString) else {
            throw OctopusAPIError.invalidURL
        }
        
        let (data, response) = try await session.data(for: URLRequest(url: url))
        
        guard let httpResponse = response as? HTTPURLResponse,
              (200...299).contains(httpResponse.statusCode) else {
            throw OctopusAPIError.invalidResponse
        }
        
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        
        let ratesResponse = try decoder.decode(OctopusRatesResponse.self, from: data)
        return ratesResponse.results
    }
}

// =====================================================================
// MARK: - PRIVATE data models for product listing & single product
//   Prefixed with "Octopus" to avoid collisions
// =====================================================================
private struct OctopusProductListResponse: Decodable {
    let count: Int
    let next: String?
    let previous: String?
    let results: [OctopusProductItem]
}

private struct OctopusProductItem: Decodable {
    let code: String
    let direction: String
    let full_name: String
    let display_name: String
    let description: String
    let links: [OctopusLinkItem]
}

private struct OctopusLinkItem: Decodable {
    let href: String
    let method: String
    let rel: String
}

private struct OctopusSingleProductDetail: Decodable {
    let code: String
    let full_name: String
    let display_name: String
    let description: String
    // region "dictionary" like "_A", "_B", etc.
    let single_register_electricity_tariffs: [String: OctopusRegion]?
}

private struct OctopusRegion: Decodable {
    let direct_debit_monthly: OctopusDirectDebitMonthly
}

private struct OctopusDirectDebitMonthly: Decodable {
    let code: String
    let links: [OctopusLinkItem]
}