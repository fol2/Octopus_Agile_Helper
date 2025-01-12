import Combine
import CoreData
import SwiftUI
import OctopusHelperShared

public struct CurrentRateCardView: View {
    // MARK: - Dependencies
    @ObservedObject var viewModel: RatesViewModel
    @Environment(\.colorScheme) var colorScheme
    @EnvironmentObject var globalSettings: GlobalSettingsManager
    @EnvironmentObject var globalTimer: GlobalTimer
    @State private var refreshTrigger = false
    @State private var clockIconTrigger = Date()  // Add state for clock icon

    // Use the shared manager
    @ObservedObject private var refreshManager = CardRefreshManager.shared

    private func getDayRates(for date: Date, productCode: String) -> [NSManagedObject] {
        let calendar = Calendar.current
        let startOfDay = calendar.startOfDay(for: date)
        let endOfDay = calendar.date(byAdding: .day, value: 1, to: startOfDay)!

        let allRates = viewModel.allRates(for: productCode)
        return allRates.filter { rate in
            guard let validFrom = rate.value(forKey: "valid_from") as? Date else { return false }
            return validFrom >= startOfDay && validFrom < endOfDay
        }.sorted { 
            let date1 = $0.value(forKey: "valid_from") as? Date ?? .distantPast
            let date2 = $1.value(forKey: "valid_from") as? Date ?? .distantPast
            return date1 < date2
        }
    }

    private func getRateColor(for rate: NSManagedObject) -> Color {
        guard let currentValidFrom = rate.value(forKey: "valid_from") as? Date else {
            return .white
        }

        // Get all rates for the day
        let dayRates = getDayRates(for: currentValidFrom, productCode: viewModel.currentAgileCode)

        // Handle negative rates
        let currentValue = rate.value(forKey: "value_including_vat") as? Double ?? 0
        if currentValue < 0 {
            let negativeRates = dayRates.filter {
                ($0.value(forKey: "value_including_vat") as? Double ?? 0) < 0
            }
            if let mostNegative = negativeRates.min(by: {
                ($0.value(forKey: "value_including_vat") as? Double ?? 0) < ($1.value(forKey: "value_including_vat") as? Double ?? 0)
            }) {
                let mostNegativeValue = mostNegative.value(forKey: "value_including_vat") as? Double ?? 0
                let rawPercentage = abs(currentValue / mostNegativeValue)
                let percentage = 0.5 + (rawPercentage * 0.5)  // This ensures we keep at least 50% of the color
                // Base green color (RGB: 0.2, 0.8, 0.4)
                return Color(
                    red: 1.0 - (0.8 * percentage),  // Interpolate from 1.0 to 0.2
                    green: 1.0 - (0.2 * percentage),  // Interpolate from 1.0 to 0.8
                    blue: 1.0 - (0.6 * percentage)  // Interpolate from 1.0 to 0.4
                )
            }
            return Color(red: 0.2, green: 0.8, blue: 0.4)
        }

        // Find the day's rate statistics
        let sortedRates = dayRates.map { $0.value(forKey: "value_including_vat") as? Double ?? 0 }.sorted()
        guard !sortedRates.isEmpty else { return .white }

        let medianRate = sortedRates[sortedRates.count / 2]
        let maxRate = sortedRates.last ?? 0

        // Only color rates above the median
        if currentValue >= medianRate {
            // Calculate how "high" the rate is compared to the range between median and max
            let percentage = (currentValue - medianRate) / (maxRate - medianRate)
            
            // Interpolate between yellow and red based on percentage
            return Color(
                red: 1.0,  // Full red
                green: 1.0 - (0.8 * percentage),  // Fade from full yellow to slight yellow
                blue: 0.0   // No blue
            )
        }
        
        // Return white for rates below median
        return .white
    }

    /// Fetches the current active rate if any (validFrom <= now < validTo).
    private func getCurrentRate() -> NSManagedObject? {
        let now = Date()
        return viewModel.allRates(for: viewModel.currentAgileCode).first { rate in
            guard let start = rate.value(forKey: "valid_from") as? Date,
                  let end = rate.value(forKey: "valid_to") as? Date else { return false }
            return start <= now && end > now
        }
    }

