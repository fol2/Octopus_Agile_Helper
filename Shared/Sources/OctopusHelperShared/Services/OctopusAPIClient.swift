//
//  OctopusAPIClient.swift
//  Refactored & Cleaned
//
//  iOS 17+
//

import Foundation

// MARK: - OctopusAPI Error Types
public enum OctopusAPIError: Error {
    case invalidURL
    case invalidResponse
    case networkError(Error)
    case decodingError(Error)
    case invalidAPIKey
}

// MARK: - Public Models Referenced By Callers
// (Definition of OctopusRate, OctopusRatesResponse, etc. must be available elsewhere.)
// Here we assume they're declared in RateModel.swift or a similar file.
//
// e.g.:
// public struct OctopusRatesResponse: Codable {
//     public let results: [OctopusRate]
// }
//
// public struct OctopusRate: Codable, Identifiable {
//     public let id = UUID()
//     public let valid_from: Date
//     public let valid_to: Date
//     public let value_exc_vat: Double
//     public let value_inc_vat: Double
// }
//
// Additional references:
// - OctopusProductListResponse, OctopusProductItem, etc.
//   For completeness, they're inlined below.
//   If you already have them in separate files, remove the duplicates.

// MARK: - Public Client Class
public final class OctopusAPIClient {
    
    // MARK: - Singleton
    public static let shared = OctopusAPIClient()
    
    // MARK: - Public Methods
    /// Fetches region-based Agile rates.
    /// - Parameter regionID: A single-character region code, e.g. "H".
    /// - Returns: Array of `OctopusRate`.
    /// - Throws: Network or decoding errors.
    public func fetchRates(regionID: String) async throws -> [OctopusRate] {
        let (url, fullName, description) = try await resolveAgileRatesURLAndMetadata(regionID: regionID)
        cacheAgileMetadata(fullName: fullName, description: description)
        return try await downloadRates(from: url)
    }

    /// Fetch region-based product code, plus overall product metadata.
    /// - Parameter regionID: Region code, e.g. "H".
    /// - Returns: (regionCode, fullName, description).
    /// - Throws: Network or decoding errors.
    public func fetchAgileRegionInfo(
        regionID: String
    ) async throws -> (regionCode: String, fullName: String, description: String) {
        
        let (regionCode, fullName, description) = try await resolveAgileRegionCodeAndMetadata(regionID: regionID)
        cacheAgileMetadata(fullName: fullName, description: description)
        return (regionCode, fullName, description)
    }

    /// Fetches product-level metadata (for the main Agile product), ignoring region specifics.
    /// - Returns: (fullName, description).
    /// - Throws: Network or decoding errors.
    public func fetchAgileProductMetadata() async throws -> (fullName: String, description: String) {
        let (_, fullName, description) = try await resolveAgileRatesURLAndMetadata(
            regionID: "H",
            skipRatesLink: true
        )
        cacheAgileMetadata(fullName: fullName, description: description)
        return (fullName, description)
    }

    /// Returns any cached Agile product name & description previously retrieved.
    /// - Returns: Optional `(fullName, description)` if available.
    public func getCachedAgileMetadata() -> (fullName: String, description: String)? {
        guard
            let name = Self.cachedAgileFullName,
            let desc = Self.cachedAgileDescription
        else {
            return nil
        }
        return (name, desc)
    }
    
    // MARK: - Private / Internal
    private let baseURL = "https://api.octopus.energy/v1"
    private let session: URLSession
    
    // Locally cached metadata to satisfy getCachedAgileMetadata()
    private static var cachedAgileFullName: String?
    private static var cachedAgileDescription: String?

    // MARK: - Init
    /// Private init to enforce singleton usage.
    private init() {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 30
        self.session = URLSession(configuration: config)
    }
}

// MARK: - Internal Logic
extension OctopusAPIClient {
    
    /// Caches the Agile product's name and description in static vars.
    private func cacheAgileMetadata(fullName: String, description: String) {
        Self.cachedAgileFullName = fullName
        Self.cachedAgileDescription = description
    }
    
    /// Downloads rates from a fully resolved URL returning `[OctopusRate]`.
    private func downloadRates(from urlString: String) async throws -> [OctopusRate] {
        guard let url = URL(string: urlString) else {
            throw OctopusAPIError.invalidURL
        }
        return try await fetchDecodable(OctopusRatesResponse.self, from: url).results
    }
    
