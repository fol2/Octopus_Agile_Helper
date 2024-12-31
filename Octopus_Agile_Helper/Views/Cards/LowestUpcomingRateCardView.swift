import SwiftUI
import CoreData

// MARK: - Local Settings
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

// MARK: - Flip Card Approach
struct LowestUpcomingRateCardView: View {
    @ObservedObject var viewModel: RatesViewModel
    @Environment(\.colorScheme) var colorScheme
    
    @StateObject private var localSettings = LowestRateCardLocalSettingsManager()
    @EnvironmentObject var globalSettings: GlobalSettingsManager
    
    // For flipping between front (rates) and back (settings)
    @State private var flipped = false
    
    @State private var refreshTrigger = false
    
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
        // Size as needed, e.g.:
        .frame(maxWidth: 400)
        // Our shared card style
        .rateCardStyle()
        .environment(\.locale, globalSettings.locale)
        .onChange(of: globalSettings.locale) { _, _ in
            refreshTrigger.toggle()
        }
    }
    
    // MARK: - Front Side
    private var frontSide: some View {
        VStack(alignment: .leading, spacing: 12) {
            // Header
            HStack {
                if let def = CardRegistry.shared.definition(for: .lowestUpcoming) {
                    Image(systemName: def.iconName)
                        .foregroundColor(Theme.icon)
                }
                Text("Lowest Upcoming Rates")
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
            
            // Content
            if viewModel.isLoading {
                ProgressView()
            } else if let lowestRate = viewModel.lowestUpcomingRate {
                
                VStack(alignment: .leading, spacing: 8) {
                    // Main lowest rate
                    HStack(alignment: .firstTextBaseline) {
                        let parts = viewModel.formatRate(
                            lowestRate.valueIncludingVAT,
                            showRatesInPounds: globalSettings.settings.showRatesInPounds
                        ).split(separator: " ")
                        
                        Text(parts[0])
                            .font(Theme.mainFont())
                            .foregroundColor(RateColor.getColor(for: lowestRate, allRates: viewModel.allRates))
                        
                        if parts.count > 1 {
                            Text(parts[1])
                                .font(Theme.subFont())
                                .foregroundColor(Theme.secondaryTextColor)
                        }
                        
                        Spacer()
                        Text(formatTimeRange(lowestRate.validFrom, lowestRate.validTo))
                            .font(Theme.secondaryFont())
                            .foregroundColor(Theme.secondaryTextColor)
                    }
                    
                    // Additional lowest rates if configured
                    if localSettings.settings.additionalRatesCount > 0 {
                        let upcomingRates = Array(viewModel.upcomingRates)
                            .filter { rate in
                                guard let validFrom = rate.validFrom else { return false }
                                return validFrom > Date()
                            }
                            .sorted { rate1, rate2 in
                                rate1.valueIncludingVAT < rate2.valueIncludingVAT
                            }
                        
                        if upcomingRates.count > 1 {
                            Divider()
                            ForEach(upcomingRates.prefix(localSettings.settings.additionalRatesCount + 1).dropFirst(), id: \.validFrom) { rate in
                                let subParts = viewModel.formatRate(
                                    rate.valueIncludingVAT,
                                    showRatesInPounds: globalSettings.settings.showRatesInPounds
                                ).split(separator: " ")
                                
                                HStack(alignment: .firstTextBaseline) {
                                    Text(subParts[0])
                                        .font(Theme.mainFont2())
                                        .foregroundColor(RateColor.getColor(for: rate, allRates: viewModel.allRates))
                                    
                                    if subParts.count > 1 {
                                        Text(subParts[1])
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
            // Header row for settings
            HStack {
                if let def = CardRegistry.shared.definition(for: .lowestUpcoming) {
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
            
            // Minimal row: label + stepper
            HStack(alignment: .top) {
                Text("Additional Rates to Show: \(localSettings.settings.additionalRatesCount)")
                    .font(Theme.secondaryFont())
                    .foregroundColor(Theme.mainTextColor)
                
                Spacer()
                
                Stepper(
                    "",
                    value: $localSettings.settings.additionalRatesCount,
                    in: 0...10
                )
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
        // Force content to top
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
        
        if calendar.isDate(fromDay, inSameDayAs: nowDay) {
            // Same day
            return "\(timeFormatter.string(from: from))-\(timeFormatter.string(from: to))"
        } else {
            // Different day
            return "\(dateFormatter.string(from: from)) \(timeFormatter.string(from: from))-\(timeFormatter.string(from: to))"
        }
    }
}
