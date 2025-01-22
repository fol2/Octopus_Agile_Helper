import Combine
import CoreData
import OctopusHelperShared
import SwiftUI

/// A template for creating new card views in the Octopus Agile Helper app.
/// This template provides common functionality and structure found across card views.
///
/// # Features
/// - Standard card layout with header and content sections
/// - Automatic refresh management via CardRefreshManager
/// - Loading state handling
/// - Optional detail sheet support
/// - Rate formatting and coloring via RateFormatting and RateColor
/// - Theme-based styling with Theme system
/// - Localization support
///
/// # Usage
/// 1. Copy this template and rename it to your specific card name (e.g., `MyNewCardView`)
/// 2. Update the card type in `headerView` from `.currentRate` to your card type
/// 3. Implement the `mainContentView` with your specific card content
/// 4. Add localization strings to Localizable.strings
/// 5. Optionally implement `detailView` if your card needs a detail sheet
/// 6. Add any additional properties or methods needed for your card
/// 7. Register your card in CardRegistry (see CardRegistry.swift for detailed registration guide)
///
/// # Card Registration
/// After creating your card view, you need to:
/// 1. Add your card type to the CardType enum in CardRegistry.swift
/// 2. Register your card in the registerAllCards() function
/// 3. Follow the CardDefinition template in CardRegistry.swift for proper registration
/// 4. See CardRegistry.swift for complete registration documentation and examples
///
/// # Example Implementation
/// ```swift
/// struct MyNewCardView: View {
///     // Copy the dependencies and properties from this template
///
///     // Implement your custom content in mainContentView
///     private var mainContentView: some View {
///         VStack(alignment: .leading, spacing: 8) {
///             Text("card.mycustom.title", bundle: .module)
///                 .font(Theme.mainFont())
///             // Add your card-specific UI here
///         }
///     }
/// }
/// ```
///
/// # Localization
/// Add these keys to your Localizable.strings:
/// ```
/// // Common card strings
/// "card.loading" = "Loading...";
/// "card.fetching" = "Fetching latest rates...";
/// "card.error" = "Error";
/// "card.retry" = "Retry";
/// "card.details" = "Details";
/// ```
///
/// # Best Practices
/// - Keep the card focused on a single responsibility
/// - Use RateFormatting for consistent rate display
/// - Use RateColor for consistent rate coloring
/// - Use Theme for consistent styling
/// - Use CardRefreshManager for refresh coordination
/// - Use RateCardStyle for consistent card styling
/// - Always use localized strings
/// - Handle loading and error states appropriately
@available(iOS 17.0, *)
public struct CardViewTemplate: View {
    // MARK: - Common Dependencies
    @ObservedObject var viewModel: RatesViewModel
    @EnvironmentObject var globalSettings: GlobalSettingsManager
    @EnvironmentObject var globalTimer: GlobalTimer
    @Environment(\.colorScheme) var colorScheme

    // MARK: - Refresh Management
    @ObservedObject private var refreshManager = CardRefreshManager.shared
    @State private var refreshTrigger = false

    // MARK: - View State
    @State private var showingDetails = false  // For detail sheet/navigation
    @State private var error: Error?

    // MARK: - Product Code
    private var productCode: String {
        return viewModel.currentAgileCode
    }

    // MARK: - Initialization
    public init(viewModel: RatesViewModel) {
        self.viewModel = viewModel
    }

    // MARK: - Body
    public var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            // Header row with icon + title + optional right icon
            headerView

