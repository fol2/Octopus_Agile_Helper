//
//  RatesRepository.swift
//  Octopus_Agile_Helper
//  Full Example (adjusted to avoid name collisions and missing extensions)
//
//  Description:
//    - Manages all electricity rates & standing charges in Core Data
//      via NSManagedObject for RateEntity, StandingChargeEntity.
//    - Preserves Agile logic: multi-page fetch, coverage checks, aggregator queries.
//
//  Principles:
//    - SOLID: One class controlling rate/standing-charge data
//    - KISS, DRY, YAGNI: Minimal duplication, straightforward upserts
//    - Fully scalable: can handle Agile or other product codes
//

import Combine
import CoreData
import Foundation
import SwiftUI

@MainActor
public final class RatesRepository: ObservableObject {
    // MARK: - Singleton
    public static let shared = RatesRepository()

    // MARK: - Published
    /// Local cache if your UI or logic needs quick reference
    @Published public private(set) var currentCachedRates: [NSManagedObject] = []

    // MARK: - Dependencies
    private let apiClient = OctopusAPIClient.shared
    private let context: NSManagedObjectContext
    @AppStorage("postcode") private var postcode: String = ""

    // Networking (for older agile logic if needed)
    private let urlSession: URLSession
    private let maxRetries = 3

    // MARK: - Init
    private init() {
        self.context = PersistenceController.shared.container.viewContext
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 30
        config.waitsForConnectivity = true
        self.urlSession = URLSession(configuration: config)
    }

    // MARK: - Public API

    /// Extracts a short code from a tariff code by removing 2 parts from front and 1 from end
    /// e.g. "E-1R-OE-FIX-14M-25-01-08-H" -> "OE-FIX-14M-25-01-08"
    private func productCodeFromTariff(_ tariffCode: String) -> String? {
        let parts = tariffCode.components(separatedBy: "-")
        // Need at least 4 parts (2 prefix + 1 main + 1 suffix)
        guard parts.count >= 4 else { return nil }

        // Remove first 2 parts and last part
        let productParts = parts[2...(parts.count - 2)]
        return productParts.joined(separator: "-")
    }

