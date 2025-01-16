//
//  ProductsRepository.swift
//  OctopusHelperShared
//
//  Created by James To on 06/01/2025.
//
//  Description:
//    - Manages the retrieval and storage of ProductEntity data in Core Data.
//    - Leverages OctopusAPIClient for network operations.
//    - Uses NSManagedObject to upsert products in a shared context.
//
//  Principles:
//    - SOLID: Single responsibility (fetch + store product records).
//    - KISS: Straightforward upsert logic.
//    - DRY/YAGNI: Minimally sufficient code for your product needs.
//

import CoreData
import Foundation

public final class ProductsRepository: ObservableObject {
    // MARK: - Shared / Singleton
    public static let shared = ProductsRepository()

    // MARK: - Dependencies
    private let apiClient = OctopusAPIClient.shared
    private let context: NSManagedObjectContext

    // MARK: - Constants
    private let defaultProductCodes = [
        "SILVER-24-12-31",
        "SILVER-FLEX-22-11-25",
        "SILVER-23-12-06",
        "SILVER-24-04-03",
        "SILVER-24-07-01",
        "SILVER-24-10-01"
    ]

    // MARK: - Initializer
    private init() {
        // Adjust to your actual persistence setup
        // If you have multiple containers, or a different environment,
        // you can pass in the context at init time, etc.
        self.context = PersistenceController.shared.container.viewContext
    }

    // MARK: - Public Methods

    /// Fetches all products from the remote API (optionally filtered by `brand`),
    /// upserts them into Core Data (`ProductEntity`), and returns the final array
    /// of NSManagedObject for further usage if needed.
    ///
    /// - Parameter brand: If specified, appends "?brand=XYZ" to the fetch. If nil, fetches all products.
    /// - Throws: Possible network/decoding errors (OctopusAPIError) or Core Data errors.
    /// - Returns: Array of newly updated/inserted `ProductEntity` as NSManagedObject.
    @discardableResult
    public func syncAllProducts(brand: String? = nil) async throws -> [NSManagedObject] {
        print("🔄 开始同步产品数据...")
        // 1) Fetch from the API
        let apiItems = try await apiClient.fetchAllProducts(brand: brand)
        print("✅ API返回数据数量: \(apiItems.count)")

        // 2) Upsert them into Core Data
        let finalEntities = try await upsertProducts(apiItems)
        print("✅ 成功保存到Core Data，最终实体数量: \(finalEntities.count)")

        // 3) After main sync, ensure we have all default products if not in the list
        for defaultProductCode in defaultProductCodes {
            let isProductInAPI = apiItems.contains { $0.code == defaultProductCode }
            if !isProductInAPI {
                print("ℹ️ Product \(defaultProductCode) not in official list, adding manually...")
                _ = try await ensureProductExists(productCode: defaultProductCode)
            }
        }

        return finalEntities
    }

    /// Fetches a single product's detailed JSON from the Octopus API.
    /// You can store it in Core Data or parse out tariff details as you like.
    ///
    /// - Parameter productCode: e.g. "VAR-22-11-01"
    /// - Throws: Network/decoding errors
    /// - Returns: A fully decoded OctopusSingleProductDetail object (not stored by default).
    public func fetchProductDetail(_ productCode: String) async throws -> OctopusSingleProductDetail {
        try await apiClient.fetchSingleProductDetail(productCode)
    }

    /// Retrieves all local `ProductEntity` rows from Core Data, sorted by `code`.
    ///
    /// - Returns: `[NSManagedObject]` representing all ProductEntity rows.
    public func fetchLocalProducts() async throws -> [NSManagedObject] {
        try await context.perform {
            let request = NSFetchRequest<NSManagedObject>(entityName: "ProductEntity")
            request.sortDescriptors = [NSSortDescriptor(key: "code", ascending: true)]
            return try self.context.fetch(request)
        }
    }

    /// Fetch all local products from ProductEntity
    /// - Returns: Array of ProductEntity as NSManagedObject
    public func fetchAllLocalProducts() async throws -> [NSManagedObject] {
        try await context.perform {
            let request = NSFetchRequest<NSManagedObject>(entityName: "ProductEntity")
            // Sort by code to ensure consistent order
            request.sortDescriptors = [NSSortDescriptor(key: "code", ascending: true)]
            return try self.context.fetch(request)
        }
    }

