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
                        if config.isEnabled && config.isPurchased {
                            switch config.cardType {
                            case .currentRate:
                                CurrentRateCardView(viewModel: ratesViewModel)
                            case .lowestUpcoming:
                                LowestUpcomingRateCardView(viewModel: ratesViewModel)
                            case .highestUpcoming:
                                HighestUpcomingRateCardView(viewModel: ratesViewModel)
                            case .averageUpcoming:
                                AverageUpcomingRateCardView(viewModel: ratesViewModel)
                            }
                        }
                    }
                }
                .padding(.vertical)
            }
            .navigationTitle("Octopus Agile")
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

struct ContentView_Previews: PreviewProvider {
    static var previews: some View {
        ContentView()
            .environment(\.managedObjectContext, PersistenceController.preview.container.viewContext)
            .environmentObject(GlobalTimer())
            .environmentObject(GlobalSettingsManager())
    }
}
