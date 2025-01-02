//
//  Octopus_HelperWidgets.swift
//  Octopus_HelperWidgets
//
//  Created by James To on 31/12/2024.
//

import AppIntents
import OctopusHelperShared
import SwiftUI
import WidgetKit

@available(iOS 17.0, *)
struct Provider: AppIntentTimelineProvider {
    private var repository: RatesRepository {
        get async {
            await MainActor.run { RatesRepository.shared }
        }
    }

    func placeholder(in context: Context) -> SimpleEntry {
        SimpleEntry(date: Date(), configuration: ConfigurationAppIntent(), rates: [])
    }

    func snapshot(for configuration: ConfigurationAppIntent, in context: Context) async
        -> SimpleEntry
    {
        // For previews and snapshots, use empty data
        SimpleEntry(date: Date(), configuration: configuration, rates: [])
    }

    func timeline(for configuration: ConfigurationAppIntent, in context: Context) async -> Timeline<
        SimpleEntry
    > {
        do {
            // Fetch latest rates
            let repo = await repository
            try await repo.updateRates()
            let rates = try await repo.fetchAllRates()

            let entry = SimpleEntry(
                date: Date(),
                configuration: configuration,
                rates: rates
            )

            // Update every 30 minutes
            let nextUpdate =
                Calendar.current.date(byAdding: .minute, value: 30, to: Date()) ?? Date()
            return Timeline(entries: [entry], policy: .after(nextUpdate))
        } catch {
            // If we fail to fetch data, try again in 5 minutes
            let entry = SimpleEntry(date: Date(), configuration: configuration, rates: [])
            let retryDate = Calendar.current.date(byAdding: .minute, value: 5, to: Date()) ?? Date()
            return Timeline(entries: [entry], policy: .after(retryDate))
        }
    }
}

struct SimpleEntry: TimelineEntry {
    let date: Date
    let configuration: ConfigurationAppIntent
    let rates: [RateEntity]
}

@available(iOS 17.0, *)
struct CardWidgetView: View {
    let entry: SimpleEntry

    var body: some View {
        switch entry.configuration.cardType {
        case .lowestUpcoming:
            LowestRateMiniWidget(rates: entry.rates)
                .padding(.horizontal, 4)
                .padding(.vertical, 4)
                .background(Theme.secondaryBackground)
                .cornerRadius(12)
        case .highestUpcoming:
            HighestRateMiniWidget(rates: entry.rates)
                .padding(.horizontal, 4)
                .padding(.vertical, 4)
                .background(Theme.secondaryBackground)
                .cornerRadius(12)
        case .averageUpcoming:
            AverageRateMiniWidget(rates: entry.rates)
                .padding(.horizontal, 4)
                .padding(.vertical, 4)
                .background(Theme.secondaryBackground)
                .cornerRadius(12)
        case .currentRate:
            CurrentRateMiniWidget(rates: entry.rates)
                .padding(.horizontal, 4)
                .padding(.vertical, 4)
                .background(Theme.secondaryBackground)
                .cornerRadius(12)
        case .interactiveChart:
            Text("Interactive Chart not available in widget")
                .font(Theme.subFont())
                .foregroundColor(Theme.secondaryTextColor)
                .padding(.horizontal, 4)
                .padding(.vertical, 4)
                .background(Theme.secondaryBackground)
                .cornerRadius(12)
        }
    }
}

@available(iOS 17.0, *)
struct LowestRateMiniWidget: View {
    let rates: [RateEntity]

    var body: some View {
        if let lowest = rates.min(by: { $0.valueIncludingVAT < $1.valueIncludingVAT }) {
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Image(systemName: "chart.bar.fill")
                        .foregroundColor(Theme.icon)
                        .font(Theme.subFont())
                    Text("Lowest Rate")
                        .font(Theme.subFont())
                        .foregroundColor(Theme.secondaryTextColor)
                }

                Text(RateFormatting.formatRate(lowest.valueIncludingVAT))
                    .font(Theme.mainFont())
                    .foregroundColor(RateColor.getColor(for: lowest, allRates: rates))
                    .minimumScaleFactor(0.5)
                    .lineLimit(1)

                if let validFrom = lowest.validFrom {
                    Text(RateFormatting.formatTime(validFrom))
                        .font(Theme.subFont())
                        .foregroundColor(Theme.secondaryTextColor)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        } else {
            Text("No rates available")
                .font(Theme.subFont())
                .foregroundColor(Theme.secondaryTextColor)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        }
    }
}

@available(iOS 17.0, *)
struct HighestRateMiniWidget: View {
    let rates: [RateEntity]

