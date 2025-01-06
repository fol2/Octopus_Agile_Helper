//
//  Persistence.swift
//  Octopus_Agile_Helper
//
//  Created by James To on 26/12/2024.
//

import CoreData

public class PersistenceController {
    public static let shared = PersistenceController()

    public static let preview: PersistenceController = {
        let result = PersistenceController(inMemory: true)
        // Preview container is empty by default
        // Add sample data here if needed for previews
        return result
    }()

    public let container: NSPersistentContainer

    public init(inMemory: Bool = false) {
        container = NSPersistentCloudKitContainer(name: "Octopus_Agile_Helper")
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
                description.setOption(true as NSNumber, forKey: NSPersistentHistoryTrackingKey)
                description.setOption(
                    true as NSNumber, forKey: NSPersistentStoreRemoteChangeNotificationPostOptionKey
                )
                
                // Add automatic lightweight migration options
                description.shouldMigrateStoreAutomatically = true
                description.shouldInferMappingModelAutomatically = true
                
                container.persistentStoreDescriptions = [description]
            }
        }
        
        // Handle store loading errors more gracefully
        container.loadPersistentStores { [weak self] storeDescription, error in
            if let error = error as NSError? {
                // For development, we'll delete the store and try again
                #if DEBUG
                print("Error loading persistent store: \(error), \(error.userInfo)")
                print("Attempting to delete and recreate the store...")
                if let storeURL = storeDescription.url {
                    try? FileManager.default.removeItem(at: storeURL)
                    // Try loading again
                    do {
                        try self?.container.persistentStoreCoordinator.addPersistentStore(
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
                #else
                // In production, log the error but don't crash
                print("Unresolved error loading persistent store: \(error), \(error.userInfo)")
                #endif
            }
        }
        container.viewContext.automaticallyMergesChangesFromParent = true
    }
}
