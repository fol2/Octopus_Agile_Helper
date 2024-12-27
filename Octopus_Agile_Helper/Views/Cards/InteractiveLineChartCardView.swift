import SwiftUI
import Charts
import Foundation
import CoreData
import UIKit

// Reuse the same settings types from AverageUpcomingRateCardView
private struct AverageCardLocalSettings: Codable {
    var customAverageHours: Double
    var maxListCount: Int
    
    static let `default` = AverageCardLocalSettings(customAverageHours: 3.0, maxListCount: 10)
}

private class AverageCardLocalSettingsManager: ObservableObject {
    @Published var settings: AverageCardLocalSettings {
        didSet {
            saveSettings()
        }
    }
    
    private let userDefaultsKey = "AverageCardSettings"
    
    init() {
        if let data = UserDefaults.standard.data(forKey: userDefaultsKey),
           let decoded = try? JSONDecoder().decode(AverageCardLocalSettings.self, from: data) {
            self.settings = decoded
        } else {
            self.settings = .default
        }
    }
    
    func saveSettings() {
        if let encoded = try? JSONEncoder().encode(settings) {
            UserDefaults.standard.set(encoded, forKey: userDefaultsKey)
        }
    }
}

private struct AverageCardSettingsSheet: View {
    @ObservedObject var localSettings: AverageCardLocalSettingsManager
    @Environment(\.dismiss) var dismiss
    @EnvironmentObject var globalSettings: GlobalSettingsManager
    @State private var refreshTrigger = false

    var body: some View {
        NavigationView {
            Form {
                Section(header: Text("Card Settings")) {
                    Stepper("Custom Average Hours: \(String(format: "%.1f", localSettings.settings.customAverageHours))",
                            value: $localSettings.settings.customAverageHours,
                            in: 1...24,
                            step: 0.5)
                    Stepper("Max List Count: \(localSettings.settings.maxListCount)",
                            value: $localSettings.settings.maxListCount,
                            in: 1...50)
                }
            }
            .navigationTitle("Average Upcoming Rates")
            .toolbar {
                ToolbarItem(placement: .automatic) {
                    Button {
                        dismiss()
                    } label: {
                        Text("Done")
                    }
                }
            }
        }
        .environment(\.locale, globalSettings.locale)
        .id("settings-sheet-\(refreshTrigger)")
        .onChange(of: globalSettings.locale) { oldValue, newValue in
            refreshTrigger.toggle()
        }
    }
}

struct InteractiveLineChartCardView: View {
    @ObservedObject var viewModel: RatesViewModel
    @EnvironmentObject var globalSettings: GlobalSettingsManager
    @Environment(\.colorScheme) var colorScheme
    @State private var refreshTrigger = false
    
    // Reuse the existing local settings manager
    @StateObject private var localSettings = AverageCardLocalSettingsManager()
    @State private var showingLocalSettings = false
    
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            // Header
            HStack {
                Image(systemName: "chart.xyaxis.line")
                    .foregroundColor(.blue)
                Text("Interactive Rate Chart")
                    .font(.headline)
                Spacer()
                Button(action: {
                    showingLocalSettings.toggle()
                }) {
                    Image(systemName: "gearshape.fill")
                        .font(.footnote)
                        .foregroundColor(.secondary.opacity(0.7))
                }
                .padding(.trailing, 4)
            }
            
            if viewModel.isLoading {
                ProgressView()
            } else {
                // Placeholder for chart content
                Rectangle()
                    .foregroundColor(.gray.opacity(0.3))
                    .frame(height: 200)
                    .overlay {
                        VStack(spacing: 8) {
                            Text("Chart coming soon")
                            Text("Hours: \(String(format: "%.1f", localSettings.settings.customAverageHours))")
                                .font(.caption)
                            Text("Max List: \(localSettings.settings.maxListCount)")
                                .font(.caption)
                        }
                    }
            }
        }
        .sheet(isPresented: $showingLocalSettings) {
            AverageCardSettingsSheet(localSettings: localSettings)
                .environment(\.locale, globalSettings.locale)
        }
        .rateCardStyle()
        .environment(\.locale, globalSettings.locale)
        .id("interactive-chart-\(refreshTrigger)")
        .onChange(of: globalSettings.locale) { oldValue, newValue in
            refreshTrigger.toggle()
        }
    }
}

#Preview {
    let globalTimer = GlobalTimer()
    let viewModel = RatesViewModel(globalTimer: globalTimer)
    InteractiveLineChartCardView(viewModel: viewModel)
        .environmentObject(GlobalSettingsManager())
        .preferredColorScheme(.dark)
} 