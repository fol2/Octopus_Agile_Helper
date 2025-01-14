import Combine
import Foundation
import SwiftUI

public final class AccountRepository: ObservableObject {
    public static let shared = AccountRepository()

    private let apiClient = OctopusAPIClient.shared
    private let productsRepo = ProductsRepository.shared
    private let productDetailRepo = ProductDetailRepository.shared

    private init() {}

    /// Fetch account JSON, store in GlobalSettings, parse MPRN/MPAN
    public func fetchAndStoreAccount(
        accountNumber: String, apiKey: String, globalSettings: GlobalSettingsManager
    ) async throws {
        print("🔄 Starting account fetch and store...")
        let accountData = try await apiClient.fetchAccountData(
            accountNumber: accountNumber, apiKey: apiKey)
        print("✅ Account data fetched from API")
        print("📊 Properties count: \(accountData.properties.count)")
        if let firstProperty = accountData.properties.first {
            print("📊 First property details:")
            print("  - ID: \(firstProperty.id)")
            print("  - Address: \(firstProperty.address_line_1 ?? "N/A")")
            print("  - Postcode: \(firstProperty.postcode ?? "N/A")")
            print("  - Moved in at: \(firstProperty.moved_in_at ?? "N/A")")
        }

        // 1) Convert to raw JSON for safe-keeping (if desired)
        let rawData = try JSONEncoder().encode(accountData)
        print("✅ Account data encoded successfully")

        // Ensure we're on the main thread for UserDefaults updates
        await MainActor.run {
            print("💾 Storing account data in settings...")
            globalSettings.settings.accountData = rawData
            globalSettings.settings.accountNumber = accountNumber
            
            // Store postcode if available from first property
            if let firstProperty = accountData.properties.first,
               let postcode = firstProperty.postcode {
                print("📍 Found postcode: \(postcode)")
                globalSettings.settings.regionInput = postcode
                print("📍 Updated regionInput to: \(globalSettings.settings.regionInput)")
                
                // Lookup region code from postcode
                Task {
                    do {
                        let region = try await self.lookupPostcodeRegion(postcode: postcode)
                        print("🌍 Found region code: \(region)")
                        await MainActor.run {
                            globalSettings.settings.regionInput = region
                            print("🌍 Updated regionInput to region code: \(region)")
                        }
                    } catch {
                        print("⚠️ Failed to lookup region code: \(error)")
                    }
                }
            } else {
                print("⚠️ No postcode found in account data")
            }
            
            print("✅ Account data stored in settings")
            print("📊 Account data size: \(rawData.count) bytes")
        }

        // 2) For simplicity, parse the first property + first electricity_meter_points
        if let firstProperty = accountData.properties.first,
            let elecPoints = firstProperty.electricity_meter_points?.first,
            let firstMeter = elecPoints.meters?.first
        {
            // store them in settings on main thread
            await MainActor.run {
                globalSettings.settings.electricityMPAN = elecPoints.mpan
                globalSettings.settings.electricityMeterSerialNumber = firstMeter.serial_number
            }
        }

        // 3) Process all properties and their meter points to store products
        for property in accountData.properties {
            // Handle electricity meter points
            if let electricityPoints = property.electricity_meter_points {
                for point in electricityPoints {
                    if let agreements = point.agreements {
                        for agreement in agreements {
                            // Extract product code from tariff code (e.g. "E-1R-AGILE-24-04-03-H" -> "AGILE-24-04-03")
                            if let productCode = extractProductCode(from: agreement.tariff_code) {
                                // Ensure the product exists in our database
                                try await productsRepo.ensureProductExists(productCode: productCode)
                            }
                        }
                    }
                }
            }
        }
    }

    /// Extracts the product code from a tariff code
    /// e.g. "E-1R-AGILE-24-04-03-H" -> "AGILE-24-04-03"
    private func extractProductCode(from tariffCode: String) -> String? {
        let parts = tariffCode.components(separatedBy: "-")
        guard parts.count >= 6 else { return nil }

        // For AGILE products: parts[2] would be "AGILE", parts[3,4,5] would be "24", "04", "03"
        return parts[2...5].joined(separator: "-")  // e.g. "AGILE-24-04-03"
    }

    private func lookupPostcodeRegion(postcode: String) async throws -> String {
        let cleanedPostcode = postcode.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanedPostcode.isEmpty else { return "H" }
        
        let encoded = cleanedPostcode.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed)
        guard let encodedPostcode = encoded,
            let url = URL(
                string:
                    "https://api.octopus.energy/v1/industry/grid-supply-points/?postcode=\(encodedPostcode)"
            )
        else { return "H" }
        
        let urlSession = URLSession.shared
        let (data, response) = try await urlSession.data(for: URLRequest(url: url))
        guard let httpResponse = response as? HTTPURLResponse,
              (200...299).contains(httpResponse.statusCode)
        else {
            return "H"
        }
        
        struct SupplyPointsResponse: Codable {
            let count: Int
            let results: [SupplyPoint]
        }
        
        struct SupplyPoint: Codable {
            let group_id: String
        }
        
        let supplyPoints = try JSONDecoder().decode(SupplyPointsResponse.self, from: data)
        if supplyPoints.count == 0 {
            return "H"  // Default to H if no supply points found
        }
        if let first = supplyPoints.results.first {
            let region = first.group_id.replacingOccurrences(of: "_", with: "")
            return region
        }
        return "H"
    }
}
