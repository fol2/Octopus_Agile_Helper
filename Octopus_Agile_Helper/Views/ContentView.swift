//
//  ContentView.swift
//  Octopus_Agile_Helper
//
//  Created by James To on 26/12/2024.
//

import SwiftUI
import CoreData

struct ContentView: View {
    @EnvironmentObject var globalTimer: GlobalTimer
    @StateObject private var ratesViewModel: RatesViewModel
    
    init() {
        // We need to initialize ratesViewModel with globalTimer,
        // but we can't use @EnvironmentObject in init
        // So we create a temporary instance just for init
        let tempTimer = GlobalTimer()
        _ratesViewModel = StateObject(wrappedValue: RatesViewModel(globalTimer: tempTimer))
    }
    
    var body: some View {
        TabView {
            NavigationView {
                ScrollView {
                    VStack(spacing: 0) {
                        CurrentRateCardView(viewModel: ratesViewModel)
                        LowestUpcomingRateCardView(viewModel: ratesViewModel)
                        HighestUpcomingRateCardView(viewModel: ratesViewModel)
                        AverageUpcomingRateCardView(viewModel: ratesViewModel)
                    }
                    .padding(.vertical)
                }
                .navigationTitle("Octopus Agile")
                .refreshable {
                    // Force update when user pulls to refresh
                    await ratesViewModel.refreshRates(force: true)
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
            // Initial load when app opens
            await ratesViewModel.loadRates()
        }
        .onAppear {
            // Replace the temporary timer with the real one from environment
            ratesViewModel.updateTimer(globalTimer)
        }
    }
}

struct ContentView_Previews: PreviewProvider {
    static var previews: some View {
        ContentView()
            .environment(\.managedObjectContext, PersistenceController.preview.container.viewContext)
            .environmentObject(GlobalTimer())
    }
}
