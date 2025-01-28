import CoreData
import Foundation
import SwiftUI

public final class ProductDetailRepository: ObservableObject {
    public static let shared = ProductDetailRepository()

    // Cache implementation
    private let detailCache: NSCache<NSString, NSArray> = {
        let cache = NSCache<NSString, NSArray>()
        cache.countLimit = 100  // Limit cache to 100 entries
        return cache
    }()

    private let context: NSManagedObjectContext
    private let apiClient = OctopusAPIClient.shared

    private init() {
        context = PersistenceController.shared.container.viewContext
    }

    /// Fetch detail from API, parse, store into ProductDetailEntity
    @discardableResult
    public func fetchAndStoreProductDetail(productCode: String) async throws -> [NSManagedObject] {
        print("fetchAndStoreProductDetail: 🔄 开始获取产品详情，产品代码: \(productCode)...")
        let detailData = try await apiClient.fetchSingleProductDetail(productCode)
        print("fetchAndStoreProductDetail: ✅ API返回产品详情数据成功")
        return try await upsertProductDetail(json: detailData, code: productCode)
    }

    /// Load local detail rows for a given code
    public func loadLocalProductDetail(code: String) async throws -> [NSManagedObject] {
        // Check cache first
        if let cached = detailCache.object(forKey: "code_\(code)" as NSString) as? [NSManagedObject]
        {
            return cached
        }

        print("loadLocalProductDetail: 🔍 Loading local product detail for code: \(code)")
        let results = try await context.perform {
            let request = NSFetchRequest<NSManagedObject>(entityName: "ProductDetailEntity")
            request.predicate = NSPredicate(format: "code == %@", code)
            let details = try self.context.fetch(request)
            // Cache the results
            self.detailCache.setObject(details as NSArray, forKey: "code_\(code)" as NSString)
            print("loadLocalProductDetail: 📊 Found \(details.count) product details")

            return details
        }
        return results
    }

    public func loadLocalProductDetailByTariffCode(tariffCode: String) async throws
        -> [NSManagedObject]
    {
        // Check cache first
        if let cached = detailCache.object(forKey: tariffCode as NSString) as? [NSManagedObject] {
            return cached
        }

        let results = try await context.perform {
            let req = NSFetchRequest<NSManagedObject>(entityName: "ProductDetailEntity")
            req.predicate = NSPredicate(format: "tariff_code == %@", tariffCode)
            let results = try self.context.fetch(req)
            // Cache the results
            self.detailCache.setObject(results as NSArray, forKey: tariffCode as NSString)
            return results
        }
        return results
    }

    /// Fetch all local product details
    /// (Renamed for clarity; same functionality)
    public func fetchAllLocalProductDetails() async throws -> [NSManagedObject] {
        try await context.perform {
            let req = NSFetchRequest<NSManagedObject>(entityName: "ProductDetailEntity")
            // Sort by code to ensure consistent order
            req.sortDescriptors = [NSSortDescriptor(key: "code", ascending: true)]
            return try self.context.fetch(req)
        }
    }

    /// Fetch all tariff codes for a given product code
    public func fetchTariffCodes(for productCode: String) async throws -> [String] {
        print("🔍 Fetching tariff codes for product: \(productCode)")
        return try await context.perform {
            let request = NSFetchRequest<NSManagedObject>(entityName: "ProductDetailEntity")
            request.predicate = NSPredicate(format: "code == %@", productCode)
            let details = try self.context.fetch(request)
            print("📦 Found \(details.count) product details")

            // Debug: Print all details
            for detail in details {
                if let tariffCode = detail.value(forKey: "tariff_code") as? String,
                    let code = detail.value(forKey: "code") as? String
                {
                    print("Found detail - code: \(code), tariff_code: \(tariffCode)")
                }
            }

            let codes = details.compactMap { $0.value(forKey: "tariff_code") as? String }
            print("🏷 Extracted tariff codes: \(codes)")
            return codes
        }
    }

