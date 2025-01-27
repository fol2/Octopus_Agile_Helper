import OctopusHelperShared
import SwiftUI

@MainActor
final class InfoSheetViewModel: ObservableObject {
    let title: LocalizedStringKey
    let message: LocalizedStringKey
    let mediaItems: [MediaItem]
    let linkURL: URL?
    let linkText: LocalizedStringKey?
    let isPremium: Bool
    let supportedPlans: [EnergyPlan]

    init(
        title: LocalizedStringKey,
        message: LocalizedStringKey,
        mediaItems: [MediaItem] = [],
        linkURL: URL? = nil,
        linkText: LocalizedStringKey? = nil,
        supportedPlans: [EnergyPlan] = [],
        isPremium: Bool = false
    ) {
        self.title = title
        self.message = message
        self.mediaItems = mediaItems
        self.linkURL = linkURL
        self.linkText = linkText
        self.isPremium = isPremium
        self.supportedPlans = supportedPlans
    }

    convenience init(from definition: CardDefinition) {
        self.init(
            title: LocalizedStringKey(definition.displayNameKey),
            message: LocalizedStringKey(definition.descriptionKey),
            mediaItems: definition.mediaItems,
            linkURL: definition.learnMoreURL,
            linkText: "Learn more",
            supportedPlans: definition.supportedPlans,
            isPremium: definition.isPremium
        )
    }
}