    /// New approach: we accept a tariffCode and use getBaseRateURL to construct the URL, with pagination support
    /// Now supports two-phase execution:
    /// 1) First phase quickly fetches page 1 for immediate UI update
    /// 2) Second phase performs smart pagination in the background
    @discardableResult
    public func fetchAndStoreRates(tariffCode: String) async throws -> (
        firstPhaseRates: [NSManagedObject], totalPages: Int
    ) {
        print("fetchAndStoreRates: 🔄 Starting rate update for tariff: \(tariffCode)")

        // 1. First ensure we have the product details
        guard let productCode = productCodeFromTariff(tariffCode) else {
            print("fetchAndStoreRates: ❌ Invalid tariff code format: \(tariffCode)")
            throw OctopusAPIError.invalidTariffCode
        }

        print("fetchAndStoreRates: 🔍 Ensuring product exists for code: \(productCode)")
        _ = try await ProductsRepository.shared.ensureProductExists(productCode: productCode)

        // Get base URL using our helper
        let url = try await getBaseRateURL(tariffCode: tariffCode)
        print("fetchAndStoreRates: 📡 Base URL for fetching rates: \(url)")

        // 1. Query local DB state
        let request = NSFetchRequest<NSManagedObject>(entityName: "RateEntity")
        request.predicate = NSPredicate(format: "tariff_code == %@", tariffCode)
        let localData = try await context.perform {
            try self.context.fetch(request)
        }
        let localMinDate = localData.compactMap { $0.value(forKey: "valid_from") as? Date }.min()
        let localMaxDate = localData.compactMap { $0.value(forKey: "valid_to") as? Date }.max()
        let localCount = localData.count

        print("fetchAndStoreRates: 📊 Local data state:")
        print("fetchAndStoreRates: 📝 Record count: \(localCount)")
        if let minDate = localMinDate {
            print("fetchAndStoreRates: 📅 Earliest rate: \(minDate.formatted())")
        }
        if let maxDate = localMaxDate {
            print("fetchAndStoreRates: 📅 Latest rate: \(maxDate.formatted())")
        }

        // 2. Get server's data range by fetching first page
        print("fetchAndStoreRates: 🔍 Fetching first page to determine server data range")
        let firstPageResponse = try await apiClient.fetchTariffRates(url: url)
        let totalRecordsOnServer = firstPageResponse.totalCount
        if totalRecordsOnServer == 0 {
            print("fetchAndStoreRates: ❌ No rates available on server")
            return ([], 0)
        }

        let recordsPerPage = 100  // Octopus API standard
        let totalPages = Int(ceil(Double(totalRecordsOnServer) / Double(recordsPerPage)))
        print("fetchAndStoreRates: 📊 Total pages available: \(totalPages)")

        // Get last page to determine full date range
        let lastPageUrl = url + (url.contains("?") ? "&" : "?") + "page=\(totalPages)"
        let lastPageResponse = try await apiClient.fetchTariffRates(url: lastPageUrl)

        guard let serverNewestRate = firstPageResponse.results.first,
            let serverOldestRate = lastPageResponse.results.last
        else {
            print("fetchAndStoreRates: ❌ Could not determine server data range")
            return ([], totalPages)
        }

        let serverNewestDate = serverNewestRate.valid_to ?? Date.distantFuture
        let serverOldestDate = serverOldestRate.valid_from

        print("fetchAndStoreRates: 📅 Server data range:")
        print("fetchAndStoreRates: 📅 Newest rate: \(serverNewestDate.formatted())")
        print("fetchAndStoreRates: 📅 Oldest rate: \(serverOldestDate.formatted())")

        // 3. Determine what data we need to fetch
        var needNewerData = localMaxDate == nil  // If no local max date, we need newer data
        var needOlderData =
            localMinDate == nil || serverOldestDate < (localMinDate ?? Date.distantFuture)

        print("fetchAndStoreRates: 🔍 Analyzing data requirements:")
        if localCount == 0 {
            print("fetchAndStoreRates: 📝 CoreData is empty - optimizing to forward-only pagination")
            needNewerData = true
            needOlderData = false
        } else {
            if needNewerData {
                print(
                    "fetchAndStoreRates: 📥 Need newer data: Server has newer rates until \(serverNewestDate.formatted())"
                )
            }
            if needOlderData {
                print(
                    "fetchAndStoreRates: 📥 Need older data: Server has older rates from \(serverOldestDate.formatted())"
                )
            }
            if !needNewerData && !needOlderData {
                print(
                    "fetchAndStoreRates: 🔍 Local data covers the entire server range, checking for gaps"
                )
                if let localMin = localMinDate {
                    // If localMaxDate is nil, it means we have an indefinite rate
                    // Use serverNewestDate as the end date for gap checking
                    if hasMissingRecords(from: localMin, to: serverNewestDate, localData: localData)
                    {
                        print(
                            "fetchAndStoreRates: 🕳️ Found gaps in local data, will fetch full range")
                        needNewerData = true
                        needOlderData = true
                    } else {
                        print("fetchAndStoreRates: ✅ No gaps found, data is complete")
                        return (localData, totalPages)
                    }
                }
            }
        }

        // Phase 1: Store first page results for immediate UI update
        print(
            "fetchAndStoreRates: 💾 Storing \(firstPageResponse.results.count) rates from first page"
        )
        try await upsertRates(firstPageResponse.results, tariffCode: tariffCode)

        // Read back the stored rates to return for phase 1
        let firstPhaseRates = try await context.perform {
            let req = NSFetchRequest<NSManagedObject>(entityName: "RateEntity")
            req.predicate = NSPredicate(format: "tariff_code == %@", tariffCode)
            req.sortDescriptors = [NSSortDescriptor(key: "valid_from", ascending: true)]
            return try self.context.fetch(req)
        }

        // Phase 2: Start background task for smart pagination
        backgroundFetchTask = Task.detached(priority: .utility) { [weak self] in
            guard let self = self else { return }
            do {
                print("fetchAndStoreRates: 🔄 Starting phase 2 (background) with smart pagination")

                // 4. Process newest data first (page 2 onwards) if needed
                if needNewerData {
                    print("fetchAndStoreRates: 📥 Fetching newer data (forward pagination)")
                    var currentPage = 2  // Start from page 2 since we already have page 1
                    var hasMore = true

                    while hasMore {
                        if currentPage > totalPages {
                            hasMore = false
                            break
                        }

                        let nextPageUrl =
                            url + (url.contains("?") ? "&" : "?") + "page=\(currentPage)"
                        let pageResponse = try await self.apiClient.fetchTariffRates(
                            url: nextPageUrl)

                        // Stop if we hit existing data
                        if let oldestInPage = pageResponse.results.last,
                            let localMax = localMaxDate,
                            let oldestValidTo = oldestInPage.valid_to,
                            oldestValidTo <= localMax
                        {
                            // Only store records newer than our local max
                            let newRecords = pageResponse.results.filter { rate in
                                if let validTo = rate.valid_to {
                                    return validTo > localMax
                                }
                                // If valid_to is nil (ongoing), include it
                                return true
                            }
                            print(
                                "fetchAndStoreRates: 📥 Found \(newRecords.count) new rates in page \(currentPage)"
                            )
                            if !newRecords.isEmpty {
                                try await self.upsertRates(newRecords, tariffCode: tariffCode)
                            }
                            hasMore = false
                            break
                        }

                        print(
                            "fetchAndStoreRates: 💾 Storing \(pageResponse.results.count) rates from page \(currentPage)"
                        )
                        try await self.upsertRates(pageResponse.results, tariffCode: tariffCode)
                        hasMore =
                            pageResponse.results.count == recordsPerPage && currentPage < totalPages
                        currentPage += 1
                    }
                    print("fetchAndStoreRates: ✅ Completed forward pagination")
                }

                // 5. Process older data if needed
                if needOlderData {
                    print("fetchAndStoreRates: 📥 Fetching older data (backward pagination)")
                    var currentPage = totalPages
                    var hasMore = true

                    while hasMore && currentPage > 1 {  // Start from last page, skip page 1
                        if currentPage == totalPages {
                            // We already have the last page response
                            print(
                                "fetchAndStoreRates: 💾 Storing \(lastPageResponse.results.count) rates from last page"
                            )
                            try await self.upsertRates(
                                lastPageResponse.results, tariffCode: tariffCode)
                        } else {
                            let pageUrl =
                                url + (url.contains("?") ? "&" : "?") + "page=\(currentPage)"
                            let pageResponse = try await self.apiClient.fetchTariffRates(
                                url: pageUrl)
                            print(
                                "fetchAndStoreRates: 💾 Storing \(pageResponse.results.count) rates from page \(currentPage)"
                            )
                            try await self.upsertRates(pageResponse.results, tariffCode: tariffCode)
                        }
                        currentPage -= 1
                        hasMore = currentPage > 1
                        print("fetchAndStoreRates: 📄 Moving to page \(currentPage)")
                    }
                    print("fetchAndStoreRates: ✅ Completed backward pagination")
                }

                // Final status
                let finalData = try await self.context.perform {
                    let req = NSFetchRequest<NSManagedObject>(entityName: "RateEntity")
                    req.predicate = NSPredicate(format: "tariff_code == %@", tariffCode)
                    return try self.context.fetch(req)
                }

                print("fetchAndStoreRates: ✅ Phase 2 complete")
                print("fetchAndStoreRates: 📊 Final record count: \(finalData.count)")

                // Get the date range of the data
                if let minDate = finalData.compactMap({ $0.value(forKey: "valid_from") as? Date })
                    .min()
                {
                    // For maxDate, if all valid_to dates are null, use "ongoing" in the log
                    let maxDates = finalData.compactMap({ $0.value(forKey: "valid_to") as? Date })
                    let maxDateStr =
                        maxDates.isEmpty ? "ongoing" : (maxDates.max()?.formatted() ?? "ongoing")
                    print(
                        "fetchAndStoreRates: 📅 Final date range: \(minDate.formatted()) to \(maxDateStr)"
                    )
                }
            } catch {
                print("fetchAndStoreRates: ❌ Error in phase 2: \(error)")
            }
        }

        return (firstPhaseRates, totalPages)
    }

