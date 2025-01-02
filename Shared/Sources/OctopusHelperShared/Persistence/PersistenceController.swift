//
//  Persistence.swift
//  Octopus_Agile_Helper
//
//  Created by James To on 26/12/2024.
//

import CoreData

public struct PersistenceController {
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
                container.persistentStoreDescriptions = [description]
            }
        }
        container.loadPersistentStores { storeDescription, error in
            if let error = error as NSError? {
                fatalError("Unresolved error \(error), \(error.userInfo)")
            }
        }
        container.viewContext.automaticallyMergesChangesFromParent = true
    }
}
