import SwiftUI

struct LowestUpcomingRateCardView: View {
    @ObservedObject var viewModel: RatesViewModel
    
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Image(systemName: "arrow.down.circle.fill")
                    .foregroundColor(.green)
                Text("Lowest Upcoming Rate")
                    .font(.headline)
                Spacer()
            }
            
            if viewModel.isLoading {
                ProgressView()
            } else if let lowestRate = viewModel.lowestUpcomingRate {
                VStack(alignment: .leading, spacing: 8) {
                    Text(viewModel.formatRate(lowestRate.valueIncludingVAT))
                        .font(.title)
                        .foregroundColor(.primary)
                    
                    Text("at \(viewModel.formatTime(lowestRate.validFrom))")
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                }
            } else {
                Text("No upcoming rates available")
                    .foregroundColor(.secondary)
            }
        }
        .rateCardStyle()
    }
}

#Preview {
    NavigationView {
        LowestUpcomingRateCardView(viewModel: RatesViewModel())
            .environment(\.managedObjectContext, PersistenceController.preview.container.viewContext)
    }
} 