    /// Calculate the expected number of half-hour records between two dates
    private func expectedRecordCount(from startDate: Date, to endDate: Date) -> Int {
        let timeInterval = endDate.timeIntervalSince(startDate)
        // Each record is 30 minutes (1800 seconds)
        return Int(ceil(timeInterval / 1800.0))
    }

    /// Check if we have any gaps in our local data between the given dates
    private func hasMissingRecords(
        from startDate: Date, to endDate: Date, localData: [NSManagedObject]
    ) -> Bool {
        let expected = expectedRecordCount(from: startDate, to: endDate)

        // Filter records within this date range
        let recordsInRange = localData.filter { record in
            guard let recordStart = record.value(forKey: "valid_from") as? Date else {
                return false
            }
            // For valid_to, if it's nil it means the rate is valid indefinitely
            if let recordEnd = record.value(forKey: "valid_to") as? Date {
                return recordStart >= startDate && recordEnd <= endDate
            } else {
                // If valid_to is nil, the rate is valid indefinitely
                return recordStart >= startDate
            }
        }

        print("Debug - Date range check:")
        print("Debug - Start: \(startDate.formatted())")
        print("Debug - End: \(endDate.formatted())")
        print("Debug - Expected records: \(expected)")
        print("Debug - Actual records: \(recordsInRange.count)")

        return recordsInRange.count < expected
    }

