import SwiftUI

struct MediaItem {
    let localName: String?
    let remoteURL: URL?
    let youtubeID: String?
    let caption: LocalizedStringKey?
    
    var isVideo: Bool {
        if youtubeID != nil { return true }
        if let localName = localName {
            return Bundle.main.url(forResource: localName, withExtension: "mp4") != nil
        }
        if let remoteURL = remoteURL {
            let pathExtension = remoteURL.pathExtension.lowercased()
            return ["mp4", "mov", "m4v"].contains(pathExtension)
        }
        return false
    }
    
    init(localName: String? = nil, 
         remoteURL: URL? = nil, 
         youtubeID: String? = nil,
         caption: LocalizedStringKey? = nil) {
        self.localName = localName
        self.remoteURL = remoteURL
        self.youtubeID = youtubeID
        self.caption = caption
    }
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
                        caption: LocalizedStringKey("Current Rate Card in the Cards view")
                    ),
                    MediaItem(
                        localName: "imgCurrentRateInfo2",
                        remoteURL: nil,
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
                        localName: "imgLowestRateInfo",
                        remoteURL: nil,
                        caption: LocalizedStringKey("Simple card view to find lowest rates")
                    ),
                    MediaItem(
                        localName: "imgLowestRateInfo2",
                        remoteURL: nil,
                        caption: LocalizedStringKey("Settings to list more lower rates")
                    )
                ],
                learnMoreURL: URL(string: "")
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
                        localName: "imgHighestRateInfo",
                        remoteURL: nil,
                        caption: LocalizedStringKey("Overview of highest rates card")
                    ),
                    MediaItem(
                        localName: "imgHighestRateInfo2",
                        remoteURL: nil,
                        caption: LocalizedStringKey("How to find more higher rates")
                    )
                ],
                learnMoreURL: URL(string: "")
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
                        localName: "imgAvgRateInfo",
                        remoteURL: nil,
                        caption: LocalizedStringKey("Overview of average rates card")
                    ),
                    MediaItem(
                        localName: "imgAvgRateInfo2",
                        remoteURL: nil,
                        caption: LocalizedStringKey("You can choose length of period to average and how many rates to show")
                    )
                ],
                learnMoreURL: URL(string: "")
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
                        localName: "imgChartRateInfo",
                        remoteURL: nil,
                        caption: LocalizedStringKey("An interactive chart to see rates over time, also shows best time ranges")
                    ),
                    MediaItem(
                        localName: "imgChartRateInfo2",
                        remoteURL: nil,
                        caption: LocalizedStringKey("You can customise the best time ranges for example set the average hours and how many in the list, which we've learnt from average rates cards")
                    )
                ],
                learnMoreURL: URL(string: "")
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
