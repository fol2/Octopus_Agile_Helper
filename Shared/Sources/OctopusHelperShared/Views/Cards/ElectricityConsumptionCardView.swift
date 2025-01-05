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
    
    static let `default` = ElectricityConsumptionCardLocalSettings(
        rowsToShow: 5,
        showChart: true,
        showDailyAverage: true,
        showWeeklyAverage: true
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
    @State private var debugRates: [RateEntity] = []
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
            await loadDebugRates()
        }
    }

    private func loadDebugRates() async {
        isLoadingRates = true
        defer { isLoadingRates = false }
        
        if let ratesRepo = try? RatesRepository.shared {
            debugRates = (try? await ratesRepo.fetchAllRates()) ?? []
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
            } else if viewModel.consumptionRecords.isEmpty {
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
            } else {
                // Summary Section
                VStack(alignment: .leading, spacing: 16) {
                    // Latest Reading
                    if let latestRecord = viewModel.consumptionRecords.sorted(by: { 
                        ($0.value(forKey: "interval_end") as? Date ?? .distantPast) > ($1.value(forKey: "interval_end") as? Date ?? .distantPast) 
                    }).first {
                        let consumption = latestRecord.value(forKey: "consumption") as? Double ?? 0
                        let end = latestRecord.value(forKey: "interval_end") as? Date ?? Date()
                        
                        HStack(alignment: .center, spacing: 12) {
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
                    
                    if localSettings.settings.showDailyAverage || localSettings.settings.showWeeklyAverage {
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
                    
                    // Recent Consumption List
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Recent Usage")
                            .font(Theme.subFont())
                            .foregroundColor(Theme.secondaryTextColor)
                        
                        ForEach(getRecentConsumption(), id: \.interval_end) { record in
                            HStack {
                                Text(formatTime(record.interval_start))
                                    .font(Theme.secondaryFont())
                                    .foregroundColor(Theme.secondaryTextColor)
                                Spacer()
                                Text("\(String(format: "%.2f", record.consumption)) kWh")
                                    .font(Theme.subFont())
                                    .foregroundColor(Theme.mainTextColor)
                            }
                            .padding(.vertical, 4)
                        }
                    }
                    .padding(.vertical, 8)
                    
                    Divider()
                    
                    // Data Range Info
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

            // DEBUG: Sync All Rates Button
            Button {
                Task {
                    isSyncingAllRates = true
                    lastSyncError = nil
                    do {
                        try await RatesRepository.shared.syncAllRates()
                        // Refresh our local debug rates after sync
                        await loadDebugRates()
                    } catch {
                        lastSyncError = error
                        print("Error syncing all rates: \(error)")
                    }
                    isSyncingAllRates = false
                }
            } label: {
                HStack {
                    if isSyncingAllRates {
                        ProgressView()
                            .scaleEffect(0.8)
                            .padding(.trailing, 4)
                    }
                    Image(systemName: "arrow.triangle.2.circlepath")
                    Text(isSyncingAllRates ? "Syncing All Historical Rates..." : "Debug: Sync All Rates")
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 8)
            }
            .buttonStyle(.bordered)
            .tint(.orange)
            .disabled(isSyncingAllRates || viewModel.isLoading)
            
            // DEBUG: Display Rate Info
            VStack(alignment: .leading, spacing: 4) {
                Text("Debug Rate Info:")
                    .font(Theme.secondaryFont())
                    .foregroundColor(Theme.secondaryTextColor)
                
                if isLoadingRates || isSyncingAllRates {
                    ProgressView(isLoadingRates ? "Loading rates..." : "Syncing rates...")
                        .scaleEffect(0.8)
                } else {
                    Text("Total Rates in DB: \(debugRates.count)")
                        .font(Theme.secondaryFont())
                    
                    if let firstRate = debugRates.first,
                       let lastRate = debugRates.last {
                        Text("Historical Coverage:")
                            .font(Theme.secondaryFont())
                            .foregroundColor(Theme.secondaryTextColor)
                            .padding(.top, 4)
                        
                        Text("Earliest: \(formatOptionalDate(firstRate.validFrom))")
                            .font(Theme.secondaryFont())
                        Text("Latest: \(formatOptionalDate(lastRate.validTo))")
                            .font(Theme.secondaryFont())
                        
                        if let repo = try? RatesRepository.shared {
                            Text("Has Coverage Through Expected End: \(repo.hasDataThroughExpectedEndUKTime() ? "Yes" : "No")")
                                .font(Theme.secondaryFont())
                                .foregroundColor(repo.hasDataThroughExpectedEndUKTime() ? .green : .red)
                        }
                    }
                    
                    if let error = lastSyncError {
                        Text("Last Sync Error:")
                            .font(Theme.secondaryFont())
                            .foregroundColor(.red)
                            .padding(.top, 4)
                        Text(error.localizedDescription)
                            .font(Theme.secondaryFont())
                            .foregroundColor(.red)
                            .lineLimit(2)
                    }
                }
            }
            .padding(.vertical, 8)
            .padding(.horizontal, 12)
            .background(Theme.secondaryBackground.opacity(0.5))
            .cornerRadius(8)
        }
        .padding(16)
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
            }
            .padding(.top, 8)
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