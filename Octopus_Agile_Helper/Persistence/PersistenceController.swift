//
//  Persistence.swift
//  Octopus_Agile_Helper
//
//  Created by James To on 26/12/2024.
//

import CoreData

struct PersistenceController {
    static let shared = PersistenceController()

    static let preview: PersistenceController = {
        let result = PersistenceController(inMemory: true)
        // Preview container is empty by default
        // Add sample data here if needed for previews
        return result
    }()

    let container: NSPersistentContainer

    init(inMemory: Bool = false) {
        container = NSPersistentCloudKitContainer(name: "Octopus_Agile_Helper")
        if inMemory {
            container.persistentStoreDescriptions.first!.url = URL(fileURLWithPath: "/dev/null")
        }
        container.loadPersistentStores { storeDescription, error in
            if let error = error as NSError? {
                fatalError("Unresolved error \(error), \(error.userInfo)")
            }
        }
        container.viewContext.automaticallyMergesChangesFromParent = true
    }
}
