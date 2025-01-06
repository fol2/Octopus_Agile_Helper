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
    @AppStorage("isLoading") private var isLoading = true
    
    init() {
        // Reset isLoading to true on app launch
        UserDefaults.standard.set(true, forKey: "isLoading")
        
        // Cards are now auto-registered by CardRegistry.shared
        // Update the registry with our global timer
        CardRegistry.shared.updateTimer(globalTimer)
        
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
    
    private func checkInitialLoadingStatus() {
        // 检查所有需要的数据是否已加载
        let isTimerReady = globalTimer.currentTime > Date.distantPast
        let isRegistryReady = CardRegistry.shared.isReady
        let isSettingsReady = !globalSettings.settings.apiKey.isEmpty
        
        if isTimerReady && isRegistryReady && isSettingsReady {
            withAnimation(.easeOut(duration: 0.5)) {
                isLoading = false
            }
        }
    }

    var body: some Scene {
        WindowGroup {
            ZStack {
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
                            // Check loading status periodically
                            Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { timer in
                                if !isLoading {
                                    timer.invalidate()
                                } else {
                                    checkInitialLoadingStatus()
                                }
                            }
                        case .background:
                            globalTimer.stopTimer()
                            WidgetCenter.shared.reloadAllTimelines()
                            isLoading = true
                        case .inactive:
                            break
                        @unknown default:
                            break
                        }
                    }
                
                if isLoading {
                    SplashScreenView(isLoading: $isLoading)
                        .transition(AnyTransition.opacity)
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
