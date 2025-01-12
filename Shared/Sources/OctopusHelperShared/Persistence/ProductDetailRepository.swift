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
        let detailData = try await apiClient.fetchSingleProductDetail(productCode)
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

    /// Fetch all local product details
    public func fetchLocalProducts() async throws -> [NSManagedObject] {
        try await context.perform {
            let req = NSFetchRequest<NSManagedObject>(entityName: "ProductDetailEntity")
            // Sort by code to ensure consistent order
            req.sortDescriptors = [NSSortDescriptor(key: "code", ascending: true)]
            return try self.context.fetch(req)
        }
    }

    /// Parse nested JSON (single_register_electricity_tariffs, etc.)
    /// Flatten for each region, payment, etc.
    @discardableResult
    private func upsertProductDetail(json: OctopusSingleProductDetail, code: String) async throws -> [NSManagedObject] {
        // For brevity, only a sketch:
        var newDetails: [NSManagedObject] = []

        // example for single_register_electricity_tariffs
        if let singleElec = json.single_register_electricity_tariffs {
            let rows = try await processTariffType(
                tariffType: "single_register_electricity_tariffs",
                dictionary: singleElec,
                code: code,
                activeAt: json.tariffs_active_at
            )
            newDetails.append(contentsOf: rows)
        }
        // similarly for dual_register_electricity_tariffs, single_register_gas_tariffs, etc.

        // Save once at the end
        try await context.perform {
            try self.context.save()
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
