import SwiftUI
import CoreData

struct CurrentRateCardView: View {
    // MARK: - Dependencies
    @ObservedObject var viewModel: RatesViewModel
    @Environment(\.colorScheme) var colorScheme
    @EnvironmentObject var globalSettings: GlobalSettingsManager
    @EnvironmentObject var globalTimer: GlobalTimer
    @State private var refreshTrigger = false
    
    // Timer for content refresh
    private let refreshTimer = Timer
        .publish(every: 1, on: .main, in: .common)
        .autoconnect()
    
    private func getDayRates(for date: Date) -> [RateEntity] {
        let calendar = Calendar.current
        let startOfDay = calendar.startOfDay(for: date)
        let endOfDay = calendar.date(byAdding: .day, value: 1, to: startOfDay)!
        
        return viewModel.allRates.filter { rate in
            guard let validFrom = rate.validFrom else { return false }
            return validFrom >= startOfDay && validFrom < endOfDay
        }.sorted { ($0.validFrom ?? .distantPast) < ($1.validFrom ?? .distantPast) }
    }
    
    private func getRateColor(for rate: RateEntity) -> Color {
        guard let currentValidFrom = rate.validFrom else {
            return .white
        }
        
        // Get all rates for the day
        let dayRates = getDayRates(for: currentValidFrom)
        
        // Handle negative rates
        if rate.valueIncludingVAT < 0 {
            if let mostNegative = dayRates.filter({ $0.valueIncludingVAT < 0 }).min(by: { $0.valueIncludingVAT < $1.valueIncludingVAT }) {
                let percentage = abs(rate.valueIncludingVAT / mostNegative.valueIncludingVAT)
                return Color(red: 0.2, green: 0.8, blue: 0.4).opacity(0.4 + (percentage * 0.6))
            }
            return Color(red: 0.2, green: 0.8, blue: 0.4)
        }
        
        // Find the day's rate statistics
        let sortedRates = dayRates.map { $0.valueIncludingVAT }.sorted()
        guard !sortedRates.isEmpty else { return .white }
        
        let medianRate = sortedRates[sortedRates.count / 2]
        let maxRate = sortedRates.last ?? 0
        
        let currentValue = rate.valueIncludingVAT
        
        // Only color rates above the median
        if currentValue >= medianRate {
            // Calculate how far above median this rate is
            let percentage = (currentValue - medianRate) / (maxRate - medianRate)
            
            // Base color for the softer red (RGB: 255, 69, 58)
            let baseRed = 1.0
            let baseGreen = 0.2
            let baseBlue = 0.2
            
            // For the highest rate, use the base red color at full intensity
            if currentValue == maxRate {
                return Color(red: baseRed, green: baseGreen, blue: baseBlue)
            }
            
            // For other high rates, interpolate from white to the base red color
            let intensity = 0.2 + (percentage * 0.5)
            return Color(
                red: 1.0,
                green: 1.0 - ((1.0 - baseGreen) * intensity),
                blue: 1.0 - ((1.0 - baseBlue) * intensity)
            )
        }
        
        // Lower half rates stay white
        return .white
    }
    
    // MARK: - Body
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            // Header row with left icon + title + "more" icon on right
            HStack {
                if let def = CardRegistry.shared.definition(for: .currentRate) {
                    Image(systemName: def.iconName)
                        .foregroundColor(Theme.icon)
                }
                Text("Current Rate")
                    .font(Theme.titleFont())
                    .foregroundColor(Theme.secondaryTextColor)
                Spacer()
                Image(systemName: "chevron.right.circle.fill")
                    .foregroundColor(Theme.secondaryTextColor)
            }
            
            // Content
            if viewModel.isLoading {
                ProgressView()
            } else if let currentRate = getCurrentRate() {
                // The current rate block
                VStack(alignment: .leading, spacing: 8) {
                    HStack(alignment: .firstTextBaseline) {
                        let parts = viewModel.formatRate(
                            currentRate.valueIncludingVAT,
                            showRatesInPounds: globalSettings.settings.showRatesInPounds
                        )
                        .split(separator: " ")
                        
                        // E.g., "22.58p" or "£0.2258"
                        Text(parts[0])
                            .font(Theme.mainFont())
                            .foregroundColor(RateColor.getColor(for: currentRate, allRates: viewModel.allRates))
                        
                        // E.g., "/kWh"
                        Text(parts.count > 1 ? parts[1] : "")
                            .font(Theme.subFont())
                            .foregroundColor(Theme.secondaryTextColor)
                        
                        Spacer()
                        
                        // "Until HH:mm"
                        if let validTo = currentRate.validTo {
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
        .onTapGesture {
            presentAllRatesView()
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
    
    // MARK: - Helper Methods
    
    /// Opens a full-screen list of all rates.
    private func presentAllRatesView() {
        if let scene = UIApplication.shared.connectedScenes.first as? UIWindowScene,
           let window = scene.windows.first,
           let rootViewController = window.rootViewController {
            
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
    
    /// Fetches the current active rate if any (validFrom <= now < validTo).
    private func getCurrentRate() -> RateEntity? {
        let now = Date()
        return viewModel.upcomingRates.first { rate in
            guard let start = rate.validFrom, let end = rate.validTo else { return false }
            return start <= now && end > now
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
