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
    }

    private func moveCards(from source: IndexSet, to destination: Int) {
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
    }
}

struct CardRowView: View {
    @Binding var cardConfig: CardConfig
    @Environment(\.editMode) private var editMode
    @EnvironmentObject var globalSettings: GlobalSettingsManager
    let onInfoTap: () -> Void

    var body: some View {
        if let definition = CardRegistry.shared.definition(for: cardConfig.cardType) {
            ZStack {
                // Row background
                Theme.secondaryBackground
                    .cornerRadius(12)

                HStack(spacing: 12) {
                    // Leading icon
                    Image(systemName: definition.iconName)
                        .foregroundColor(Theme.icon)
                        .font(Theme.titleFont())
                        .padding(.leading, 12)

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
                        Toggle(isOn: $cardConfig.isEnabled) {
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
        }
    }

    private func purchaseCard() {
        // In a real app, integrate with StoreKit, etc.
        cardConfig.isPurchased = true
    }
}
