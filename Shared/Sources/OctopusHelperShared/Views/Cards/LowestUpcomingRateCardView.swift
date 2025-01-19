import Combine
import CoreData
import OctopusHelperShared
import SwiftUI

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
            let decoded = try? JSONDecoder().decode(LowestRateCardLocalSettings.self, from: data)
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
public struct LowestUpcomingRateCardView: View {
    @ObservedObject var viewModel: RatesViewModel
    @Environment(\.colorScheme) var colorScheme

    @StateObject private var localSettings = LowestRateCardLocalSettingsManager()
    @EnvironmentObject var globalSettings: GlobalSettingsManager

    // MARK: - Product Code
    private var productCode: String {
        return viewModel.currentAgileCode
    }

    // For flipping between front (rates) and back (settings)
    @State private var flipped = false
    @State private var refreshTrigger = false

    // Use the shared manager
    @ObservedObject private var refreshManager = CardRefreshManager.shared

    // MARK: - Rate Fetching Logic
    private func getAdditionalLowestRates() -> [NSManagedObject] {
        let upcomingRates = viewModel.productStates[productCode]?.upcomingRates ?? []
        let sortedRates = upcomingRates
            .sorted { rate1, rate2 in
                let value1 = rate1.value(forKey: "value_including_vat") as? Double ?? 0
                let value2 = rate2.value(forKey: "value_including_vat") as? Double ?? 0
                return value1 < value2
            }
        
        // Skip the first one (it's shown as main rate) and take the next N
        return Array(sortedRates.dropFirst().prefix(localSettings.settings.additionalRatesCount))
    }

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
        // Size as needed
        .frame(maxWidth: 400)
        // Our shared card style
        .rateCardStyle()
        .environment(\.locale, globalSettings.locale)
        .id("lowest-upcoming-\(refreshTrigger)-\(productCode)")  // Added ID for refresh
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
            // Header
            HStack {
                if let def = CardRegistry.shared.definition(for: .lowestUpcoming) {
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

            // Content
            if viewModel.isLoading(for: productCode)
               && (viewModel.productStates[productCode]?.upcomingRates.isEmpty ?? true) {
                // Show loading spinner if no rates loaded
                ProgressView("Loading...").padding(.vertical, 12)
            } else if (viewModel.productStates[productCode]?.upcomingRates.isEmpty ?? true)
                      && viewModel.isLoading(for: productCode) {
                ProgressView("Loading...").padding(.vertical, 12)
            } else if (viewModel.productStates[productCode]?.upcomingRates.isEmpty ?? true) {
                Text("No upcoming rates available")
                    .foregroundColor(Theme.secondaryTextColor)
            } else if let lowestRate = viewModel.lowestUpcomingRate(productCode: productCode),
                      let value = lowestRate.value(forKey: "value_including_vat") as? Double {
                VStack(alignment: .leading, spacing: 8) {
                    // Main lowest rate
                    HStack(alignment: .firstTextBaseline) {
                        let valueStr = viewModel.formatRate(
                            value,
                            showRatesInPounds: globalSettings.settings.showRatesInPounds
                        )
                        let parts = valueStr.split(separator: " ")

                        Text(parts[0])
                            .font(Theme.mainFont())
                            .foregroundColor(
                                RateColor.getColor(
                                    for: lowestRate,
                                    allRates: viewModel.allRates(for: productCode)
                                )
                            )

                        if parts.count > 1 {
                            Text(parts[1])
                                .font(Theme.subFont())
                                .foregroundColor(Theme.secondaryTextColor)
                        }

                        Spacer()
                        if let fromDate = lowestRate.value(forKey: "valid_from") as? Date,
                           let toDate = lowestRate.value(forKey: "valid_to") as? Date {
                            Text(
                                formatTimeRange(
                                    fromDate, toDate,
                                    locale: globalSettings.locale
                                )
                            )
                            .font(Theme.secondaryFont())
                            .foregroundColor(Theme.secondaryTextColor)
                        }
                    }

                    // Additional lowest rates if configured
                    if localSettings.settings.additionalRatesCount > 0 {
                        let additionalRates = getAdditionalLowestRates()
                        if !additionalRates.isEmpty {
                            Divider()
                            ForEach(additionalRates, id: \.self) { rate in
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
}
