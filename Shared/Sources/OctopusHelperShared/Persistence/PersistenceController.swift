//
//  Persistence.swift
//  Octopus_Agile_Helper
//
//  Created by James To on 26/12/2024.
//

import CoreData

/// Manages Core Data persistence for the Octopus Agile Helper app.
/// This controller handles local storage with SQLite backend.
public class PersistenceController {
    public static let shared = PersistenceController()
    
    /// Preview instance for SwiftUI previews with in-memory storage
    public static let preview: PersistenceController = {
        let result = PersistenceController(inMemory: true)
        return result
    }()
    
    public let container: NSPersistentContainer
    
    public init(inMemory: Bool = false) {
        container = NSPersistentContainer(name: "Octopus_Agile_Helper")
        
        // Configure memory settings for better performance
        container.viewContext.automaticallyMergesChangesFromParent = true
        container.viewContext.mergePolicy = NSMergeByPropertyObjectTrumpMergePolicy
        
        if inMemory {
            container.persistentStoreDescriptions.first!.url = URL(fileURLWithPath: "/dev/null")
        } else {
            // Configure the persistent store to use the shared app group container
            let storeURL = FileManager.default
                .containerURL(
                    forSecurityApplicationGroupIdentifier: "group.com.jamesto.octopus-agile-helper")?
                .appendingPathComponent("Octopus_Agile_Helper.sqlite")
            
            if let storeURL = storeURL {
                let description = NSPersistentStoreDescription(url: storeURL)
                
                // Enable history tracking for undo support
                description.setOption(true as NSNumber, forKey: NSPersistentHistoryTrackingKey)
                
                // Migration settings
                description.shouldMigrateStoreAutomatically = true
                description.shouldInferMappingModelAutomatically = true
                
                container.persistentStoreDescriptions = [description]
            }
        }
        
        // Load persistent stores with enhanced error handling
        container.loadPersistentStores { [weak self] storeDescription, error in
            if let error = error as NSError? {
                #if DEBUG
                // In debug mode, attempt recovery based on error type
                self?.handlePersistentStoreError(error, storeDescription: storeDescription)
                #else
                // In production, post notification but keep the app running if possible
                NotificationCenter.default.post(
                    name: NSNotification.Name("PersistentStoreError"),
                    object: error
                )
                #endif
            }
        }
    }
    
    // MARK: - Private Methods
    
    private func handlePersistentStoreError(_ error: NSError, storeDescription: NSPersistentStoreDescription) {
        guard let storeURL = storeDescription.url else { return }
        
        switch error.code {
        case NSMigrationError, NSMigrationMissingSourceModelError, NSMigrationMissingMappingModelError:
            // Handle migration errors
            try? FileManager.default.removeItem(at: storeURL)
            retryLoadingPersistentStore(at: storeURL)
            
        case NSPersistentStoreIncompatibleVersionHashError:
            // Handle model version incompatibility
            try? FileManager.default.removeItem(at: storeURL)
            retryLoadingPersistentStore(at: storeURL)
            
        case NSCoreDataError:
            // Handle corruption
            try? FileManager.default.removeItem(at: storeURL)
            retryLoadingPersistentStore(at: storeURL)
            
        default:
            fatalError("Unresolved Core Data error: \(error)")
        }
    }
    
    private func retryLoadingPersistentStore(at storeURL: URL) {
        do {
            try container.persistentStoreCoordinator.addPersistentStore(
                ofType: NSSQLiteStoreType,
                configurationName: nil,
                at: storeURL,
                options: [
                    NSMigratePersistentStoresAutomaticallyOption: true,
                    NSInferMappingModelAutomaticallyOption: true
                ]
            )
        } catch {
            fatalError("Failed to recreate store: \(error)")
        }
    }
    
    // MARK: - Debug Helpers
    
    public func printStoreContent(entityName: String) {
        let fetchRequest = NSFetchRequest<NSManagedObject>(entityName: entityName)
        
        do {
            let results = try container.viewContext.fetch(fetchRequest)
            print("\n=== Contents of \(entityName) ===")
            print("Total count: \(results.count)")
            
            for (index, object) in results.enumerated() {
                print("\nRecord \(index + 1):")
                for attribute in object.entity.attributesByName.keys {
                    let value = object.value(forKey: attribute) ?? "nil"
                    print("\(attribute): \(value)")
                }
            }
            print("===========================\n")
        } catch {
            print("Error fetching \(entityName): \(error.localizedDescription)")
        }
    }
    
    public func printAllEntities() {
        print("\n=== All Core Data Entities ===")
        for entity in container.managedObjectModel.entities {
            if let name = entity.name {
                printStoreContent(entityName: name)
            }
        }
        print("===========================\n")
    }
}
