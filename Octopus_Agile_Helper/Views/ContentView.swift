//
//  ContentView.swift
//  Octopus_Agile_Helper
//
//  Created by James To on 26/12/2024.
//

import SwiftUI

struct ContentView: View {
    @StateObject private var ratesViewModel = RatesViewModel()
    
    var body: some View {
        TabView {
            NavigationView {
                ScrollView {
                    VStack {
                        LowestUpcomingRateCardView(viewModel: ratesViewModel)
                        HighestUpcomingRateCardView(viewModel: ratesViewModel)
                        AverageUpcomingRateCardView(viewModel: ratesViewModel)
                    }
                }
                .navigationTitle("Octopus Agile")
                .refreshable {
                    await ratesViewModel.refreshRates()
                }
            }
            .tabItem {
                Label("Home", systemImage: "house")
            }
            
            NavigationView {
                SettingsView()
            }
            .tabItem {
                Label("Settings", systemImage: "gear")
            }
        }
        .task {
            await ratesViewModel.loadRates()
        }
    }
}

#Preview {
    ContentView()
        .environment(\.managedObjectContext, PersistenceController.preview.container.viewContext)
}