    // MARK: - Body
    public var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            // Header row with left icon + title + "more" icon on right
            HStack(alignment: .center) {
                if let def = CardRegistry.shared.definition(for: .currentRate) {
                    Image(ClockModel.iconName(for: clockIconTrigger))
                        .renderingMode(.template)
                        .resizable()
                        .scaledToFit()
                        .frame(width: 20, height: 20)
                        .foregroundColor(Theme.icon)
                    Text(LocalizedStringKey(def.displayNameKey))
                        .font(Theme.titleFont())
                        .foregroundColor(Theme.secondaryTextColor)
                }
                Spacer()
                Image(systemName: "chevron.right.circle.fill")
                    .foregroundColor(Theme.secondaryTextColor)
            }

            // Content
            if viewModel.isLoading(for: viewModel.currentAgileCode) {
                ProgressView()
            } else if let currentRate = getCurrentRate() {
                // The current rate block
                VStack(alignment: .leading, spacing: 8) {
                    HStack(alignment: .firstTextBaseline) {
                        let parts = viewModel.formatRate(
                            currentRate.value(forKey: "value_including_vat") as? Double ?? 0,
                            showRatesInPounds: globalSettings.settings.showRatesInPounds
                        )
                        .split(separator: " ")

                        // E.g., "22.58p" or "£0.2258"
                        Text(parts[0])
                            .font(Theme.mainFont())
                            .foregroundColor(
                                getRateColor(for: currentRate)
                            )

                        // E.g., "/kWh"
                        Text(parts.count > 1 ? parts[1] : "")
                            .font(Theme.subFont())
                            .foregroundColor(Theme.secondaryTextColor)

                        Spacer()

                        // "Until HH:mm"
                        if let validTo = currentRate.value(forKey: "valid_to") as? Date {
                            Text(LocalizedStringKey("Until \(timeFormatter.string(from: validTo))"))
                                .font(Theme.secondaryFont())
                                .foregroundColor(Theme.secondaryTextColor)
                        }
                    }
                }
            } else {
                // Fallback if there's no current rate
                Text("No current rate available")
                    .foregroundColor(Theme.secondaryTextColor)
            }
        }
        .rateCardStyle()  // Our shared card style
        .environment(\.locale, globalSettings.locale)
        .id("current-rate-\(refreshTrigger)")
        .onChange(of: globalSettings.locale) { _, _ in
            refreshTrigger.toggle()
        }
        // Re-render on half-hour
        .onReceive(refreshManager.$halfHourTick) { tickTime in
            guard tickTime != nil else { return }
            Task {
                clockIconTrigger = Date()  // Update clock icon
                await viewModel.refreshRates(productCode: viewModel.currentAgileCode)
            }
        }
        // Also re-render if app becomes active
        .onReceive(refreshManager.$sceneActiveTick) { _ in
            refreshTrigger.toggle()
            clockIconTrigger = Date()  // Update clock icon
            Task {
                await viewModel.refreshRates(productCode: viewModel.currentAgileCode)
            }
        }
        .onTapGesture {
            presentAllRatesView()
        }
    }

    // MARK: - Helper Methods

    /// Opens a full-screen list of all rates.
    private func presentAllRatesView() {
        if let scene = UIApplication.shared.connectedScenes.first as? UIWindowScene,
            let window = scene.windows.first,
            let rootViewController = window.rootViewController
        {

            let allRatesView = NavigationView {
                AllRatesListView(viewModel: viewModel)
                    .environment(\.locale, globalSettings.locale)
                    .toolbar {
                        ToolbarItem(placement: .navigationBarTrailing) {
                            Button {
                                rootViewController.dismiss(animated: true)
                            } label: {
                                Image(systemName: "xmark.circle.fill")
                                    .foregroundColor(Theme.secondaryTextColor.opacity(0.9))
                            }
                        }
                    }
            }
            .environmentObject(globalTimer)
            .environmentObject(globalSettings)
            .environment(\.locale, globalSettings.locale)
            .id("all-rates-nav-\(globalSettings.locale.identifier)")
            .preferredColorScheme(colorScheme)

            let hostingController = UIHostingController(rootView: allRatesView)
            hostingController.modalPresentationStyle = .fullScreen

            // Force dark/light if needed
            hostingController.overrideUserInterfaceStyle =
                (colorScheme == .dark) ? .dark : .light

            rootViewController.present(hostingController, animated: true)
        }
    }

    /// Time formatter for "Until HH:mm".
    private var timeFormatter: DateFormatter {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm"
        formatter.locale = globalSettings.locale
        return formatter
    }
}
