import CoreData
import OctopusHelperShared
import SwiftUI

@main
@available(iOS 17.0, *)
struct Octopus_Agile_HelperApp: App {
    let persistenceController = PersistenceController.shared
    @StateObject private var globalTimer = GlobalTimer()
    @StateObject private var globalSettings = GlobalSettingsManager()
    @Environment(\.scenePhase) private var scenePhase

    init() {
        // Register all cards
        CardRegistry.registerCards()
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environment(\.managedObjectContext, persistenceController.container.viewContext)
                .environmentObject(globalTimer)
                .environmentObject(globalSettings)
                .environment(\.locale, globalSettings.locale)
                .onChange(of: scenePhase) { _, newPhase in
                    switch newPhase {
                    case .active:
                        globalTimer.startTimer()
                        globalTimer.refreshTime()
                    case .background:
                        globalTimer.stopTimer()
                    case .inactive:
                        break
                    @unknown default:
                        break
                    }
                }
        }
    }
}
