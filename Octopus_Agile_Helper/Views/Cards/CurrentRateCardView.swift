import SwiftUI
import CoreData

struct CurrentRateCardView: View {
    // MARK: - Dependencies
    @ObservedObject var viewModel: RatesViewModel
    @Environment(\.colorScheme) var colorScheme
    @EnvironmentObject var globalSettings: GlobalSettingsManager
    @EnvironmentObject var globalTimer: GlobalTimer
    @State private var refreshTrigger = false
    
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
                            .foregroundColor(Theme.mainTextColor)
                        
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
