import AVKit
import OctopusHelperShared
import SwiftUI
import WebKit

struct CardManagementView: View {
    @EnvironmentObject var globalSettings: GlobalSettingsManager
    @State private var editMode = EditMode.active
    @State private var selectedCard: CardConfig?
    @State private var refreshTrigger = false

    var body: some View {
        VStack(spacing: 0) {
            // Title
            HStack {
                Text(LocalizedStringKey("Manage Cards"))
                    .font(Theme.mainFont())
                    .foregroundColor(Theme.mainTextColor)
                Spacer()
            }
            .padding(.horizontal, 16)
            .padding(.top, 12)
            .padding(.bottom, 22)

            // Instruction text
            HStack {
                Text(LocalizedStringKey("Drag to reorder cards"))
                    .font(Theme.subFont())
                    .foregroundColor(Theme.secondaryTextColor)
                Spacer()
            }
            .padding(.horizontal, 16)
            .padding(.top, 4)

            // List of cards
            List {
                ForEach($globalSettings.settings.cardSettings, id: \.id) { $cardConfig in
                    CardRowView(
                        cardConfig: $cardConfig,
                        onInfoTap: {
                            selectedCard = cardConfig
                        }
                    )
                    .listRowInsets(EdgeInsets())
                    .listRowSeparator(.hidden)
                    .listRowBackground(Color.clear)
                }
                .onMove(perform: moveCards)
            }
            .listStyle(.plain)
        }
        .background(Theme.mainBackground.ignoresSafeArea())
        .environment(\.editMode, $editMode)
        .sheet(item: $selectedCard) { config in
            if let definition = CardRegistry.shared.definition(for: config.cardType) {
                InfoSheet(viewModel: InfoSheetViewModel(from: definition))
                    .environmentObject(globalSettings)
                    .environment(\.locale, globalSettings.locale)
                    .presentationDragIndicator(.visible)
            }
        }
        .id(refreshTrigger)
        .onChange(of: globalSettings.locale) { _, _ in
            refreshTrigger.toggle()
        }
        .onAppear {
            DebugLogger.debug("🔄 CardManagementView appeared", component: .cardManagement)
            DebugLogger.enableLogging(for: .cardManagement)
            // Log initial card states
            DebugLogger.debug("📊 Initial card states:", component: .cardManagement)
            for card in globalSettings.settings.cardSettings {
                DebugLogger.debug(
                    "  • \(card.cardType): enabled=\(card.isEnabled), purchased=\(card.isPurchased)",
                    component: .cardManagement)
            }
        }
        .onChange(of: globalSettings.settings.cardSettings) { oldValue, newValue in
            DebugLogger.debug("🔄 Card settings changed", component: .cardManagement)
            DebugLogger.debug("📊 Previous card states:", component: .cardManagement)
            for card in oldValue {
                DebugLogger.debug(
                    "  • \(card.cardType): enabled=\(card.isEnabled), purchased=\(card.isPurchased)",
                    component: .cardManagement)
            }
            DebugLogger.debug("📊 New card states:", component: .cardManagement)
            for card in newValue {
                DebugLogger.debug(
                    "  • \(card.cardType): enabled=\(card.isEnabled), purchased=\(card.isPurchased)",
                    component: .cardManagement)
            }
        }
    }

    private func moveCards(from source: IndexSet, to destination: Int) {
        DebugLogger.debug(
            "🔄 Moving cards from \(source) to \(destination)", component: .cardManagement)
        withAnimation {
            var cards = globalSettings.settings.cardSettings
            cards.move(fromOffsets: source, toOffset: destination)

            // Update sort order
            for (index, _) in cards.enumerated() {
                cards[index].sortOrder = index + 1
            }

            globalSettings.settings.cardSettings = cards
            globalSettings.saveSettings()
        }
        DebugLogger.debug("✅ Card move completed", component: .cardManagement)
    }
}

struct CardRowView: View {
    @Binding var cardConfig: CardConfig
    @Environment(\.editMode) private var editMode
    @EnvironmentObject var globalSettings: GlobalSettingsManager
    @ObservedObject private var refreshManager = CardRefreshManager.shared
    @State private var clockIconTrigger = Date()
    let onInfoTap: () -> Void