    /// Fetch and store standing charges
    public func fetchAndStoreStandingCharges(tariffCode: String, url: String) async throws {
        let charges = try await apiClient.fetchStandingCharges(url: url)
        try await upsertStandingCharges(charges, tariffCode: tariffCode)
    }

    /// Store standing charges in CoreData
    private func upsertStandingCharges(_ charges: [OctopusStandingCharge], tariffCode: String)
        async throws
    {
        try await context.perform {
            print("🔄 Upserting \(charges.count) standing charges for tariff \(tariffCode)")

            // Fetch only existing charges for this tariff code
            let request = NSFetchRequest<NSManagedObject>(entityName: "StandingChargeEntity")
            request.predicate = NSPredicate(format: "tariff_code == %@", tariffCode)
            let existingCharges = try self.context.fetch(request)
            print(
                "📦 Found \(existingCharges.count) existing standing charges for tariff \(tariffCode)"
            )

            // Create composite key map using both date and tariff code
            var mapByKey = [String: NSManagedObject]()
            for c in existingCharges {
                if let fromDate = c.value(forKey: "valid_from") as? Date,
                    let code = c.value(forKey: "tariff_code") as? String
                {
                    let key = "\(code)_\(fromDate.timeIntervalSince1970)"
                    mapByKey[key] = c
                }
            }

            for charge in charges {
                let validFrom = charge.valid_from
                let key = "\(tariffCode)_\(validFrom.timeIntervalSince1970)"

                if let found = mapByKey[key] {
                    // update
                    print("🔄 Updating standing charge for \(validFrom)")
                    if let validTo = charge.valid_to {
                        found.setValue(validTo, forKey: "valid_to")
                    } else {
                        found.setValue(nil, forKey: "valid_to")
                    }
                    found.setValue(charge.value_excluding_vat, forKey: "value_excluding_vat")
                    found.setValue(charge.value_including_vat, forKey: "value_including_vat")
                } else {
                    // insert
                    print("➕ Inserting new standing charge for \(validFrom)")
                    let newCharge = NSEntityDescription.insertNewObject(
                        forEntityName: "StandingChargeEntity", into: self.context)
                    newCharge.setValue(UUID().uuidString, forKey: "id")
                    newCharge.setValue(charge.valid_from, forKey: "valid_from")
                    if let validTo = charge.valid_to {
                        newCharge.setValue(validTo, forKey: "valid_to")
                    }
                    newCharge.setValue(charge.value_excluding_vat, forKey: "value_excluding_vat")
                    newCharge.setValue(charge.value_including_vat, forKey: "value_including_vat")
                    newCharge.setValue(tariffCode, forKey: "tariff_code")
                }
            }
            try self.context.save()
        }
    }

