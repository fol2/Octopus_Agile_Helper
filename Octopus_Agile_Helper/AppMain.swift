import CoreData
import OctopusHelperShared
import SwiftUI
import WidgetKit

@main
@available(iOS 17.0, *)
struct Octopus_Agile_HelperApp: App {
    // MARK: - Dependencies that must exist before StateObjects
    private let globalTimer = GlobalTimer()
    private let persistenceController = PersistenceController.shared
    private let cardRegistry = CardRegistry.shared
    @StateObject private var tariffVM = TariffViewModel()

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
        _ratesVM = StateObject(wrappedValue: initialRatesVM)

        // 2) Configure the NavBar appearance (Dark style, etc.)
        configureNavigationBarAppearance()
    }

    private func updateHasAgileCards() {
        let activeCards = globalSettings.settings.cardSettings.filter { $0.isEnabled }
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
                        .onAppear {
                            updateHasAgileCards()
                        }
                        .onChange(of: globalSettings.settings.cardSettings) {
                            oldSettings, newSettings in
                            updateHasAgileCards()
                        }
                        .environment(
                            \.managedObjectContext, persistenceController.container.viewContext
                        )
                        .environmentObject(globalSettings)
                        .environmentObject(tariffVM)
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
                                    .environmentObject(tariffVM)
                                    .environment(
                                        \.managedObjectContext,
                                        persistenceController.container.viewContext
                                    )
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
                await initializeAppData()
            }
            .onChange(of: scenePhase) { oldPhase, newPhase in
                handleScenePhaseChange(newPhase)
            }
        }
    }
}

// MARK: - Private Helpers
extension Octopus_Agile_HelperApp {
    private func initializeAppData() async {
        do {
            // 1. Sync products first
            await ratesVM.syncProducts()

            // 2. Set Agile product
            await ratesVM.setAgileProductFromAccountOrFallback(globalSettings: globalSettings)

            var productsToInit: [String] = []

            if !ratesVM.currentAgileCode.isEmpty {
                productsToInit.append(ratesVM.currentAgileCode)
            }

            ratesVM.productsToInitialize = productsToInit

            if !productsToInit.isEmpty {
                await ratesVM.initializeProducts()
            }

            withAnimation(.easeOut(duration: 0.5)) {
                isAppInitialized = true
            }
        }
    }

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
        let tariffVM = TariffViewModel()

        var body: some View {
            ZStack {
                if isInitialized {
                    ContentView(hasAgileCards: true)
                        .environmentObject(globalTimer)
                        .environmentObject(globalSettings)
                        .environmentObject(ratesVM)
                        .environmentObject(tariffVM)
                        .preferredColorScheme(.dark)
                } else {
                    SplashScreenView(isLoading: .constant(true))
                }
            }
            .task {
                do {
                    await ratesVM.setAgileProductFromAccountOrFallback(
                        globalSettings: globalSettings)
                    if !ratesVM.currentAgileCode.isEmpty {
                        await ratesVM.initializeProducts()
                    }
                    withAnimation(.easeOut(duration: 0.5)) {
                        isInitialized = true
                    }
                }
            }
        }
    }

    return PreviewWrapper()
}
