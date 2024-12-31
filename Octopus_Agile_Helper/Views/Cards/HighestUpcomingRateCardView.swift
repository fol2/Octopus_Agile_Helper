import SwiftUI

// MARK: - Local Settings
private struct HighestRateCardLocalSettings: Codable {
    var additionalRatesCount: Int
    static let `default` = HighestRateCardLocalSettings(additionalRatesCount: 2)
}

private class HighestRateCardLocalSettingsManager: ObservableObject {
    @Published var settings: HighestRateCardLocalSettings {
        didSet { saveSettings() }
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

// MARK: - Flip Card Approach
struct HighestUpcomingRateCardView: View {
    @ObservedObject var viewModel: RatesViewModel
    @Environment(\.colorScheme) var colorScheme
    
    @StateObject private var localSettings = HighestRateCardLocalSettingsManager()
    @EnvironmentObject var globalSettings: GlobalSettingsManager
    
    @State private var flipped = false
    @State private var refreshTrigger = false
    
    // Timer for content refresh
    private let refreshTimer = Timer
        .publish(every: 1, on: .main, in: .common)
        .autoconnect()
    
    var body: some View {
        ZStack {
            // FRONT side
            frontSide
                .opacity(flipped ? 0 : 1)
                .rotation3DEffect(.degrees(flipped ? 180 : 0),
                                  axis: (x: 0, y: 1, z: 0),
                                  perspective: 0.8)
            
            // BACK side (settings)
            backSide
                .opacity(flipped ? 1 : 0)
                .rotation3DEffect(.degrees(flipped ? 0 : -180),
                                  axis: (x: 0, y: 1, z: 0),
                                  perspective: 0.8)
        }
        .frame(maxWidth: 400) // or whatever suits your layout
        .rateCardStyle()
        .environment(\.locale, globalSettings.locale)
        .onChange(of: globalSettings.locale) { _, _ in
            refreshTrigger.toggle()
        }
        .onReceive(refreshTimer) { _ in
            let calendar = Calendar.current
            let date = Date()
            let minute = calendar.component(.minute, from: date)
            let second = calendar.component(.second, from: date)
            
            // Only refresh content at o'clock and half o'clock
            if second == 0 && (minute == 0 || minute == 30) {
                Task {
                    await viewModel.refreshRates()
                }
            }
        }
    }
    
    // MARK: - Front Side
    private var frontSide: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                if let def = CardRegistry.shared.definition(for: .highestUpcoming) {
                    Image(systemName: def.iconName)
                        .foregroundColor(Theme.icon)
                }
                Text("Highest Upcoming Rates")
                    .font(Theme.titleFont())
                    .foregroundColor(Theme.secondaryTextColor)
                Spacer()
                // Flip to settings
                Button {
                    withAnimation(.spring()) {
                        flipped = true
                    }
                } label: {
                    Image(systemName: "gearshape.fill")
                        .font(Theme.subFont())
                        .foregroundColor(Theme.secondaryTextColor)
                }
            }
            
            if viewModel.isLoading {
                ProgressView()
            } else if let highestRate = viewModel.highestUpcomingRate {
                VStack(alignment: .leading, spacing: 8) {
                    let parts = viewModel.formatRate(
                        highestRate.valueIncludingVAT,
                        showRatesInPounds: globalSettings.settings.showRatesInPounds
                    )
                    .split(separator: " ")
                    
                    HStack(alignment: .firstTextBaseline) {
                        Text(parts[0])
                            .font(Theme.mainFont())
                            .foregroundColor(RateColor.getColor(for: highestRate, allRates: viewModel.allRates))
                        
                        if parts.count > 1 {
                            Text(parts[1])
                                .font(Theme.subFont())
                                .foregroundColor(Theme.secondaryTextColor)
                        }
                        
                        Spacer()
                        Text(formatTimeRange(highestRate.validFrom, highestRate.validTo))
                            .font(Theme.secondaryFont())
                            .foregroundColor(Theme.secondaryTextColor)
                    }
                    
                    if localSettings.settings.additionalRatesCount > 0 {
                        let upcomingRates = viewModel.upcomingRates
                            .filter { ($0.validFrom ?? .distantPast) > Date() }
                            .sorted { $0.valueIncludingVAT > $1.valueIncludingVAT }
                        
                        if upcomingRates.count > 1 {
                            Divider()
                            
                            ForEach(
                                upcomingRates.prefix(localSettings.settings.additionalRatesCount + 1).dropFirst(),
                                id: \.validFrom
                            ) { rate in
                                let rateParts = viewModel.formatRate(
                                    rate.valueIncludingVAT,
                                    showRatesInPounds: globalSettings.settings.showRatesInPounds
                                )
                                .split(separator: " ")
                                
                                HStack(alignment: .firstTextBaseline) {
                                    Text(rateParts[0])
                                        .font(Theme.mainFont2())
                                        .foregroundColor(RateColor.getColor(for: rate, allRates: viewModel.allRates))
                                    
                                    if rateParts.count > 1 {
                                        Text(rateParts[1])
                                            .font(Theme.subFont())
                                            .foregroundColor(Theme.secondaryTextColor)
                                    }
                                    Spacer()
                                    Text(formatTimeRange(rate.validFrom, rate.validTo))
                                        .font(Theme.subFont())
                                        .foregroundColor(Theme.secondaryTextColor)
                                }
                            }
                        }
                    }
                }
                
            } else {
                Text("No upcoming rates available")
                    .foregroundColor(Theme.secondaryTextColor)
            }
        }
    }
    
    // MARK: - Back Side (Settings)
    private var backSide: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                if let def = CardRegistry.shared.definition(for: .highestUpcoming) {
                    Image(systemName: def.iconName)
                        .foregroundColor(Theme.icon)
                }
                Text("Card Settings")
                    .font(Theme.titleFont())
                    .foregroundColor(Theme.secondaryTextColor)
                Spacer()
                // Flip back
                Button {
                    withAnimation(.spring()) {
                        flipped = false
                    }
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(Theme.subFont())
                        .foregroundColor(Theme.secondaryTextColor)
                }
            }
            
            // The row for "Additional Rates..."
            HStack(alignment: .center) {
                Text("Additional Rates to Show: \(localSettings.settings.additionalRatesCount)")
                    .font(Theme.secondaryFont())
                    .foregroundColor(Theme.mainTextColor)
                Spacer()
                Stepper("", value: $localSettings.settings.additionalRatesCount, in: 0...10)
                    .labelsHidden()
                    .font(Theme.secondaryFont())
                    .foregroundColor(Theme.mainTextColor)
                    .tint(Theme.secondaryColor)
                    .padding(.horizontal, 6)
                    .background(Theme.secondaryBackground)
                    .cornerRadius(8)
            }
            .padding(.top, 8)
        }
        .padding(8)
        // Force the entire content to stick to the top:
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }
    
    // MARK: - Helper
    private func formatTimeRange(_ from: Date?, _ to: Date?) -> String {
        guard let from = from, let to = to else { return "" }
        let now = Date()
        let calendar = Calendar.current
        
        let fromDay = calendar.startOfDay(for: from)
        let nowDay = calendar.startOfDay(for: now)
        
        let timeFormatter = DateFormatter()
        timeFormatter.dateFormat = "HH:mm"
        timeFormatter.locale = globalSettings.locale
        
        let dateFormatter = DateFormatter()
        if globalSettings.locale.language.languageCode?.identifier == "zh" {
            dateFormatter.dateFormat = "MM月dd日"
        } else {
            dateFormatter.dateFormat = "d MMM"
        }
        dateFormatter.locale = globalSettings.locale
        
        // If same day as 'today', just show time range
        if calendar.isDate(fromDay, inSameDayAs: nowDay) {
            return "\(timeFormatter.string(from: from))-\(timeFormatter.string(from: to))"
        } else {
            return "\(dateFormatter.string(from: from)) \(timeFormatter.string(from: from))-\(timeFormatter.string(from: to))"
        }
    }
}