    /// Now we identify by `tariff_code`:
    private func upsertRates(_ rates: [OctopusTariffRate], tariffCode: String) async throws {
        try await context.perform {
            // Fetch only existing rates for this tariff code
            let request = NSFetchRequest<NSManagedObject>(entityName: "RateEntity")
            request.predicate = NSPredicate(format: "tariff_code == %@", tariffCode)
            let existingRates = try self.context.fetch(request)

            // Create composite key map using both date and tariff code
            var mapByKey = [String: NSManagedObject]()
            for r in existingRates {
                if let fromDate = r.value(forKey: "valid_from") as? Date,
                    let code = r.value(forKey: "tariff_code") as? String
                {
                    let key = "\(code)_\(fromDate.timeIntervalSince1970)"
                    mapByKey[key] = r
                }
            }

            for apiRate in rates {
                let validFrom = apiRate.valid_from
                let key = "\(tariffCode)_\(validFrom.timeIntervalSince1970)"

                // Use Date.distantFuture if valid_to is nil (ongoing rate)
                let validTo = apiRate.valid_to ?? Date.distantFuture

                if let found = mapByKey[key] {
                    // update existing rate
                    found.setValue(validTo, forKey: "valid_to")
                    found.setValue(apiRate.value_exc_vat, forKey: "value_excluding_vat")
                    found.setValue(apiRate.value_inc_vat, forKey: "value_including_vat")
                } else {
                    // insert new rate
                    let newRate = NSEntityDescription.insertNewObject(
                        forEntityName: "RateEntity", into: self.context)
                    newRate.setValue(UUID().uuidString, forKey: "id")
                    newRate.setValue(apiRate.valid_from, forKey: "valid_from")
                    newRate.setValue(validTo, forKey: "valid_to")
                    newRate.setValue(apiRate.value_exc_vat, forKey: "value_excluding_vat")
                    newRate.setValue(apiRate.value_inc_vat, forKey: "value_including_vat")
                    newRate.setValue(tariffCode, forKey: "tariff_code")
                }
            }
            try self.context.save()
        }
    }

    /// Example fetchAllRates returning NSManagedObject
    public func fetchAllRates() async throws -> [NSManagedObject] {
        try await context.perform {
            let req = NSFetchRequest<NSManagedObject>(entityName: "RateEntity")
            req.sortDescriptors = [NSSortDescriptor(key: "valid_from", ascending: true)]
            let list = try self.context.fetch(req)
            self.currentCachedRates = list
            return list
        }
    }

    /// Fetch all standing charges from CoreData
    public func fetchAllStandingCharges() async throws -> [NSManagedObject] {
        try await context.perform {
            let request = NSFetchRequest<NSManagedObject>(entityName: "StandingChargeEntity")
            request.sortDescriptors = [NSSortDescriptor(key: "valid_from", ascending: true)]
            return try self.context.fetch(request)
        }
    }

    /// Fetch rates from CoreData for a specific tariff code
    /// If pastHours is provided, only returns rates from past X hours plus all future rates
    public func fetchRatesByTariffCode(
        _ tariffCode: String,
        pastHours: Int? = nil
    ) async throws -> [NSManagedObject] {
        if let hours = pastHours {
            print(
                "fetchRatesByTariffCode: 📊 Starting fetch for tariff \(tariffCode), past hours: \(hours)"
            )
        } else {
            print("fetchRatesByTariffCode: 📊 Starting fetch for all rates of tariff \(tariffCode)")
        }

        return try await context.perform {
            let request = NSFetchRequest<NSManagedObject>(entityName: "RateEntity")
            let now = Date()

            if let hours = pastHours {
                let pastBoundary = now.addingTimeInterval(-Double(hours) * 3600)
                print("fetchRatesByTariffCode: 📅 Time window")
                print("   • Now: \(now.formatted())")
                print("   • Past boundary: \(pastBoundary.formatted())")

                request.predicate = NSCompoundPredicate(andPredicateWithSubpredicates: [
                    NSPredicate(format: "tariff_code == %@", tariffCode),
                    NSPredicate(format: "valid_from >= %@", pastBoundary as NSDate),
                ])
            } else {
                request.predicate = NSPredicate(format: "tariff_code == %@", tariffCode)
            }

            request.sortDescriptors = [NSSortDescriptor(key: "valid_from", ascending: true)]
            let list = try self.context.fetch(request)
            print("fetchRatesByTariffCode: ✅ Found \(list.count) rates")

            // Log first and last rate timestamps if available
            if let firstRate = list.first,
                let lastRate = list.last,
                let firstValidFrom = firstRate.value(forKey: "valid_from") as? Date,
                let lastValidFrom = lastRate.value(forKey: "valid_from") as? Date
            {
                print("   • First rate from: \(firstValidFrom.formatted())")
                print("   • Last rate from: \(lastValidFrom.formatted())")
            }

            return list
        }
    }

