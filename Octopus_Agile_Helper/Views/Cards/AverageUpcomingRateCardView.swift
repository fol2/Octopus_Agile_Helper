import SwiftUI
import Foundation

// MARK: - Local settings
private struct AverageCardLocalSettings: Codable {
    var customAverageHours: Double
    var maxListCount: Int
    
    static let `default` = AverageCardLocalSettings(
        customAverageHours: 3.0,
        maxListCount: 10
    )
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

// MARK: - Flip Card Approach
struct AverageUpcomingRateCardView: View {
    @ObservedObject var viewModel: RatesViewModel
    @StateObject private var localSettings = AverageCardLocalSettingsManager()
    
    @EnvironmentObject var globalSettings: GlobalSettingsManager
    @Environment(\.colorScheme) var colorScheme
    
    // Flip state for front/back
    @State private var flipped = false
    
    // For re-render triggers
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
        .frame(maxWidth: 400) // or any layout constraints you prefer
        .rateCardStyle()      // Our shared card style
        .environment(\.locale, globalSettings.locale)
        .id("average-rate-\(refreshTrigger)")
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
    
    // MARK: - FRONT side
    private var frontSide: some View {
        VStack(alignment: .leading, spacing: 12) {
            // Title row
            HStack {
                if let def = CardRegistry.shared.definition(for: .averageUpcoming) {
                    Image(systemName: def.iconName)
                        .foregroundColor(Theme.icon)
                }
                Text("Lowest \(localSettings.settings.maxListCount) (\(localSettings.settings.customAverageHours.truncatingRemainder(dividingBy: 1) == 0 ? String(format: "%.0f", localSettings.settings.customAverageHours) : String(format: "%.1f", localSettings.settings.customAverageHours))-hour Averages)")
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
            } else {
                let averages = viewModel.getLowestAverages(
                    hours: localSettings.settings.customAverageHours,
                    maxCount: localSettings.settings.maxListCount
                )
                
                if averages.isEmpty {
                    Text("No upcoming data for \(String(format: "%.1f", localSettings.settings.customAverageHours))-hour averages")
                        .foregroundColor(Theme.secondaryTextColor)
                } else {
                    VStack(alignment: .leading, spacing: 8) {
                        ForEach(averages) { entry in
                            HStack {
                                let parts = viewModel.formatRate(
                                    entry.average,
                                    showRatesInPounds: globalSettings.settings.showRatesInPounds
                                ).split(separator: " ")
                                
                                Text(parts[0])
                                    .font(Theme.mainFont2())
                                    .foregroundColor(getRateColorForAverage(entry.average, entry.start, entry.end))
                                
                                if parts.count > 1 {
                                    Text(parts[1])
                                        .font(Theme.subFont())
                                        .foregroundColor(Theme.secondaryTextColor)
                                }
                                Spacer()
                                Text(formatTimeRange(entry.start, entry.end, locale: globalSettings.locale))
                                    .font(Theme.subFont())
                                    .foregroundColor(Theme.secondaryTextColor)
                            }
                        }
                    }
                }
            }
        }
    }
    
    // MARK: - BACK side (settings)
    private var backSide: some View {
        VStack(alignment: .leading, spacing: 8) {
            // Header with "settings" + close
            HStack {
                if let def = CardRegistry.shared.definition(for: .averageUpcoming) {
                    Image(systemName: def.iconName)
                        .foregroundColor(Theme.icon)
                }
                Text("Card Settings")
                    .font(Theme.titleFont())
                    .foregroundColor(Theme.secondaryTextColor)
                Spacer()
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
            
            // Stepper controls
            HStack(alignment: .center) {
                Text("Custom Average Hours: \(localSettings.settings.customAverageHours.truncatingRemainder(dividingBy: 1) == 0 ? String(format: "%.0f", localSettings.settings.customAverageHours) : String(format: "%.1f", localSettings.settings.customAverageHours))")
                    .font(Theme.secondaryFont())
                    .foregroundColor(Theme.mainTextColor)
                
                Spacer()
                Stepper(
                    "",
                    value: $localSettings.settings.customAverageHours,
                    in: 0.5...24,
                    step: 0.5
                )
                .labelsHidden()
                .font(Theme.secondaryFont())
                .foregroundColor(Theme.mainTextColor)
                .tint(Theme.secondaryColor)
                .padding(.horizontal, 6)
                .background(Theme.secondaryBackground)
                .cornerRadius(8)
            }
            
            HStack(alignment: .center) {
                Text("Max List Count: \(localSettings.settings.maxListCount)")
                    .font(Theme.secondaryFont())
                    .foregroundColor(Theme.mainTextColor)
                
                Spacer()
                Stepper(
                    "",
                    value: $localSettings.settings.maxListCount,
                    in: 1...50
                )
                .labelsHidden()
                .font(Theme.secondaryFont())
                .foregroundColor(Theme.mainTextColor)
                .tint(Theme.secondaryColor)
                .padding(.horizontal, 6)
                .background(Theme.secondaryBackground)
                .cornerRadius(8)
            }
        }
        .padding(8)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }
    
    // MARK: - Helpers
    
    // MARK: - Color Helper
    private func getRateColorForAverage(_ average: Double, _ start: Date, _ end: Date) -> Color {
        // Get all rates sorted by time
        let sortedRates = viewModel.allRates
            .filter { $0.validFrom != nil }
            .sorted { ($0.validFrom ?? .distantPast) < ($1.validFrom ?? .distantPast) }
        
        // Find the rate that starts closest to our average's start time
        let nearestRate = sortedRates
            .min { rate1, rate2 in
                let diff1 = abs((rate1.validFrom ?? .distantFuture).timeIntervalSince(start))
                let diff2 = abs((rate2.validFrom ?? .distantFuture).timeIntervalSince(start))
                return diff1 < diff2
            }
        
        // Find rates that overlap with our average period
        let overlappingRates = sortedRates.filter { rate in
            guard let rateStart = rate.validFrom, let rateEnd = rate.validTo else { return false }
            return (rateStart < end && rateEnd > start)
        }
        
        // If we have overlapping rates, use the one closest in value to our average
        if !overlappingRates.isEmpty {
            let closestRate = overlappingRates
                .min { rate1, rate2 in
                    abs(rate1.valueIncludingVAT - average) < abs(rate2.valueIncludingVAT - average)
                }
            if let rate = closestRate {
                return RateColor.getColor(for: rate, allRates: viewModel.allRates)
            }
        }
        
        // Fallback to nearest rate by time if no overlapping rates
        if let rate = nearestRate {
            return RateColor.getColor(for: rate, allRates: viewModel.allRates)
        }
        
        return .white
    }
}
