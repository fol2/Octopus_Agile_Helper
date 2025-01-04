import CoreData
import OctopusHelperShared
import SwiftUI
import WidgetKit

@main
@available(iOS 17.0, *)
struct Octopus_Agile_HelperApp: App {
    let persistenceController = PersistenceController.shared
    @StateObject private var globalTimer = GlobalTimer()
    @StateObject private var globalSettings = GlobalSettingsManager()
    @Environment(\.scenePhase) private var scenePhase

    init() {
        // Cards are now auto-registered by CardRegistry.shared
        
        // Configure navigation bar appearance
        let appearance = UINavigationBarAppearance()
        appearance.configureWithDefaultBackground()
        appearance.backgroundColor = UIColor(Theme.mainBackground)
        appearance.largeTitleTextAttributes = [.foregroundColor: UIColor.white]
        appearance.titleTextAttributes = [.foregroundColor: UIColor.white]
        
        UINavigationBar.appearance().scrollEdgeAppearance = appearance
        UINavigationBar.appearance().standardAppearance = appearance
        UINavigationBar.appearance().compactAppearance = appearance
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environment(\.managedObjectContext, persistenceController.container.viewContext)
                .environmentObject(globalTimer)
                .environmentObject(globalSettings)
                .environment(\.locale, globalSettings.locale)
                .preferredColorScheme(.dark)
                .onChange(of: scenePhase) { _, newPhase in
                    switch newPhase {
                    case .active:
                        globalTimer.startTimer()
                        globalTimer.refreshTime()
                    case .background:
                        globalTimer.stopTimer()
                        // Force widget refresh when app goes to background
                        WidgetCenter.shared.reloadAllTimelines()
                    case .inactive:
                        break
                    @unknown default:
                        break
                    }
                }
        }
    }
}

@available(iOS 17.0, *)
#Preview {
    let globalTimer = GlobalTimer()
    let globalSettings = GlobalSettingsManager()
    
    return ContentView()
        .environment(\.managedObjectContext, PersistenceController.preview.container.viewContext)
        .environmentObject(globalTimer)
        .environmentObject(globalSettings)
        .environmentObject(RatesViewModel(globalTimer: globalTimer))
        .environment(\.locale, globalSettings.locale)
        .preferredColorScheme(.dark)
}
