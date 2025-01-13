//
//  TestProductsRepository.swift
//  Octopus_Agile_Helper
//
//  Created by James To on 06/01/2025.
//


// In some Swift file, e.g. TestProductsRepository.swift

import XCTest
@testable import Octopus_Agile_Helper

final class TestProductsRepository: XCTestCase {

    var inMemoryContext: NSManagedObjectContext!
    var repository: ProductsRepository!

    override func setUpWithError() throws {
        // 1) Create an in-memory NSPersistentContainer
        let container = NSPersistentContainer(name: "Octopus_Agile_Helper")
        let description = NSPersistentStoreDescription()
        description.url = URL(fileURLWithPath: "/dev/null")
        container.persistentStoreDescriptions = [description]

        // 2) Load it
        container.loadPersistentStores { (storeDescription, error) in
            if let error = error {
                fatalError("Failed to load in-memory store: \(error)")
            }
        }

        // 3) Keep a reference to the in-memory context
        inMemoryContext = container.viewContext

        // 4) Create a custom repository that uses this context
        repository = ProductsRepository(context: inMemoryContext)
    }

    func testUpsertProducts() async throws {
        // 1) Mock or fake the API data
        let fakeApiItems = [
            OctopusProductItem(
                code: "FAKE-1",
                direction: "IMPORT",
                full_name: "Fake Product 1",
                display_name: "Fake 1",
                description: "Testing",
                is_variable: true,
                is_green: false,
                is_tracker: false,
                is_prepay: false,
                is_business: false,
                is_restricted: false,
                term: 12,
                available_from: Date(),
                available_to: nil,
                links: [],
                brand: "TEST"
            )
        ]

        // 2) Call the upsert logic directly
        let finalEntities = try await repository.upsertProducts(fakeApiItems)

        // 3) Assert the results
        XCTAssertEqual(finalEntities.count, 1)
        XCTAssertEqual(finalEntities[0].code, "FAKE-1")

        // 4) Optionally fetch them back
        let stored = try await repository.fetchAllLocalProductDetails()
        XCTAssertEqual(stored.count, 1)
        XCTAssertEqual(stored[0].full_name, "Fake Product 1")
    }
}
