import SwiftUI

/// Identifies which plan(s) a given card supports.
public enum SupportedPlan: String, Codable {
    case agile
    case flux
    case any
}

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

public enum CardType: String, Codable, CaseIterable, Equatable {
    case currentRate
    case lowestUpcoming
    case highestUpcoming
    case averageUpcoming
    case interactiveChart
    case accountTariff
}

/// Identifies a single card's metadata and how to produce its SwiftUI view
public final class CardDefinition {
    public let id: CardType
    public let displayNameKey: String
    public let descriptionKey: String
    public let isPremium: Bool
    public let makeView: (CardDependencies) -> AnyView
    public let makeWidgetView: (Any) -> AnyView  // Keep this as Any for now since widgets aren't affected
    public let iconName: String
    public let defaultIsEnabled: Bool
    public let defaultIsPurchased: Bool
    public let defaultSortOrder: Int
    public let mediaItems: [MediaItem]
    public let learnMoreURL: URL?
    public let supportedPlans: [SupportedPlan]

    public init(
        id: CardType,
        displayNameKey: String,
        descriptionKey: String,
        isPremium: Bool,
        makeView: @escaping (CardDependencies) -> AnyView,
        makeWidgetView: @escaping (Any) -> AnyView,
        iconName: String,
        defaultIsEnabled: Bool = true,
        defaultIsPurchased: Bool = true,
        defaultSortOrder: Int,
        mediaItems: [MediaItem] = [],
        learnMoreURL: URL? = nil,
        supportedPlans: [SupportedPlan] = [.any]
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
        self.supportedPlans = supportedPlans
    }
}

/// Central registry for all card definitions and metadata
public final class CardRegistry: ObservableObject {
    public static let shared = CardRegistry()

    // A dictionary mapping CardType -> CardDefinition
    private var definitions: [CardType: CardDefinition] = [:]
    private var timer: GlobalTimer?

    @Published public private(set) var isReady: Bool = false

    private init() {
        // Register all cards automatically on initialization
        registerAllCards()
        // Set ready state after initialization
        self.isReady = true
    }

    public func updateTimer(_ timer: GlobalTimer) {
        self.timer = timer
    }

    /// Register all standard cards automatically
    private func registerAllCards() {
        register(
            CardDefinition(
                id: .currentRate,
                displayNameKey: "Current Rate",
                descriptionKey: "Shows the current electricity rate and when it changes.",
                isPremium: false,
                makeView: { deps in
                    AnyView(CurrentRateCardView(viewModel: deps.ratesViewModel))
                },
                makeWidgetView: { _ in AnyView(EmptyView()) },
                iconName: "clock",
                defaultSortOrder: 1,
                mediaItems: [
                    MediaItem(
                        localName: "imgCurrentRateInfo",
                        caption: LocalizedStringKey("Simple card view to show current rate")
                    ),
                    MediaItem(
                        localName: "imgCurrentRateInfo2",
                        caption: LocalizedStringKey("Shows when rate changes")
                    ),
                ],
                supportedPlans: [.agile]
            )
        )

        register(
            CardDefinition(
                id: .lowestUpcoming,
                displayNameKey: "Lowest Upcoming Rates",
                descriptionKey: "Shows upcoming times with the cheapest electricity rates.",
                isPremium: false,
                makeView: { deps in
                    AnyView(LowestUpcomingRateCardView(viewModel: deps.ratesViewModel))
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
                ],
                supportedPlans: [.agile]
            )
        )

        register(
            CardDefinition(
                id: .highestUpcoming,
                displayNameKey: "Highest Upcoming Rates",
                descriptionKey: "Warns you of upcoming peak pricing times.",
                isPremium: false,
                makeView: { deps in
                    AnyView(HighestUpcomingRateCardView(viewModel: deps.ratesViewModel))
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
                ],
                supportedPlans: [.agile]
            )
        )

        register(
            CardDefinition(
                id: .averageUpcoming,
                displayNameKey: "Average Upcoming Rates",
                descriptionKey:
                    "Shows the average cost over selected periods or the next 10 lowest windows.",
                isPremium: true,
                makeView: { deps in
                    AnyView(AverageUpcomingRateCardView(viewModel: deps.ratesViewModel))
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
                ],
                supportedPlans: [.agile]
            )
        )

        register(
            CardDefinition(
                id: .interactiveChart,
                displayNameKey: "Interactive Rates",
                descriptionKey: "A dynamic line chart showing rates, best time ranges, and more.",
                isPremium: true,
                makeView: { deps in
                    AnyView(InteractiveLineChartCardView(viewModel: deps.ratesViewModel))
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
                ],
                supportedPlans: [.agile]
            )
        )

        register(
            CardDefinition(
                id: .accountTariff,
                displayNameKey: "Account Tariff",
                descriptionKey:
                    "View your account's tariff costs with daily, weekly, and monthly breakdowns.",
                isPremium: true,
                makeView: { deps in
                    AnyView(
                        AccountTariffCardView(
                            viewModel: deps.ratesViewModel, consumptionVM: deps.consumptionViewModel
                        ))
                },
                makeWidgetView: { _ in AnyView(EmptyView()) },
                iconName: "chart.bar.doc.horizontal",
                defaultSortOrder: 6,
                mediaItems: [],
                supportedPlans: [.any]
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

    // MARK: - Public API
    @MainActor
    public func createDependencies(
        ratesViewModel: RatesViewModel,
        consumptionViewModel: ConsumptionViewModel,
        globalTimer: GlobalTimer,
        globalSettings: GlobalSettingsManager
    ) -> CardDependencies {
        CardDependencies(
            ratesViewModel: ratesViewModel,
            consumptionViewModel: consumptionViewModel,
            globalTimer: globalTimer,
            globalSettings: globalSettings
        )
    }
}
