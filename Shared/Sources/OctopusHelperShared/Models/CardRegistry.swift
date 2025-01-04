import SwiftUI

public struct MediaItem {
    public let localName: String?
    public let remoteURL: URL?
    public let youtubeID: String?
    public let caption: LocalizedStringKey?

    public var isVideo: Bool {
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

    public init(
        localName: String? = nil,
        remoteURL: URL? = nil,
        youtubeID: String? = nil,
        caption: LocalizedStringKey? = nil
    ) {
        self.localName = localName
        self.remoteURL = remoteURL
        self.youtubeID = youtubeID
        self.caption = caption
    }
}

/// Identifies a single card's metadata and how to produce its SwiftUI view
public final class CardDefinition {
    public let id: CardType
    public let displayNameKey: String
    public let descriptionKey: String
    public let isPremium: Bool
    public let makeView: (Any) -> AnyView
    public let makeWidgetView: (Any) -> AnyView
    public let iconName: String
    public let defaultIsEnabled: Bool
    public let defaultIsPurchased: Bool
    public let defaultSortOrder: Int
    public let mediaItems: [MediaItem]
    public let learnMoreURL: URL?

    public init(
        id: CardType,
        displayNameKey: String,
        descriptionKey: String,
        isPremium: Bool,
        makeView: @escaping (Any) -> AnyView,
        makeWidgetView: @escaping (Any) -> AnyView,
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
        self.makeWidgetView = makeWidgetView
        self.iconName = iconName
        self.defaultIsEnabled = defaultIsEnabled
        self.defaultIsPurchased = defaultIsPurchased
        self.defaultSortOrder = defaultSortOrder
        self.mediaItems = mediaItems
        self.learnMoreURL = learnMoreURL
    }
}

/// Central registry for all card definitions and metadata
public final class CardRegistry {
    public static let shared = CardRegistry()

    // A dictionary mapping CardType -> CardDefinition
    private var definitions: [CardType: CardDefinition] = [:]

    private init() {
        // Register all cards automatically on initialization
        registerAllCards()
    }

    /// Register all standard cards automatically
    private func registerAllCards() {
        register(
            CardDefinition(
                id: .currentRate,
                displayNameKey: "Current Rate",
                descriptionKey: "Displays the ongoing rate for the current half-hour slot.",
                isPremium: false,
                makeView: { vm in AnyView(CurrentRateCardView(viewModel: vm as! RatesViewModel)) },
                makeWidgetView: { vm in AnyView(CurrentRateCardView(viewModel: vm as! RatesViewModel)) },
                iconName: ClockModel.iconName(),
                defaultSortOrder: 1,
                mediaItems: [
                    MediaItem(
                        localName: "imgCurrentRateInfo",
                        caption: LocalizedStringKey("Current Rate Card in the Cards view")
                    ),
                    MediaItem(
                        localName: "imgCurrentRateInfo2",
                        caption: LocalizedStringKey("Detailed rates list after expanded")
                    ),
                ]
            )
        )

        register(
            CardDefinition(
                id: .lowestUpcoming,
                displayNameKey: "Lowest Upcoming Rates",
                descriptionKey: "Shows upcoming times with the cheapest electricity rates.",
                isPremium: false,
                makeView: { vm in
                    AnyView(LowestUpcomingRateCardView(viewModel: vm as! RatesViewModel))
                },
                makeWidgetView: { _ in AnyView(EmptyView()) },
                iconName: "chevron.down",
                defaultSortOrder: 2,
                mediaItems: [
                    MediaItem(
                        localName: "imgLowestRateInfo",
                        caption: LocalizedStringKey("Simple card view to find lowest rates")
                    ),
                    MediaItem(
                        localName: "imgLowestRateInfo2",
                        caption: LocalizedStringKey("Settings to list more lower rates")
                    ),
                ]
            )
        )

        register(
            CardDefinition(
                id: .highestUpcoming,
                displayNameKey: "Highest Upcoming Rates",
                descriptionKey: "Warns you of upcoming peak pricing times.",
                isPremium: false,
                makeView: { vm in
                    AnyView(HighestUpcomingRateCardView(viewModel: vm as! RatesViewModel))
                },
                makeWidgetView: { _ in AnyView(EmptyView()) },
                iconName: "chevron.up",
                defaultSortOrder: 3,
                mediaItems: [
                    MediaItem(
                        localName: "imgHighestRateInfo",
                        caption: LocalizedStringKey("Overview of highest rates card")
                    ),
                    MediaItem(
                        localName: "imgHighestRateInfo2",
                        caption: LocalizedStringKey("How to find more higher rates")
                    ),
                ]
            )
        )

        register(
            CardDefinition(
                id: .averageUpcoming,
                displayNameKey: "Average Upcoming Rates",
                descriptionKey:
                    "Shows the average cost over selected periods or the next 10 lowest windows.",
                isPremium: true,
                makeView: { vm in
                    AnyView(AverageUpcomingRateCardView(viewModel: vm as! RatesViewModel))
                },
                makeWidgetView: { _ in AnyView(EmptyView()) },
                iconName: "chart.bar.fill",
                defaultSortOrder: 4,
                mediaItems: [
                    MediaItem(
                        localName: "imgAvgRateInfo",
                        caption: LocalizedStringKey("Overview of average rates card")
                    ),
                    MediaItem(
                        localName: "imgAvgRateInfo2",
                        caption: LocalizedStringKey(
                            "You can choose length of period to average and how many rates to show")
                    ),
                ]
            )
        )

        register(
            CardDefinition(
                id: .interactiveChart,
                displayNameKey: "Interactive Rates",
                descriptionKey: "A dynamic line chart showing rates, best time ranges, and more.",
                isPremium: true,
                makeView: { vm in
                    AnyView(InteractiveLineChartCardView(viewModel: vm as! RatesViewModel))
                },
                makeWidgetView: { _ in AnyView(EmptyView()) },
                iconName: "chart.xyaxis.line",
                defaultSortOrder: 5,
                mediaItems: [
                    MediaItem(
                        localName: "imgChartRateInfo",
                        caption: LocalizedStringKey(
                            "An interactive chart to see rates over time, also shows best time ranges"
                        )
                    ),
                    MediaItem(
                        localName: "imgChartRateInfo2",
                        caption: LocalizedStringKey(
                            "You can customise the best time ranges for example set the average hours and how many in the list, which we've learnt from average rates cards"
                        )
                    ),
                ]
            )
        )
    }

    public func register(_ definition: CardDefinition) {
        definitions[definition.id] = definition
    }

    /// Public accessor to fetch a card definition (if it exists)
    public func definition(for type: CardType) -> CardDefinition? {
        definitions[type]
    }
}
