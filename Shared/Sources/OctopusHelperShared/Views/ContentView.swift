//
//  ContentView.swift
//  Octopus_Agile_Helper
//
//  Created by James To on 26/12/2024.
//

import Combine
import CoreData
import OctopusHelperShared
import SwiftUI

// MARK: - Scroll Offset Key

/// A preference key to track the vertical offset in a ScrollView.
struct ScrollOffsetPreferenceKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = nextValue()
    }
}

/// A small invisible view to capture the .minY offset at the top.
private struct OffsetTrackingView: View {
    var body: some View {
        GeometryReader { geo in
            Color.clear.preference(
                key: ScrollOffsetPreferenceKey.self,
                value: geo.frame(in: .named("scrollArea")).minY
            )
        }
        .frame(height: 0)
    }
}

// MARK: - Fetch Status Manager
final class FetchStatusManager: ObservableObject {
    @Published private(set) var combinedStatus: CombinedFetchStatus = .none
    
    // Track individual statuses
    private var ratesStatus: FetchStatus = .none
    private var consumptionStatus: FetchStatus = .none
    private var clearDoneWorkItem: DispatchWorkItem?
    
    func update(ratesStatus: FetchStatus? = nil, consumptionStatus: FetchStatus? = nil) {
        if let rStatus = ratesStatus { self.ratesStatus = rStatus }
        if let cStatus = consumptionStatus { self.consumptionStatus = cStatus }
        
        // Compute combined status
        let newStatus = computeCombinedStatus()
        
        // Animate status change if needed
        withAnimation(.easeInOut(duration: 0.3)) {
            self.combinedStatus = newStatus
        }
        
        // If status is .done, schedule it to be cleared after a delay
        if case .done = newStatus {
            clearDoneWorkItem?.cancel()
            let workItem = DispatchWorkItem { [weak self] in
                withAnimation {
                    if case .done = self?.combinedStatus {
                        self?.combinedStatus = .none
                    }
                }
            }
            clearDoneWorkItem = workItem
            DispatchQueue.main.asyncAfter(deadline: .now() + 3.0, execute: workItem)
        }
    }
    
    private func computeCombinedStatus() -> CombinedFetchStatus {
        var fetchingSources: Set<String> = []
        var pendingSources: Set<String> = []
        var doneSources: Set<String> = []
        var failedSource: String?
        
        // Check rates status
        switch ratesStatus {
        case .fetching: fetchingSources.insert("Rates")
        case .pending: pendingSources.insert("Rates")
        case .failed: failedSource = "Rates"
        case .done: doneSources.insert("Rates")
        case .none: break
        }
        
        // Check consumption status
        switch consumptionStatus {
        case .fetching: fetchingSources.insert("Consumption")
        case .pending: pendingSources.insert("Consumption")
        case .failed: failedSource = "Consumption"
        case .done: doneSources.insert("Consumption")
        case .none: break
        }
        
        // Determine combined state
        if let failed = failedSource {
            return .failed(source: failed, error: nil)
        }
        if !fetchingSources.isEmpty {
            return .fetching(sources: fetchingSources)
        }
        if !pendingSources.isEmpty {
            return .pending(sources: pendingSources)
        }
        if !doneSources.isEmpty {
            return .done(source: doneSources.first ?? "Unknown")
        }
        return .none
    }
}

// MARK: - Combined Status Indicator View
struct CombinedStatusIndicatorView: View {
    let status: CombinedFetchStatus
    
    var body: some View {
        HStack(spacing: 4) {
            Circle()
                .fill(status.color)
                .frame(width: 8, height: 8)
            Text(status.displayText)
                .font(Theme.subFont())
                .foregroundColor(Theme.secondaryTextColor)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(Theme.secondaryBackground)
        .cornerRadius(8)
    }
}

// MARK: - ContentView

public final class ContentViewModel: ObservableObject {
    var cancellables = Set<AnyCancellable>()
}

public struct ContentView: View {
    @EnvironmentObject var globalTimer: GlobalTimer
    @EnvironmentObject var globalSettings: GlobalSettingsManager
    @EnvironmentObject var ratesVM: RatesViewModel
    @StateObject private var consumptionVM = ConsumptionViewModel()
    @StateObject private var statusManager = FetchStatusManager()
    @StateObject private var viewModel = ContentViewModel()
    let hasAgileCards: Bool  // Now passed in from AppMain

