import CoreData
import OctopusHelperShared
import SwiftUI
import WidgetKit

@main
@available(iOS 17.0, *)
struct Octopus_Agile_HelperApp: App {
    // MARK: - Dependencies that must exist before StateObjects
    // Make globalTimer a plain stored property so we can pass it into the RatesViewModel init
    private let globalTimer = GlobalTimer()

    // MARK: - Persistence
    private let persistenceController = PersistenceController.shared

    // MARK: - StateObjects
    @StateObject private var globalSettings = GlobalSettingsManager()
    @StateObject private var ratesVM: RatesViewModel
    
    // MARK: - ScenePhase
    @Environment(\.scenePhase) private var scenePhase
    
    // MARK: - UI States
    @State private var isAppInitialized = false
    @State private var showDebugView = false
    @State public var hasAgileCards = false

    // MARK: - Init
    init() {
        // 1) Create the RatesViewModel with the previously declared globalTimer
        let initialRatesVM = RatesViewModel(globalTimer: globalTimer)
        initialRatesVM.fetchStatus = .fetching  // Optional: start in fetching state
        _ratesVM = StateObject(wrappedValue: initialRatesVM)

        // 2) Configure the NavBar appearance (Dark style, etc.)
        configureNavigationBarAppearance()

        // 3) Check if we have any Agile cards
        let settings = globalSettings.settings
        let activeCards = settings.cardSettings.filter { $0.isEnabled }
        hasAgileCards = activeCards.contains {
            if let def = CardRegistry.shared.definition(for: $0.cardType) {
                return def.supportedPlans.contains(.agile)
            }
            return false
        }
    }
    
    // MARK: - Body
    var body: some Scene {
        WindowGroup {
            ZStack {
                if isAppInitialized {
                    ContentView(hasAgileCards: hasAgileCards)
                        .environment(\.managedObjectContext, persistenceController.container.viewContext)
                        .environmentObject(globalSettings)
                        .environmentObject(ratesVM)
                        .environmentObject(globalTimer)
                        .preferredColorScheme(.dark)
                        #if DEBUG
                        // Debug button overlay
                        .overlay(alignment: .bottom) {
                            Button("Debug") {
                                showDebugView.toggle()
                            }
                            .font(.caption)
                            .foregroundColor(Theme.secondaryTextColor.opacity(0.6))
                            .padding(.bottom, 8)
                        }
                        .sheet(isPresented: $showDebugView) {
                            NavigationStack {
                                TestView(ratesViewModel: ratesVM)
                                    .environmentObject(globalSettings)
                                    .environmentObject(globalTimer)
                                    .environmentObject(ratesVM)
                                    .environment(\.managedObjectContext, persistenceController.container.viewContext)
                                    .preferredColorScheme(.dark)
                            }
                        }
                        #endif
                } else {
                    // While loading => show Splash
                    SplashScreenView(isLoading: .constant(true))
                        .transition(AnyTransition.opacity.animation(.easeOut))
                }
            }
            .task {
                // Perform one-time async initialization
                await initializeAppData()
            }
            // Use new iOS 17 style: .onChange(scenePhase)
            .onChange(of: scenePhase) { oldPhase, newPhase in
                handleScenePhaseChange(newPhase)
            }
        }
    }
}

// MARK: - Private Helpers
extension Octopus_Agile_HelperApp {
    /// Centralized function to load initial data, matching your #Preview flow.
    private func initializeAppData() async {
        do {
            // 1) Let RatesViewModel detect user's agile product or fallback (includes product sync)
            await ratesVM.setAgileProductFromAccountOrFallback(globalSettings: globalSettings)
            
            // 2) If we already know the agile code, initialize product data
            if !ratesVM.currentAgileCode.isEmpty {
                await ratesVM.initializeProducts()
            }
            
            // 3) Mark app as initialized => show main content
            withAnimation(.easeOut(duration: 0.5)) {
                isAppInitialized = true
            }
        }
    }

    /// Handles app lifecycle changes
    private func handleScenePhaseChange(_ phase: ScenePhase) {
        switch phase {
        case .active:
            globalTimer.startTimer()
            globalTimer.refreshTime()
        case .inactive, .background:
            globalTimer.stopTimer()
            WidgetCenter.shared.reloadAllTimelines()
        @unknown default:
            break
        }
    }

    /// Configures the global UINavigationBar appearance for large & standard titles
    private func configureNavigationBarAppearance() {
        let appearance = UINavigationBarAppearance()
        appearance.configureWithDefaultBackground()
        appearance.backgroundColor = UIColor(Theme.mainBackground)
        appearance.largeTitleTextAttributes = [.foregroundColor: UIColor.white]
        appearance.titleTextAttributes = [.foregroundColor: UIColor.white]
        
        UINavigationBar.appearance().scrollEdgeAppearance = appearance
        UINavigationBar.appearance().standardAppearance = appearance
        UINavigationBar.appearance().compactAppearance = appearance
    }
}

@available(iOS 17.0, *)
#Preview {
    struct PreviewWrapper: View {
        @State private var isInitialized = false
        
        let globalTimer = GlobalTimer()
        let globalSettings = GlobalSettingsManager()
        let ratesVM = RatesViewModel(globalTimer: GlobalTimer())

        var body: some View {
            ZStack {
                if isInitialized {
                    ContentView(hasAgileCards: true)
                        .environmentObject(globalTimer)
                        .environmentObject(globalSettings)
                        .environmentObject(ratesVM)
                        .preferredColorScheme(.dark)
                } else {
                    SplashScreenView(isLoading: .constant(true))
                }
            }
            .task {
                // Mimic your real app’s initialization
                do {
                    await ratesVM.setAgileProductFromAccountOrFallback(globalSettings: globalSettings)
                    if !ratesVM.currentAgileCode.isEmpty {
                        await ratesVM.initializeProducts()
                    }
                    // Show main content
                    withAnimation(.easeOut(duration: 0.5)) {
                        isInitialized = true
                    }
                }
            }
        }
    }
    
    return PreviewWrapper()
}
