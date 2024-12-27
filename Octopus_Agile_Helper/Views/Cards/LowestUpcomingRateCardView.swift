import SwiftUI
import CoreData

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
                    
                    Text("at \(viewModel.formatTime(lowestRate.validFrom ?? <#default value#>))")
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                }
            } else {
                Text("No upcoming rates available")
                    .foregroundColor(.secondary)
            }
        }
        .padding()
        .background(colorScheme == .dark ? Color.black : Color.white)
        .cornerRadius(12)
        .shadow(radius: 4)
        .padding(.horizontal)
        .padding(.vertical, 4)
    }
}

struct LowestUpcomingRateCardView_Previews: PreviewProvider {
    static var previews: some View {
        LowestUpcomingRateCardView(viewModel: RatesViewModel())
            .preferredColorScheme(.dark)
    }
} 