    // Store each card's VM in a dictionary keyed by `CardType`
    @State private var cardViewModels: [CardType: Any] = [:]  // For other cards only

    @Environment(\.scenePhase) private var scenePhase

    // Track if large title is collapsed enough
    @State private var isCollapsed = false

    // Timer for 16:00 check
    private let contentTimer =
        Timer
        .publish(every: 1, on: .main, in: .common)
        .autoconnect()

    // Dynamic copyright text
    private var copyrightText: String {
        let currentYear = Calendar.current.component(.year, from: Date())
        return currentYear > 2024 ? " Eugnel 2024-\(currentYear)" : " Eugnel 2024"
   }

    public init(hasAgileCards: Bool) {
        self.hasAgileCards = hasAgileCards
        // Initialize view models
        _consumptionVM = StateObject(wrappedValue: ConsumptionViewModel())
        _statusManager = StateObject(wrappedValue: FetchStatusManager())
        _viewModel = StateObject(wrappedValue: ContentViewModel())
    }

    public var body: some View {
        NavigationStack {
            ScrollView(.vertical, showsIndicators: true) {

                // The main content (cards)
                VStack(spacing: 0) {
                    ForEach(sortedCardConfigs()) { config in
                        if config.isEnabled {
                            if let definition = CardRegistry.shared.definition(for: config.cardType)
                            {
                                if config.isPurchased || !definition.isPremium {
                                    if config.cardType == .currentRate || config.cardType == .lowestUpcoming || config.cardType == .highestUpcoming || config.cardType == .averageUpcoming || config.cardType == .interactiveChart {
                                        // Use the same ratesVM for all rate-related cards
                                        definition.makeView(ratesVM)
                                    } else if let vm = cardViewModels[config.cardType] {
                                        definition.makeView(vm)
                                    } else {
                                        Text("No VM found")
                                            .foregroundColor(.red)
                                    }
                                } else {
                                    CardLockedView(definition: definition, config: config)
                                        .environment(\.locale, globalSettings.locale)
                                }
                            }
                        }
                    }
                }
                .padding(.top, 22)  // Add spacing between title and first card

                // Offset tracking for title collapse
                OffsetTrackingView()
                    .padding(.vertical, 4)  // Reduced from default padding

                // Copyright notice
                Text(copyrightText)
                    .font(.footnote)
                    .foregroundColor(Theme.secondaryTextColor)
                    .padding(.vertical, 8)  // Reduced from default padding to 8 points
            }
            .background(Theme.mainBackground)
            .scrollContentBackground(.hidden)
            .coordinateSpace(name: "scrollArea")  // for offset detection
            .navigationTitle(LocalizedStringKey("Octopus Agile"))
            .navigationBarTitleDisplayMode(.large)

            // Pull-to-refresh
            .refreshable {
                await withTaskGroup(of: Void.self) { group in
                    group.addTask { await ratesVM.refreshRates(productCode: ratesVM.currentAgileCode, force: true) }
                    group.addTask { await consumptionVM.refreshDataFromAPI(force: true) }
                }
            }
            // Detect offset changes => check if we collapsed large title
            .onPreferenceChange(ScrollOffsetPreferenceKey.self) { offset in
                withAnimation(.easeInOut(duration: 0.2)) {
                    isCollapsed = (offset < -50)
                }
            }
            .toolbar {
                // 1) Trailing => gear + optional status
                ToolbarItem(placement: .navigationBarTrailing) {
                    // We animate the HStack so the gear doesn't jump
                    HStack(spacing: 8) {
                        if statusManager.combinedStatus != .none {
                            CombinedStatusIndicatorView(status: statusManager.combinedStatus)
                                .transition(.opacity)
                        }
                        NavigationLink(
                            destination: SettingsView(didFinishEditing: {
                                // This runs when user returns from Settings
                                Task {
                                    await ratesVM.setAgileProductFromAccountOrFallback(
                                        globalSettings: globalSettings
                                    )
                                    if !ratesVM.currentAgileCode.isEmpty {
                                        await ratesVM.initializeProducts()
                                    }
                                }
                            })
                            .environment(\.locale, globalSettings.locale)
                        ) {
                            Image(systemName: "gear")
                                .foregroundColor(Theme.mainTextColor)
                                .font(Theme.secondaryFont())
                        }
                    }
                }

                // 2) Principal => inline title, only if isCollapsed == true
                ToolbarItem(placement: .principal) {
                    if isCollapsed {
                        InlineCenteredTitle()
                            .transition(.opacity)
                            .animation(.easeInOut(duration: 0.3), value: isCollapsed)
                    }
                }
            }
        }
        // Listen for language changes => force re-render
        .environment(\.locale, globalSettings.locale)
        // .onChange is optional if you want to reload or re-localise
        //.onChange(of: globalSettings.locale) { _, _ in ... }
        .onChange(of: scenePhase) { phase in
            if phase == .active {
                Task {
                    await consumptionVM.loadData()
                }
                CardRefreshManager.shared.notifyAppBecameActive()
            }
        }
        .onReceive(contentTimer) { _ in
            let calendar = Calendar.current
            let now = Date()
            let hour = calendar.component(.hour, from: now)
            let minute = calendar.component(.minute, from: now)
            let second = calendar.component(.second, from: now)

            // Check rates at 16:00
            if hour == 16, minute == 0, second == 0 {
                Task {
                    if hasAgileCards {
                        await ratesVM.initializeProducts()
                    }
                }
            }
            
            // Check consumption at 12:00 (noon)
            // This is when we start expecting previous day's data
            if hour == 12, minute == 0, second == 0 {
                Task {
                    await consumptionVM.loadData()
                    // If pending after noon check, trigger refresh
                    if consumptionVM.fetchStatus == .pending {
                        await consumptionVM.refreshDataFromAPI(force: false)
                    }
                }
            }
        }
        // Called once when the view appears to create all card view models
        .onAppear {
            setupStatusObservers()

            // 2) Create VMs for non-rate cards only
            for cardType in CardType.allCases {
                if cardType == .electricityConsumption {  // Only create VM for non-rate cards
                    if cardViewModels[cardType] == nil {
                        let newVM = CardRegistry.shared.createViewModel(for: cardType)
                        cardViewModels[cardType] = newVM
                    }
                }
            }
        }
        .task {
            await consumptionVM.loadData()
        }
    }