    var body: some View {
        if let highest = rates.max(by: { $0.valueIncludingVAT < $1.valueIncludingVAT }) {
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundColor(Theme.icon)
                        .font(Theme.subFont())
                    Text("Highest Rate")
                        .font(Theme.subFont())
                        .foregroundColor(Theme.secondaryTextColor)
                }

                Text(RateFormatting.formatRate(highest.valueIncludingVAT))
                    .font(Theme.mainFont())
                    .foregroundColor(RateColor.getColor(for: highest, allRates: rates))
                    .minimumScaleFactor(0.5)
                    .lineLimit(1)

                if let validFrom = highest.validFrom {
                    Text(RateFormatting.formatTime(validFrom))
                        .font(Theme.subFont())
                        .foregroundColor(Theme.secondaryTextColor)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        } else {
            Text("No rates available")
                .font(Theme.subFont())
                .foregroundColor(Theme.secondaryTextColor)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        }
    }
}

@available(iOS 17.0, *)
struct AverageRateMiniWidget: View {
    let rates: [RateEntity]

    var body: some View {
        if !rates.isEmpty {
            let average = rates.reduce(0.0) { $0 + $1.valueIncludingVAT } / Double(rates.count)

            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Image(systemName: "chart.bar.fill")
                        .foregroundColor(Theme.icon)
                        .font(Theme.subFont())
                    Text("Average Rate")
                        .font(Theme.subFont())
                        .foregroundColor(Theme.secondaryTextColor)
                }

                Text(RateFormatting.formatRate(average))
                    .font(Theme.mainFont())
                    .foregroundColor(Theme.mainTextColor)
                    .minimumScaleFactor(0.5)
                    .lineLimit(1)

                Text("Next 24 hours")
                    .font(Theme.subFont())
                    .foregroundColor(Theme.secondaryTextColor)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        } else {
            Text("No rates available")
                .font(Theme.subFont())
                .foregroundColor(Theme.secondaryTextColor)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        }
    }
}

@available(iOS 17.0, *)
struct CurrentRateMiniWidget: View {
    let rates: [RateEntity]

    var body: some View {
        if let current = rates.first(where: {
            guard let validFrom = $0.validFrom, let validTo = $0.validTo else { return false }
            return Date() >= validFrom && Date() < validTo
        }) {
            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: 0) {
                    Image(systemName: "bolt.fill")
                        .foregroundColor(Theme.icon)
                        .font(Theme.subFont())
                    Text("Current Rate")
                        .font(Theme.subFont())
                        .foregroundColor(Theme.secondaryTextColor)
                }

                Text(RateFormatting.formatRate(current.valueIncludingVAT))
                    .font(Theme.mainFont())
                    .foregroundColor(RateColor.getColor(for: current, allRates: rates))
                    .minimumScaleFactor(0.5)
                    .lineLimit(1)

                if let validTo = current.validTo {
                    Text("Until \(RateFormatting.formatTime(validTo))")
                        .font(Theme.subFont())
                        .foregroundColor(Theme.secondaryTextColor)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        } else {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 4) {
                    Image(systemName: "bolt.fill")
                        .foregroundColor(Theme.icon)
                        .font(Theme.subFont())
                    Text("Current Rate")
                        .font(Theme.subFont())
                        .foregroundColor(Theme.secondaryTextColor)
                }

                Text("No current rate")
                    .font(Theme.mainFont())
                    .foregroundColor(Theme.mainTextColor)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        }
    }
}

@available(iOS 17.0, *)
struct Octopus_HelperWidgets: Widget {
    let kind: String = "Octopus_HelperWidgets"

    var body: some WidgetConfiguration {
        AppIntentConfiguration(
            kind: kind,
            intent: ConfigurationAppIntent.self,
            provider: Provider()
        ) { entry in
            CardWidgetView(entry: entry)
                .containerBackground(.clear, for: .widget)
        }
        .configurationDisplayName("Octopus Rate Card")
        .description("Display your chosen rate card.")
        .supportedFamilies([.systemSmall])
    }
}

#Preview(as: .systemSmall) {
    Octopus_HelperWidgets()
} timeline: {
    let context = PersistenceController.preview.container.viewContext
    let previewRate = RateEntity(context: context)
    previewRate.id = UUID().uuidString
    previewRate.validFrom = Date()
    previewRate.validTo = Date().addingTimeInterval(1800)
    previewRate.valueIncludingVAT = 15.5
    previewRate.valueExcludingVAT = 12.5

    return [
        SimpleEntry(date: .now, configuration: ConfigurationAppIntent(), rates: []),
        SimpleEntry(date: .now, configuration: ConfigurationAppIntent(), rates: [previewRate]),
    ]
}
