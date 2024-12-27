import SwiftUI
import CoreData

@main
struct AppMain: App {
    let persistenceController = PersistenceController.shared
    @StateObject private var globalTimer = GlobalTimer()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environment(\.managedObjectContext, persistenceController.container.viewContext)
                .environmentObject(globalTimer)
                .onAppear {
                    globalTimer.startTimer()
                }
                .onDisappear {
                    globalTimer.stopTimer()
                }
        }
    }
} 