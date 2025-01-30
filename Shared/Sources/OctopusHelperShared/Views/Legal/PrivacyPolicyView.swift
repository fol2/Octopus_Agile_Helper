import Foundation
import OctopusHelperShared
import SwiftUI

// MARK: - Data Models
private struct GDPRData: Codable {
    let title: String
    let sections: [GDPRSection]
    let tldr: [String: String]
    let introduction: String
}

private struct GDPRSection: Codable {
    let heading: String
    let body: [String]
}

// MARK: - View Model
private class PrivacyPolicyViewModel: ObservableObject {
    @Published var gdprData: GDPRData?
    @EnvironmentObject var globalSettings: GlobalSettingsManager

    init() {
        loadGDPRJSON()
    }

    private func loadGDPRJSON() {
        guard let url = Bundle.module.url(forResource: "GDPR", withExtension: "json")
        else {
            print("GDPR.json not found in bundle.")
            return
        }

        do {
            let data = try Data(contentsOf: url)
            let decoded = try JSONDecoder().decode(GDPRData.self, from: data)
            self.gdprData = decoded
        } catch {
            print("Error loading GDPR.json: \(error)")
            print("Detailed error: \(error.localizedDescription)")
        }
    }
}

// MARK: - View
public struct PrivacyPolicyView: View {
    @StateObject private var viewModel = PrivacyPolicyViewModel()
    @EnvironmentObject var globalSettings: GlobalSettingsManager
    @Environment(\.dismiss) private var dismiss

    public var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                if let gdprData = viewModel.gdprData {
                    // TL;DR section with modern card style
                    VStack(alignment: .leading, spacing: 16) {
                        Text(LocalizedStringKey("TL;DR"))
                            .font(.system(.title2, design: .rounded, weight: .bold))
                            .foregroundColor(Theme.mainTextColor)

                        Text(
                            LocalizedStringKey(
                                gdprData.tldr[globalSettings.settings.selectedLanguage.rawValue]
                                    ?? gdprData.tldr["en"] ?? "")
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
                    Text(LocalizedStringKey(gdprData.introduction))
                        .font(.system(.body, design: .rounded))
                        .foregroundColor(Theme.mainTextColor)
                        .padding(.horizontal, 20)
                        .padding(.top, 8)
                        .frame(maxWidth: .infinity, alignment: .leading)

                    // Sections
                    ForEach(Array(gdprData.sections.enumerated()), id: \.offset) { index, section in
                        VStack(alignment: .leading, spacing: 12) {
                            Text(LocalizedStringKey(section.heading))
                                .font(.system(.headline, design: .rounded, weight: .bold))
                                .foregroundColor(Theme.mainTextColor)

                            ForEach(section.body, id: \.self) { bullet in
                                Text(LocalizedStringKey("• \(bullet)"))
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
                    Text(LocalizedStringKey("Unable to load privacy policy."))
                        .font(.system(.body, design: .rounded))
                        .foregroundColor(.red)
                        .padding()
                }
            }
            .padding(.vertical, 24)
        }
        .background(Theme.mainBackground)
        .navigationTitle(LocalizedStringKey("Privacy Policy"))
        .navigationBarTitleDisplayMode(.inline)
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
