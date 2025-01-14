import Charts
import Combine
import CoreData
import SwiftUI

// MARK: - ConsumptionSection
struct ConsumptionSection: View {
    @EnvironmentObject private var globalSettings: GlobalSettingsManager
    @ObservedObject var consumptionVM: ConsumptionViewModel

    var body: some View {
        Section(header: Text("Consumption")) {
            if globalSettings.settings.electricityMPAN != nil
                && globalSettings.settings.electricityMeterSerialNumber != nil
            {
                // Status
                HStack {
                    Text("Status:")
                    Text(statusText)
                        .foregroundColor(statusColor)
                }
                .onAppear {
                    print("Debug - ConsumptionSection appeared")
                    print("Debug - MPAN: \(globalSettings.settings.electricityMPAN ?? "nil")")
                    print("Debug - Meter Serial: \(globalSettings.settings.electricityMeterSerialNumber ?? "nil")")
                    print("Debug - Fetch Status: \(statusText)")
                    print("Debug - Record Count: \(consumptionVM.consumptionRecords.count)")
                    if let minDate = consumptionVM.minInterval,
                       let maxDate = consumptionVM.maxInterval {
                        print("Debug - Date Range: \(minDate.formatted()) to \(maxDate.formatted())")
                    }
                    if let latest = consumptionVM.consumptionRecords.first,
                       let consumption = latest.value(forKey: "consumption") as? Double,
                       let interval = latest.value(forKey: "interval_end") as? Date {
                        print("Debug - Latest Reading: \(consumption) kWh at \(interval.formatted())")
                    }
                }
                .onChange(of: consumptionVM.fetchStatus) { _, newStatus in
                    print("Debug - Consumption Fetch Status Changed: \(newStatus)")
                }
                
                // Data Range
                if let minDate = consumptionVM.minInterval,
                   let maxDate = consumptionVM.maxInterval {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Data Range:")
                            .font(.caption)
                            .foregroundColor(.secondary)
                        Text("\(minDate.formatted()) to")
                            .font(.caption)
                        Text(maxDate.formatted())
                            .font(.caption)
                    }
                }
                
                // Record Count
                Text("Records: \(consumptionVM.consumptionRecords.count)")
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .onChange(of: consumptionVM.consumptionRecords.count) { _, newCount in
                        print("Debug - Consumption Records Count Changed: \(newCount)")
                    }
                
                // Latest Consumption
                if let latest = consumptionVM.consumptionRecords.first {
                    if let consumption = latest.value(forKey: "consumption") as? Double,
                       let interval = latest.value(forKey: "interval_end") as? Date {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Latest Reading:")
                                .font(.caption)
                                .foregroundColor(.secondary)
                            Text("\(consumption, specifier: "%.2f") kWh at")
                                .font(.caption)
                            Text(interval.formatted())
                                .font(.caption)
                        }
                    }
                }
            } else {
                Text("Configure MPAN and Meter Serial to view consumption")
                    .foregroundColor(.secondary)
                    .onAppear {
                        print("Debug - ConsumptionSection: Missing Configuration")
                        print("Debug - MPAN exists: \(globalSettings.settings.electricityMPAN != nil)")
                        print("Debug - Meter Serial exists: \(globalSettings.settings.electricityMeterSerialNumber != nil)")
                    }
            }
        }
    }
    
    private var statusText: String {
        switch consumptionVM.fetchStatus {
        case .none: return "Idle"
        case .fetching: return "Fetching..."
        case .done: return "Complete"
        case .failed: return "Failed"
        case .pending: return "Pending"
        }
    }
    
    private var statusColor: Color {
        switch consumptionVM.fetchStatus {
        case .none: return .primary
        case .fetching: return .blue
        case .done: return .green
        case .failed: return .red
        case .pending: return .orange
        }
    }
} 