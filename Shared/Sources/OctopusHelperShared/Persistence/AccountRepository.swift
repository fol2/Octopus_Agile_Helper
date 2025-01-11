import Foundation
import Combine
import SwiftUI

public final class AccountRepository: ObservableObject {
    public static let shared = AccountRepository()

    private let apiClient = OctopusAPIClient.shared
    private let globalSettings = GlobalSettingsManager() // or pass in init

    private init() {}

    /// Fetch account JSON, store in GlobalSettings, parse MPRN/MPAN
    public func fetchAndStoreAccount(accountNumber: String, apiKey: String) async throws {
        let accountData = try await apiClient.fetchAccountData(accountNumber: accountNumber, apiKey: apiKey)

        // 1) Convert to raw JSON for safe-keeping (if desired)
        let rawData = try JSONEncoder().encode(accountData)
        globalSettings.settings.accountData = rawData
        globalSettings.settings.accountNumber = accountNumber

        // 2) For simplicity, parse the first property + first electricity_meter_points
        if let firstProperty = accountData.properties.first,
           let elecPoints = firstProperty.electricity_meter_points?.first,
           let firstMeter = elecPoints.meters?.first {

            // store them in settings
            globalSettings.settings.electricityMPAN = elecPoints.mpan
            globalSettings.settings.electricityMeterSerialNumber = firstMeter.serial_number
        }

        // 3) (Optional) Register user's actual tariffs in ProductEntity
        // if you want to parse agreements
        // e.g. for agreement in elecPoints.agreements: parse code -> call ProductsRepository
        // 
        // For each property:
        //   for mp in property.electricity_meter_points ?? [] { ... }
        //   for agreement in mp.agreements ?? [] { ... parse product code ... }
    }
}
