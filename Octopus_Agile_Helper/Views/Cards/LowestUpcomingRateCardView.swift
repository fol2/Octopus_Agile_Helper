import SwiftUI

// Local settings for this card
private struct LowestRateCardLocalSettings: Codable {
    var additionalRatesCount: Int
    
    static let `default` = LowestRateCardLocalSettings(additionalRatesCount: 2)
}

private class LowestRateCardLocalSettingsManager: ObservableObject {
    @Published var settings: LowestRateCardLocalSettings {
        didSet {
            saveSettings()
        }
    }
    
    private let userDefaultsKey = "LowestRateCardSettings"
    
    init() {
        if let data = UserDefaults.standard.data(forKey: userDefaultsKey),
           let decoded = try? JSONDecoder().decode(LowestRateCardLocalSettings.self, from: data) {
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

struct LowestUpcomingRateCardView: View {
    @ObservedObject var viewModel: RatesViewModel
    @Environment(\.colorScheme) var colorScheme
    @StateObject private var localSettings = LowestRateCardLocalSettingsManager()
    @EnvironmentObject var globalSettings: GlobalSettingsManager
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
                Image(systemName: "arrow.down.circle.fill")
                    .foregroundColor(.green)
                Text("Lowest Upcoming Rates", comment: "Title of the card showing the lowest upcoming electricity rates")
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
            } else if let lowestRate = viewModel.lowestUpcomingRate {
                VStack(alignment: .leading, spacing: 8) {
                    // Main lowest rate
                    HStack(alignment: .center) {
                        let parts = viewModel.formatRate(
                            lowestRate.valueIncludingVAT,
                            showRatesInPounds: globalSettings.settings.showRatesInPounds
                        ).split(separator: " ")
                        Text(parts[0])
                            .font(.system(size: 34, weight: .medium))
                            .foregroundColor(.primary)
                        Text(parts[1])
                            .font(.system(size: 17))
                            .foregroundColor(.secondary)
                        Spacer()
                        Text(formatTimeRange(lowestRate.validFrom, lowestRate.validTo))
                            .font(.subheadline)
                            .foregroundColor(.primary)
                    }
                    
                    // Additional lowest rates
                    if localSettings.settings.additionalRatesCount > 0 {
                        let upcomingRates = viewModel.upcomingRates
                            .filter { ($0.validFrom ?? .distantPast) > Date() }
                            .sorted { $0.valueIncludingVAT < $1.valueIncludingVAT }
                        
                        if upcomingRates.count > 1 {
                            Divider()
                            ForEach(upcomingRates.prefix(localSettings.settings.additionalRatesCount + 1).dropFirst(), id: \.validFrom) { rate in
                                HStack {
                                    let parts = viewModel.formatRate(
                                        rate.valueIncludingVAT,
                                        showRatesInPounds: globalSettings.settings.showRatesInPounds
                                    ).split(separator: " ")
                                    Text(parts[0])
                                        .font(.system(size: 17, weight: .medium))
                                    Text(parts[1])
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
                Text("No upcoming rates available", comment: "Message shown when no upcoming rate data is available")
                    .foregroundColor(.secondary)
            }
        }
        .sheet(isPresented: $showingLocalSettings) {
            LowestRateCardSettingsSheet(localSettings: localSettings)
        }
        .rateCardStyle()
    }
}

// Settings sheet for this card
private struct LowestRateCardSettingsSheet: View {
    @ObservedObject var localSettings: LowestRateCardLocalSettingsManager
    @Environment(\.dismiss) var dismiss

    var body: some View {
        NavigationView {
            Form {
                Section(header: Text("Card Settings", comment: "Header for the card's settings section")) {
                    Stepper(String(localized: "Additional Rates to Show: \(localSettings.settings.additionalRatesCount)", 
                           comment: "Label for stepper controlling how many additional rates to display"),
                            value: $localSettings.settings.additionalRatesCount,
                            in: 0...10)
                }
            }
            .navigationTitle(LocalizedStringKey("Lowest Upcoming Rates"))
            .toolbar {
                ToolbarItem(placement: .automatic) {
                    Button {
                        dismiss()
                    } label: {
                        Text("Done", comment: "Button to dismiss the settings sheet")
                    }
                }
            }
        }
    }
}

#Preview {
    let globalTimer = GlobalTimer()
    let viewModel = RatesViewModel(globalTimer: globalTimer)
    LowestUpcomingRateCardView(viewModel: viewModel)
        .environmentObject(GlobalSettingsManager())
        .preferredColorScheme(.dark)
} 
