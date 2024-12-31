//
//  AppIntent.swift
//  Octopus_HelperWidgets
//
//  Created by James To on 31/12/2024.
//

// AppIntent.swift
import WidgetKit
import AppIntents

// 1) Define your CardType enum here with AppEnum
enum CardType: String, CaseIterable, AppEnum {
    case lowestUpcoming
    case highestUpcoming
    case averageUpcoming
    case currentRate
    case interactiveChart   // Include if you want to switch on it

    // Compile-time static properties:
    static let typeDisplayRepresentation = TypeDisplayRepresentation(name: "Card Type")

    static let caseDisplayRepresentations: [CardType: DisplayRepresentation] = [
        .lowestUpcoming: "Lowest Upcoming",
        .highestUpcoming: "Highest Upcoming",
        .averageUpcoming: "Average Upcoming",
        .currentRate: "Current Rate",
        .interactiveChart: "Interactive Chart"
    ]
}

// 2) Define your ConfigurationAppIntent in the same file
struct ConfigurationAppIntent: WidgetConfigurationIntent {
    static var title: LocalizedStringResource = "Configuration"
    static var description: IntentDescription = "Choose which rate card to display."

    // We can give a default, or let it be optional.
    // Non-optional + default is often easiest:
    @Parameter(title: "Card Type", default: .lowestUpcoming)
    var cardType: CardType

    init() {}
}
