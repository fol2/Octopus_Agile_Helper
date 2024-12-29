//
//  ContentView.swift
//  Octopus_Agile_Helper
//
//  Created by James To on 26/12/2024.
//

import SwiftUI
import CoreData
import Combine
import UIKit

struct ContentView: View {
    @EnvironmentObject var globalTimer: GlobalTimer
    @EnvironmentObject var globalSettings: GlobalSettingsManager
    @StateObject private var ratesViewModel: RatesViewModel
    @Environment(\.colorScheme) var colorScheme
    @State private var refreshTrigger = false
    @State private var forcedRefresh = false
    
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
                                        .environment(\.locale, globalSettings.locale)
                                        .id("\(config.id)-\(refreshTrigger)-\(forcedRefresh)")
                                } else {
                                    CardLockedView(definition: definition, config: config)
                                        .environment(\.locale, globalSettings.locale)
                                        .id("\(config.id)-\(refreshTrigger)-\(forcedRefresh)")
                                }
                            }
                        }
                    }
                }
                .padding(.vertical)
                .id("vstack-\(forcedRefresh)")
            }
            .navigationTitle(LocalizedStringKey("Octopus Agile"))
            .refreshable {
                await ratesViewModel.refreshRates(force: true)
            }
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    NavigationLink(destination: SettingsView()
                        .environment(\.locale, globalSettings.locale)
                        .id("settings-view-\(refreshTrigger)")) {
                        Image(systemName: "gear")
                            .foregroundColor(.primary)
                    }
                }
            }
        }
        .environment(\.locale, globalSettings.locale)
        .onChange(of: globalSettings.locale) { oldValue, newValue in
            refreshTrigger.toggle()
        }
        .task {
            await ratesViewModel.loadRates()
        }
        .onAppear {
            ratesViewModel.updateTimer(globalTimer)
            Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { _ in
                forcedRefresh.toggle()
                print("Forcing re-render at \(Date())")
            }
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
                Text("Unlock")
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
