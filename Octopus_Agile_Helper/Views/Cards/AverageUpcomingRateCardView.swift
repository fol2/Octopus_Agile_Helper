import SwiftUI
import Foundation

// Local settings for this card
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

struct AverageUpcomingRateCardView: View {
    @ObservedObject var viewModel: RatesViewModel
    @StateObject private var localSettings = AverageCardLocalSettingsManager()
    @State private var showingLocalSettings = false
    
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Image(systemName: "chart.bar.fill")
                    .foregroundColor(.blue)
                Text("Lowest \(localSettings.settings.maxListCount) (\(String(format: "%.1f", localSettings.settings.customAverageHours))-hour Averages)")
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
                let averages = viewModel.getLowestAverages(hours: localSettings.settings.customAverageHours, maxCount: localSettings.settings.maxListCount)
                if averages.isEmpty {
                    Text("No upcoming data for \(String(format: "%.1f", localSettings.settings.customAverageHours))-hour averages")
                        .foregroundColor(.secondary)
                } else {
                    VStack(alignment: .leading, spacing: 8) {
                        ForEach(averages) { entry in
                            HStack {
                                Text(viewModel.formatRate(entry.average))
                                    .font(.headline)
                                Spacer()
                                Text("\(viewModel.formatTime(entry.start)) - \(viewModel.formatTime(entry.end))")
                                    .font(.subheadline)
                            }
                        }
                    }
                }
            }
        }
        .sheet(isPresented: $showingLocalSettings) {
            AverageCardSettingsSheet(localSettings: localSettings)
        }
        .modifier(RateCardStyle())
    }
}

// Settings sheet for this card
private struct AverageCardSettingsSheet: View {
    @ObservedObject var localSettings: AverageCardLocalSettingsManager
    @Environment(\.dismiss) var dismiss

    var body: some View {
        NavigationView {
            Form {
                Section(header: Text("Local Card Settings")) {
                    Stepper("Custom Average Hours: \(String(format: "%.1f", localSettings.settings.customAverageHours))",
                            value: $localSettings.settings.customAverageHours,
                            in: 1...24,
                            step: 0.5)
                    Stepper("Max List Count: \(localSettings.settings.maxListCount)",
                            value: $localSettings.settings.maxListCount,
                            in: 1...50)
                }
            }
            .navigationTitle("Card Settings")
            .toolbar {
                ToolbarItem(placement: .automatic) {
                    Button("Done") {
                        dismiss()
                    }
                }
            }
        }
    }
}

#Preview {
    let timer = GlobalTimer()
    AverageUpcomingRateCardView(viewModel: RatesViewModel(globalTimer: timer))
        .preferredColorScheme(.dark)
} 