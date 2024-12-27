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
    
    private func formatTimeRange(_ from: Date?, _ to: Date?) -> String {
        guard let from = from, let to = to else { return "" }
        let now = Date()
        let calendar = Calendar.current
        
        let fromDay = calendar.startOfDay(for: from)
        let toDay = calendar.startOfDay(for: to)
        let nowDay = calendar.startOfDay(for: now)
        
        let timeFormatter = DateFormatter()
        timeFormatter.dateFormat = "HH:mm"
        
        let dateFormatter = DateFormatter()
        dateFormatter.dateFormat = "d MMM"
        
        if calendar.isDate(fromDay, inSameDayAs: toDay) {
            // Same day for start and end
            if calendar.isDate(fromDay, inSameDayAs: nowDay) {
                return "\(timeFormatter.string(from: from))-\(timeFormatter.string(from: to))"
            } else {
                return "\(dateFormatter.string(from: from)) \(timeFormatter.string(from: from))-\(timeFormatter.string(from: to))"
            }
        } else {
            // Different days for start and end
            return "\(dateFormatter.string(from: from)) \(timeFormatter.string(from: from))-\(dateFormatter.string(from: to)) \(timeFormatter.string(from: to))"
        }
    }
    
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
                                let parts = viewModel.formatRate(entry.average).split(separator: " ")
                                Text(parts[0] + "p")
                                    .font(.system(size: 17, weight: .medium))
                                Text("/kWh")
                                    .font(.system(size: 13))
                                    .foregroundColor(.secondary)
                                Spacer()
                                Text(formatTimeRange(entry.start, entry.end))
                                    .font(.caption)
                                    .foregroundColor(.primary)
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