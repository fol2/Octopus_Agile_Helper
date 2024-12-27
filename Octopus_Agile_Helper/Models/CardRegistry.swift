import SwiftUI

/// Identifies a single card's metadata and how to produce its SwiftUI view
final class CardDefinition {
    let id: CardType                 // we'll reuse CardType as the unique identifier
    let displayNameKey: String       // e.g. "Current Rate Card"
    let descriptionKey: String       // short info about the card
    let isPremium: Bool             // indicates if the card requires purchase
    let makeView: (RatesViewModel) -> AnyView
    
    init(id: CardType, displayNameKey: String, descriptionKey: String, isPremium: Bool, makeView: @escaping (RatesViewModel) -> AnyView) {
        self.id = id
        self.displayNameKey = displayNameKey
        self.descriptionKey = descriptionKey
        self.isPremium = isPremium
        self.makeView = makeView
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
                makeView: { vm in AnyView(CurrentRateCardView(viewModel: vm)) }
            )
        )
        
        register(
            CardDefinition(
                id: .lowestUpcoming,
                displayNameKey: "Lowest Upcoming Rates",
                descriptionKey: "Shows upcoming times with the cheapest electricity rates.",
                isPremium: false,
                makeView: { vm in AnyView(LowestUpcomingRateCardView(viewModel: vm)) }
            )
        )
        
        register(
            CardDefinition(
                id: .highestUpcoming,
                displayNameKey: "Highest Upcoming Rates",
                descriptionKey: "Warns you of upcoming peak pricing times.",
                isPremium: false,
                makeView: { vm in AnyView(HighestUpcomingRateCardView(viewModel: vm)) }
            )
        )
        
        register(
            CardDefinition(
                id: .averageUpcoming,
                displayNameKey: "Average Upcoming Rates",
                descriptionKey: "Shows the average cost over selected periods or the next 10 lowest windows.",
                isPremium: true,
                makeView: { vm in AnyView(AverageUpcomingRateCardView(viewModel: vm)) }
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