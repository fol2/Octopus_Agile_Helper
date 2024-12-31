//
//  Octopus_HelperWidgets.swift
//  Octopus_HelperWidgets
//
//  Created by James To on 31/12/2024.
//

import WidgetKit
import SwiftUI
import AppIntents
import OctopusHelperShared

struct Provider: AppIntentTimelineProvider {
    let repository = RatesRepository.shared
    
    func placeholder(in context: Context) -> SimpleEntry {
        SimpleEntry(date: Date(), configuration: ConfigurationAppIntent(), rates: [])
    }

    func snapshot(for configuration: ConfigurationAppIntent, in context: Context) async -> SimpleEntry {
        // For previews and snapshots, use empty data
        SimpleEntry(date: Date(), configuration: configuration, rates: [])
    }
    
    func timeline(for configuration: ConfigurationAppIntent, in context: Context) async -> Timeline<SimpleEntry> {
        do {
            // Fetch latest rates
            try await repository.updateRates()
            let rates = try await repository.fetchAllRates()
            
            let entry = SimpleEntry(
                date: Date(),
                configuration: configuration,
                rates: rates
            )
            
            // Update every 30 minutes
            let nextUpdate = Calendar.current.date(byAdding: .minute, value: 30, to: Date()) ?? Date()
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

struct CardWidgetView: View {
    let entry: SimpleEntry
    
    var body: some View {
        switch entry.configuration.cardType {
        case .lowestUpcoming:
            LowestRateMiniWidget(rates: entry.rates)
        case .highestUpcoming:
            HighestRateMiniWidget(rates: entry.rates)
        case .averageUpcoming:
            AverageRateMiniWidget(rates: entry.rates)
        case .currentRate:
            CurrentRateMiniWidget(rates: entry.rates)
        case .interactiveChart:
            Text("Interactive Chart not available in widget")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }
}

struct LowestRateMiniWidget: View {
    let rates: [RateEntity]
    
    var body: some View {
        if let lowest = rates.min(by: { $0.valueIncludingVAT < $1.valueIncludingVAT }) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Lowest Rate")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                
                Text(RateFormatting.formatRate(lowest.valueIncludingVAT))
                    .font(.title2)
                    .bold()
                
                if let validFrom = lowest.validFrom {
                    Text(RateFormatting.formatTime(validFrom))
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
            .padding()
        } else {
            Text("No rates available")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }
}

struct HighestRateMiniWidget: View {
    let rates: [RateEntity]
    
    var body: some View {
        if let highest = rates.max(by: { $0.valueIncludingVAT < $1.valueIncludingVAT }) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Highest Rate")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                
                Text(RateFormatting.formatRate(highest.valueIncludingVAT))
                    .font(.title2)
                    .bold()
                
                if let validFrom = highest.validFrom {
                    Text(RateFormatting.formatTime(validFrom))
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
            .padding()
        } else {
            Text("No rates available")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }
}

struct AverageRateMiniWidget: View {
    let rates: [RateEntity]
    
    var body: some View {
        if !rates.isEmpty {
            let average = rates.reduce(0.0) { $0 + $1.valueIncludingVAT } / Double(rates.count)
            
            VStack(alignment: .leading, spacing: 4) {
                Text("Average Rate")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                
                Text(RateFormatting.formatRate(average))
                    .font(.title2)
                    .bold()
                
                Text("Next 24 hours")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
            .padding()
        } else {
            Text("No rates available")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }
}

struct CurrentRateMiniWidget: View {
    let rates: [RateEntity]
    
    var body: some View {
        if let current = rates.first(where: { 
            guard let validFrom = $0.validFrom, let validTo = $0.validTo else { return false }
            return Date() >= validFrom && Date() < validTo
        }) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Current Rate")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                
                Text(RateFormatting.formatRate(current.valueIncludingVAT))
                    .font(.title2)
                    .bold()
                
                if let validTo = current.validTo {
                    Text("Until \(RateFormatting.formatTime(validTo))")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
            .padding()
        } else {
            Text("No current rate available")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }
}

struct Octopus_HelperWidgets: Widget {
    let kind: String = "Octopus_HelperWidgets"

    var body: some WidgetConfiguration {
        AppIntentConfiguration(
            kind: kind,
            intent: ConfigurationAppIntent.self,
            provider: Provider()
        ) { entry in
            CardWidgetView(entry: entry)
                .containerBackground(.fill.tertiary, for: .widget)
        }
        .configurationDisplayName("Octopus Rate Card")
        .description("Display your chosen rate card.")
        .supportedFamilies([.systemSmall])
    }
}

#Preview(as: .systemSmall) {
    Octopus_HelperWidgets()
} timeline: {
    SimpleEntry(date: .now, configuration: ConfigurationAppIntent(), rates: [])
    SimpleEntry(date: .now, configuration: ConfigurationAppIntent(), rates: [
        RateEntity(validFrom: Date(), validTo: Date().addingTimeInterval(1800), valueIncludingVAT: 15.5)
    ])
}