    /// Upserts a product detail JSON response into Core Data
    /// - Parameters:
    ///   - json: The decoded JSON response from the API
    ///   - code: Product code (e.g. "AGILE-FLEX-22-11-25")
    /// - Returns: Array of upserted NSManagedObject (ProductDetailEntity)
    @discardableResult
    public func upsertProductDetail(json: OctopusSingleProductDetail, code: String) async throws
        -> [NSManagedObject]
    {
        // Clear cache for this code
        detailCache.removeObject(forKey: "code_\(code)" as NSString)

        print("📝 开始更新/插入产品详情数据...")
        var newDetails: [NSManagedObject] = []
        var totalTariffs = 0

        // Process single register electricity tariffs
        if let singleElec = json.single_register_electricity_tariffs {
            print("⚡️ 处理单一电表电费...")
            let rows = try await processTariffType(
                tariffType: "single_register_electricity_tariffs",
                dictionary: singleElec,
                code: code,
                activeAt: json.tariffs_active_at
            )
            newDetails.append(contentsOf: rows)
            totalTariffs += rows.count
            print("📊 单一电表电费数量: \(rows.count)")
        }

        // Process dual register electricity tariffs
        if let dualElec = json.dual_register_electricity_tariffs {
            print("⚡️ 处理双电表电费...")
            let rows = try await processTariffType(
                tariffType: "dual_register_electricity_tariffs",
                dictionary: dualElec,
                code: code,
                activeAt: json.tariffs_active_at
            )
            newDetails.append(contentsOf: rows)
            totalTariffs += rows.count
            print("📊 双电表电费数量: \(rows.count)")
        }

        // Process single register gas tariffs
        if let singleGas = json.single_register_gas_tariffs {
            print("🔥 处理单一燃气费...")
            let rows = try await processTariffType(
                tariffType: "single_register_gas_tariffs",
                dictionary: singleGas,
                code: code,
                activeAt: json.tariffs_active_at
            )
            newDetails.append(contentsOf: rows)
            totalTariffs += rows.count
            print("📊 单一燃气费数量: \(rows.count)")
        }

        // Process dual register gas tariffs
        if let dualGas = json.dual_register_gas_tariffs {
            print("🔥 处理双燃气费...")
            let rows = try await processTariffType(
                tariffType: "dual_register_gas_tariffs",
                dictionary: dualGas,
                code: code,
                activeAt: json.tariffs_active_at
            )
            newDetails.append(contentsOf: rows)
            totalTariffs += rows.count
            print("📊 双燃气费数量: \(rows.count)")
        }

        // Save once at the end
        try await context.perform {
            try self.context.save()
            print("💾 成功保存到Core Data")
            print("✅ 最终保存的费率详情数量: \(totalTariffs)")

            // Update cache for new/modified tariff codes
            for detail in newDetails {
                if let tariffCode = detail.value(forKey: "tariff_code") as? String {
                    self.detailCache.setObject([detail] as NSArray, forKey: tariffCode as NSString)
                }
            }
        }
        return newDetails
    }

    /// Example method to flatten a dictionary like ["_A": RegionData, "_B": ...]
    private func processTariffType(
        tariffType: String,
        dictionary: [String: OctopusRegionData],
        code: String,
        activeAt: Date?
    ) async throws -> [NSManagedObject] {
        var results: [NSManagedObject] = []
        try await context.perform {
            for (rawRegion, regionData) in dictionary {
                let region = String(rawRegion.dropFirst())  // drop underscore

                // Possibly each region can have multiple payment keys
                // e.g. regionData.direct_debit_monthly, regionData.varying, etc.
                if let dd = regionData.direct_debit_monthly {
                    let entity = self.buildOrUpdateEntity(
                        code: code,
                        tariffType: tariffType,
                        region: region,
                        payment: "direct_debit_monthly",
                        defn: dd,
                        activeAt: activeAt
                    )
                    results.append(entity)
                }
                // if there's "varying", do similarly
            }
        }
        return results
    }

