import SwiftUI

struct MediaItem {
    let localName: String?
    let remoteURL: URL?
    let isVideo: Bool
    let caption: LocalizedStringKey?
}

/// Identifies a single card's metadata and how to produce its SwiftUI view
final class CardDefinition {
    let id: CardType
    let displayNameKey: String
    let descriptionKey: String
    let isPremium: Bool
    let makeView: (RatesViewModel) -> AnyView
    let iconName: String
    let defaultIsEnabled: Bool
    let defaultIsPurchased: Bool
    let defaultSortOrder: Int
    let mediaItems: [MediaItem]
    let learnMoreURL: URL?
    
    init(
        id: CardType,
        displayNameKey: String,
        descriptionKey: String,
        isPremium: Bool,
        makeView: @escaping (RatesViewModel) -> AnyView,
        iconName: String,
        defaultIsEnabled: Bool = true,
        defaultIsPurchased: Bool = true,
        defaultSortOrder: Int,
        mediaItems: [MediaItem] = [],
        learnMoreURL: URL? = nil
    ) {
        self.id = id
        self.displayNameKey = displayNameKey
        self.descriptionKey = descriptionKey
        self.isPremium = isPremium
        self.makeView = makeView
        self.iconName = iconName
        self.defaultIsEnabled = defaultIsEnabled
        self.defaultIsPurchased = defaultIsPurchased
        self.defaultSortOrder = defaultSortOrder
        self.mediaItems = mediaItems
        self.learnMoreURL = learnMoreURL
    }
}

/// Central registry for all card definitions and metadata
final class CardRegistry {
    static let shared = CardRegistry()
    
    // A dictionary mapping CardType -> CardDefinition
    private var definitions: [CardType: CardDefinition] = [:]
    
    private init() {
        // Register all known cards here
        register(
            CardDefinition(
                id: .currentRate,
                displayNameKey: "Current Rate",
                descriptionKey: "Displays the ongoing rate for the current half-hour slot.",
                isPremium: false,
                makeView: { vm in AnyView(CurrentRateCardView(viewModel: vm)) },
                iconName: "clock.fill",
                defaultSortOrder: 1,
                mediaItems: [
                    MediaItem(
                        localName: "imgCurrentRateInfo",
                        remoteURL: nil,
                        isVideo: false,
                        caption: LocalizedStringKey("Current Rate Card in the Cards view")
                    ),
                    MediaItem(
                        localName: "imgCurrentRateInfo2",
                        remoteURL: nil,
                        isVideo: false,
                        caption: LocalizedStringKey("Detailed rates list after expanded")
                    )
                ],
                learnMoreURL: URL(string: "")
            )
        )
        
        register(
            CardDefinition(
                id: .lowestUpcoming,
                displayNameKey: "Lowest Upcoming Rates",
                descriptionKey: "Shows upcoming times with the cheapest electricity rates.",
                isPremium: false,
                makeView: { vm in AnyView(LowestUpcomingRateCardView(viewModel: vm)) },
                iconName: "chevron.down",
                defaultSortOrder: 2,
                mediaItems: [
                    MediaItem(
                        localName: "imgLowestRatesOverview",
                        remoteURL: nil,
                        isVideo: false,
                        caption: LocalizedStringKey("Overview of lowest rates card")
                    ),
                    MediaItem(
                        localName: "vidLowestRatesDemo",
                        remoteURL: nil,
                        isVideo: true,
                        caption: LocalizedStringKey("How to find the best rates")
                    )
                ],
                learnMoreURL: URL(string: "https://octopus.energy/help/lowest-rates")
            )
        )
        
        register(
            CardDefinition(
                id: .highestUpcoming,
                displayNameKey: "Highest Upcoming Rates",
                descriptionKey: "Warns you of upcoming peak pricing times.",
                isPremium: false,
                makeView: { vm in AnyView(HighestUpcomingRateCardView(viewModel: vm)) },
                iconName: "chevron.up",
                defaultSortOrder: 3,
                mediaItems: [
                    MediaItem(
                        localName: "imgHighestRatesOverview",
                        remoteURL: nil,
                        isVideo: false,
                        caption: LocalizedStringKey("Overview of highest rates card")
                    ),
                    MediaItem(
                        localName: "vidHighestRatesDemo",
                        remoteURL: nil,
                        isVideo: true,
                        caption: LocalizedStringKey("How to find the best rates")
                    )
                ],
                learnMoreURL: URL(string: "https://octopus.energy/help/highest-rates")
            )
        )
        
        register(
            CardDefinition(
                id: .averageUpcoming,
                displayNameKey: "Average Upcoming Rates",
                descriptionKey: "Shows the average cost over selected periods or the next 10 lowest windows.",
                isPremium: true,
                makeView: { vm in AnyView(AverageUpcomingRateCardView(viewModel: vm)) },
                iconName: "chart.bar.fill",
                defaultSortOrder: 4,
                mediaItems: [
                    MediaItem(
                        localName: "imgAverageRatesOverview",
                        remoteURL: nil,
                        isVideo: false,
                        caption: LocalizedStringKey("Overview of average rates card")
                    ),
                    MediaItem(
                        localName: "vidAverageRatesDemo",
                        remoteURL: nil,
                        isVideo: true,
                        caption: LocalizedStringKey("How to find the best rates")
                    )
                ],
                learnMoreURL: URL(string: "https://octopus.energy/help/average-rates")
            )
        )
        
        register(
            CardDefinition(
                id: .interactiveChart,
                displayNameKey: "Interactive Rate Chart",
                descriptionKey: "A dynamic line chart showing rates, best time ranges, and more.",
                isPremium: true,
                makeView: { vm in AnyView(InteractiveLineChartCardView(viewModel: vm)) },
                iconName: "chart.xyaxis.line",
                defaultSortOrder: 5,
                mediaItems: [
                    MediaItem(
                        localName: "imgInteractiveChartOverview",
                        remoteURL: nil,
                        isVideo: false,
                        caption: LocalizedStringKey("Overview of interactive chart card")
                    ),
                    MediaItem(
                        localName: "vidInteractiveChartDemo",
                        remoteURL: nil,
                        isVideo: true,
                        caption: LocalizedStringKey("How to use interactive chart")
                    )
                ],
                learnMoreURL: URL(string: "https://octopus.energy/help/interactive-chart")
            )
        )
    }
    
    private func register(_ definition: CardDefinition) {
        definitions[definition.id] = definition
    }
    
    /// Public accessor to fetch a card definition (if it exists)
    func definition(for type: CardType) -> CardDefinition? {
        definitions[type]
    }
} 