            // Main content with loading and error handling
            if viewModel.isLoading(for: productCode) && viewModel.allRates(for: productCode).isEmpty
            {
                loadingView
            } else if let error = error {
                errorView(error)
            } else {
                mainContentView
            }
        }
        .rateCardStyle()  // Use shared card styling
        .environment(\.locale, globalSettings.locale)
        .id("card-\(refreshTrigger)-\(productCode)")  // Refresh on trigger or product code change
        // Common refresh behaviors
        .onReceive(refreshManager.$halfHourTick) { tickTime in
            guard tickTime != nil else { return }
            refreshTrigger.toggle()
        }
        .onReceive(refreshManager.$sceneActiveTick) { _ in
            refreshTrigger.toggle()
        }
        // Optional detail sheet
        .sheet(isPresented: $showingDetails) {
            detailView
        }
        // Optional tap action
        .onTapGesture {
            handleCardTap()
        }
    }

    // MARK: - View Components

    /// The header view with title and icons
    private var headerView: some View {
        HStack(alignment: .center) {
            if let def = CardRegistry.shared.definition(for: .currentRate) {  // Use .currentRate as example
                Image(systemName: def.iconName)
                    .renderingMode(.template)
                    .resizable()
                    .scaledToFit()
                    .frame(width: 20, height: 20)
                    .foregroundColor(Theme.icon)

                Text(LocalizedStringKey(def.displayNameKey))
                    .font(Theme.titleFont())
                    .foregroundColor(Theme.secondaryTextColor)

                Spacer()

                // Optional right icon/button
                if viewModel.isLoading(for: productCode) {
                    ProgressView()
                        .scaleEffect(0.7)
                } else {
                    Image(systemName: "chevron.right.circle.fill")
                        .foregroundColor(Theme.secondaryTextColor)
                }
            }
        }
    }

    /// Loading view shown when data is being fetched
    private var loadingView: some View {
        VStack(spacing: 8) {
            ProgressView("card.loading")
                .padding(.vertical, 12)
            Text("card.fetching", bundle: .module)
                .font(Theme.subFont())
                .foregroundColor(Theme.secondaryTextColor)
        }
    }

    /// Error view shown when an error occurs
    private func errorView(_ error: Error) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Label(
                title: { Text("card.error", bundle: .module) },
                icon: { Image(systemName: "exclamationmark.triangle.fill") }
            )
            .foregroundColor(.red)
            .font(Theme.secondaryFont())

            Text(error.localizedDescription)
                .font(Theme.subFont())
                .foregroundColor(Theme.secondaryTextColor)
                .multilineTextAlignment(.leading)

            Button(action: handleRetry) {
                Text("card.retry", bundle: .module)
                    .font(Theme.subFont())
                    .foregroundColor(Theme.mainColor)
            }
            .padding(.top, 4)
        }
        .padding(.vertical, 8)
    }

    /// Main content view - Implement this for your specific card
    private var mainContentView: some View {
        // Replace with your card's main content
        Text("Implement your card content here")
            .foregroundColor(Theme.secondaryTextColor)
    }

    /// Detail view shown in sheet - Implement this if your card needs it
    private var detailView: some View {
        NavigationView {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    Text("Implement your detail view here")
                        .font(Theme.secondaryFont())
                        .foregroundColor(Theme.mainTextColor)

                    // Add your detail content sections here

                    Spacer()
                }
                .padding()
            }
            .navigationTitle(Text("card.details", bundle: .module))
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button {
                        showingDetails = false
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundColor(Theme.secondaryTextColor.opacity(0.9))
                    }
                }
            }
        }
        .environmentObject(globalSettings)
        .environmentObject(globalTimer)
        .environment(\.locale, globalSettings.locale)
        .preferredColorScheme(colorScheme)
    }

    // MARK: - Helper Methods

    /// Format a rate value according to global settings
    private func formatRate(excVAT: Double, incVAT: Double) -> String {
        RateFormatting.formatRate(
            excVAT: excVAT,
            incVAT: incVAT,
            showRatesInPounds: globalSettings.settings.showRatesInPounds,
            showRatesWithVAT: globalSettings.settings.showRatesWithVAT
        )
    }

    /// Get color for a rate based on its value
    private func getRateColor(for rate: NSManagedObject) -> Color {
        RateColor.getColor(for: rate, allRates: viewModel.allRates(for: productCode))
    }

    /// Format a time range with localization support
    private func formatTimeRange(_ from: Date?, _ to: Date?) -> String {
        self.formatTimeRange(from, to, locale: globalSettings.locale)
    }

    /// Format a date according to the current locale
    private func formatDate(_ date: Date, style: DateFormatter.Style = .short) -> String {
        let formatter = DateFormatter()
        formatter.dateStyle = style
        formatter.timeStyle = .short
        formatter.locale = globalSettings.locale
        return formatter.string(from: date)
    }

    /// Format a time interval in a human-readable way
    private func formatDuration(_ interval: TimeInterval) -> String {
        let formatter = DateComponentsFormatter()
        formatter.allowedUnits = [.hour, .minute]
        formatter.unitsStyle = .abbreviated
        formatter.calendar?.locale = globalSettings.locale
        return formatter.string(from: interval) ?? ""
    }

    // MARK: - Event Handlers

    /// Handle tapping on the card
    private func handleCardTap() {
        // By default, show the detail sheet
        // Override this method to customize tap behavior
        showingDetails = true
    }

    /// Handle retry when an error occurs
    private func handleRetry() {
        // Clear error state
        error = nil
        // Trigger a refresh
        refreshTrigger.toggle()
    }
}

// MARK: - Preview Provider
@available(iOS 17.0, *)
private struct PreviewContainer: View {
    let globalTimer: GlobalTimer
    let globalSettings: GlobalSettingsManager
    let viewModel: RatesViewModel

    init() {
        self.globalTimer = GlobalTimer()
        self.globalTimer.startTimer()

        self.globalSettings = GlobalSettingsManager()
        self.viewModel = RatesViewModel(globalTimer: globalTimer)
    }

    var body: some View {
        CardViewTemplate(viewModel: viewModel)
            .environmentObject(globalSettings)
            .environmentObject(globalTimer)
            .padding()
            .preferredColorScheme(.light)
    }
}

@available(iOS 17.0, *)
#Preview {
    PreviewContainer()
}