    private func setupStatusObservers() {
        ratesVM.$fetchStatus
            .sink { [weak statusManager] status in
                statusManager?.update(ratesStatus: convertToLocalFetchStatus(status))
            }
            .store(in: &viewModel.cancellables)
            
        consumptionVM.$fetchStatus
            .sink { [weak statusManager] status in
                statusManager?.update(consumptionStatus: status)
            }
            .store(in: &viewModel.cancellables)
    }

    // Provide a helper to convert ProductFetchStatus -> local FetchStatus
    private func convertToLocalFetchStatus(_ pfs: ProductFetchStatus) -> FetchStatus {
        // minimal logic
        switch pfs {
        case .none: return .none
        case .fetching: return .fetching
        case .done: return .done
        case .pending: return .pending
        case .failed(_): return .failed
        }
    }

    /// Sort user's card configs by sortOrder
    private func sortedCardConfigs() -> [CardConfig] {
        globalSettings.settings.cardSettings.sorted { $0.sortOrder < $1.sortOrder }
    }
}

// MARK: - Inline Title

/// Centered inline title that appears only when large title is collapsed
private struct InlineCenteredTitle: View {
    var body: some View {
        HStack {
            Spacer()
            Text("Octopus Agile")
                .font(Theme.titleFont())
                .foregroundColor(Theme.mainTextColor)
            Spacer()
        }
    }
}

// MARK: - CardLockedView

struct CardLockedView: View {
    let definition: CardDefinition
    let config: CardConfig

    var body: some View {
        VStack(spacing: 8) {
            HStack {
                Image(systemName: "lock.fill")
                    .foregroundColor(Theme.icon)
                Text(LocalizedStringKey("\(definition.displayNameKey) (Locked)"))
                    .font(Theme.titleFont())
                    .foregroundColor(Theme.mainTextColor)
            }

            Text(LocalizedStringKey(definition.descriptionKey))
                .font(Theme.subFont())
                .foregroundColor(Theme.secondaryTextColor)

            Button {
                // Hook into your IAP or purchasing logic
            } label: {
                Text("Unlock")
                    .font(Theme.secondaryFont())
            }
            .buttonStyle(.borderedProminent)
            .tint(Theme.mainColor)
        }
        .rateCardStyle()
    }
}