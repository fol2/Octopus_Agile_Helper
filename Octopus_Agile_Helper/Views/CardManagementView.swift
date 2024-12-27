import SwiftUI

struct CardManagementView: View {
    @EnvironmentObject var globalSettings: GlobalSettingsManager
    @State private var editMode = EditMode.active
    
    var body: some View {
        List {
            Section {
                ForEach($globalSettings.settings.cardSettings) { $cardConfig in
                    CardRowView(cardConfig: $cardConfig)
                }
                .onMove(perform: moveCards)
            } header: {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Drag to reorder cards")
                        .font(.footnote)
                        .foregroundColor(.secondary)
                }
                .textCase(nil)
                .padding(.bottom, 8)
            }
        }
        .navigationTitle("Manage Cards")
        .listStyle(.insetGrouped)
        // Use @State editMode instead of constant
        .environment(\.editMode, $editMode)
        // Add extra bleeding areas for dragging
        .safeAreaInset(edge: .bottom) {
            Color.clear.frame(height: 100)
        }
        .safeAreaInset(edge: .top) {
            Color.clear.frame(height: 20)
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
            
            // Reset edit mode briefly to refresh drag state
            editMode = .inactive
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                editMode = .active
            }
        }
    }
}

struct CardRowView: View {
    @Binding var cardConfig: CardConfig
    @Environment(\.editMode) private var editMode
    
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
            
            Text(formatCardTypeName(cardConfig.cardType.rawValue))
                .font(.body)
            
            Spacer()
            
            if cardConfig.isPurchased {
                Toggle("Enabled", isOn: $cardConfig.isEnabled)
                    .labelsHidden()
            } else {
                Button("Unlock") {
                    purchaseCard()
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
        // Make the entire row draggable
        .contentShape(Rectangle())
        // Add haptic feedback for drag
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
    
    private func formatCardTypeName(_ name: String) -> String {
        name.replacingOccurrences(of: "([A-Z])", with: " $1", options: [.regularExpression])
            .trimmingCharacters(in: .whitespaces)
            .capitalized
    }
    
    private func purchaseCard() {
        // In a real app, this would integrate with StoreKit
        cardConfig.isPurchased = true
    }
} 