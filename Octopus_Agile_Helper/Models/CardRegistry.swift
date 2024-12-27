import SwiftUI

/// Identifies a single card's metadata and how to produce its SwiftUI view
final class CardDefinition {
    let id: CardType                 // we'll reuse CardType as the unique identifier
    let displayName: String          // e.g. "Current Rate Card"
    let description: String          // short info about the card
    let isPremium: Bool             // indicates if the card requires purchase
    let makeView: (RatesViewModel) -> AnyView
    
    init(id: CardType, displayName: String, description: String, isPremium: Bool, makeView: @escaping (RatesViewModel) -> AnyView) {
        self.id = id
        self.displayName = displayName
        self.description = description
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
                displayName: String(localized: "Current Rate"),
                description: String(localized: "Displays the ongoing rate for the current half-hour slot."),
                isPremium: false,
                makeView: { vm in AnyView(CurrentRateCardView(viewModel: vm)) }
            )
        )
        
        register(
            CardDefinition(
                id: .lowestUpcoming,
                displayName: String(localized: "Lowest Upcoming Rates"),
                description: String(localized: "Shows upcoming times with the cheapest electricity rates."),
                isPremium: false,
                makeView: { vm in AnyView(LowestUpcomingRateCardView(viewModel: vm)) }
            )
        )
        
        register(
            CardDefinition(
                id: .highestUpcoming,
                displayName: String(localized: "Highest Upcoming Rates"),
                description: String(localized: "Warns you of upcoming peak pricing times."),
                isPremium: false,
                makeView: { vm in AnyView(HighestUpcomingRateCardView(viewModel: vm)) }
            )
        )
        
        register(
            CardDefinition(
                id: .averageUpcoming,
                displayName: String(localized: "Average Upcoming Rates"),
                description: String(localized: "Shows the average cost over selected periods or the next 10 lowest windows."),
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