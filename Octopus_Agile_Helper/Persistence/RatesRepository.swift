import Foundation
import CoreData
import SwiftUI

// Extend NSManagedObjectContext with async support
extension NSManagedObjectContext {
    func performAsync<T>(_ block: @escaping () throws -> T) async throws -> T {
        try await withCheckedThrowingContinuation { continuation in
            perform {
                do {
                    let result = try block()
                    continuation.resume(returning: result)
                } catch let thrownError as Error {
                    continuation.resume(throwing: thrownError)
                }
            }
        }
    }
}

@MainActor
class RatesRepository {
    static let shared = RatesRepository()
    private let apiClient = OctopusAPIClient.shared
    private let context: NSManagedObjectContext
    
    private init() {
        self.context = PersistenceController.shared.container.viewContext
    }
    
    func updateRates() async throws {
        let rates = try await apiClient.fetchRates()
        try await saveRates(rates)
    }
    
    private func saveRates(_ rates: [OctopusRate]) async throws {
        try await context.performAsync {
            // First, fetch existing rates to avoid duplicates
            let fetchRequest: NSFetchRequest<RateEntity> = RateEntity.fetchRequest()
            let existingRates = try self.context.fetch(fetchRequest)
            
            // Create a dictionary of existing rates by their valid_from date for quick lookup
            let existingRatesByDate = Dictionary(uniqueKeysWithValues: existingRates.map { ($0.validFrom!, $0) })
            
            // Update or insert rates
            for rate in rates {
                if let existingRate = existingRatesByDate[rate.valid_from] {
                    // Update existing rate
                    existingRate.validTo = rate.valid_to
                    existingRate.valueExcludingVAT = rate.value_exc_vat
                    existingRate.valueIncludingVAT = rate.value_inc_vat
                } else {
                    // Create new rate
                    let newRate = RateEntity(context: self.context)
                    newRate.id = rate.id.uuidString
                    newRate.validFrom = rate.valid_from
                    newRate.validTo = rate.valid_to
                    newRate.valueExcludingVAT = rate.value_exc_vat
                    newRate.valueIncludingVAT = rate.value_inc_vat
                }
            }
            
            // Save changes
            try self.context.save()
        }
    }
    
    func fetchAllRates() async throws -> [RateEntity] {
        try await context.performAsync {
            let fetchRequest: NSFetchRequest<RateEntity> = RateEntity.fetchRequest()
            fetchRequest.sortDescriptors = [NSSortDescriptor(keyPath: \RateEntity.validFrom, ascending: true)]
            return try self.context.fetch(fetchRequest)
        }
    }
    
    func deleteAllRates() async throws {
        try await context.performAsync {
            let fetchRequest: NSFetchRequest<NSFetchRequestResult> = RateEntity.fetchRequest()
            let deleteRequest = NSBatchDeleteRequest(fetchRequest: fetchRequest)
            try self.context.execute(deleteRequest)
            try self.context.save()
        }
    }
} 