    /// Ensures a specific product code exists in Core Data. If not found locally,
    /// it fetches from the API (GET /products/<code>/) and upserts the data.
    /// 
    /// This method is specifically designed to create a ProductEntity from a ProductDetail
    /// response when we don't have access to the full product list. It synthesizes the
    /// necessary ProductEntity fields from the detail response, which is useful for:
    /// - Adding default products (e.g., SILVER-24-12-31)
    /// - Ensuring specific products exist when referenced by tariff codes
    /// - Single-product scenarios where fetching the full product list would be inefficient
    ///
    /// - Parameter productCode: e.g. "SILVER-24-12-31"
    /// - Returns: Final array of ProductEntity as NSManagedObject
    @discardableResult
    public func ensureProductExists(productCode: String) async throws -> [NSManagedObject] {
        // 1) Check if it already exists
        let existing = try await fetchLocalProductsByCode(productCode)
        if !existing.isEmpty {
            print("✅ Product \(productCode) already in local DB, skipping fetch.")
            return existing
        }

        // 2) Fetch from API
        print("🌐 Fetching product details for code: \(productCode)")
        let detail = try await apiClient.fetchSingleProductDetail(productCode)
        print("🔄 Upserting product + product detail for code: \(productCode)")

        // 3) Upsert into ProductEntity (like syncAllProducts but for one code)
        let upserted = try await upsertProducts([
            OctopusProductItem(
                code: detail.code,
                direction: detail.direction ?? (detail.single_register_electricity_tariffs == nil
                    && detail.single_register_gas_tariffs == nil ? "UNKNOWN" : "IMPORT"),
                full_name: detail.full_name,
                display_name: detail.display_name,
                description: detail.description,
                is_variable: detail.is_variable ?? true,
                is_green: detail.is_green ?? false,
                is_tracker: detail.is_tracker ?? detail.code.contains("AGILE"),
                is_prepay: detail.is_prepay ?? false,
                is_business: detail.is_business ?? false,
                is_restricted: detail.is_restricted ?? false,
                term: detail.term,
                available_from: detail.available_from,
                available_to: detail.available_to,
                links: detail.links ?? [
                    OctopusLinkItem(
                        href: apiClient.getProductURL(detail.code),
                        method: "GET",
                        rel: "self"
                    )
                ],
                brand: detail.brand
            )
        ])
        
        // 4) Upsert the tariff details
        _ = try await ProductDetailRepository.shared.upsertProductDetail(json: detail, code: productCode)
        return upserted
    }

    /// Ensures multiple tariff codes exist as product codes in Core Data. 
    /// E.g. from an account's "E-1R-AGILE-24-04-03-H", we derive "AGILE-24-04-03".
    /// We skip duplicates if they're already stored.
    /// - Parameter tariffCodes: e.g. ["E-1R-AGILE-24-04-03-H", "E-1R-SILVER-24-12-31-A"]
    /// - Returns: All newly added or existing product rows
    @discardableResult
    public func ensureProductsForTariffCodes(_ tariffCodes: [String]) async throws -> [NSManagedObject] {
        var allUpserted: [NSManagedObject] = []
        for code in tariffCodes {
            if let shortCode = productCodeFromTariff(code) {
                let upserted = try await ensureProductExists(productCode: shortCode)
                allUpserted.append(contentsOf: upserted)
            }
        }
        return allUpserted
    }

    // MARK: - Private Methods

