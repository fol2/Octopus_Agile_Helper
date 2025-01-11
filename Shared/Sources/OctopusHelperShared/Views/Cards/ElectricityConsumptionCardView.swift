import Combine
import CoreData
import Foundation
import SwiftUI

// MARK: - Local Settings
private struct ElectricityConsumptionCardLocalSettings: Codable {
    var rowsToShow: Int
    var showChart: Bool
    var showDailyAverage: Bool
    var showWeeklyAverage: Bool
    var isDebugMode: Bool
    
    static let `default` = ElectricityConsumptionCardLocalSettings(
        rowsToShow: 5,
        showChart: true,
        showDailyAverage: true,
        showWeeklyAverage: true,
        isDebugMode: false
    )
}

private class ElectricityConsumptionCardLocalSettingsManager: ObservableObject {
    @Published var settings: ElectricityConsumptionCardLocalSettings {
        didSet { saveSettings() }
    }

    private let userDefaultsKey = "ElectricityConsumptionCardSettings"

    init() {
        if let data = UserDefaults.standard.data(forKey: userDefaultsKey),
           let decoded = try? JSONDecoder().decode(ElectricityConsumptionCardLocalSettings.self, from: data) {
            self.settings = decoded
        } else {
            self.settings = .default
        }
    }

    func saveSettings() {
        if let encoded = try? JSONEncoder().encode(settings) {
            UserDefaults.standard.set(encoded, forKey: userDefaultsKey)
        }
    }
}

// MARK: - Flip Card View
public struct ElectricityConsumptionCardView: View {
    @StateObject private var localSettings = ElectricityConsumptionCardLocalSettingsManager()
    @ObservedObject var viewModel: ConsumptionViewModel
    @EnvironmentObject var globalSettings: GlobalSettingsManager
    
    @State private var flipped = false
    @State private var isLoadingRates = false
    @State private var isSyncingAllRates = false
    @State private var lastSyncError: Error?
    
    public init(viewModel: ConsumptionViewModel) {
        self.viewModel = viewModel
    }
    
    public var body: some View {
        ZStack {
            // FRONT side
            frontSide
                .opacity(flipped ? 0 : 1)
                .rotation3DEffect(
                    .degrees(flipped ? 180 : 0),
                    axis: (x: 0, y: 1, z: 0),
                    perspective: 0.8
                )

            // BACK side (settings)
            backSide
                .opacity(flipped ? 1 : 0)
                .rotation3DEffect(
                    .degrees(flipped ? 0 : -180),
                    axis: (x: 0, y: 1, z: 0),
                    perspective: 0.8
                )
        }
        .frame(maxWidth: 400)
        .rateCardStyle()
        .task {
            // On appear, load existing data
            await viewModel.loadData()
        }
    }

    // MARK: - Front Side
    private var frontSide: some View {
        VStack(alignment: .leading, spacing: 12) {
            // Header
            HStack {
                Image(systemName: "bolt.fill")
                    .foregroundColor(Theme.icon)
                Text("Electricity Usage")
                    .font(Theme.titleFont())
                    .foregroundColor(Theme.secondaryTextColor)

                Spacer()

                Button {
                    withAnimation(.spring()) {
                        flipped = true
                    }
                } label: {
                    Image(systemName: "gearshape.fill")
                        .font(Theme.subFont())
                        .foregroundColor(Theme.secondaryTextColor)
                }
            }
            
            if viewModel.isLoading {
                loadingView
            } else if viewModel.consumptionRecords.isEmpty {
                emptyStateView
            } else {
                consumptionDataView
            }
            
            // Refresh Button
            Button {
                Task {
                    await viewModel.refreshDataFromAPI()
                }
            } label: {
                HStack {
                    Image(systemName: "arrow.clockwise")
                    Text(viewModel.isLoading ? "Updating..." : "Update Usage Data")
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 12)
            }
            .buttonStyle(.borderedProminent)
            .tint(Theme.mainColor)
            .disabled(viewModel.isLoading)
        }
        .padding(16)
    }

    // MARK: - Loading View
    private var loadingView: some View {
        VStack(spacing: 8) {
            ProgressView()
                .scaleEffect(1.2)
                .padding(.top, 16)
            Text("Fetching your electricity usage data...")
                .font(Theme.secondaryFont())
                .foregroundColor(Theme.secondaryTextColor)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 12)
    }

