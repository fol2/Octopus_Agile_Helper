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
public struct HighestUpcomingRateCardView: View {
    @ObservedObject var viewModel: RatesViewModel
    @Environment(\.colorScheme) var colorScheme

    @StateObject private var localSettings = HighestRateCardLocalSettingsManager()
    @EnvironmentObject var globalSettings: GlobalSettingsManager

    // MARK: - NEW: Decide which product code to use
    private var productCode: String {
        // If your plan is agile:
        return viewModel.currentAgileCode
    }

    @State private var flipped = false
    @State private var refreshTrigger = false

    // Use the shared manager
    @ObservedObject private var refreshManager = CardRefreshManager.shared

    public var body: some View {
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
            refreshTrigger.toggle()
        }
        // Also re-render if app becomes active
        .onReceive(refreshManager.$sceneActiveTick) { _ in
            refreshTrigger.toggle()
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

            if viewModel.isLoading(for: productCode) && viewModel.fetchState == .loading {
                // Show a progress spinner if no data is available yet
                if (viewModel.productStates[productCode]?.upcomingRates.isEmpty ?? true) {
                    ProgressView("Loading...").padding(.vertical, 12)
                } else {
                    // If we do have some rates loaded, show partial content below
                    // or you can keep a smaller inline spinner
                    ProgressView().scaleEffect(0.8)
                }
            } else if let highestRate = viewModel.highestUpcomingRate(productCode: productCode),
                      let value = highestRate.value(forKey: "value_including_vat") as? Double {
                VStack(alignment: .leading, spacing: 8) {
                    let parts = viewModel.formatRate(
                        value,
                        showRatesInPounds: globalSettings.settings.showRatesInPounds
                    )
                    .split(separator: " ")

                    HStack(alignment: .firstTextBaseline) {
                        Text(parts[0])
                            .font(Theme.mainFont())
                            .foregroundColor(
                                RateColor.getColor(
                                    for: highestRate,
                                    allRates: viewModel.allRates(for: productCode)
                                )
                            )

                        if parts.count > 1 {
                            Text(parts[1])
                                .font(Theme.subFont())
                                .foregroundColor(Theme.secondaryTextColor)
                        }

                        Spacer()

                        if let fromDate = highestRate.value(forKey: "valid_from") as? Date,
                           let toDate = highestRate.value(forKey: "valid_to") as? Date {
                            Text(
                                formatTimeRange(
                                    fromDate, toDate,
                                    locale: globalSettings.locale
                                )
                            )
                            .font(Theme.subFont())
                            .foregroundColor(Theme.secondaryTextColor)
                        }
                    }

                    if localSettings.settings.additionalRatesCount > 0 {
                        // We'll use upcomingRates directly
                        let upcomingRates = viewModel.productStates[productCode]?.upcomingRates ?? []
                        let sortedRates = upcomingRates
                            .sorted { r1, r2 in
                                (r1.value(forKey: "value_including_vat") as? Double ?? 0) > (r2.value(forKey: "value_including_vat") as? Double ?? 0)
                            }

                        if sortedRates.count > 1 {
                            ForEach(
                                sortedRates.prefix(
                                    localSettings.settings.additionalRatesCount + 1
                                ).dropFirst(),
                                id: \.self
                            ) { rate in
                                HStack(alignment: .firstTextBaseline) {
                                    let valStr = viewModel.formatRate(
                                        rate.value(forKey: "value_including_vat") as? Double ?? 0,
                                        showRatesInPounds: globalSettings.settings.showRatesInPounds
                                    )
                                    let subParts = valStr.split(separator: " ")

                                    Text(subParts[0])
                                        .font(Theme.mainFont2())
                                        .foregroundColor(
                                            RateColor.getColor(
                                                for: rate,
                                                allRates: viewModel.allRates(for: productCode)
                                            )
                                        )

                                    if subParts.count > 1 {
                                        Text(subParts[1])
                                            .font(Theme.subFont())
                                            .foregroundColor(Theme.secondaryTextColor)
                                    }
                                    Spacer()

                                    if let fromD = rate.value(forKey: "valid_from") as? Date,
                                       let toD = rate.value(forKey: "valid_to") as? Date {
                                        Text(
                                            formatTimeRange(fromD, toD, locale: globalSettings.locale)
                                        )
                                        .font(Theme.subFont())
                                        .foregroundColor(Theme.secondaryTextColor)
                                    }
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

    // MARK: - Private Helpers
}
