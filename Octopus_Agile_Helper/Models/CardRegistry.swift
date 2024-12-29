import SwiftUI

/// Identifies a single card's metadata and how to produce its SwiftUI view
final class CardDefinition {
    let id: CardType                 // we'll reuse CardType as the unique identifier
    let displayNameKey: String       // e.g. "Current Rate Card"
    let descriptionKey: String       // short info about the card
    let isPremium: Bool             // indicates if the card requires purchase
    let makeView: (RatesViewModel) -> AnyView
    let iconName: String            // SF Symbol name for the card
    
    // Default config fields
    let defaultIsEnabled: Bool
    let defaultIsPurchased: Bool
    let defaultSortOrder: Int
    
    init(
        id: CardType,
        displayNameKey: String,
        descriptionKey: String,
        isPremium: Bool,
        makeView: @escaping (RatesViewModel) -> AnyView,
        iconName: String,
        defaultIsEnabled: Bool = true,
        defaultIsPurchased: Bool = true,
        defaultSortOrder: Int
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
                defaultIsEnabled: true,
                defaultIsPurchased: true,
                defaultSortOrder: 1
            )
        )
        
        register(
            CardDefinition(
                id: .lowestUpcoming,
                displayNameKey: "Lowest Upcoming Rates",
                descriptionKey: "Shows upcoming times with the cheapest electricity rates.",
                isPremium: false,
                makeView: { vm in AnyView(LowestUpcomingRateCardView(viewModel: vm)) },
                iconName: "arrow.down.circle.fill",
                defaultIsEnabled: true,
                defaultIsPurchased: true,
                defaultSortOrder: 2
            )
        )
        
        register(
            CardDefinition(
                id: .highestUpcoming,
                displayNameKey: "Highest Upcoming Rates",
                descriptionKey: "Warns you of upcoming peak pricing times.",
                isPremium: false,
                makeView: { vm in AnyView(HighestUpcomingRateCardView(viewModel: vm)) },
                iconName: "arrow.up.circle.fill",
                defaultIsEnabled: true,
                defaultIsPurchased: true,
                defaultSortOrder: 3
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
                defaultIsEnabled: true,
                defaultIsPurchased: true,
                defaultSortOrder: 4
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
                defaultIsEnabled: true,
                defaultIsPurchased: true,
                defaultSortOrder: 5
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
