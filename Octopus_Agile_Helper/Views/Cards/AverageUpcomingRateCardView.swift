import SwiftUI

struct AverageUpcomingRateCardView: View {
    @ObservedObject var viewModel: RatesViewModel
    
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Image(systemName: "chart.bar.fill")
                    .foregroundColor(.blue)
                Text("Lowest 10 Upcoming Rates (Avg)")
                    .font(.headline)
                Spacer()
            }
            
            if viewModel.isLoading {
                ProgressView()
            } else if let lowestTenAvg = viewModel.lowestTenAverageRate {
                VStack(alignment: .leading, spacing: 8) {
                    Text(viewModel.formatRate(lowestTenAvg))
                        .font(.title)
                        .foregroundColor(.primary)
                    
                    Text("Average of next 10 lowest rates")
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
    AverageUpcomingRateCardView(viewModel: RatesViewModel())
        .preferredColorScheme(.dark)
} 