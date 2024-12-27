//
//  ContentView.swift
//  Octopus_Agile_Helper
//
//  Created by James To on 26/12/2024.
//

import SwiftUI
import CoreData
import UIKit

struct ContentView: View {
    @EnvironmentObject var globalTimer: GlobalTimer
    @EnvironmentObject var globalSettings: GlobalSettingsManager
    @StateObject private var ratesViewModel: RatesViewModel
    @Environment(\.colorScheme) var colorScheme
    
    init() {
        let tempTimer = GlobalTimer()
        _ratesViewModel = StateObject(wrappedValue: RatesViewModel(globalTimer: tempTimer))
    }
    
    var body: some View {
        NavigationView {
            ScrollView {
                VStack(spacing: 0) {
                    ForEach(sortedCardConfigs()) { config in
                        if config.isEnabled {
                            if let definition = CardRegistry.shared.definition(for: config.cardType) {
                                if config.isPurchased || !definition.isPremium {
                                    definition.makeView(ratesViewModel)
                                } else {
                                    CardLockedView(definition: definition, config: config)
                                }
                            }
                        }
                    }
                }
                .padding(.vertical)
            }
            .navigationTitle(LocalizedStringKey("Octopus Agile"))
            .refreshable {
                await ratesViewModel.refreshRates(force: true)
            }
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    NavigationLink(destination: SettingsView()) {
                        Image(systemName: "gear")
                            .foregroundColor(.primary)
                    }
                }
            }
        }
        .task {
            await ratesViewModel.loadRates()
        }
        .onAppear {
            ratesViewModel.updateTimer(globalTimer)
        }
    }
    
    private func sortedCardConfigs() -> [CardConfig] {
        globalSettings.settings.cardSettings.sorted { $0.sortOrder < $1.sortOrder }
    }
}

struct CardLockedView: View {
    let definition: CardDefinition
    let config: CardConfig
    
    var body: some View {
        VStack(spacing: 8) {
            HStack {
                Image(systemName: "lock.fill")
                Text(LocalizedStringKey("\(definition.displayNameKey) (Locked)"))
            }
            .font(.headline)
            
            Text(LocalizedStringKey(definition.descriptionKey))
                .font(.subheadline)
                .foregroundColor(.secondary)
            
            Button {
                // Hook into your IAP or purchasing logic
            } label: {
                Text("Unlock", comment: "Button to unlock a premium feature")
            }
            .buttonStyle(.borderedProminent)
        }
        .rateCardStyle()
    }
}

struct ContentView_Previews: PreviewProvider {
    static var previews: some View {
        ContentView()
            .environment(\.managedObjectContext, PersistenceController.preview.container.viewContext)
            .environmentObject(GlobalTimer())
            .environmentObject(GlobalSettingsManager())
    }
}
