import Combine
import Foundation
import SwiftUI

public protocol AccountRepositoryDelegate: AnyObject {
    func accountRepository(_ repository: AccountRepository, didFindProductCodes codes: Set<String>)
}

public final class AccountRepository: ObservableObject {
    public static let shared = AccountRepository()

    private let apiClient = OctopusAPIClient.shared
    private let productsRepo = ProductsRepository.shared
    private let productDetailRepo = ProductDetailRepository.shared
    private let ratesRepo = RatesRepository.shared
    public weak var delegate: AccountRepositoryDelegate?

    private init() {}

    /// Fetch account JSON, store in GlobalSettings, parse MPRN/MPAN
    public func fetchAndStoreAccount(
        accountNumber: String, apiKey: String, globalSettings: GlobalSettingsManager
    ) async throws {
        print("fetchAndStoreAccount: 🔄 Starting account fetch and store...")
        let accountData = try await apiClient.fetchAccountData(
            accountNumber: accountNumber, apiKey: apiKey)
        print("fetchAndStoreAccount: ✅ Account data fetched from API")
        print("fetchAndStoreAccount: 📊 Properties count: \(accountData.properties.count)")
        if let firstProperty = accountData.properties.first {
            print("fetchAndStoreAccount: 📊 First property details:")
            print("  - ID: \(firstProperty.id)")
            print("  - Address: \(firstProperty.address_line_1 ?? "N/A")")
            print("  - Postcode: \(firstProperty.postcode ?? "N/A")")
            print("  - Moved in at: \(firstProperty.moved_in_at ?? "N/A")")

            // Debug electricity meter points
            if let elecPoints = firstProperty.electricity_meter_points {
                print("  - Found \(elecPoints.count) electricity meter points")
                for (index, point) in elecPoints.enumerated() {
                    print("    Point \(index + 1):")
                    print("    - MPAN: \(point.mpan)")
                    if let meters = point.meters {
                        print("    - Found \(meters.count) meters")
                        for (mIndex, meter) in meters.enumerated() {
                            print("      Meter \(mIndex + 1) Serial: \(meter.serial_number)")
                        }
                    } else {
                        print("    - No meters found")
                    }
                }
            } else {
                print("  - No electricity meter points found")
            }
        }

        // 1) Convert to raw JSON for safe-keeping (if desired)
        let rawData = try JSONEncoder().encode(accountData)
        print("fetchAndStoreAccount: ✅ Account data encoded successfully")

        // Ensure we're on the main thread for UserDefaults updates
        await MainActor.run {
            print("fetchAndStoreAccount: 💾 Storing account data in settings...")
            globalSettings.settings.accountData = rawData
            globalSettings.settings.accountNumber = accountNumber
            globalSettings.settings.apiKey = apiKey  // Store API key
            print("fetchAndStoreAccount: 🔑 Stored API key in settings")

            // Store postcode if available from first property
            if let firstProperty = accountData.properties.first,
                let postcode = firstProperty.postcode
            {
                print("fetchAndStoreAccount: 📍 Found postcode: \(postcode)")
                globalSettings.settings.regionInput = postcode
                print(
                    "fetchAndStoreAccount: 📍 Updated regionInput to: \(globalSettings.settings.regionInput)"
                )

                // Lookup region code from postcode
                Task {
                    do {
                        let region = try await ratesRepo.fetchRegionID(for: postcode) ?? "H"
                        print("fetchAndStoreAccount: 🌍 Found region code: \(region)")
                        await MainActor.run {
                            globalSettings.settings.regionInput = region
                            print(
                                "fetchAndStoreAccount: 🌍 Updated regionInput to region code: \(region)"
                            )
                        }
                    } catch {
                        print("fetchAndStoreAccount: ⚠️ Failed to lookup region code: \(error)")
                    }
                }
            } else {
                print("fetchAndStoreAccount: ⚠️ No postcode found in account data")
            }

            print("fetchAndStoreAccount: ✅ Account data stored in settings")
            print("fetchAndStoreAccount: 📊 Account data size: \(rawData.count) bytes")
        }

        // 2) For simplicity, parse the first property + first electricity_meter_points
        if let firstProperty = accountData.properties.first {
            if let elecPoints = firstProperty.electricity_meter_points?.first {
                print(
                    "fetchAndStoreAccount: ⚡️ Found electricity meter point with MPAN: \(elecPoints.mpan)"
                )

                if let firstMeter = elecPoints.meters?.first {
                    print(
                        "fetchAndStoreAccount: 📟 Found meter with serial number: \(firstMeter.serial_number)"
                    )

                    // Store them in settings on main thread
                    await MainActor.run {
                        globalSettings.settings.electricityMPAN = elecPoints.mpan
                        globalSettings.settings.electricityMeterSerialNumber =
                            firstMeter.serial_number
                        print(
                            "fetchAndStoreAccount: ✅ Stored MPAN and meter serial number in settings"
                        )
                        print("  - MPAN: \(elecPoints.mpan)")
                        print("  - Serial: \(firstMeter.serial_number)")
                    }
                } else {
                    print("fetchAndStoreAccount: ⚠️ No meter found for electricity point")
                    throw OctopusAPIError.invalidResponse
                }
            } else {
                print("fetchAndStoreAccount: ⚠️ No electricity meter points found")
                throw OctopusAPIError.invalidResponse
            }
        } else {
            print("fetchAndStoreAccount: ⚠️ No properties found in account data")
            throw OctopusAPIError.invalidResponse
        }

        // 3) Process all properties and their meter points to store products
        var activeAgileCode: String? = nil
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

                                // If this is an active Agile agreement, store its code
                                if agreement.tariff_code.contains("AGILE") {
                                    let now = Date()
                                    let dateFormatter = ISO8601DateFormatter()
                                    dateFormatter.formatOptions = [
                                        .withInternetDateTime, .withFractionalSeconds,
                                    ]

                                    let isActive =
                                        (agreement.valid_from == nil
                                            || (dateFormatter.date(from: agreement.valid_from!)
                                                ?? .distantFuture) <= now)
                                        && (agreement.valid_to == nil
                                            || (dateFormatter.date(from: agreement.valid_to!)
                                                ?? .distantPast) >= now)

                                    if isActive {
                                        activeAgileCode = productCode
                                    }
                                }
                            }
                        }
                    }
                }
            }
        }

        // Notify delegate of the active Agile code if found
        if let code = activeAgileCode {
            await MainActor.run {
                self.delegate?.accountRepository(self, didFindProductCodes: Set([code]))
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
}
