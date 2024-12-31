//
//  Octopus_HelperWidgets.swift
//  Octopus_HelperWidgets
//
//  Created by James To on 31/12/2024.
//

import WidgetKit
import SwiftUI
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
        case .current:
            CurrentRateMiniWidget(rates: entry.rates)
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
                
                Text(RateFormatting.formatTime(lowest.validFrom))
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
                
                Text(RateFormatting.formatTime(highest.validFrom))
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
                
                Text("\(rates.count) upcoming rates")
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
            $0.validFrom <= Date() && $0.validTo > Date()
        }) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Current Rate")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                
                Text(RateFormatting.formatRate(current.valueIncludingVAT))
                    .font(.title2)
                    .bold()
                
                Text("Until \(RateFormatting.formatTime(current.validTo))")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
            .padding()
        } else {
            Text("No current rate")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }
}

struct Octopus_HelperWidgets: Widget {
    let kind: String = "Octopus_HelperWidgets"

    var body: some WidgetConfiguration {
        AppIntentConfiguration(kind: kind, intent: ConfigurationAppIntent.self, provider: Provider()) { entry in
            CardWidgetView(entry: entry)
                .containerBackground(.fill.tertiary, for: .widget)
        }
        .configurationDisplayName("Octopus Rate Card")
        .description("Display your chosen rate card.")
        .supportedFamilies([.systemSmall, .systemMedium])
    }
}

#Preview(as: .systemSmall) {
    Octopus_HelperWidgets()
} timeline: {
    SimpleEntry(date: .now, configuration: ConfigurationAppIntent(cardType: .lowestUpcoming), rates: [
        RateEntity(validFrom: Date(), validTo: Date().addingTimeInterval(1800), valueIncludingVAT: 15.5),
        RateEntity(validFrom: Date().addingTimeInterval(1800), validTo: Date().addingTimeInterval(3600), valueIncludingVAT: 20.0)
    ])
}
