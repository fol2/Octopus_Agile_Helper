import SwiftUI

// Import view model
@_implementationOnly import class Octopus_Agile_Helper.RatesViewModel

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
        .padding()
        .background(Color(.systemBackground))
        .cornerRadius(12)
        .shadow(radius: 4)
        .padding(.horizontal)
        .padding(.vertical, 4)
    }
} 