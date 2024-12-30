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
                    Text("Drag to reorder cards")
                        .font(Theme.subFont())
                        .foregroundColor(Theme.secondaryTextColor)
                }
                .textCase(nil)
                .padding(.bottom, 8)
            }
        }
        .navigationTitle(LocalizedStringKey("Manage Cards"))
        .listStyle(.insetGrouped)
        .scrollContentBackground(.hidden)
        .background(Theme.mainBackground)
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
                if let definition = CardRegistry.shared.definition(for: cardConfig.cardType) {
                    Image(systemName: definition.iconName)
                        .foregroundColor(Theme.icon)
                        .font(Theme.subFont())
                }
                
                // Small drag indicator
                Image(systemName: "grip.horizontal")
                    .foregroundColor(Theme.secondaryTextColor.opacity(0.5))
                    .font(Theme.subFont())
            }
            .frame(width: 44)
            .contentShape(Rectangle())
            
            Text(LocalizedStringKey(getCardDisplayName(cardConfig.cardType)))
                .font(Theme.secondaryFont())
                .foregroundColor(Theme.mainTextColor)
            
            Spacer()
            
            // Info button
            Button(action: onInfoTap) {
                Image(systemName: "info.circle")
                    .foregroundColor(Theme.secondaryTextColor)
                    .font(Theme.subFont())
            }
            .buttonStyle(.plain)
            .padding(.trailing, 8)
            
            if cardConfig.isPurchased {
                Toggle(isOn: $cardConfig.isEnabled) {
                    Text("Enable card")
                }
                .labelsHidden()
                .tint(Theme.secondaryColor)
            } else {
                Button {
                    purchaseCard()
                } label: {
                    Text("Unlock")
                        .font(Theme.secondaryFont())
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .tint(Theme.mainColor)
            }
        }
        .listRowSeparator(.hidden)
        .listRowBackground(Theme.secondaryBackground)
        .listRowInsets(EdgeInsets(top: 4, leading: 16, bottom: 4, trailing: 16))
        .padding(.vertical, 6)
        .contentShape(Rectangle())
        .sensoryFeedback(.selection, trigger: cardConfig.sortOrder)
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
                            .font(Theme.mainFont())
                            .foregroundColor(Theme.mainTextColor)
                            .padding(.bottom, 8)
                        
                        Text(LocalizedStringKey(definition.descriptionKey))
                            .font(Theme.secondaryFont())
                            .foregroundColor(Theme.secondaryTextColor)
                        
                        if definition.isPremium {
                            HStack {
                                Image(systemName: "star.fill")
                                    .foregroundColor(.yellow)
                                    .font(Theme.subFont())
                                Text("Premium Feature")
                                    .font(Theme.titleFont())
                                    .foregroundColor(Theme.mainTextColor)
                            }
                            .padding(.top, 8)
                        }
                    }
                    .padding(.horizontal, 20)
                    .padding(.vertical, 16)
                }
                .listRowBackground(Theme.secondaryBackground)
                .listRowInsets(EdgeInsets())
            }
            .listStyle(.plain)
            .scrollContentBackground(.hidden)
            .background(Theme.mainBackground)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button {
                        dismiss()
                    } label: {
                        Text("Done")
                            .font(Theme.secondaryFont())
                            .foregroundColor(Theme.mainColor)
                    }
                }
            }
        }
        .environment(\.locale, locale)
    }
} 