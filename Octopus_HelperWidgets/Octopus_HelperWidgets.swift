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

class Provider: NSObject, AppIntentTimelineProvider {
    override init() {
        super.init()
        CardRegistry.shared.registerWidgetCards()
    }
    
    private var repository: RatesRepository {
        get async {
            await MainActor.run { RatesRepository.shared }
        }
    }
    
    private var sharedDefaults: UserDefaults? {
        UserDefaults(suiteName: "group.com.jamesto.OctopusHelper")
    }
    
    private func getSettings() -> (postcode: String, showRatesInPounds: Bool, language: String) {
        let defaults = sharedDefaults
        // Try to read the full settings object first
        if let data = defaults?.data(forKey: "user_settings"),
           let settings = try? JSONDecoder().decode(GlobalSettings.self, from: data) {
            print("Widget: Read settings from encoded data - showRatesInPounds: \(settings.showRatesInPounds), language: \(settings.selectedLanguage.rawValue)")
            return (
                postcode: settings.postcode,
                showRatesInPounds: settings.showRatesInPounds,
                language: settings.selectedLanguage.rawValue
            )
        }
        
        // Fallback to individual keys if full settings not available
        let settings = (
            postcode: defaults?.string(forKey: "selected_postcode") ?? "",
            showRatesInPounds: defaults?.bool(forKey: "show_rates_in_pounds") ?? false,
            language: defaults?.string(forKey: "selected_language") ?? "en"
        )
        print("Widget: Using fallback settings - showRatesInPounds: \(settings.showRatesInPounds), language: \(settings.language)")
        return settings
    }
    
    private func getRegionID() async throws -> String {
        let postcode = getSettings().postcode
        // Use postcode to determine region, fallback to "H" if empty
        if postcode.isEmpty { return "H" }
        
        // Use RatesRepository to fetch region
        let repo = await repository
        return try await repo.fetchRegionID(for: postcode) ?? "H"
    }
    
    private func formatRate(_ rate: Double) -> String {
        let settings = getSettings()
        if settings.showRatesInPounds {
            return String(format: "£%.3f", rate / 100.0)
        } else {
            return String(format: "%.2f", rate)
        }
    }
    
    private func rateView(value: Double, color: Color, font: Font = .subheadline) -> some View {
        let settings = getSettings()
        return HStack(alignment: .firstTextBaseline, spacing: 0) {
            Text(formatRate(value))
                .font(font)
                .foregroundColor(color)
                .lineLimit(1)
                .minimumScaleFactor(0.5)
            Text(settings.showRatesInPounds ? "/kWh" : "p/kWh")
                .font(font == Theme.mainFont() ? Theme.secondaryFont() : .caption2)
                .foregroundColor(Theme.secondaryTextColor)
                .scaleEffect(font == Theme.mainFont() ? 0.95 : 0.8)
        }
        .environment(\.locale, Locale(identifier: settings.language))
    }
    
    private func fetchRatesDirectly() async throws -> [RateEntity] {
        let client = OctopusAPIClient.shared
        let regionID = try await getRegionID()  // Use shared settings
        
        let rates = try await client.fetchRates(regionID: regionID)
        
        // Convert to RateEntity and save to CoreData
        let context = PersistenceController.shared.container.viewContext
        let entities = rates.map { rate in
            let entity = RateEntity(context: context)
            entity.id = UUID().uuidString
            entity.validFrom = rate.valid_from
            entity.validTo = rate.valid_to
            entity.valueExcludingVAT = rate.value_exc_vat
            entity.valueIncludingVAT = rate.value_inc_vat
            return entity
        }
        
        // Save to CoreData
        if context.hasChanges {
            do {
                try context.save()
                print("Widget: Successfully saved direct fetch rates to CoreData")
            } catch {
                print("Widget: Failed to save rates to CoreData: \(error.localizedDescription)")
                // Even if save fails, return the entities for widget display
            }
        }
        
        return entities
    }

    func placeholder(in context: Context) -> SimpleEntry {
        SimpleEntry(
            date: Date(),
            configuration: ConfigurationAppIntent(),
            rates: [],
            settings: getSettings()
        )
    }

    func snapshot(for configuration: ConfigurationAppIntent, in context: Context) async -> SimpleEntry {
        SimpleEntry(
            date: Date(),
            configuration: configuration,
            rates: [],
            settings: getSettings()
        )
    }
    
