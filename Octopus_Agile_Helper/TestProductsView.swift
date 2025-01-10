//
//  TestProductsView.swift
//  Octopus_Agile_Helper
//
//  Created by James To on 06/01/2025.
//

//
//  TestProductsView.swift
//  Octopus_Agile_Helper
//
//  Description:
//    A simple SwiftUI view that tests the ProductsRepository
//    by fetching products from the API, storing them, and displaying them.
//
//  Usage:
//    1. Place this file in your project.
//    2. Open it in the Preview or run it on a simulator.
//    3. Tap the "Fetch & Store" button to trigger repository calls.
//    4. Observe the list update with newly fetched products.
//
import SwiftUI
import OctopusHelperShared
import CoreData

struct TestProductsView: View {

    // Repository instance
    @ObservedObject private var repository = ProductsRepository.shared

    // Local state to hold fetched NSManagedObjects
    @State private var products: [NSManagedObject] = []

    // UI states
    @State private var isLoading = false
    @State private var errorMessage: String?

    var body: some View {
        NavigationView {
            VStack {
                // Button to fetch from remote API & store in Core Data
                Button(action: {
                    Task {
                        await fetchAndStore()
                    }
                }) {
                    Text("Fetch & Store Products")
                }
                .padding()

                // Display error if any
                if let errorMessage = errorMessage {
                    Text("Error: \(errorMessage)")
                        .foregroundColor(.red)
                }

                // Display loading
                if isLoading {
                    ProgressView("Fetching...")
                }

                // Show list of local products
                List(products, id: \.objectID) { product in
                    VStack(alignment: .leading) {
                        Text(product.value(forKey: "full_name") as? String ?? "No Name")
                            .font(.headline)
                        Text("Code: \(product.value(forKey: "code") as? String ?? "")")
                            .font(.subheadline)
                        Text("Direction: \(product.value(forKey: "direction") as? String ?? "")")
                            .font(.footnote)
                    }
                }
            }
            .navigationTitle("Test Products")
        }
        .onAppear {
            // On appear, load from local if any
            Task {
                await loadLocal()
            }
        }
    }

    // MARK: - Private Methods

    /// Fetch products from the API, store them, then load local results
    private func fetchAndStore() async {
        isLoading = true
        errorMessage = nil

        do {
            // Example: You can pass brand: "OCTOPUS_ENERGY" or nil
            let _ = try await repository.syncAllProducts(brand: nil)
            // After sync, read from local
            await loadLocal()
        } catch {
            self.errorMessage = error.localizedDescription
        }

        isLoading = false
    }

    /// Load products from local Core Data storage
    private func loadLocal() async {
        do {
            self.products = try await repository.fetchLocalProducts()
        } catch {
            self.errorMessage = error.localizedDescription
        }
    }
}

// MARK: - SwiftUI Preview
#if DEBUG
struct TestProductsView_Previews: PreviewProvider {
    static var previews: some View {
        TestProductsView()
    }
}
#endif
