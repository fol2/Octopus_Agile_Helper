import SwiftUI
import CoreData

@main
@available(iOS 17.0, *)
struct Octopus_Agile_HelperApp: App {
    let persistenceController = PersistenceController.shared
    @StateObject private var globalTimer = GlobalTimer()
    @StateObject private var globalSettings = GlobalSettingsManager()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environment(\.managedObjectContext, persistenceController.container.viewContext)
                .environmentObject(globalTimer)
                .environmentObject(globalSettings)
                .environment(\.locale, globalSettings.locale)
                .onAppear {
                    globalTimer.startTimer()
                }
                .onDisappear {
                    globalTimer.stopTimer()
                }
        }
    }
} 