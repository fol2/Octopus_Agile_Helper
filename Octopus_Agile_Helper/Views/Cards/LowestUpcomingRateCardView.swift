import SwiftUI

struct LowestUpcomingRateCardView: View {
    @ObservedObject var viewModel: RatesViewModel
    @Environment(\.colorScheme) var colorScheme
    
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
                    
                    Text("at \(viewModel.formatTime(lowestRate.validFrom ?? Date()))")
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

struct LowestUpcomingRateCardView_Previews: PreviewProvider {
    static var previews: some View {
        LowestUpcomingRateCardView(viewModel: RatesViewModel())
            .preferredColorScheme(.dark)
    }
} 
