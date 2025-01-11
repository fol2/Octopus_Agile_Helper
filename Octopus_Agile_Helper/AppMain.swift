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
    @StateObject private var ratesVM = RatesViewModel(
        globalTimer: GlobalTimer() // replaced later in onAppear
    )
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
        
        if isTimerReady && isRegistryReady {
            withAnimation(.easeOut(duration: 0.5)) {
                isLoading = false
            }
        }
    }

    private func syncProductsIfNeeded() async {
        do {
            // If you want only certain brand, pass it here; e.g., syncAllProducts(brand: "OCTOPUS_ENERGY").
            // Otherwise, just call syncAllProducts() with no params:
            let _ = try await ProductsRepository.shared.syncAllProducts()
            print("DEBUG: Products sync completed.")
        } catch {
            print("DEBUG: Error syncing products: \(error)")
        }
    }

    var body: some Scene {
        WindowGroup {
            ZStack {
                ContentView()
                    .environment(\.managedObjectContext, persistenceController.container.viewContext)
                    .environmentObject(globalTimer)
                    .environmentObject(globalSettings)
                    .environmentObject(ratesVM)
                    .environment(\.locale, globalSettings.locale)
                    .preferredColorScheme(.dark)
                    .onChange(of: scenePhase) { _, newPhase in
                        switch newPhase {
                        case .active:
                            ratesVM.updateTimer(globalTimer)
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
                    .onAppear {
                        Task {
                            // 1) Ensure local Products are synced from API
                            await syncProductsIfNeeded()

                            // 2) Let RatesViewModel detect user's agile product or fallback
                            await ratesVM.setAgileProductFromAccountOrFallback(globalSettings: globalSettings)
                            // Then load rates
                            await ratesVM.loadRates(for: [ratesVM.currentAgileCode])
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
