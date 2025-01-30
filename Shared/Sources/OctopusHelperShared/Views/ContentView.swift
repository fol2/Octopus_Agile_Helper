//
//  ContentView.swift
//  Octopus_Agile_Helper
//
//  Created by James To on 26/12/2024.
//

import Combine
import CoreData
import SwiftUI

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

public final class ContentViewModel: ObservableObject {
    var cancellables = Set<AnyCancellable>()
}

/// Simplified: we no longer use FetchStatusManager or CombinedFetchStatus
/// We'll do an inline aggregator if needed or just show each VM's fetchState.
public struct ContentView: View {
    @EnvironmentObject var globalTimer: GlobalTimer
    @EnvironmentObject var globalSettings: GlobalSettingsManager
    @EnvironmentObject var ratesVM: RatesViewModel
    @StateObject private var consumptionVM: ConsumptionViewModel
    @StateObject private var viewModel = ContentViewModel()
    let hasAgileCards: Bool

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
        // Initialize view models with a temporary GlobalSettingsManager
        // This will be replaced by the environment object when the view appears
        _consumptionVM = StateObject(
            wrappedValue: ConsumptionViewModel(globalSettingsManager: GlobalSettingsManager()))
        _viewModel = StateObject(wrappedValue: ContentViewModel())
    }

    public var body: some View {
        NavigationStack {
            ScrollView(.vertical, showsIndicators: true) {
                // The main content (cards)
                VStack(spacing: 0) {
                    let deps = CardDependencies.createDependencies(
                        ratesViewModel: ratesVM,
                        consumptionViewModel: consumptionVM,
                        globalTimer: globalTimer,
                        globalSettings: globalSettings
                    )

                    ForEach(sortedCardConfigs()) { config in
                        if config.isEnabled,
                            let definition = CardRegistry.shared.definition(for: config.cardType)
                        {
                            if config.isPurchased || !definition.isPremium {
                                definition.makeView(deps)
                            } else {
                                CardLockedView(definition: definition, config: config)
                                    .environment(\.locale, globalSettings.locale)
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
            .navigationTitle(LocalizedStringKey("Octomiser"))
            .navigationBarTitleDisplayMode(.large)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    HStack(spacing: 8) {
                        // If you want a single combined color, do a quick aggregator
                        Circle()
                            .fill(aggregateColor)
                            .frame(width: 8, height: 8)
                        NavigationLink {
                            SettingsView(didFinishEditing: {
                                Task {
                                    // Refresh rates data
                                    await ratesVM.setAgileProductFromAccountOrFallback(
                                        globalSettings: globalSettings)
                                    if !ratesVM.currentAgileCode.isEmpty {
                                        await ratesVM.initializeProducts()
                                    }
                                }
                            })
                            .environment(\.locale, globalSettings.locale)
                            .navigationTitle(LocalizedStringKey("Settings"))
                        } label: {
                            Image(systemName: "gear")
                                .foregroundColor(Theme.mainTextColor)
                                .font(Theme.secondaryFont())
                        }
                    }
                }

                // Principal => inline title, only if isCollapsed == true
                ToolbarItem(placement: .principal) {
                    if isCollapsed {
                        InlineCenteredTitle()
                            .transition(.opacity)
                            .animation(.easeInOut(duration: 0.3), value: isCollapsed)
                    }
                }
            }
            .refreshable {
                await withTaskGroup(of: Void.self) { group in
                    group.addTask {
                        await ratesVM.refreshRates(
                            productCode: ratesVM.currentAgileCode, force: true)
                    }
                    group.addTask { await consumptionVM.refreshDataFromAPI(force: true) }
                }
            }
            // Detect offset changes => check if we collapsed large title
            .onPreferenceChange(ScrollOffsetPreferenceKey.self) { offset in
                withAnimation(.easeInOut(duration: 0.2)) {
                    isCollapsed = (offset < -50)
                }
            }
            // Listen for language changes => force re-render
            .environment(\.locale, globalSettings.locale)
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
                    }
                }
            }
            .onAppear {
                // Update ConsumptionViewModel with the environment GlobalSettingsManager
                consumptionVM.updateGlobalSettingsManager(globalSettings)
                Task { await consumptionVM.loadData() }
            }
            // Track all settings changes that affect consumption data loading
            .onChange(of: [
                globalSettings.settings.accountData != nil,
                globalSettings.settings.apiKey.isEmpty,
                globalSettings.settings.electricityMPAN != nil,
                globalSettings.settings.electricityMeterSerialNumber != nil,
            ]) { oldValue, newValue in
                print("🔄 ContentView: Settings changed that affect consumption")
                print("  - API Key present: \(!globalSettings.settings.apiKey.isEmpty)")
                print("  - MPAN present: \(globalSettings.settings.electricityMPAN != nil)")
                print(
                    "  - Serial present: \(globalSettings.settings.electricityMeterSerialNumber != nil)"
                )
                print("  - Account data present: \(globalSettings.settings.accountData != nil)")

                // Only load data if we have all required settings
                if !globalSettings.settings.apiKey.isEmpty
                    && globalSettings.settings.electricityMPAN != nil
                    && globalSettings.settings.electricityMeterSerialNumber != nil
                {
                    Task {
                        await consumptionVM.loadData()
                    }
                }
            }
        }
    }

    // MARK: - Helper Methods
    private var aggregateColor: Color {
        // If no API key/account info, only consider rates state
        let hasAccountInfo =
            !globalSettings.settings.apiKey.isEmpty
            && globalSettings.settings.electricityMPAN != nil
            && globalSettings.settings.electricityMeterSerialNumber != nil

        switch (ratesVM.fetchState, consumptionVM.fetchState) {
        case (.failure(_), _),
            (_, .failure(_)) where hasAccountInfo:
            return .red
        case (.loading, _),
            (_, .loading) where hasAccountInfo:
            return .blue
        case (.partial, _),
            (_, .partial) where hasAccountInfo:
            return .orange
        case (.success, _) where !hasAccountInfo:
            // Only check rates success if no account info
            return .green
        case (.success, .success) where hasAccountInfo:
            // Check both when account info exists
            return .green
        default:
            return .clear
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
            Text("Octomiser")
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