    /// Takes an array of `OctopusProductItem` from the API
    /// and upserts them into the `ProductEntity` in Core Data.
    ///
    /// - Parameter items: Array of decoded product items from the API.
    /// - Returns: An array of NSManagedObject representing the final (updated/inserted) product rows.
    private func upsertProducts(_ items: [OctopusProductItem]) async throws -> [NSManagedObject] {
        print("📝 开始更新/插入产品数据...")
        return try await context.perform {
            // 1) Fetch all existing ProductEntity rows at once
            let request = NSFetchRequest<NSManagedObject>(entityName: "ProductEntity")
            let existingProducts = try self.context.fetch(request)
            print("📊 现有产品数量: \(existingProducts.count)")

            // 2) Build a map: productCode -> NSManagedObject for quick lookups
            var existingMap = [String: NSManagedObject]()
            for product in existingProducts {
                if let code = product.value(forKey: "code") as? String {
                    existingMap[code] = product
                }
            }
            print("🗺 现有产品映射表大小: \(existingMap.count)")

            // 3) Insert or Update each incoming item
            var updatedCount = 0
            var insertedCount = 0
            for item in items {
                if let existingObject = existingMap[item.code] {
                    // Update existing record
                    self.update(productEntity: existingObject, from: item)
                    updatedCount += 1
                } else {
                    // Create a new record
                    let newProduct = NSEntityDescription.insertNewObject(
                        forEntityName: "ProductEntity",
                        into: self.context
                    )
                    self.update(productEntity: newProduct, from: item)
                    existingMap[item.code] = newProduct
                    insertedCount += 1
                }
            }
            print("📈 更新记录: \(updatedCount), 新增记录: \(insertedCount)")

            // 4) Save changes once at the end
            try self.context.save()
            print("💾 成功保存到Core Data")
            
            // 发送合并通知以确保其他上下文能看到更改
            NotificationCenter.default.post(
                name: NSManagedObjectContext.didSaveObjectsNotification,
                object: self.context,
                userInfo: nil
            )

            // 5) Return all final objects
            return Array(existingMap.values)
        }
    }

    /// Copies fields from the API model (`OctopusProductItem`) into a `ProductEntity` row.
    /// Update this logic if you add/remove columns from your ProductEntity.
    private func update(productEntity: NSManagedObject, from item: OctopusProductItem) {
        productEntity.setValue(item.code,         forKey: "code")
        productEntity.setValue(item.direction,    forKey: "direction")
        productEntity.setValue(item.full_name,    forKey: "full_name")
        productEntity.setValue(item.display_name, forKey: "display_name")
        productEntity.setValue(item.description,  forKey: "desc")
        productEntity.setValue(item.is_variable,  forKey: "is_variable")
        productEntity.setValue(item.is_green,     forKey: "is_green")
        productEntity.setValue(item.is_tracker,   forKey: "is_tracker")
        productEntity.setValue(item.is_prepay,    forKey: "is_prepay")
        
        // Convert Boolean to String as per Core Data model requirement
        productEntity.setValue(item.is_business ? "true" : "false", forKey: "is_business")
        
        // Use correct attribute name "is_stricted" from Core Data model
        productEntity.setValue(item.is_restricted, forKey: "is_stricted")

        productEntity.setValue(item.term,         forKey: "term")
        productEntity.setValue(item.brand,        forKey: "brand")
        
        // Handle optional dates with nil coalescing
        productEntity.setValue(item.available_from ?? Date.distantPast, forKey: "available_from")
        productEntity.setValue(item.available_to ?? Date.distantFuture, forKey: "available_to")

        // Store the "self" link if present
        if let selfLink = item.links.first(where: { $0.rel == "self" })?.href {
            productEntity.setValue(selfLink, forKey: "link")
        } else {
            productEntity.setValue("", forKey: "link")
        }
    }

    /// Extracts a short code from a tariff code, e.g. "E-1R-AGILE-24-04-03-H" -> "AGILE-24-04-03".
    /// If it doesn't contain "AGILE" or a known pattern, you can adjust your logic as needed.
    private func productCodeFromTariff(_ tariffCode: String) -> String? {
        // e.g. "E-1R-AGILE-24-04-03-H"
        let parts = tariffCode.components(separatedBy: "-")
        guard parts.count >= 6 else { return nil }
        return parts[2...5].joined(separator: "-") // e.g. "AGILE-24-04-03"
    }

    /// Fetch local product rows by the exact product code (case-sensitive match).
    /// - Parameter code: e.g. "SILVER-24-12-31"
    /// - Returns: Array of matching ProductEntity
    private func fetchLocalProductsByCode(_ code: String) async throws -> [NSManagedObject] {
        try await context.perform {
            let request = NSFetchRequest<NSManagedObject>(entityName: "ProductEntity")
            request.fetchLimit = 1
            request.predicate = NSPredicate(format: "code == %@", code)
            let found = try self.context.fetch(request)
            if !found.isEmpty {
                print("🔍 Found product in local DB: \(code)")
            }
            return found
        }
    }
}
