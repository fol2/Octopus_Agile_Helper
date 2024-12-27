import SwiftUI

struct AverageCardSettingsSheet: View {
    @ObservedObject var localSettings: CardSettingsManager
    @Environment(\.dismiss) var dismiss

    var body: some View {
        NavigationView {
            Form {
                Section(header: Text("Local Card Settings")) {
                    Stepper("Custom Average Hours: \(String(format: "%.1f", localSettings.settings.customAverageHours))",
                            value: $localSettings.settings.customAverageHours,
                            in: 1...24,
                            step: 0.5)
                    Stepper("Max List Count: \(localSettings.settings.maxListCount)",
                            value: $localSettings.settings.maxListCount,
                            in: 1...50)
                }
            }
            .navigationTitle("Card Settings")
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("Done") {
                        dismiss()
                    }
                }
            }
        }
    }
} 