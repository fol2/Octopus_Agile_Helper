import AVKit
import Foundation
import OctopusHelperShared
import SwiftUI

struct CustomListRowModifier: ViewModifier {
    func body(content: Content) -> some View {
        content
            .listRowBackground(Theme.secondaryBackground)
    }
}

extension View {
    func customListRow() -> some View {
        modifier(CustomListRowModifier())
    }
}

struct SettingsView: View {
    @EnvironmentObject var globalSettings: GlobalSettingsManager

    var body: some View {
        Form {
            if let cached = OctopusAPIClient.shared.getCachedAgileMetadata() {
                Text(cached.fullName)
                    .font(Theme.subFont())
                    .foregroundColor(Theme.secondaryTextColor)
                    .listRowBackground(Theme.mainBackground)
            }
            Section(
                header: HStack {
                    Text("Region Lookup")
                        .font(Theme.subFont())
                        .foregroundColor(Theme.secondaryTextColor)
                        .textCase(.none)
                    Spacer()
                    InfoButton(
                        message: LocalizedStringKey(
                            "Your postcode is used to determine your electricity region for accurate rates. The postcode is stored locally on your device only and is never shared with app developers.\n\nIf the postcode is empty or invalid, region 'H' (Southern England) will be used as default."
                        ),
                        title: LocalizedStringKey("Region Lookup"),
                        mediaItems: [
                            MediaItem(
                                youtubeID: "2Gp68uXVGfo",
                                caption: LocalizedStringKey(
                                    "Zonal pricing would make energy bills cheaper...")
                            )
                        ],
                        linkURL: URL(
                            string: "https://octopus.energy/blog/regional-pricing-explained/"),
                        linkText: LocalizedStringKey("How zonal pricing could make bills cheaper")
                    )
                }
            ) {
                TextField(
                    LocalizedStringKey("Postcode"),
                    text: $globalSettings.settings.postcode,
                    prompt: Text(LocalizedStringKey("Postcode"))
                        .foregroundColor(Theme.secondaryTextColor)
                )
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled(true)
                .textCase(.uppercase)
                .font(Theme.secondaryFont())
                .foregroundColor(Theme.mainTextColor)
                .customListRow()
            }

            Section(
                header: HStack {
                    Text("API Configuration")
                        .font(Theme.subFont())
                        .foregroundColor(Theme.secondaryTextColor)
                        .textCase(.none)
                    Spacer()
                    InfoButton(
                        message: LocalizedStringKey(
                            "API Key is optional for most features like viewing Agile rates, price trends, and historical data.\n\nYou only need an API key if you want to access your personal data such as:\n• Your actual consumption data\n• Your billing information\n• Your tariff details\n\nYour API key is stored securely on your device only and is never shared with app developers or third parties."
                        ),
                        title: LocalizedStringKey("API Configuration"),
                        mediaItems: [],
                        linkURL: URL(
                            string:
                                "https://octopus.energy/dashboard/new/accounts/personal-details/api-access"
                        ),
                        linkText: LocalizedStringKey("Get your API key (Login required)")
                    )
                }
            ) {
                SecureField(
                    LocalizedStringKey("API Key"),
                    text: $globalSettings.settings.apiKey,
                    prompt: Text(LocalizedStringKey("API Key"))
                        .foregroundColor(Theme.secondaryTextColor)
                )
                .font(Theme.secondaryFont())
                .foregroundColor(Theme.mainTextColor)
                .customListRow()
            }

            Section(
                header: HStack {
                    Text("Preferences")
                        .font(Theme.subFont())
                        .foregroundColor(Theme.secondaryTextColor)
                        .textCase(.none)
                    Spacer()
                    InfoButton(
                        message: LocalizedStringKey(
                            "Configure your preferred language and how rates are displayed. Language changes will be applied immediately across the app. Rate display changes affect how prices are shown (pence vs pounds)."
                        ),
                        title: LocalizedStringKey("Preferences"),
                        mediaItems: []
                    )
                }
            ) {
                Picker(
                    LocalizedStringKey("Language"),
                    selection: $globalSettings.settings.selectedLanguage
                ) {
                    ForEach(Language.allCases, id: \.self) { lang in
                        Text(lang.displayNameWithAutonym)
                            .font(Theme.secondaryFont())
                            .textCase(.none)
                            .foregroundColor(Theme.secondaryTextColor)
                    }
                }
                .pickerStyle(.menu)
                .accentColor(Theme.secondaryTextColor)
                .font(Theme.secondaryFont())
                .foregroundColor(Theme.mainTextColor)
                .customListRow()

                Toggle(
                    LocalizedStringKey("Display Rates in Pounds (£)"),
                    isOn: $globalSettings.settings.showRatesInPounds
                )
                .font(Theme.secondaryFont())
                .foregroundColor(Theme.mainTextColor)
                .tint(Theme.secondaryColor)
                .customListRow()
            }

            Section(
                header: HStack {
                    Text("Cards")
                        .font(Theme.subFont())
                        .foregroundColor(Theme.secondaryTextColor)
                        .textCase(.none)
                    Spacer()
                    InfoButton(
                        message: LocalizedStringKey(
                            "Customise your dashboard by managing your cards:\n\n• Enable/disable cards to show only what matters to you\n• Reorder cards by dragging to arrange your perfect layout\n• Each card offers unique insights into your energy usage and rates\n\nStay tuned for new card modules - we're constantly developing new features to help you better understand and manage your energy usage."
                        ),
                        title: LocalizedStringKey("Cards"),
                        mediaItems: [
                            MediaItem(
                                localName: "imgCardManagementViewInfo",
                                caption: LocalizedStringKey("")
                            )
                        ]
                    )
                }
            ) {
                NavigationLink(destination: CardManagementView()) {
                    HStack {
                        Text(LocalizedStringKey("Manage Cards"))
                            .font(Theme.secondaryFont())
                            .foregroundColor(Theme.mainTextColor)
                            .textCase(.none)
                        Spacer()
                        Text(
                            LocalizedStringKey(
                                "\(globalSettings.settings.cardSettings.filter { $0.isEnabled }.count) Active"
                            )
                        )
                        .font(Theme.subFont())
                        .foregroundColor(Theme.secondaryTextColor)
                        .textCase(.none)
                    }
                }
                .customListRow()
            }
        }
        .scrollContentBackground(.hidden)
        .background(Theme.mainBackground)
        .environment(\.locale, globalSettings.locale)
        .navigationTitle(LocalizedStringKey("Settings"))
    }
}

