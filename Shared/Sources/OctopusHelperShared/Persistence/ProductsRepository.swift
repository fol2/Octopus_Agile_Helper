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
        productEntity.setValue(item.available_from, forKey: "available_from")
        productEntity.setValue(item.available_to, forKey: "available_to")

        // Store the "self" link if present
        if let selfLink = item.links.first(where: { $0.rel == "self" })?.href {
            productEntity.setValue(selfLink, forKey: "link")
        } else {
            productEntity.setValue("", forKey: "link")
        }
    }
}
