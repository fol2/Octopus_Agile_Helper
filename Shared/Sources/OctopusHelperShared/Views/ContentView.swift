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

// MARK: - ContentView

public struct ContentView: View {
    @EnvironmentObject var globalTimer: GlobalTimer
    @EnvironmentObject var globalSettings: GlobalSettingsManager
    @StateObject private var ratesViewModel: RatesViewModel

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
        return currentYear > 2024 ? "© Eugnel 2024-\(currentYear)" : "© Eugnel 2024"
    }

    public init() {
        let tempTimer = GlobalTimer()
        _ratesViewModel = StateObject(wrappedValue: RatesViewModel(globalTimer: tempTimer))
    }

    public var body: some View {
        NavigationView {
            ScrollView(.vertical, showsIndicators: true) {

                // The main content (cards)
                VStack(spacing: 0) {
                    ForEach(sortedCardConfigs()) { config in
                        if config.isEnabled {
                            if let definition = CardRegistry.shared.definition(for: config.cardType)
                            {
                                if config.isPurchased || !definition.isPremium {
                                    definition.makeView(ratesViewModel)
                                        .environment(\.locale, globalSettings.locale)
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
                await ratesViewModel.refreshRates(force: true)
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
                        // If the status is .none, skip the indicator entirely
                        // => gear slides smoothly to the left
                        if ratesViewModel.fetchStatus != .none {
                            StatusIndicatorView(status: ratesViewModel.fetchStatus)
                                .transition(.opacity)
                                .animation(
                                    .easeInOut(duration: 0.3), value: ratesViewModel.fetchStatus)
                        }

                        // The gear always here
                        NavigationLink(
                            destination: SettingsView()
                                .environment(\.locale, globalSettings.locale)
                        ) {
                            Image(systemName: "gear")
                                .foregroundColor(Theme.secondaryTextColor)
                                .font(Theme.secondaryFont())
                        }
                    }
                    .animation(.easeInOut(duration: 0.3), value: ratesViewModel.fetchStatus)
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
        .onChange(of: globalSettings.locale) { _, _ in
            // Let individual cards handle their own refresh
        }
        // Scene phase changes
        .onChange(of: scenePhase) { oldPhase, newPhase in
            if newPhase == .active {
                Task {
                    await ratesViewModel.loadRates()
                }
                CardRefreshManager.shared.notifyAppBecameActive()
            }
        }
        // Timer for daily 16:00 check
        .onReceive(contentTimer) { _ in
            let calendar = Calendar.current
            let now = Date()
            let hour = calendar.component(.hour, from: now)
            let minute = calendar.component(.minute, from: now)
            let second = calendar.component(.second, from: now)

            // If it's exactly 16:00:00 local, we do a coverage check
            if hour == 16, minute == 0, second == 0 {
                Task {
                    await ratesViewModel.loadRates()
                }
            }
        }
        // Attempt to load data
        .task {
            await ratesViewModel.loadRates()
        }
        // Update timer when view appears
        .onAppear {
            ratesViewModel.updateTimer(globalTimer)
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

// MARK: - StatusIndicatorView

/// Shows small coloured dot + text for each fetchStatus
struct StatusIndicatorView: View {
    let status: FetchStatus

    var body: some View {
        let (dotColor, textKey) = statusDetails(status)

        HStack(spacing: 4) {
            Circle()
                .fill(dotColor)
                .frame(width: 8, height: 8)
            Text(textKey)
                .font(Theme.subFont())
                .foregroundColor(Theme.secondaryTextColor)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(Theme.secondaryBackground)
        .cornerRadius(8)
    }

    private func statusDetails(_ status: FetchStatus) -> (Color, LocalizedStringKey) {
        switch status {
        case .none:
            return (.clear, "")
        case .fetching:
            return (.green, LocalizedStringKey("StatusIndicator.Fetching"))
        case .done:
            return (.green, LocalizedStringKey("StatusIndicator.Done"))
        case .failed:
            return (.red, LocalizedStringKey("StatusIndicator.Failed"))
        case .pending:
            return (.blue, LocalizedStringKey("StatusIndicator.Pending"))
        }
    }
}

#Preview {
    ContentView()
        .environmentObject(GlobalTimer())
        .environmentObject(GlobalSettingsManager())
}
