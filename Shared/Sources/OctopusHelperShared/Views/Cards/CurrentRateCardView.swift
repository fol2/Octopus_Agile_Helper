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

    // Track whether sheet is presented
    @State private var showingAllRates = false

    // MARK: - Product Code
    private var productCode: String {
        return viewModel.currentAgileCode
    }

    private func getDayRates(for date: Date) -> [NSManagedObject] {
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
        return RateColor.getColor(for: rate, allRates: viewModel.allRates(for: productCode))
    }

    /// Fetches the current active rate if any (validFrom <= now < validTo).
    private func getCurrentRate() -> NSManagedObject? {
        let now = Date()
        return viewModel.allRates(for: productCode).first { rate in
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
                if viewModel.isLoading(for: productCode)
                   && viewModel.allRates(for: productCode).isEmpty {
                    ProgressView("Loading Rates...")
                        .font(Theme.subFont())
                } else if let def = CardRegistry.shared.definition(for: .currentRate) {
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
            if viewModel.isLoading(for: productCode)
               && viewModel.allRates(for: productCode).isEmpty {
                // Show a bigger spinner if no rates loaded yet
                ProgressView().padding(.vertical, 12)
            } else if let currentRate = getCurrentRate() {
                // The current rate block
                VStack(alignment: .leading, spacing: 8) {
                    HStack(alignment: .firstTextBaseline) {
                        let parts = viewModel.formatRate(
                            excVAT: currentRate.value(forKey: "value_excluding_vat") as? Double ?? 0,
                            incVAT: currentRate.value(forKey: "value_including_vat") as? Double ?? 0,
                            showRatesInPounds: globalSettings.settings.showRatesInPounds,
                            showRatesWithVAT: globalSettings.settings.showRatesWithVAT
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
        .id("current-rate-\(refreshTrigger)-\(productCode)")  // Also refresh on product code change
        .onChange(of: globalSettings.locale) { _, _ in
            refreshTrigger.toggle()
        }
        // Re-render on half-hour
        .onReceive(refreshManager.$halfHourTick) { tickTime in
            guard tickTime != nil else { return }
            clockIconTrigger = Date()  // Update clock icon
            refreshTrigger.toggle()    // Force UI update
        }
        // Also re-render if app becomes active
        .onReceive(refreshManager.$sceneActiveTick) { _ in
            refreshTrigger.toggle()
            clockIconTrigger = Date()  // Update clock icon
        }
        .onTapGesture {
            showingAllRates = true
        }
        .sheet(isPresented: $showingAllRates) {
            NavigationView {
                AllRatesListView(viewModel: viewModel)
                    .environment(\.locale, globalSettings.locale)
                    .toolbar {
                        ToolbarItem(placement: .navigationBarTrailing) {
                            Button {
                                showingAllRates = false
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
        }
    }

    // MARK: - Helper Methods

    /// Time formatter for "Until HH:mm".
    private var timeFormatter: DateFormatter {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm"
        formatter.locale = globalSettings.locale
        return formatter
    }
}