    private func getNextHalfHourDate(from date: Date = Date()) -> Date {
        let calendar = Calendar.current
        let components = calendar.dateComponents([.year, .month, .day, .hour, .minute], from: date)
        
        let minute = components.minute ?? 0
        let targetMinute = minute >= 30 ? 0 : 30
        var dateComponents = DateComponents()
        dateComponents.year = components.year
        dateComponents.month = components.month
        dateComponents.day = components.day
        dateComponents.hour = targetMinute == 0 ? (components.hour ?? 0) + 1 : components.hour
        dateComponents.minute = targetMinute
        dateComponents.second = 0
        
        return calendar.date(from: dateComponents) ?? date.addingTimeInterval(30 * 60)
    }
    
    private func getRefreshDates(from currentDate: Date) -> [Date] {
        let calendar = Calendar.current
        var dates: [Date] = []
        
        // Add current date
        dates.append(currentDate)
        
        // Calculate next refresh times
        var nextDate = currentDate
        for _ in 0..<8 { // Next 4 hours (8 half-hour intervals)
            // Get next half hour
            nextDate = getNextHalfHourDate(from: nextDate)
            
            // Add a date 2 minutes before the half hour for pre-loading
            if let preloadDate = calendar.date(byAdding: .minute, value: -2, to: nextDate) {
                dates.append(preloadDate)
            }
            
            // Add the exact half hour
            dates.append(nextDate)
            
            // Add a date 2 minutes after the half hour for safety
            if let postloadDate = calendar.date(byAdding: .minute, value: 2, to: nextDate) {
                dates.append(postloadDate)
            }
        }
        
        return dates.sorted()
    }

    func timeline(for configuration: ConfigurationAppIntent, in context: Context) async -> Timeline<SimpleEntry> {
        do {
            let repo = await repository
            try await repo.updateRates()
            var rates = try await repo.fetchAllRates()
            
            // If no rates in storage, try direct fetch
            if rates.isEmpty {
                do {
                    rates = try await fetchRatesDirectly()
                } catch {
                    print("Widget: Direct fetch failed: \(error.localizedDescription)")
                }
            }
            
            let currentDate = Date()
            let refreshDates = getRefreshDates(from: currentDate)
            
            // Create entries for all refresh dates
            let entries = refreshDates.map { date in
                print("Widget: Creating entry for \(date) with settings: \(getSettings())")
                return SimpleEntry(
                    date: date,
                    configuration: configuration,
                    rates: rates,
                    settings: getSettings()  // Get fresh settings for each entry
                )
            }
            
            // Set next reload date to be very soon to ensure quick refresh
            let nextRefreshDate = Date().addingTimeInterval(1)
            
            print("Widget: Next refresh scheduled for \(nextRefreshDate)")
            return Timeline(entries: entries, policy: .after(nextRefreshDate))
            
        } catch {
            print("Widget: Timeline generation failed: \(error.localizedDescription)")
            
            let currentDate = Date()
            let settings = getSettings()
            
            // Try direct fetch as last resort
            var rates: [RateEntity] = []
            do {
                rates = try await fetchRatesDirectly()
            } catch {
                print("Widget: Last resort direct fetch failed: \(error.localizedDescription)")
            }
            
            // Even on error, create multiple entries with shorter intervals
            var entries: [SimpleEntry] = []
            
            // Current entry
            entries.append(SimpleEntry(date: currentDate, configuration: configuration, rates: rates, settings: settings))
            
            // Entry for very soon (quick retry)
            let retryDate = Date().addingTimeInterval(1)
            entries.append(SimpleEntry(date: retryDate, configuration: configuration, rates: rates, settings: settings))
            
            print("Widget: Error occurred, will retry at \(retryDate)")
            
            return Timeline(entries: entries, policy: .after(retryDate))
        }
    }
}

struct SimpleEntry: TimelineEntry {
    let date: Date
    let configuration: ConfigurationAppIntent
    let rates: [RateEntity]
    let settings: (postcode: String, showRatesInPounds: Bool, language: String)
}

struct CurrentRateWidget: View {
    let rates: [RateEntity]
    let settings: (postcode: String, showRatesInPounds: Bool, language: String)
    
    private func formatRate(_ rate: Double) -> String {
        if settings.showRatesInPounds {
            return String(format: "£%.3f", rate / 100.0)
        } else {
            return String(format: "%.2f", rate)
        }
    }
    
