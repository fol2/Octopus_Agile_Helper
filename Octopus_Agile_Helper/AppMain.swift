import SwiftUI
import CoreData

@main
struct AppMain: App {
    let persistenceController = PersistenceController.shared
    @StateObject private var globalTimer = GlobalTimer()
    @StateObject private var globalSettings = GlobalSettingsManager()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environment(\.managedObjectContext, persistenceController.container.viewContext)
                .environmentObject(globalTimer)
                .environmentObject(globalSettings)
                .onAppear {
                    globalTimer.startTimer()
                }
                .onDisappear {
                    globalTimer.stopTimer()
                }
        }
    }
} 