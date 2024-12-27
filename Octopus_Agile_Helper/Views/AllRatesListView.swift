import SwiftUI
import CoreData

struct AllRatesListView: View {
    @ObservedObject var viewModel: RatesViewModel
    @Environment(\.dismiss) var dismiss
    @EnvironmentObject var globalSettings: GlobalSettingsManager
    @State private var refreshTrigger = false
    
    private var dateFormatter: DateFormatter {
        let formatter = DateFormatter()
        if globalSettings.locale.language.languageCode?.identifier == "zh" {
            formatter.dateFormat = "MM月dd日"
        } else {
            formatter.dateFormat = "d MMM"  // UK format
        }
        formatter.locale = globalSettings.locale
        return formatter
    }
    
    private var ratesByDate: [(String, [RateEntity])] {
        let grouped = Dictionary(grouping: viewModel.allRates) { rate in
            if let date = rate.validFrom {
                return dateFormatter.string(from: date)
            }
            return String(localized: "Unknown Date")
        }
        // Sort by date ascending (earliest first)
        return grouped.map { ($0.key, $0.value) }
            .sorted { pair1, pair2 in
                guard let date1 = pair1.1.first?.validFrom,
                      let date2 = pair2.1.first?.validFrom else {
                    return false
                }
                return date1 < date2
            }
    }
    
    var body: some View {
        ScrollViewReader { scrollProxy in
            List {
                ForEach(ratesByDate, id: \.0) { dateString, rates in
                    Section {
                        ForEach(rates, id: \.objectID) { rate in
                            HStack(spacing: 8) {
                                Text("\(viewModel.formatTime(rate.validFrom ?? Date())) - \(viewModel.formatTime(rate.validTo ?? Date()))")
                                    .font(.subheadline)
                                    .frame(minWidth: 110, alignment: .leading)
                                
                                let parts = viewModel.formatRate(
                                    rate.valueIncludingVAT,
                                    showRatesInPounds: globalSettings.settings.showRatesInPounds
                                ).split(separator: " ")
                                HStack(alignment: .firstTextBaseline, spacing: 1) {
                                    Text(parts[0])  // Now includes currency symbol
                                        .font(.headline)
                                    Text(parts[1])  // Just "/kWh"
                                        .font(.caption)
                                }
                                .frame(minWidth: 80, alignment: .trailing)
                                
                                Spacer()
                                
                                if isRateCurrentlyActive(rate) {
                                    Text("NOW")
                                        .font(.caption)
                                        .fontWeight(.bold)
                                        .foregroundColor(.white)
                                        .padding(.horizontal, 6)
                                        .padding(.vertical, 2)
                                        .background(Capsule().fill(Color.green))
                                }
                            }
                            .lineLimit(1)
                            .id(rate.objectID)
                            .listRowBackground(isRateCurrentlyActive(rate) ? Color.green.opacity(0.1) : nil)
                        }
                    } header: {
                        Text(dateString)
                            .font(.headline)
                            .foregroundStyle(.primary)
                            .listRowInsets(EdgeInsets())
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(Color(UIColor.systemBackground))
                    }
                }
            }
            .listStyle(.plain)
            .onAppear {
                if let currentRate = viewModel.allRates.first(where: { isRateCurrentlyActive($0) }) {
                    withAnimation {
                        scrollProxy.scrollTo(currentRate.objectID, anchor: .center)
                    }
                }
            }
        }
        .navigationTitle(LocalizedStringKey("All Rates"))
        .navigationBarTitleDisplayMode(.inline)
        .environment(\.locale, globalSettings.locale)
        .id("all-rates-\(refreshTrigger)")
        .onChange(of: globalSettings.locale) { oldValue, newValue in
            refreshTrigger.toggle()
        }
    }
    
    private func isRateCurrentlyActive(_ rate: RateEntity) -> Bool {
        let now = Date()
        guard let start = rate.validFrom, let end = rate.validTo else { return false }
        return start <= now && end > now
    }
}

#Preview {
    let globalTimer = GlobalTimer()
    let viewModel = RatesViewModel(globalTimer: globalTimer)
    NavigationView {
        AllRatesListView(viewModel: viewModel)
            .environmentObject(GlobalSettingsManager())
    }
} 