import SwiftUI

struct CardManagementView: View {
    @EnvironmentObject var globalSettings: GlobalSettingsManager
    @State private var editMode = EditMode.active
    @State private var selectedCard: CardConfig?
    @State private var refreshTrigger = false
    
    var body: some View {
        List {
            Section {
                ForEach($globalSettings.settings.cardSettings) { $cardConfig in
                    CardRowView(cardConfig: $cardConfig, onInfoTap: {
                        selectedCard = cardConfig
                    })
                }
                .onMove(perform: moveCards)
            } header: {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Drag to reorder cards", comment: "Instructions for reordering cards")
                        .font(.footnote)
                        .foregroundColor(.secondary)
                }
                .textCase(nil)
                .padding(.bottom, 8)
            }
        }
        .navigationTitle(LocalizedStringKey("Manage Cards"))
        .listStyle(.insetGrouped)
        .environment(\.editMode, $editMode)
        .safeAreaInset(edge: .bottom) {
            Color.clear.frame(height: 100)
        }
        .safeAreaInset(edge: .top) {
            Color.clear.frame(height: 20)
        }
        .sheet(item: $selectedCard) { config in
            if let definition = CardRegistry.shared.definition(for: config.cardType) {
                CardInfoSheet(definition: definition)
                    .environmentObject(globalSettings)
                    .environment(\.locale, globalSettings.locale)
                    .presentationDragIndicator(.visible)
            }
        }
        .id(refreshTrigger)
        .onChange(of: globalSettings.locale) { oldValue, newValue in
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
        HStack(spacing: 12) {
            // Card-specific icon with drag indicator
            HStack(spacing: 4) {
                Image(systemName: iconName(for: cardConfig.cardType))
                    .foregroundColor(.secondary)
                    .font(.system(size: 18))
                
                // Small drag indicator
                Image(systemName: "grip.horizontal")
                    .foregroundColor(.secondary.opacity(0.5))
                    .font(.system(size: 12))
            }
            .frame(width: 44)
            .contentShape(Rectangle())
            
            Text(LocalizedStringKey(getCardDisplayName(cardConfig.cardType)))
                .font(.body)
            
            Spacer()
            
            // Info button
            Button(action: onInfoTap) {
                Image(systemName: "info.circle")
                    .foregroundColor(.blue)
            }
            .buttonStyle(.plain)
            .padding(.trailing, 8)
            
            if cardConfig.isPurchased {
                Toggle(isOn: $cardConfig.isEnabled) {
                    Text("Enable card", comment: "Toggle to enable/disable a card")
                }
                .labelsHidden()
            } else {
                Button {
                    purchaseCard()
                } label: {
                    Text("Unlock", comment: "Button to unlock a premium card")
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .foregroundColor(.accentColor)
            }
        }
        .listRowSeparator(.hidden)
        .listRowInsets(EdgeInsets(top: 4, leading: 16, bottom: 4, trailing: 16))
        .padding(.vertical, 6)
        .background(Color.clear)
        .contentShape(Rectangle())
        .sensoryFeedback(.selection, trigger: cardConfig.sortOrder)
    }
    
    private func iconName(for cardType: CardType) -> String {
        switch cardType {
        case .currentRate:
            return "clock.fill"
        case .lowestUpcoming:
            return "arrow.down.circle.fill"
        case .highestUpcoming:
            return "arrow.up.circle.fill"
        case .averageUpcoming:
            return "chart.bar.fill"
        }
    }
    
    private func getCardDisplayName(_ cardType: CardType) -> String {
        if let definition = CardRegistry.shared.definition(for: cardType) {
            return definition.displayNameKey
        }
        return ""  // Fallback empty string if definition not found
    }
    
    private func purchaseCard() {
        // In a real app, this would integrate with StoreKit
        cardConfig.isPurchased = true
    }
}

struct CardInfoSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.locale) private var locale
    @EnvironmentObject var globalSettings: GlobalSettingsManager
    let definition: CardDefinition
    
    var body: some View {
        NavigationView {
            List {
                Section {
                    VStack(alignment: .leading, spacing: 16) {
                        Text(LocalizedStringKey(definition.displayNameKey))
                            .font(.title)
                            .padding(.bottom, 8)
                            .environment(\.locale, locale)
                        
                        Text(LocalizedStringKey(definition.descriptionKey))
                            .font(.body)
                            .environment(\.locale, locale)
                        
                        if definition.isPremium {
                            HStack {
                                Image(systemName: "star.fill")
                                    .foregroundColor(.yellow)
                                Text("Premium Feature", comment: "Label indicating a premium feature")
                                    .font(.headline)
                            }
                            .padding(.top, 8)
                        }
                    }
                    .padding(.horizontal, 20)
                    .padding(.vertical, 16)
                }
                .listRowBackground(Color.clear)
                .listRowInsets(EdgeInsets())
            }
            .listStyle(.plain)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button {
                        dismiss()
                    } label: {
                        Text("Done", comment: "Button to dismiss the info sheet")
                    }
                }
            }
        }
        .environment(\.locale, locale)
    }
} 