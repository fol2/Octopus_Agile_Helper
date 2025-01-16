import Combine
import Foundation
import OctopusHelperShared
import SwiftUI
import CoreData

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
            let decoded = try? JSONDecoder().decode(AverageCardLocalSettings.self, from: data)
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
public struct AverageUpcomingRateCardView: View {
    @ObservedObject var viewModel: RatesViewModel
    @StateObject private var localSettings = AverageCardLocalSettingsManager()

    // MARK: - NEW: Decide which product code to use
    private var productCode: String {
        // If your plan is agile:
        return viewModel.currentAgileCode
    }

    @EnvironmentObject var globalSettings: GlobalSettingsManager
    @Environment(\.colorScheme) var colorScheme

    // Flip state for front/back
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
        .frame(maxWidth: 400)  // or any layout constraints you prefer
        .rateCardStyle()  // Our shared card style
        .environment(\.locale, globalSettings.locale)
        .id("average-rate-\(refreshTrigger)")
        .onChange(of: globalSettings.locale) { _, _ in
            refreshTrigger.toggle()
        }
        // Re-render on half-hour
        .onReceive(refreshManager.$halfHourTick) { tickTime in
            guard tickTime != nil else { return }
            // Pass the Agile code:
            Task { await viewModel.refreshRates(productCode: viewModel.currentAgileCode) }
        }
        // Also re-render if app becomes active
        .onReceive(refreshManager.$sceneActiveTick) { _ in
            refreshTrigger.toggle()
            Task {
                await viewModel.refreshRates(productCode: viewModel.currentAgileCode)
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
               && viewModel.allRates(for: productCode).isEmpty {
                // Show big spinner if we have no data yet
                ProgressView("Loading...").padding(.vertical, 12)
            } else if viewModel.allRates(for: productCode).isEmpty {
                Text(
                  "No upcoming data for \(String(format: "%.1f", localSettings.settings.customAverageHours))-hour averages"
                )
                .foregroundColor(Theme.secondaryTextColor)
            } else {
                let averages = viewModel.getLowestAverages(
                    productCode: productCode,
                    hours: localSettings.settings.customAverageHours,
                    maxCount: localSettings.settings.maxListCount
                )

                if averages.isEmpty {
                    Text(
                        "No upcoming data for \(String(format: "%.1f", localSettings.settings.customAverageHours))-hour averages"
                    )
                    .foregroundColor(Theme.secondaryTextColor)
                } else {
                    VStack(alignment: .leading, spacing: 8) {
                        ForEach(averages.prefix(localSettings.settings.maxListCount)) { entry in
                            HStack(alignment: .firstTextBaseline) {
                                let parts = viewModel.formatRate(
                                    entry.average,
                                    showRatesInPounds: globalSettings.settings.showRatesInPounds
                                )
                                .split(separator: " ")

                                Text(parts[0])
                                    .font(Theme.mainFont2())
                                    .foregroundColor(
                                        getAverageColor(
                                            for: entry.average,
                                            allAverages: averages.map { $0.average }
                                        )
                                    )

                                if parts.count > 1 {
                                    Text(parts[1])
                                        .font(Theme.subFont())
                                        .foregroundColor(Theme.secondaryTextColor)
                                }

                                Spacer()

                                Text(
                                    formatTimeRange(
                                        entry.start,
                                        entry.end,
                                        locale: globalSettings.locale
                                    )
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
                Text(
                    "Custom Average Hours: \(localSettings.settings.customAverageHours.truncatingRemainder(dividingBy: 1) == 0 ? String(format: "%.0f", localSettings.settings.customAverageHours) : String(format: "%.1f", localSettings.settings.customAverageHours))"
                )
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
    private func getAverageColor(for average: Double, allAverages: [Double]) -> Color {
        // Get all rates for comparison
        let rates = viewModel.allRates(for: productCode)
        
        // If we have actual rates, use them for color context
        if !rates.isEmpty {
            // Find rates that match our average value
            // Otherwise, find the rates within our time period
            let now = Date()
            let relevantRates = rates.filter { rate in
                guard let validFrom = rate.value(forKey: "valid_from") as? Date else { return false }
                return validFrom >= now
            }
            // Instead of exact match, find the nearest rate by absolute difference
            if let nearestRate = relevantRates.min(by: {
                let v0 = ($0.value(forKey: "value_including_vat") as? Double) ?? 0
                let v1 = ($1.value(forKey: "value_including_vat") as? Double) ?? 0
                return abs(v0 - average) < abs(v1 - average)
            }) {
                return RateColor.getColor(for: nearestRate, allRates: relevantRates)
            }
        }
        
        // Fallback to basic coloring if no rates available
        return .white
    }
}
