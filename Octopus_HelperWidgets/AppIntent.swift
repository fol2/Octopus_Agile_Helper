//
//  AppIntent.swift
//  Octopus_HelperWidgets
//
//  Created by James To on 31/12/2024.
//

import WidgetKit
import AppIntents
import OctopusHelperShared

struct ConfigurationAppIntent: WidgetConfigurationIntent {
    static var title: LocalizedStringResource { "Configuration" }
    static var description: IntentDescription { "Choose which rate card to display." }

    @Parameter(title: "Card Type")
    var cardType: CardType

    init() {
        self.cardType = .lowestUpcoming
    }

    init(cardType: CardType) {
        self.cardType = cardType
    }
}

extension CardType: AppEnum {
    public static var typeDisplayRepresentation: TypeDisplayRepresentation = "Card Type"
    public static var caseDisplayRepresentations: [CardType: DisplayRepresentation] = [
        .lowestUpcoming: "Lowest Upcoming Rate",
        .highestUpcoming: "Highest Upcoming Rate",
        .averageUpcoming: "Average Upcoming Rate",
        .current: "Current Rate"
    ]
}
