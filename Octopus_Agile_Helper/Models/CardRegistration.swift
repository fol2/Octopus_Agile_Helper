import OctopusHelperShared
import SwiftUI

extension CardRegistry {
    static func registerCards() {
        shared.register(
            CardDefinition(
                id: .currentRate,
                displayNameKey: "Current Rate",
                descriptionKey: "Displays the ongoing rate for the current half-hour slot.",
                isPremium: false,
                makeView: { vm in AnyView(CurrentRateCardView(viewModel: vm as! RatesViewModel)) },
                iconName: "clock.fill",
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

        shared.register(
            CardDefinition(
                id: .lowestUpcoming,
                displayNameKey: "Lowest Upcoming Rates",
                descriptionKey: "Shows upcoming times with the cheapest electricity rates.",
                isPremium: false,
                makeView: { vm in
                    AnyView(LowestUpcomingRateCardView(viewModel: vm as! RatesViewModel))
                },
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

        shared.register(
            CardDefinition(
                id: .highestUpcoming,
                displayNameKey: "Highest Upcoming Rates",
                descriptionKey: "Warns you of upcoming peak pricing times.",
                isPremium: false,
                makeView: { vm in
                    AnyView(HighestUpcomingRateCardView(viewModel: vm as! RatesViewModel))
                },
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

        shared.register(
            CardDefinition(
                id: .averageUpcoming,
                displayNameKey: "Average Upcoming Rates",
                descriptionKey:
                    "Shows the average cost over selected periods or the next 10 lowest windows.",
                isPremium: true,
                makeView: { vm in
                    AnyView(AverageUpcomingRateCardView(viewModel: vm as! RatesViewModel))
                },
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

        shared.register(
            CardDefinition(
                id: .interactiveChart,
                displayNameKey: "Interactive Rates",
                descriptionKey: "A dynamic line chart showing rates, best time ranges, and more.",
                isPremium: true,
                makeView: { vm in
                    AnyView(InteractiveLineChartCardView(viewModel: vm as! RatesViewModel))
                },
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
}