    /// Helper to create/update a single ProductDetailEntity row
    private func buildOrUpdateEntity(
        code: String,
        tariffType: String,
        region: String,
        payment: String,
        defn: OctopusTariffDefinition,
        activeAt: Date?
    ) -> NSManagedObject {
        print("\n🔨 Building/Updating Product Detail Entity:")
        print("📦 Product Code: \(code)")
        print("🏷️ Tariff Code from API: \(defn.code)")
        print("🌍 Region: \(region)")
        print("💳 Payment: \(payment)")

        // Unique constraint: code + tariffType + region + payment (or just tariff_code)
        // Suppose we fetch existing by tariff_code, if it's unique
        let tariffCode = defn.code  // e.g. "E-1R-SILVER-24-12-31-A"
        let fetchReq = NSFetchRequest<NSManagedObject>(entityName: "ProductDetailEntity")
        fetchReq.predicate = NSPredicate(format: "tariff_code == %@", tariffCode)

        let existing = (try? context.fetch(fetchReq)) ?? []
        if !existing.isEmpty {
            print("🔄 Found existing entity with tariff code: \(tariffCode)")
        } else {
            print("➕ Creating new entity with tariff code: \(tariffCode)")
        }

        let detailEntity =
            existing.first
            ?? NSEntityDescription.insertNewObject(
                forEntityName: "ProductDetailEntity", into: context)

        // Store the values
        detailEntity.setValue(code, forKey: "code")
        detailEntity.setValue(activeAt ?? Date(), forKey: "tariffs_active_at")
        detailEntity.setValue(tariffType, forKey: "tariff_type")
        detailEntity.setValue(region, forKey: "region")
        detailEntity.setValue(payment, forKey: "payment")
        detailEntity.setValue(tariffCode, forKey: "tariff_code")

        // Store links if available
        if let links = defn.links {
            for link in links {
                if link.href.contains("standard-unit-rates") {
                    print("🔗 Found rate link: \(link.href)")
                    detailEntity.setValue(link.href, forKey: "link_rate")
                } else if link.href.contains("standing-charges") {
                    print("🔗 Found standing charge link: \(link.href)")
                    detailEntity.setValue(link.href, forKey: "link_standing_charge")
                }
            }
        }

        return detailEntity
    }

    /// Find a tariff code for a given product code and region
    /// - Parameters:
    ///   - productCode: The product code to search for (e.g. "AGILE-24-04-03")
    ///   - region: The region code (e.g. "A", "B", "C")
    /// - Returns: The matching tariff code if found, nil otherwise
    public func findTariffCode(productCode: String, region: String) async throws -> String? {
        print("findTariffCode: 🔍 Finding tariff code for:")
        print("findTariffCode: 📦 Product Code: \(productCode)")
        print("findTariffCode: 🌍 Region: \(region)")

        // Load all details for this product
        let details = try await loadLocalProductDetail(code: productCode)
        print("findTariffCode: 📊 Found \(details.count) product details")

        // Filter by region
        let matchingDetails = details.filter { detail in
            let detailRegion = detail.value(forKey: "region") as? String
            return detailRegion == region.uppercased()
        }

        print("findTariffCode: 🎯 Found \(matchingDetails.count) details matching region \(region)")

        // Sort matching details by tariff_code and get the first one
        let sortedDetails = matchingDetails.sorted { detail1, detail2 in
            let code1 = detail1.value(forKey: "tariff_code") as? String ?? ""
            let code2 = detail2.value(forKey: "tariff_code") as? String ?? ""
            return code1 < code2
        }

        let tariffCode = sortedDetails.first?.value(forKey: "tariff_code") as? String
        if let code = tariffCode {
            print("findTariffCode: ✅ Found matching tariff code: \(code)")
        } else {
            print("findTariffCode: ❌ No matching tariff code found")
        }

        return tariffCode
    }
}