    /// Generic method to fetch any `Decodable` from an endpoint.
    private func fetchDecodable<T: Decodable>(_ type: T.Type, from url: URL) async throws -> T {
        do {
            let (data, response) = try await session.data(for: URLRequest(url: url))
            
            guard let httpResponse = response as? HTTPURLResponse,
                  (200...299).contains(httpResponse.statusCode)
            else {
                throw OctopusAPIError.invalidResponse
            }
            
            return try JSONDecoder().decode(T.self, from: data)
        } catch let urlError as URLError {
            throw OctopusAPIError.networkError(urlError)
        } catch let decodeError as DecodingError {
            throw OctopusAPIError.decodingError(decodeError)
        } catch {
            throw OctopusAPIError.networkError(error)
        }
    }

    /// Resolves the region-based "standard_unit_rates" URL plus product name & description.
    /// If `skipRatesLink` is true, it returns an empty string for ratesURL.
    private func resolveAgileRatesURLAndMetadata(
        regionID: String,
        skipRatesLink: Bool = false
    ) async throws -> (ratesURL: String, fullName: String, description: String) {
        
        let products = try await fetchAllProducts()
        guard let agileProduct = findAgileProduct(in: products) else {
            throw OctopusAPIError.invalidResponse
        }
        
        let detail = try await fetchSingleProductDetail(for: agileProduct)
        let productFullName = agileProduct.full_name
        let productDescription = agileProduct.description
        
        if skipRatesLink {
            return ("", productFullName, productDescription)
        }
        
        // Find region-based link
        guard
            let regionObject = detail.single_register_electricity_tariffs?["_" + regionID],
            let standardRatesLink = regionObject.direct_debit_monthly.links.first(where: { $0.rel == "standard_unit_rates" })?.href
        else {
            throw OctopusAPIError.invalidResponse
        }
        
        return (standardRatesLink, productFullName, productDescription)
    }
    
    /// Returns the direct_debit_monthly.code for the given region plus product metadata.
    private func resolveAgileRegionCodeAndMetadata(
        regionID: String
    ) async throws -> (regionCode: String, fullName: String, description: String) {
        
        let products = try await fetchAllProducts()
        guard let agileProduct = findAgileProduct(in: products) else {
            throw OctopusAPIError.invalidResponse
        }
        
        let detail = try await fetchSingleProductDetail(for: agileProduct)
        guard let regionObj = detail.single_register_electricity_tariffs?["_" + regionID] else {
            throw OctopusAPIError.invalidResponse
        }
        
        let code = regionObj.direct_debit_monthly.code
        return (code, agileProduct.full_name, agileProduct.description)
    }
    
    /// Fetches a minimal list of known Octopus products.
    private func fetchAllProducts() async throws -> [OctopusProductItem] {
        guard let url = URL(string: "\(baseURL)/products/") else {
            throw OctopusAPIError.invalidURL
        }
        let listResponse = try await fetchDecodable(OctopusProductListResponse.self, from: url)
        return listResponse.results
    }
    
    /// Finds the first "AGILE-" product with direction == "IMPORT".
    private func findAgileProduct(in products: [OctopusProductItem]) -> OctopusProductItem? {
        products.first {
            $0.code.uppercased().hasPrefix("AGILE-") && $0.direction.uppercased() == "IMPORT"
        }
    }
    
    /// Fetches details for a given Octopus product item (via the "self" link).
    private func fetchSingleProductDetail(
        for product: OctopusProductItem
    ) async throws -> OctopusSingleProductDetail {
        
        guard let selfLink = product.links.first(where: { $0.rel == "self" })?.href,
              let url = URL(string: selfLink)
        else {
            throw OctopusAPIError.invalidURL
        }
        
        return try await fetchDecodable(OctopusSingleProductDetail.self, from: url)
    }
}

// MARK: - Private Data Models
// If you already have these in a separate file, you can remove this block.
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
    let single_register_electricity_tariffs: [String: OctopusRegion]?
}

private struct OctopusRegion: Decodable {
    let direct_debit_monthly: OctopusDirectDebitMonthly
}

private struct OctopusDirectDebitMonthly: Decodable {
    let code: String
    let links: [OctopusLinkItem]
}
