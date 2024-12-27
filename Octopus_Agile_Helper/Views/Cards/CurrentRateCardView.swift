import SwiftUI
import CoreData

struct CurrentRateCardView: View {
    // MARK: - Dependencies
    @ObservedObject var viewModel: RatesViewModel
    @Environment(\.colorScheme) var colorScheme
    
    // MARK: - Body
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Image(systemName: "clock.fill")
                    .foregroundColor(.blue)
                Text("Current Rate")
                    .font(.headline)
                Spacer()
            }
            
            if viewModel.isLoading {
                ProgressView()
            } else if let currentRate = getCurrentRate() {
                VStack(alignment: .leading, spacing: 8) {
                    HStack(alignment: .center) {
                        let parts = viewModel.formatRate(currentRate.valueIncludingVAT).split(separator: " ")
                        Text(parts[0] + "p")
                            .font(.system(size: 34, weight: .medium))
                            .foregroundColor(.primary)
                        Text("/kWh")
                            .font(.system(size: 17))
                            .foregroundColor(.secondary)
                        Spacer()
                        Text(formatTimeRange(currentRate.validFrom, currentRate.validTo))
                            .font(.subheadline)
                            .foregroundColor(.primary)
                    }
                }
            } else {
                Text("No current rate available")
                    .foregroundColor(.secondary)
            }
        }
        .rateCardStyle()
    }
    
    // MARK: - Helper Methods
    private func getCurrentRate() -> RateEntity? {
        let now = Date()
        return viewModel.upcomingRates.first { rate in
            guard let start = rate.validFrom, let end = rate.validTo else { return false }
            return start <= now && end > now
        }
    }
    
    private func formatTimeRange(_ from: Date?, _ to: Date?) -> String {
        guard let from = from, let to = to else { return "" }
        let now = Date()
        let calendar = Calendar.current
        
        let fromDay = calendar.startOfDay(for: from)
        let nowDay = calendar.startOfDay(for: now)
        
        let timeFormatter = DateFormatter()
        timeFormatter.dateFormat = "HH:mm"
        
        let dateFormatter = DateFormatter()
        dateFormatter.dateFormat = "d MMM"
        
        if calendar.isDate(fromDay, inSameDayAs: nowDay) {
            return "Until \(timeFormatter.string(from: to))"
        } else {
            return "Until \(dateFormatter.string(from: to)) \(timeFormatter.string(from: to))"
        }
    }
}

#if DEBUG
struct CurrentRateCardView_Previews: PreviewProvider {
    static var previews: some View {
        let viewModel = RatesViewModel(globalTimer: GlobalTimer())
        CurrentRateCardView(viewModel: viewModel)
            .previewLayout(.sizeThatFits)
            .padding()
            .preferredColorScheme(.dark)
    }
}
#endif 