    // MARK: - Empty State View
    private var emptyStateView: some View {
        VStack(spacing: 8) {
            Image(systemName: "exclamationmark.triangle")
                .font(.title)
                .foregroundColor(Theme.secondaryTextColor)
            Text("No consumption data available")
                .font(Theme.subFont())
                .foregroundColor(Theme.secondaryTextColor)
            Text("Tap the button below to fetch your usage data")
                .font(Theme.secondaryFont())
                .foregroundColor(Theme.secondaryTextColor.opacity(0.7))
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 12)
    }

    // MARK: - Consumption Data View
    private var consumptionDataView: some View {
        VStack(alignment: .leading, spacing: 16) {
            // Latest Reading
            if let latestRecord = viewModel.consumptionRecords.sorted(by: { 
                ($0.value(forKey: "interval_end") as? Date ?? .distantPast) > ($1.value(forKey: "interval_end") as? Date ?? .distantPast) 
            }).first {
                latestReadingView(for: latestRecord)
            }
            
            if localSettings.settings.showDailyAverage || localSettings.settings.showWeeklyAverage {
                averagesView
            }
            
            // Recent Consumption List
            recentConsumptionListView
            
            Divider()
            
            // Data Range Info
            dataRangeView
        }
    }

    // MARK: - Latest Reading View
    private func latestReadingView(for record: NSManagedObject) -> some View {
        let consumption = record.value(forKey: "consumption") as? Double ?? 0
        let end = record.value(forKey: "interval_end") as? Date ?? Date()
        
        return HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Latest Reading")
                    .font(Theme.secondaryFont())
                    .foregroundColor(Theme.secondaryTextColor)
                Text("\(String(format: "%.2f", consumption)) kWh")
                    .font(.system(size: 24, weight: .medium))
                    .foregroundColor(Theme.mainTextColor)
            }
            
            Spacer()
            
