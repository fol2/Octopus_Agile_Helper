import Combine
import Foundation
import OctopusHelperShared
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
            let decoded = try? JSONDecoder().decode(HighestRateCardLocalSettings.self, from: data)
        {
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

    // Use the shared manager
    @ObservedObject private var refreshManager = CardRefreshManager.shared

    var body: some View {
        ZStack {
            // FRONT side
            frontSide
                .opacity(flipped ? 0 : 1)
                .rotation3DEffect(
                    .degrees(flipped ? 180 : 0),
                    axis: (x: 0, y: 1, z: 0),
                    perspective: 0.8)

            // BACK side (settings)
            backSide
                .opacity(flipped ? 1 : 0)
                .rotation3DEffect(
                    .degrees(flipped ? 0 : -180),
                    axis: (x: 0, y: 1, z: 0),
                    perspective: 0.8)
        }
        .frame(maxWidth: 400)  // or whatever suits your layout
        .rateCardStyle()
        .environment(\.locale, globalSettings.locale)
        .onChange(of: globalSettings.locale) { _, _ in
            refreshTrigger.toggle()
        }
        // Re-render on half-hour
        .onReceive(refreshManager.$halfHourTick) { tickTime in
            guard tickTime != nil else { return }
            Task {
                await viewModel.refreshRates()
            }
        }
        // Also re-render if app becomes active
        .onReceive(refreshManager.$sceneActiveTick) { _ in
            refreshTrigger.toggle()
            Task {
                await viewModel.refreshRates()
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
                    Text(LocalizedStringKey(def.displayNameKey))
                        .font(Theme.titleFont())
                        .foregroundColor(Theme.secondaryTextColor)
                }
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
                            .foregroundColor(
                                RateColor.getColor(for: highestRate, allRates: viewModel.allRates))

                        if parts.count > 1 {
                            Text(parts[1])
                                .font(Theme.subFont())
                                .foregroundColor(Theme.secondaryTextColor)
                        }

                        Spacer()
                        Text(
                            formatTimeRange(
                                highestRate.validFrom, highestRate.validTo,
                                locale: globalSettings.locale)
                        )
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
                                upcomingRates.prefix(
                                    localSettings.settings.additionalRatesCount + 1
                                ).dropFirst(),
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
                                        .foregroundColor(
                                            RateColor.getColor(
                                                for: rate, allRates: viewModel.allRates))

                                    if rateParts.count > 1 {
                                        Text(rateParts[1])
                                            .font(Theme.subFont())
                                            .foregroundColor(Theme.secondaryTextColor)
                                    }
                                    Spacer()
                                    Text(
                                        formatTimeRange(
                                            rate.validFrom, rate.validTo,
                                            locale: globalSettings.locale)
                                    )
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
                    Text(LocalizedStringKey(def.displayNameKey))
                        .font(Theme.titleFont())
                        .foregroundColor(Theme.secondaryTextColor)
                }
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
}
