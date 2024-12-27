import SwiftUI
import CoreData

struct AllRatesListView: View {
    @ObservedObject var viewModel: RatesViewModel
    @Environment(\.dismiss) var dismiss
    
    private let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "E, MMM d"  // e.g., "Mon, Dec 25"
        return formatter
    }()
    
    private var ratesByDate: [(String, [RateEntity])] {
        let grouped = Dictionary(grouping: viewModel.upcomingRates) { rate in
            if let date = rate.validFrom {
                return dateFormatter.string(from: date)
            }
            return "Unknown Date"
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
                                
                                HStack(alignment: .firstTextBaseline, spacing: 1) {
                                    Text(String(format: "%.2f", rate.valueIncludingVAT))
                                        .font(.headline)
                                    Text("p/kWh")
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
                if let currentRate = viewModel.upcomingRates.first(where: { isRateCurrentlyActive($0) }) {
                    withAnimation {
                        scrollProxy.scrollTo(currentRate.objectID, anchor: .center)
                    }
                }
            }
        }
        .navigationTitle("All Rates")
        .navigationBarTitleDisplayMode(.inline)
    }
    
    private func isRateCurrentlyActive(_ rate: RateEntity) -> Bool {
        let now = Date()
        guard let start = rate.validFrom, let end = rate.validTo else { return false }
        return start <= now && end > now
    }
}

#Preview {
    let timer = GlobalTimer()
    NavigationView {
        AllRatesListView(viewModel: RatesViewModel(globalTimer: timer))
    }
} 