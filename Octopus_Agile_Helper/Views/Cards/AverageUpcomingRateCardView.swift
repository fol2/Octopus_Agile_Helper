import SwiftUI

struct AverageUpcomingRateCardView: View {
    @ObservedObject var viewModel: RatesViewModel
    @AppStorage("averageHours") private var averageHours: Double = 2.0
    
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Image(systemName: "chart.bar.fill")
                    .foregroundColor(.blue)
                Text("Average Rate (Next \(String(format: "%.1f", averageHours))h)")
                    .font(.headline)
                Spacer()
            }
            
            if viewModel.isLoading {
                ProgressView()
            } else if let averageRate = viewModel.averageUpcomingRate {
                VStack(alignment: .leading, spacing: 8) {
                    Text(viewModel.formatRate(averageRate))
                        .font(.title)
                        .foregroundColor(.primary)
                    
                    Text("Over the next \(String(format: "%.1f", averageHours)) hours")
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