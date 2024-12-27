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
            HStack {
                Image(systemName: "clock.fill")
                    .foregroundColor(.blue)
                Text("Current Rate")
                    .font(.headline)
                Spacer()
                Image(systemName: "chevron.right.circle.fill")
                    .foregroundStyle(.secondary.opacity(0.7))
            }
            
            if viewModel.isLoading {
                ProgressView()
            } else if let currentRate = getCurrentRate() {
                VStack(alignment: .leading, spacing: 8) {
                    HStack(alignment: .center) {
                        let parts = viewModel.formatRate(
                            currentRate.valueIncludingVAT,
                            showRatesInPounds: globalSettings.settings.showRatesInPounds
                        ).split(separator: " ")
                        Text(parts[0])
                            .font(.system(size: 34, weight: .medium))
                            .foregroundColor(.primary)
                        Text(parts[1])
                            .font(.system(size: 17))
                            .foregroundColor(.secondary)
                        Spacer()
                        if let validTo = currentRate.validTo {
                            Text(LocalizedStringKey("Until \(timeFormatter.string(from: validTo))"))
                                .font(.subheadline)
                                .foregroundColor(.primary)
                        }
                    }
                }
            } else {
                Text("No current rate available")
                    .foregroundColor(.secondary)
            }
        }
        .rateCardStyle()
        .environment(\.locale, globalSettings.locale)
        .id("current-rate-\(refreshTrigger)")
        .onChange(of: globalSettings.locale) { oldValue, newValue in
            refreshTrigger.toggle()
        }
        .onTapGesture {
            presentAllRatesView()
        }
    }
    
    // MARK: - Helper Methods
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
                                    .foregroundStyle(.secondary.opacity(0.9))
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
            hostingController.overrideUserInterfaceStyle = colorScheme == .dark ? .dark : .light
            rootViewController.present(hostingController, animated: true)
        }
    }
    
    private func getCurrentRate() -> RateEntity? {
        let now = Date()
        return viewModel.upcomingRates.first { rate in
            guard let start = rate.validFrom, let end = rate.validTo else { return false }
            return start <= now && end > now
        }
    }
    
    private var timeFormatter: DateFormatter {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm"
        formatter.locale = globalSettings.locale
        return formatter
    }
}

#if DEBUG
struct CurrentRateCardView_Previews: PreviewProvider {
    static var previews: some View {
        let globalTimer = GlobalTimer()
        let viewModel = RatesViewModel(globalTimer: globalTimer)
        CurrentRateCardView(viewModel: viewModel)
            .environmentObject(GlobalSettingsManager())
            .previewLayout(.sizeThatFits)
            .padding()
            .preferredColorScheme(.dark)
    }
}
#endif 