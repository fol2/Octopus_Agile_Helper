import SwiftUI
import CoreData

struct AllRatesListView: View {
    @ObservedObject var viewModel: RatesViewModel
    @Environment(\.dismiss) var dismiss
    
    var body: some View {
        ScrollViewReader { scrollProxy in
            List(viewModel.upcomingRates, id: \.objectID) { rate in
                HStack {
                    VStack(alignment: .leading) {
                        Text("\(viewModel.formatTime(rate.validFrom ?? Date())) - \(viewModel.formatTime(rate.validTo ?? Date()))")
                            .font(.headline)
                        Text(viewModel.formatRate(rate.valueIncludingVAT))
                            .font(.subheadline)
                    }
                    .padding(.vertical, 4)
                    Spacer()
                    if isRateCurrentlyActive(rate) {
                        Text("NOW")
                            .foregroundColor(.green)
                            .bold()
                    }
                }
                .id(rate.objectID)
                .listRowBackground(isRateCurrentlyActive(rate) ? Color.green.opacity(0.1) : nil)
            }
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
    NavigationView {
        AllRatesListView(viewModel: RatesViewModel())
    }
} 