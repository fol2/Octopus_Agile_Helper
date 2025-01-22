import SwiftUI

/// Card Type Registration Guide
///
/// When adding a new card type to the system, follow these guidelines:
///
/// 1. Naming Convention:
/// - Use camelCase
/// - Be descriptive but concise
/// - Focus on the card's primary function
/// - Examples: currentRate, lowestUpcoming, dailyUsage
///
/// 2. Organization:
/// - Group related cards together
/// - Keep rate-related cards together
/// - Keep usage-related cards together
/// - Keep analysis cards together
///
/// 3. Implementation Steps:
/// - Add new case here in CardType enum
/// - Create corresponding view file in Cards directory
/// - Register card in registerAllCards() function
/// - Follow CardDefinition template for registration
///
/// 4. Best Practices:
/// - Ensure unique, descriptive names
/// - Consider future extensibility
/// - Document any special requirements
/// - Maintain logical grouping
///
/// Example:
///     case dailyUsage     // Shows daily electricity usage
///     case weeklyAnalysis // Provides weekly usage analysis
///     case costComparison // Compares costs between tariffs
///
/// Identifies which card type is being used
public enum CardType: String, Codable, CaseIterable, Equatable {
    case interactiveChart
    case currentRate
    case lowestUpcoming
    case highestUpcoming
    case averageUpcoming
    case accountTariff
}

extension CardRegistry {
    /// Card Registration Guide
    ///
    /// This function registers all standard cards in the application. Follow this template when adding new cards:
    ///
    /// register(
    ///     CardDefinition(
    ///         // REQUIRED: Unique identifier for the card
    ///         id: .cardIdentifier,
    ///
    ///         // REQUIRED: Display name shown to users (localized)
    ///         displayNameKey: "Card Name",
    ///
    ///         // REQUIRED: Detailed description of card functionality (localized)
    ///         descriptionKey: "Description of what this card does and its value to users.",
    ///
    ///         // REQUIRED: Whether this is a premium feature
    ///         isPremium: false,
    ///
    ///         // REQUIRED: Main view builder - must return AnyView
    ///         makeView: { deps in
    ///             AnyView(YourCardView(viewModel: deps.requiredViewModel))
    ///         },
    ///
    ///         // REQUIRED: Widget view builder - use EmptyView if no widget
    ///         makeWidgetView: { _ in AnyView(EmptyView()) },
    ///
    ///         // REQUIRED: SF Symbol name for card icon
    ///         iconName: "symbol.name",
    ///
    ///         // REQUIRED: Default position in card list (1-based)
    ///         defaultSortOrder: nextAvailableOrder,
    ///
    ///         // OPTIONAL: Help/documentation images
    ///         mediaItems: [
    ///             MediaItem(
    ///                 localName: "imgCardInfo",
    ///                 caption: LocalizedStringKey("Main feature description")
    ///             ),
    ///             MediaItem(
    ///                 localName: "imgCardInfo2",
    ///                 caption: LocalizedStringKey("Additional feature or setting description")
    ///             ),
    ///         ],
    ///
    ///         // REQUIRED: Compatible tariff plans ([.agile], [.any], etc.)
    ///         supportedPlans: [.agile]
    ///     )
    /// )
    ///
    /// Best Practices:
    /// - Use descriptive IDs that reflect the card's primary function
    /// - Provide clear, user-focused descriptions
    /// - Include helpful media items for premium features
    /// - Maintain logical sort order with existing cards
    /// - Ensure view models are properly injected through dependencies
    ///
    internal func registerAllCards() {
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
}