    /// Fetch standing charges from CoreData for a specific tariff code
    public func fetchStandingChargesByTariffCode(_ tariffCode: String) async throws
        -> [NSManagedObject]
    {
        try await context.perform {
            let request = NSFetchRequest<NSManagedObject>(entityName: "StandingChargeEntity")
            request.predicate = NSPredicate(format: "tariff_code == %@", tariffCode)
            request.sortDescriptors = [NSSortDescriptor(key: "valid_from", ascending: true)]
            let list = try self.context.fetch(request)
            return list
        }
    }

    /// Translates a tariff code to its base rate URL
    /// - Parameters:
    ///   - tariffCode: Full tariff code (e.g. "E-1R-AGILE-24-04-03-H")
    ///   - productCode: Optional product code. If nil, will be derived from tariffCode
    /// - Returns: Complete base URL for fetching rates
    /// - Throws: OctopusAPIError if tariff code is invalid
    private func getBaseRateURL(tariffCode: String, productCode: String? = nil) async throws
        -> String
    {
        // First try to get the link_rate from ProductDetailEntity
        let request = NSFetchRequest<NSManagedObject>(entityName: "ProductDetailEntity")

        // Extract region from tariff code (last character)
        guard let region = tariffCode.last.map(String.init) else {
            throw OctopusAPIError.invalidTariffCode
        }

        // Get product code either from parameter or by extracting from tariff code
        let effectiveProductCode: String
        if let providedCode = productCode {
            effectiveProductCode = providedCode
        } else {
            // Extract product code from tariff code
            guard let extractedCode = productCodeFromTariff(tariffCode) else {
                throw OctopusAPIError.invalidTariffCode
            }
            effectiveProductCode = extractedCode
        }

        // Find all product details for this product code and region
        request.predicate = NSCompoundPredicate(andPredicateWithSubpredicates: [
            NSPredicate(format: "code == %@", effectiveProductCode),
            NSPredicate(format: "region == %@", region),
        ])
        // Sort by tariff_code to ensure consistent selection
        request.sortDescriptors = [NSSortDescriptor(key: "tariff_code", ascending: true)]

        let details = try await context.perform {
            try self.context.fetch(request)
        }

        print(
            "getBaseRateURL: 🔍 Found \(details.count) product details for code \(effectiveProductCode) in region \(region)"
        )

        // If we found stored details, use the first one's link_rate
        if let detail = details.first,
            let link = detail.value(forKey: "link_rate") as? String,
            !link.isEmpty
        {
            let actualTariffCode = detail.value(forKey: "tariff_code") as? String ?? tariffCode
            print(
                "getBaseRateURL: 🔗 Using stored link_rate for tariff \(actualTariffCode): \(link)")
            return link
        }

        print(
            "getBaseRateURL: ⚠️ No stored link_rate found, falling back to manual URL construction")

        // Construct the rates URL using OctopusAPIClient's base URL
        let url =
            "\(apiClient.apiBaseURL)/products/\(effectiveProductCode)/electricity-tariffs/\(tariffCode)/standard-unit-rates/"
        print("getBaseRateURL: 🔧 Manually constructed URL: \(url)")
        return url
    }

    private var backgroundFetchTask: Task<Void, Error>?

    /// Wait for any ongoing background fetch to complete
    public func waitForBackgroundFetch() async throws {
        if let task = backgroundFetchTask {
            try await task.value
        }
    }

    /// Get the latest standing charge values for a tariff code
    /// Returns a tuple of (excluding VAT, including VAT) values, or nil if no standing charge found
    public func getLatestStandingCharge(tariffCode: String) async throws -> (
        excVAT: Double, incVAT: Double
    )? {
        let charges = try await fetchStandingChargesByTariffCode(tariffCode)

        // Find the most recent standing charge
        let latestCharge = charges.max { a, b in
            let aDate = a.value(forKey: "valid_from") as? Date ?? .distantPast
            let bDate = b.value(forKey: "valid_from") as? Date ?? .distantPast
            return aDate < bDate
        }

        // Extract the values if found
        if let charge = latestCharge,
            let excVAT = charge.value(forKey: "value_excluding_vat") as? Double,
            let incVAT = charge.value(forKey: "value_including_vat") as? Double
        {
            return (excVAT: excVAT, incVAT: incVAT)
        }

        return nil
    }
}