    private func rateView(value: Double, color: Color, font: Font = .subheadline) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 0) {
            Text(formatRate(value))
                .font(font)
                .foregroundColor(color)
                .lineLimit(1)
                .minimumScaleFactor(0.5)
            Text(settings.showRatesInPounds ? "/kWh" : "p/kWh")
                .font(font == Theme.mainFont() ? Theme.secondaryFont() : .caption2)
                .foregroundColor(Theme.secondaryTextColor)
                .scaleEffect(font == Theme.mainFont() ? 0.9 : 0.8)
        }
        .environment(\.locale, Locale(identifier: settings.language))
    }
    
    var currentRate: RateEntity? {
        rates.first { rate in
            guard let validFrom = rate.validFrom, let validTo = rate.validTo else { return false }
            return Date() >= validFrom && Date() < validTo
        }
    }
    
    var upcomingRates: [RateEntity] {
        rates.filter { rate in
            guard let validFrom = rate.validFrom else { return false }
            return validFrom > Date()
        }.sorted { ($0.validFrom ?? .distantPast) < ($1.validFrom ?? .distantPast) }
    }
    
    var highestUpcoming: RateEntity? {
        upcomingRates.max(by: { $0.valueIncludingVAT < $1.valueIncludingVAT })
    }
    
    var lowestUpcoming: RateEntity? {
        upcomingRates.min(by: { $0.valueIncludingVAT < $1.valueIncludingVAT })
    }
    
    func formatTimeRange(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm"
        return formatter.string(from: date)
    }
    
    var body: some View {
        ZStack {
            Theme.mainBackground
                .ignoresSafeArea()
            
            if let rate = currentRate {
                VStack(alignment: .leading, spacing: 4) {
                    // Current Rate
                    HStack {
                        Image(systemName: "clock.fill")
                            .foregroundColor(Theme.icon)
                            .font(Theme.subFont())
                        Text("Agile Current")
                            .font(Theme.subFont())
                            .foregroundColor(Theme.secondaryTextColor)
                    }
                    
                    // Rate Value with smaller unit
                    rateView(value: rate.valueIncludingVAT, 
                            color: RateColor.getColor(for: rate, allRates: rates),
                            font: Theme.mainFont())
                    
                    if let validTo = rate.validTo {
                        Text("Until \(formatTimeRange(validTo))")
                            .font(.caption2)
                            .foregroundColor(Theme.secondaryTextColor)
                    }
                    
                    Spacer(minLength: 8)
                    
                    // Upcoming Rates
                    VStack(alignment: .leading, spacing: 2) {
                        if let lowest = lowestUpcoming, let validFrom = lowest.validFrom {
                            HStack(spacing: 2) {
                                Image(systemName: "chevron.down")
                                    .font(.caption)
                                    .foregroundColor(Theme.icon)
                                rateView(value: lowest.valueIncludingVAT, 
                                       color: RateColor.getColor(for: lowest, allRates: rates),
                                       font: Theme.titleFont())
                                Spacer(minLength: 4)
                                Text(formatTimeRange(validFrom))
                                    .font(.caption2)
                                    .foregroundColor(Theme.secondaryTextColor)
                            }
                        }
                        
                        if let highest = highestUpcoming, let validFrom = highest.validFrom {
                            HStack(spacing: 2) {
                                Image(systemName: "chevron.up")
                                    .font(.caption)
                                    .foregroundColor(Theme.icon)
                                rateView(value: highest.valueIncludingVAT, 
                                       color: RateColor.getColor(for: highest, allRates: rates),
                                       font: Theme.titleFont())
                                Spacer(minLength: 4)
                                Text(formatTimeRange(validFrom))
                                    .font(.caption2)
                                    .foregroundColor(Theme.secondaryTextColor)
                            }
                        }
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
                .environment(\.locale, Locale(identifier: settings.language))
            } else {
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Image(systemName: "clock.fill")
                            .foregroundColor(Theme.icon)
                            .font(Theme.subFont())
                        Text("Agile Current")
                            .font(Theme.subFont())
                            .foregroundColor(Theme.secondaryTextColor)
                    }
                    
                    Text("No current rate")
                        .font(Theme.mainFont2())
                        .foregroundColor(Theme.mainTextColor)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
                .environment(\.locale, Locale(identifier: settings.language))
            }
        }
        .id("\(settings.showRatesInPounds)_\(settings.language)")  // Force view refresh when settings change
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
            CurrentRateWidget(rates: entry.rates, settings: entry.settings)
                .containerBackground(Theme.mainBackground, for: .widget)
        }
        .configurationDisplayName("Current Rate")
        .description("Display the current electricity rate.")
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
    previewRate.valueExcludingVAT = 12.5
    previewRate.valueIncludingVAT = 15.5
    
    return [
        SimpleEntry(date: .now, configuration: ConfigurationAppIntent(), rates: [], settings: ("", false, "en")),
        SimpleEntry(date: .now, configuration: ConfigurationAppIntent(), rates: [previewRate], settings: ("", false, "en")),
    ]
}