struct InfoButton: View {
    let message: LocalizedStringKey
    let title: LocalizedStringKey
    let mediaItems: [MediaItem]
    let linkURL: URL?
    let linkText: LocalizedStringKey?

    @State private var showingInfo = false
    @EnvironmentObject var globalSettings: GlobalSettingsManager
    @State private var refreshID = UUID()
    @Environment(\.locale) private var locale

    init(
        message: LocalizedStringKey,
        title: LocalizedStringKey,
        mediaItems: [MediaItem] = [],
        linkURL: URL? = nil,
        linkText: LocalizedStringKey? = nil
    ) {
        self.message = message
        self.title = title
        self.mediaItems = mediaItems
        self.linkURL = linkURL
        self.linkText = linkText
    }

    var body: some View {
        Button(action: {
            showingInfo.toggle()
        }) {
            Image(systemName: "info.circle")
                .font(Theme.subFont())
                .foregroundColor(Theme.secondaryTextColor)
        }
        .sheet(isPresented: $showingInfo) {
            InfoSheet(
                viewModel: InfoSheetViewModel(
                    title: title,
                    message: message,
                    mediaItems: mediaItems,
                    linkURL: linkURL,
                    linkText: linkText
                )
            )
            .environmentObject(globalSettings)
            .environment(\.locale, locale)
            .presentationDragIndicator(.visible)
        }
        .onChange(of: globalSettings.locale) { _, _ in
            refreshID = UUID()
        }
    }
}

struct SettingsView_Previews: PreviewProvider {
    static let globalSettings = GlobalSettingsManager()

    static var previews: some View {
        NavigationStack {
            SettingsView()
                .environmentObject(globalSettings)
        }
    }
}
