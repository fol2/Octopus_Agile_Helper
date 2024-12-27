import SwiftUI

struct AverageUpcomingRateCardView: View {
    @ObservedObject var viewModel: RatesViewModel
    
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Image(systemName: "chart.bar.fill")
                    .foregroundColor(.blue)
                Text("Lowest 10 (\(String(format: "%.1f", viewModel.averageHours))-hour Averages)")
                    .font(.headline)
                Spacer()
            }
            
            if viewModel.isLoading {
                ProgressView()
            } else {
                let averages = viewModel.lowestTenThreeHourAverages
                if averages.isEmpty {
                    Text("No upcoming data for 3-hour averages")
                        .foregroundColor(.secondary)
                } else {
                    VStack(alignment: .leading, spacing: 8) {
                        ForEach(averages) { entry in
                            HStack {
                                Text(viewModel.formatRate(entry.average))
                                    .font(.headline)
                                Spacer()
                                Text("\(viewModel.formatTime(entry.start)) - \(viewModel.formatTime(entry.end))")
                                    .font(.subheadline)
                            }
                        }
                    }
                }
            }
        }
        .rateCardStyle()
    }
}

#Preview {
    AverageUpcomingRateCardView(viewModel: RatesViewModel())
        .preferredColorScheme(.dark)
} 