            VStack(alignment: .trailing, spacing: 4) {
                Text("as of")
                    .font(Theme.secondaryFont())
                    .foregroundColor(Theme.secondaryTextColor)
                Text(formatTime(end))
                    .font(Theme.subFont())
                    .foregroundColor(Theme.mainTextColor)
            }
        }
        .padding(.vertical, 8)
        .padding(.horizontal, 12)
        .background(Theme.secondaryBackground)
        .cornerRadius(8)
    }

    // MARK: - Averages View
    private var averagesView: some View {
        HStack(spacing: 12) {
            if localSettings.settings.showDailyAverage {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Daily Average")
                        .font(Theme.secondaryFont())
                        .foregroundColor(Theme.secondaryTextColor)
                    Text("\(calculateDailyAverage()) kWh")
                        .font(.system(size: 18, weight: .medium))
                        .foregroundColor(Theme.mainTextColor)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            
            if localSettings.settings.showWeeklyAverage {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Weekly Average")
                        .font(Theme.secondaryFont())
                        .foregroundColor(Theme.secondaryTextColor)
                    Text("\(calculateWeeklyAverage()) kWh")
                        .font(.system(size: 18, weight: .medium))
                        .foregroundColor(Theme.mainTextColor)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(.vertical, 8)
        .padding(.horizontal, 12)
        .background(Theme.secondaryBackground)
        .cornerRadius(8)
    }

    // MARK: - Recent Consumption List View
    private var recentConsumptionListView: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Recent Usage")
                .font(Theme.subFont())
                .foregroundColor(Theme.secondaryTextColor)
            ForEach(getRecentConsumption(), id: \.interval_end) { record in
                HStack {
                    VStack(alignment: .leading) {
                        Text(formatTime(record.interval_start))
                            .font(Theme.secondaryFont())
                            .foregroundColor(Theme.secondaryTextColor)
                    }
                    
                    Spacer()
                    
                    VStack(alignment: .trailing) {
                        Text("\(String(format: "%.2f", record.consumption)) kWh")
                            .font(Theme.subFont())
                            .foregroundColor(Theme.mainTextColor)
                    }
                }
                .padding(.vertical, 4)
            }
        }
        .padding(.vertical, 8)
    }

    // MARK: - Data Range View
    private var dataRangeView: some View {
        HStack {
            VStack(alignment: .leading, spacing: 4) {
                Text("Data Range")
                    .font(Theme.secondaryFont())
                    .foregroundColor(Theme.secondaryTextColor)
                Text("\(formatOptionalDate(viewModel.minInterval)) to")
                    .font(Theme.secondaryFont())
                Text("\(formatOptionalDate(viewModel.maxInterval))")
                    .font(Theme.secondaryFont())
            }
            
            Spacer()
            
            Text("\(viewModel.consumptionRecords.count) records")
                .font(Theme.secondaryFont())
                .foregroundColor(Theme.secondaryTextColor.opacity(0.7))
        }
        .padding(.vertical, 4)
    }

    // MARK: - Back Side (Settings)
    private var backSide: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Image(systemName: "bolt.fill")
                    .foregroundColor(Theme.icon)
                Text("Usage Settings")
                    .font(Theme.titleFont())
                    .foregroundColor(Theme.secondaryTextColor)
                Spacer()
                Button {
                    withAnimation(.spring()) {
                        flipped = false
                    }
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(Theme.subFont())
                        .foregroundColor(Theme.secondaryTextColor)
                }
            }

            VStack(alignment: .leading, spacing: 16) {
                Toggle("Show Daily Average", isOn: $localSettings.settings.showDailyAverage)
                    .tint(Theme.mainColor)
                
                Toggle("Show Weekly Average", isOn: $localSettings.settings.showWeeklyAverage)
                    .tint(Theme.mainColor)
                
                Toggle("Show Usage Chart", isOn: $localSettings.settings.showChart)
                    .tint(Theme.mainColor)
                
                HStack {
                    Text("Recent records to show: \(localSettings.settings.rowsToShow)")
                    Spacer()
                    Stepper("", value: $localSettings.settings.rowsToShow, in: 1...20)
                        .labelsHidden()
                }
                
                Divider()
                    .padding(.vertical, 8)
                
                Toggle("Debug Mode", isOn: $localSettings.settings.isDebugMode)
                    .tint(Theme.mainColor)
            }
            .padding(.top, 8)

            Spacer()
        }
        .padding(16)
    }
    
    // MARK: - Date Formatting
    private func formatDate(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = globalSettings.locale
        formatter.dateFormat = "yyyy-MM-dd HH:mm"
        return formatter.string(from: date)
    }
    
    private func formatOptionalDate(_ date: Date?) -> String {
        guard let date = date else { return "N/A" }
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH:mm"
        return formatter.string(from: date)
    }

    // MARK: - Helper Methods

    private func formatTime(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = globalSettings.locale
        formatter.dateStyle = .short
        formatter.timeStyle = .short
        return formatter.string(from: date)
    }

    private func calculateDailyAverage() -> String {
        let records = viewModel.consumptionRecords
        guard !records.isEmpty else { return "N/A" }
        
        let totalConsumption = records.reduce(0.0) { sum, record in
            sum + (record.value(forKey: "consumption") as? Double ?? 0)
        }
        
        let days = Double(records.count) / 48.0 // 48 half-hour intervals per day
        guard days > 0 else { return "N/A" }
        
        return String(format: "%.1f", totalConsumption / days)
    }

    private func calculateWeeklyAverage() -> String {
        let records = viewModel.consumptionRecords
        guard !records.isEmpty else { return "N/A" }
        
        let totalConsumption = records.reduce(0.0) { sum, record in
            sum + (record.value(forKey: "consumption") as? Double ?? 0)
        }
        
        let weeks = Double(records.count) / (48.0 * 7.0) // 48 half-hour intervals per day * 7 days
        guard weeks > 0 else { return "N/A" }
        
        return String(format: "%.1f", totalConsumption / weeks)
    }

    private struct ConsumptionRecord {
        let interval_start: Date
        let interval_end: Date
        let consumption: Double
    }

    private func getRecentConsumption() -> [ConsumptionRecord] {
        let records = viewModel.consumptionRecords
            .sorted(by: {
                ($0.value(forKey: "interval_end") as? Date ?? .distantPast) > ($1.value(forKey: "interval_end") as? Date ?? .distantPast)
            })
            .prefix(localSettings.settings.rowsToShow)
            .compactMap { record -> ConsumptionRecord? in
                guard 
                    let start = record.value(forKey: "interval_start") as? Date,
                    let end = record.value(forKey: "interval_end") as? Date,
                    let consumption = record.value(forKey: "consumption") as? Double
                else { return nil }
                
                return ConsumptionRecord(
                    interval_start: start,
                    interval_end: end,
                    consumption: consumption
                )
            }
        
        return Array(records)
    }
}