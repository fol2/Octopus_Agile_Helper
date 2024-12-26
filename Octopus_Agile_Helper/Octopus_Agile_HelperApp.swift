//
//  Octopus_Agile_HelperApp.swift
//  Octopus_Agile_Helper
//
//  Created by James To on 26/12/2024.
//

import SwiftUI

@main
struct Octopus_Agile_HelperApp: App {
    let persistenceController = PersistenceController.shared

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environment(\.managedObjectContext, persistenceController.container.viewContext)
        }
    }
}
