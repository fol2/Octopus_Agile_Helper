import AVKit
import OctopusHelperShared
import SwiftUI
import WebKit

struct CardManagementView: View {
    @EnvironmentObject var globalSettings: GlobalSettingsManager
    @State private var editMode = EditMode.active
    @State private var selectedCard: CardConfig?
    @State private var refreshTrigger = false
    @State private var isSaving = false
    @State private var saveError: Error?

    var body: some View {
        VStack(spacing: 0) {
            // Title with save indicator
            HStack {
                Text(LocalizedStringKey("Manage Cards"))
                    .font(Theme.mainFont())
                    .foregroundColor(Theme.mainTextColor)
                Spacer()
                if isSaving {
                    ProgressView()
                        .scaleEffect(0.7)
                        .tint(Theme.mainColor)
                }
            }
            .padding(.horizontal, 16)
            .padding(.top, 12)
            .padding(.bottom, 22)

            // Error message if present
            if let error = saveError {
                HStack {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundColor(.red)
                    Text("Error saving: \(error.localizedDescription)")
                        .font(Theme.subFont())
                        .foregroundColor(.red)
                    Spacer()
                }
                .padding(.horizontal, 16)
                .padding(.bottom, 8)
            }

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

            // Update the UI immediately
            globalSettings.settings.cardSettings = cards

            // Save in background
            Task {
                isSaving = true
                saveError = nil
                do {
                    try await globalSettings.saveSettingsAsync()
                } catch {
                    saveError = error
                    DebugLogger.debug("Error saving card order: \(error)", component: .stateChanges)
                }
                isSaving = false
            }
        }
    }
}

struct CardRowView: View {
    @Binding var cardConfig: CardConfig
    @Environment(\.editMode) private var editMode
    @EnvironmentObject var globalSettings: GlobalSettingsManager
    @ObservedObject private var refreshManager = CardRefreshManager.shared
    @State private var clockIconTrigger = Date()
    @State private var isSaving = false
    @State private var saveError: Error?
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

                    // Show the plan(s)
                    Text(
                        "Supported: \(definition.supportedPlans.map { $0.rawValue.capitalized }.joined(separator: ", "))"
                    )
                    .font(.caption)
                    .foregroundColor(Theme.secondaryTextColor)
                    .padding(.leading, 6)

                    // Toggle or 'Unlock' button with saving indicator
                    HStack(spacing: 4) {
                        if isSaving {
                            ProgressView()
                                .scaleEffect(0.5)
                                .tint(Theme.mainColor)
                        }

                        if cardConfig.isPurchased {
                            Toggle(
                                isOn: Binding(
                                    get: { cardConfig.isEnabled },
                                    set: { newValue in
                                        Task {
                                            await toggleCard(enabled: newValue)
                                        }
                                    }
                                )
                            ) {
                                EmptyView()
                            }
                            .labelsHidden()
                            .tint(Theme.secondaryColor)
                            .disabled(isSaving)
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
                            .disabled(isSaving)
                        }
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
            // Show error if present
            .overlay(alignment: .trailing) {
                if let error = saveError {
                    Text(error.localizedDescription)
                        .font(.caption)
                        .foregroundColor(.red)
                        .padding(4)
                        .background(Color.red.opacity(0.1))
                        .cornerRadius(4)
                        .transition(.opacity)
                }
            }
        }
    }

    private func toggleCard(enabled: Bool) async {
        isSaving = true
        saveError = nil

        do {
            // Create a new config with the updated state
            var updatedConfig = cardConfig
            updatedConfig.isEnabled = enabled

            // Find the index of this card in the settings
            if let index = globalSettings.settings.cardSettings.firstIndex(where: {
                $0.id == cardConfig.id
            }) {
                // Save first
                var updatedSettings = globalSettings.settings
                updatedSettings.cardSettings[index] = updatedConfig

                // Create a temporary GlobalSettings with the new card settings
                let tempSettings = GlobalSettings(
                    regionInput: updatedSettings.regionInput,
                    apiKey: updatedSettings.apiKey,
                    selectedLanguage: updatedSettings.selectedLanguage,
                    billingDay: updatedSettings.billingDay,
                    showRatesInPounds: updatedSettings.showRatesInPounds,
                    showRatesWithVAT: updatedSettings.showRatesWithVAT,
                    cardSettings: updatedSettings.cardSettings,
                    currentAgileCode: updatedSettings.currentAgileCode,
                    electricityMPAN: updatedSettings.electricityMPAN,
                    electricityMeterSerialNumber: updatedSettings.electricityMeterSerialNumber,
                    accountNumber: updatedSettings.accountNumber,
                    accountData: updatedSettings.accountData,
                    selectedTariffInterval: updatedSettings.selectedTariffInterval,
                    lastViewedTariffDates: updatedSettings.lastViewedTariffDates,
                    selectedComparisonInterval: updatedSettings.selectedComparisonInterval,
                    lastViewedComparisonDates: updatedSettings.lastViewedComparisonDates
                )

                // Try to save first
                try await globalSettings.saveSettingsAsync()

                // If save successful, update the UI
                await MainActor.run {
                    cardConfig = updatedConfig
                    globalSettings.settings = tempSettings
                }
            }
        } catch {
            saveError = error
            DebugLogger.debug("Error saving card state: \(error)", component: .stateChanges)
        }

        isSaving = false
    }

    private func purchaseCard() {
        // In a real app, integrate with StoreKit, etc.
        cardConfig.isPurchased = true
    }
}
