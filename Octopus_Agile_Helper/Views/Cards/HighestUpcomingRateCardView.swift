import SwiftUI

// Local settings for this card
private struct HighestRateCardLocalSettings: Codable {
    var additionalRatesCount: Int
    
    static let `default` = HighestRateCardLocalSettings(additionalRatesCount: 2)
}

private class HighestRateCardLocalSettingsManager: ObservableObject {
    @Published var settings: HighestRateCardLocalSettings {
        didSet {
            saveSettings()
        }
    }
    
    private let userDefaultsKey = "HighestRateCardSettings"
    
    init() {
        if let data = UserDefaults.standard.data(forKey: userDefaultsKey),
           let decoded = try? JSONDecoder().decode(HighestRateCardLocalSettings.self, from: data) {
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

struct HighestUpcomingRateCardView: View {
    @ObservedObject var viewModel: RatesViewModel
    @Environment(\.colorScheme) var colorScheme
    @StateObject private var localSettings = HighestRateCardLocalSettingsManager()
    @State private var showingLocalSettings = false
    
    private func formatTimeRange(_ from: Date?, _ to: Date?) -> String {
        guard let from = from, let to = to else { return "" }
        let now = Date()
        let calendar = Calendar.current
        
        let fromDay = calendar.startOfDay(for: from)
        let nowDay = calendar.startOfDay(for: now)
        
        let timeFormatter = DateFormatter()
        timeFormatter.dateFormat = "HH:mm"
        
        let dateFormatter = DateFormatter()
        dateFormatter.dateFormat = "d MMM"
        
        if calendar.isDate(fromDay, inSameDayAs: nowDay) {
            return "\(timeFormatter.string(from: from))-\(timeFormatter.string(from: to))"
        } else {
            return "\(dateFormatter.string(from: from)) \(timeFormatter.string(from: from))-\(timeFormatter.string(from: to))"
        }
    }
    
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Image(systemName: "arrow.up.circle.fill")
                    .foregroundColor(.red)
                Text("Highest Upcoming Rates")
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
            } else if let highestRate = viewModel.highestUpcomingRate {
                VStack(alignment: .leading, spacing: 8) {
                    // Main highest rate
                    HStack(alignment: .center) {
                        let parts = viewModel.formatRate(highestRate.valueIncludingVAT).split(separator: " ")
                        Text(parts[0] + "p")
                            .font(.system(size: 34, weight: .medium))
                            .foregroundColor(.primary)
                        Text("/kWh")
                            .font(.system(size: 17))
                            .foregroundColor(.secondary)
                        Spacer()
                        Text(formatTimeRange(highestRate.validFrom, highestRate.validTo))
                            .font(.subheadline)
                            .foregroundColor(.primary)
                    }
                    
                    // Additional highest rates
                    if localSettings.settings.additionalRatesCount > 0 {
                        let upcomingRates = viewModel.upcomingRates
                            .filter { ($0.validFrom ?? .distantPast) > Date() }
                            .sorted { $0.valueIncludingVAT > $1.valueIncludingVAT }
                        
                        if upcomingRates.count > 1 {
                            Divider()
                            ForEach(upcomingRates.prefix(localSettings.settings.additionalRatesCount + 1).dropFirst(), id: \.validFrom) { rate in
                                HStack {
                                    let parts = viewModel.formatRate(rate.valueIncludingVAT).split(separator: " ")
                                    Text(parts[0] + "p")
                                        .font(.system(size: 17, weight: .medium))
                                    Text("/kWh")
                                        .font(.system(size: 13))
                                        .foregroundColor(.secondary)
                                    Spacer()
                                    Text(formatTimeRange(rate.validFrom, rate.validTo))
                                        .font(.caption)
                                        .foregroundColor(.primary)
                                }
                            }
                        }
                    }
                }
            } else {
                Text("No upcoming rates available")
                    .foregroundColor(.secondary)
            }
        }
        .sheet(isPresented: $showingLocalSettings) {
            HighestRateCardSettingsSheet(localSettings: localSettings)
        }
        .rateCardStyle()
    }
}

// Settings sheet for this card
private struct HighestRateCardSettingsSheet: View {
    @ObservedObject var localSettings: HighestRateCardLocalSettingsManager
    @Environment(\.dismiss) var dismiss

    var body: some View {
        NavigationView {
            Form {
                Section(header: Text("Local Card Settings")) {
                    Stepper("Additional Rates to Show: \(localSettings.settings.additionalRatesCount)",
                            value: $localSettings.settings.additionalRatesCount,
                            in: 0...10)
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
    return HighestUpcomingRateCardView(viewModel: RatesViewModel(globalTimer: timer))
        .preferredColorScheme(.dark)
} 
