import Foundation
import OctopusHelperShared
import SwiftUI

// MARK: - Data Models
private struct TnCData: Codable {
    let title: String
    let sections: [TnCSection]
    let tldr: [String: String]
    let introduction: String
}

private struct TnCSection: Codable {
    let heading: String
    let body: [String]
}

// MARK: - View Model
private class TnCViewModel: ObservableObject {
    @Published var tncData: TnCData?
    @EnvironmentObject var globalSettings: GlobalSettingsManager

    init() {
        loadTnCJSON()
    }

    private func loadTnCJSON() {
        guard let url = Bundle.module.url(forResource: "TnC", withExtension: "json")
        else {
            print("TnC.json not found in bundle.")
            return
        }

        do {
            let data = try Data(contentsOf: url)
            let decoded = try JSONDecoder().decode(TnCData.self, from: data)
            self.tncData = decoded
        } catch {
            print("Error loading TnC.json: \(error)")
            print("Detailed error: \(error.localizedDescription)")
        }
    }
}

// MARK: - View
public struct TermsAndConditionsView: View {
    @StateObject private var viewModel = TnCViewModel()
    @EnvironmentObject var globalSettings: GlobalSettingsManager
    @Environment(\.dismiss) private var dismiss
    @Environment(\.locale) private var locale

    public var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                if let tncData = viewModel.tncData {
                    // TL;DR section with modern card style
                    VStack(alignment: .leading, spacing: 16) {
                        Text(LocalizedStringKey("TL;DR"))
                            .font(.system(.title2, design: .rounded, weight: .bold))
                            .foregroundColor(Theme.mainTextColor)

                        Text(
                            LocalizedStringKey(
                                tncData.tldr[globalSettings.settings.selectedLanguage.rawValue]
                                    ?? tncData.tldr["en"] ?? "")
                        )
                        .font(.system(.body, design: .rounded))
                        .foregroundColor(Theme.secondaryTextColor)
                    }
                    .padding(20)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(
                        RoundedRectangle(cornerRadius: 16)
                            .fill(Theme.secondaryBackground)
                            .shadow(color: Color.black.opacity(0.05), radius: 10, x: 0, y: 5)
                    )

                    // Introduction
                    Text(LocalizedStringKey(tncData.introduction))
                        .font(.system(.body, design: .rounded))
                        .foregroundColor(Theme.mainTextColor)
                        .padding(.horizontal, 20)
                        .padding(.top, 8)
                        .frame(maxWidth: .infinity, alignment: .leading)

                    // Sections
                    ForEach(Array(tncData.sections.enumerated()), id: \.offset) { index, section in
                        VStack(alignment: .leading, spacing: 12) {
                            Text(LocalizedStringKey(section.heading))
                                .font(.system(.headline, design: .rounded, weight: .bold))
                                .foregroundColor(Theme.mainTextColor)

                            ForEach(section.body, id: \.self) { bullet in
                                Text(LocalizedStringKey(bullet))
                                    .font(.system(.body, design: .rounded))
                                    .foregroundColor(Theme.secondaryTextColor)
                            }
                        }
                        .padding(20)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(
                            RoundedRectangle(cornerRadius: 16)
                                .fill(Theme.secondaryBackground)
                                .shadow(color: Color.black.opacity(0.05), radius: 10, x: 0, y: 5)
                        )
                    }
                } else {
                    Text(LocalizedStringKey("Unable to load terms and conditions."))
                        .font(.system(.body, design: .rounded))
                        .foregroundColor(.red)
                        .padding()
                }
            }
            .padding(.vertical, 24)
        }
        .background(Theme.mainBackground)
        .navigationTitle(LocalizedStringKey("Terms & Conditions"))
        .navigationBarTitleDisplayMode(.inline)
        .environment(\.locale, globalSettings.locale)
        .toolbar {
            ToolbarItem(placement: .navigationBarTrailing) {
                Button {
                    withAnimation(.spring(duration: 0.3)) {
                        dismiss()
                    }
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundColor(Theme.secondaryTextColor.opacity(0.9))
                        .imageScale(.large)
                }
            }
        }
    }
}
