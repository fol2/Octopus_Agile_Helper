import CoreData
import Foundation
import SwiftUI

public final class ProductDetailRepository: ObservableObject {
    public static let shared = ProductDetailRepository()

    private let context: NSManagedObjectContext
    private let apiClient = OctopusAPIClient.shared

    private init() {
        context = PersistenceController.shared.container.viewContext
    }

    /// Fetch detail from API, parse, store into ProductDetailEntity
    @discardableResult
    public func fetchAndStoreProductDetail(productCode: String) async throws -> [NSManagedObject] {
        print("🔄 开始获取产品详情，产品代码: \(productCode)...")
        let detailData = try await apiClient.fetchSingleProductDetail(productCode)
        print("✅ API返回产品详情数据成功")
        return try await upsertProductDetail(json: detailData, code: productCode)
    }

    /// Load local detail rows for a given code
    public func loadLocalProductDetail(code: String) async throws -> [NSManagedObject] {
        try await context.perform {
            let req = NSFetchRequest<NSManagedObject>(entityName: "ProductDetailEntity")
            req.predicate = NSPredicate(format: "code == %@", code)
            return try self.context.fetch(req)
        }
    }
    
    public func loadLocalProductDetailByTariffCode(tariffCode: String) async throws -> [NSManagedObject] {
        try await context.perform {
            let req = NSFetchRequest<NSManagedObject>(entityName: "ProductDetailEntity")
            req.predicate = NSPredicate(format: "tariff_code == %@", tariffCode)
            return try self.context.fetch(req)
        }
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
                   let code = detail.value(forKey: "code") as? String {
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
    public func upsertProductDetail(json: OctopusSingleProductDetail, code: String) async throws -> [NSManagedObject] {
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
                let region = String(rawRegion.dropFirst()) // drop underscore
                
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
        // Unique constraint: code + tariffType + region + payment (or just tariff_code)
        // Suppose we fetch existing by tariff_code, if it's unique
        let tariffCode = defn.code // e.g. "E-1R-SILVER-24-12-31-A"
        let fetchReq = NSFetchRequest<NSManagedObject>(entityName: "ProductDetailEntity")
        fetchReq.predicate = NSPredicate(format: "tariff_code == %@", tariffCode)

        let existing = (try? context.fetch(fetchReq)) ?? []
        let detailEntity = existing.first ?? NSEntityDescription.insertNewObject(forEntityName: "ProductDetailEntity", into: context)

        detailEntity.setValue(code, forKey: "code")
        detailEntity.setValue(activeAt ?? Date(), forKey: "tariffs_active_at")
        detailEntity.setValue(tariffType, forKey: "tariff_type")
        detailEntity.setValue(region, forKey: "region")
        detailEntity.setValue(payment, forKey: "payment")
        detailEntity.setValue(tariffCode, forKey: "tariff_code")
        detailEntity.setValue(defn.online_discount_exc_vat ?? 0, forKey: "online_discount_exc_vat")
        detailEntity.setValue(defn.online_discount_inc_vat ?? 0, forKey: "online_discount_inc_vat")
        detailEntity.setValue(defn.dual_fuel_discount_exc_vat ?? 0, forKey: "dual_fuel_discount_exc_vat")
        detailEntity.setValue(defn.dual_fuel_discount_inc_vat ?? 0, forKey: "dual_fuel_discount_inc_vat")
        detailEntity.setValue(defn.exit_fees_exc_vat ?? 0, forKey: "exit_fees_exc_vat")
        detailEntity.setValue(defn.exit_fees_inc_vat ?? 0, forKey: "exit_fees_inc_vat")
        detailEntity.setValue(defn.exit_fees_type ?? "NONE", forKey: "exit_fees_type")

        // find links
        let standingLink = defn.links?.first(where: { $0.rel == "standing_charges" })?.href ?? ""
        let ratesLink = defn.links?.first(where: { $0.rel == "standard_unit_rates" })?.href ?? ""
        detailEntity.setValue(standingLink, forKey: "link_standing_charge")
        detailEntity.setValue(ratesLink, forKey: "link_rate")

        return detailEntity
    }
}
