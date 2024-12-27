import SwiftUI

struct HighestUpcomingRateCardView: View {
    @ObservedObject var viewModel: RatesViewModel
    @Environment(\.colorScheme) var colorScheme
    
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Image(systemName: "arrow.up.circle.fill")
                    .foregroundColor(.red)
                Text("Highest Upcoming Rate")
                    .font(.headline)
                Spacer()
            }
            
            if viewModel.isLoading {
                ProgressView()
            } else if let highestRate = viewModel.highestUpcomingRate {
                VStack(alignment: .leading, spacing: 8) {
                    Text(viewModel.formatRate(highestRate.valueIncludingVAT))
                        .font(.title)
                        .foregroundColor(.primary)
                    
                    Text("at \(viewModel.formatTime(highestRate.validFrom ?? Date()))")
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
    let timer = GlobalTimer()
    return HighestUpcomingRateCardView(viewModel: RatesViewModel(globalTimer: timer))
        .preferredColorScheme(.dark)
} 
