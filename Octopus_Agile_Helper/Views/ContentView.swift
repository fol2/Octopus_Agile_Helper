//
//  ContentView.swift
//  Octopus_Agile_Helper
//
//  Created by James To on 26/12/2024.
//

import SwiftUI
import CoreData

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
                .toolbar {
                    ToolbarItem(placement: .navigationBarTrailing) {
                        NavigationLink("All Rates") {
                            AllRatesListView(viewModel: ratesViewModel)
                        }
                    }
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

struct ContentView_Previews: PreviewProvider {
    static var previews: some View {
        ContentView()
            .environment(\.managedObjectContext, PersistenceController.preview.container.viewContext)
    }
}
