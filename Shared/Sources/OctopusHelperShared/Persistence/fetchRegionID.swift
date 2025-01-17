//
//  fetchRegionID.swift
//  OctopusHelperShared
//
//  Created by James To on 07/01/2025.
//
import Combine
import CoreData
import Foundation
import SwiftUI

extension RatesRepository {
    /// Attempts to fetch the user's electricity region from the provided postcode.
    /// - Parameter postcode: The user's postcode. Fallback to `'H'` if empty or invalid.
    /// - Returns: A region ID string like "H" or "L".
    /// - Throws: Network or decoding errors. Retries on `.cancelled` up to `maxRetries`.
    public func fetchRegionID(for postcode: String, retryCount: Int = 0) async throws -> String? {
        // Clean the postcode: trim whitespace, remove all spaces, convert to uppercase
        let cleanedPostcode = postcode
            .trimmingCharacters(in: .whitespacesAndNewlines)  // Trim leading/trailing whitespace
            .replacingOccurrences(of: " ", with: "")  // Remove all spaces
            .uppercased()  // Convert to uppercase
        
        guard !cleanedPostcode.isEmpty else { return "H" }

        // MARK: - Networking
        let maxRetries = 3
        let urlSession = URLSession.shared
        
        let encoded = cleanedPostcode.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed)
        guard let encodedPostcode = encoded,
              let url = URL(string: "https://api.octopus.energy/v1/industry/grid-supply-points/?postcode=\(encodedPostcode)")
        else { return "H" }

        do {
            let (data, response) = try await urlSession.data(for: URLRequest(url: url))
            guard let httpResponse = response as? HTTPURLResponse,
                  (200...299).contains(httpResponse.statusCode)
            else {
                // If not successful, fallback to 'H'
                return "H"
            }

            let supplyPoints = try JSONDecoder().decode(SupplyPointsResponse.self, from: data)
            if let first = supplyPoints.results.first {
                // Strip underscores from group_id => region
                let region = first.group_id.replacingOccurrences(of: "_", with: "")
                return region
            }
            return "H"

        } catch let urlError as URLError where urlError.code == .cancelled {
            if retryCount < maxRetries {
                // Simple exponential-ish backoff
                try await Task.sleep(nanoseconds: UInt64(1_000_000_000 * (retryCount + 1)))
                return try await fetchRegionID(for: cleanedPostcode, retryCount: retryCount + 1)
            }
            return "H"
        } catch {
            return "H"
        }
    }
}

// MARK: - SupplyPointsResponse (Region lookup)
fileprivate struct SupplyPointsResponse: Codable {
    let count: Int
    let results: [SupplyPoint]
}

fileprivate struct SupplyPoint: Codable {
    let group_id: String
}