    var body: some View {
        if let definition = CardRegistry.shared.definition(for: cardConfig.cardType) {
            ZStack {
                // Row background
                Theme.secondaryBackground
                    .cornerRadius(12)

                HStack(spacing: 12) {
                    // Leading icon
                    if cardConfig.cardType == .currentRate {
                        // Use our custom clock icon
                        Image(ClockModel.iconName(for: clockIconTrigger))
                            .renderingMode(.template)
                            .resizable()
                            .scaledToFit()
                            .frame(width: 20, height: 20)
                            .foregroundColor(Theme.icon)
                            .padding(.leading, 12)
                    } else {
                        Image(systemName: definition.iconName)
                            .foregroundColor(Theme.icon)
                            .font(Theme.titleFont())
                            .padding(.leading, 12)
                    }

                    // Card name
                    Text(LocalizedStringKey(definition.displayNameKey))
                        .font(Theme.secondaryFont())
                        .foregroundColor(Theme.mainTextColor)
                        .textCase(.none)

                    Spacer()

                    // Info button
                    Button(action: onInfoTap) {
                        Image(systemName: "info.circle")
                            .foregroundColor(Theme.secondaryTextColor)
                            .font(Theme.subFont())
                    }
                    .buttonStyle(.plain)

                    // Toggle or 'Unlock' button
                    if cardConfig.isPurchased {
                        Toggle(
                            isOn: Binding(
                                get: { cardConfig.isEnabled },
                                set: { newValue in
                                    DebugLogger.debug(
                                        "🔄 Card toggle state change for \(cardConfig.cardType): \(cardConfig.isEnabled) -> \(newValue)",
                                        component: .cardManagement)
                                    cardConfig.isEnabled = newValue
                                    // Log the current state of all cards after toggle
                                    let allCards = globalSettings.settings.cardSettings
                                    DebugLogger.debug(
                                        "📊 Current card states after toggle:",
                                        component: .cardManagement)
                                    for card in allCards {
                                        DebugLogger.debug(
                                            "  • \(card.cardType): enabled=\(card.isEnabled), purchased=\(card.isPurchased)",
                                            component: .cardManagement)
                                    }
                                }
                            )
                        ) {
                            EmptyView()
                        }
                        .labelsHidden()
                        .tint(Theme.secondaryColor)
                    } else {
                        Button {
                            purchaseCard()
                        } label: {
                            Text(LocalizedStringKey("Unlock"))
                                .font(Theme.secondaryFont())
                                .textCase(.none)
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                        .tint(Theme.mainColor)
                    }
                }
                .padding(.vertical, 10)
            }
            .padding(.vertical, 4)
            .padding(.horizontal, 16)
            .contentShape(Rectangle())
            .sensoryFeedback(.selection, trigger: cardConfig.sortOrder)
            .onReceive(refreshManager.$halfHourTick) { tickTime in
                guard tickTime != nil else { return }
                clockIconTrigger = Date()
            }
            .onReceive(refreshManager.$sceneActiveTick) { _ in
                clockIconTrigger = Date()
            }
            .onAppear {
                DebugLogger.debug(
                    "👁️ Card row appeared for \(cardConfig.cardType): enabled=\(cardConfig.isEnabled), purchased=\(cardConfig.isPurchased), thread=\(Thread.current.description)",
                    component: .cardManagement)
            }
            .onDisappear {
                DebugLogger.debug(
                    "👋 Card row disappeared for \(cardConfig.cardType)", component: .cardManagement)
            }
            .onChange(of: cardConfig.isEnabled) { oldValue, newValue in
                DebugLogger.debug(
                    "🔄 Card \(cardConfig.cardType) enabled state changed: \(oldValue) -> \(newValue), thread=\(Thread.current.description)",
                    component: .cardManagement)
            }
            .task {
                DebugLogger.debug(
                    "🔄 Card row task started for \(cardConfig.cardType)", component: .cardManagement
                )
            }
        }
    }

    private func purchaseCard() {
        DebugLogger.debug("💳 Purchasing card \(cardConfig.cardType)", component: .cardManagement)
        cardConfig.isPurchased = true
        DebugLogger.debug(
            "✅ Card \(cardConfig.cardType) purchased successfully", component: .cardManagement)
    }
}
