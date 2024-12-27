import SwiftUI

struct AverageUpcomingRateCardView: View {
    @ObservedObject var viewModel: RatesViewModel
    @StateObject private var localSettings = CardSettingsManager(cardKey: "AverageCard")
    @State private var showingLocalSettings = false
    
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Image(systemName: "chart.bar.fill")
                    .foregroundColor(.blue)
                Text("Lowest \(localSettings.settings.maxListCount) (\(String(format: "%.1f", localSettings.settings.customAverageHours))-hour Averages)")
                    .font(.headline)
                Spacer()
                Button(action: {
                    showingLocalSettings.toggle()
                }) {
                    Image(systemName: "gearshape.fill")
                        .font(.footnote)
                        .foregroundColor(.secondary.opacity(0.7))
                }
                .padding(.trailing, 4)
            }
            
            if viewModel.isLoading {
                ProgressView()
            } else {
                let averages = viewModel.getLowestAverages(hours: localSettings.settings.customAverageHours, maxCount: localSettings.settings.maxListCount)
                if averages.isEmpty {
                    Text("No upcoming data for \(String(format: "%.1f", localSettings.settings.customAverageHours))-hour averages")
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
        .sheet(isPresented: $showingLocalSettings) {
            AverageCardSettingsSheet(localSettings: localSettings)
        }
        .rateCardStyle()
    }
}

#Preview {
    let timer = GlobalTimer()
    return AverageUpcomingRateCardView(viewModel: RatesViewModel(globalTimer: timer))
        .preferredColorScheme(.dark)
} 