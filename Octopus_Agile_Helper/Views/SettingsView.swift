import SwiftUI
import Foundation
import AVKit

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
            Section(header: HStack {
                Text("Region Lookup")
                    .font(Theme.subFont())
                    .foregroundColor(Theme.secondaryTextColor)
                    .textCase(.none)
                Spacer()
                InfoButton(
                    message: LocalizedStringKey("Postcode determines your region for accurate rates. Default is region 'H'."),
                    title: LocalizedStringKey("Region Lookup"),
                    localMediaName: "region-lookup-demo",
                    linkURL: URL(string: "https://octopus.energy/regions"),
                    linkText: LocalizedStringKey("Learn more about regions")
                )
            }) {
                TextField(LocalizedStringKey("Postcode"), 
                         text: $globalSettings.settings.postcode, 
                         prompt: Text(LocalizedStringKey("Postcode"))
                            .foregroundColor(Theme.secondaryTextColor))
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled(true)
                    .textCase(.uppercase)
                    .font(Theme.secondaryFont())
                    .foregroundColor(Theme.mainTextColor)
                    .customListRow()
            }
            
            Section(header: HStack {
                Text("API Configuration")
                    .font(Theme.subFont())
                    .foregroundColor(Theme.secondaryTextColor)
                    .textCase(.none)
                Spacer()
                InfoButton(
                    message: LocalizedStringKey("API Key is optional for viewing rates. Required for personal data access. Get it from your Octopus Energy dashboard under 'API Access'."),
                    title: LocalizedStringKey("API Configuration"),
                    localMediaName: "api-access-demo",
                    isVideo: false,
                    linkURL: URL(string: "https://octopus.energy/api-access"),
                    linkText: LocalizedStringKey("Learn more about API access")
                )
            }) {
                SecureField(LocalizedStringKey("API Key"), 
                          text: $globalSettings.settings.apiKey, 
                          prompt: Text(LocalizedStringKey("API Key"))
                            .foregroundColor(Theme.secondaryTextColor))
                    .font(Theme.secondaryFont())
                    .foregroundColor(Theme.mainTextColor)
                    .customListRow()
            }
            
            Section(header: HStack {
                Text("Preferences")
                    .font(Theme.subFont())
                    .foregroundColor(Theme.secondaryTextColor)
                    .textCase(.none)
                Spacer()
                InfoButton(
                    message: LocalizedStringKey("Set language and rate display preferences."),
                    title: LocalizedStringKey("Preferences"),
                    localMediaName: "preferences-demo",
                    isVideo: false,
                    linkURL: URL(string: "https://octopus.energy/preferences"),
                    linkText: LocalizedStringKey("Learn more about preferences")
                )
            }) {
                Picker(LocalizedStringKey("Language"), selection: $globalSettings.settings.selectedLanguage) {
                    ForEach(Language.allCases, id: \.self) { lang in
                        Text(lang.displayName)
                            .font(Theme.secondaryFont())
                            .textCase(.none)
                    }
                }
                .font(Theme.secondaryFont())
                .foregroundColor(Theme.mainTextColor)
                .customListRow()
                
                Toggle(LocalizedStringKey("Display Rates in Pounds (£)"), 
                       isOn: $globalSettings.settings.showRatesInPounds)
                    .font(Theme.secondaryFont())
                    .foregroundColor(Theme.mainTextColor)
                    .tint(Theme.secondaryColor)
                    .customListRow()
            }
            
            Section(header: HStack {
                Text("Cards")
                    .font(Theme.subFont())
                    .foregroundColor(Theme.secondaryTextColor)
                    .textCase(.none)
                Spacer()
                InfoButton(
                    message: LocalizedStringKey("Manage which cards are shown and their order."),
                    title: LocalizedStringKey("Cards"),
                    localMediaName: "cards-demo",
                    isVideo: false,
                    linkURL: URL(string: "https://octopus.energy/cards"),
                    linkText: LocalizedStringKey("Learn more about cards")
                )
            }) {
                NavigationLink(destination: CardManagementView()) {
                    HStack {
                        Text(LocalizedStringKey("Manage Cards"))
                            .font(Theme.secondaryFont())
                            .foregroundColor(Theme.mainTextColor)
                            .textCase(.none)
                        Spacer()
                        Text(LocalizedStringKey("\(globalSettings.settings.cardSettings.filter { $0.isEnabled }.count) Active"))
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
    let mediaURL: URL?
    let localMediaName: String?
    let isVideo: Bool
    let linkURL: URL?
    let linkText: LocalizedStringKey?
    
    @State private var showingInfo = false
    @EnvironmentObject var globalSettings: GlobalSettingsManager
    @State private var refreshID = UUID()
    @Environment(\.locale) private var locale
    @Environment(\.dismiss) private var dismiss
    
    init(message: LocalizedStringKey, 
         title: LocalizedStringKey, 
         mediaURL: URL? = nil,
         localMediaName: String? = nil,
         isVideo: Bool = false,
         linkURL: URL? = nil,
         linkText: LocalizedStringKey? = nil) {
        self.message = message
        self.title = title
        self.mediaURL = mediaURL
        self.localMediaName = localMediaName
        self.isVideo = isVideo
        self.linkURL = linkURL
        self.linkText = linkText
    }
    
    private var mediaView: some View {
        Group {
            if let localMediaName = localMediaName {
                if isVideo {
                    if let videoURL = Bundle.main.url(forResource: localMediaName, withExtension: "mp4") {
                        VideoPlayer(player: AVPlayer(url: videoURL))
                            .frame(height: 200)
                            .cornerRadius(8)
                    }
                } else {
                    Image(localMediaName)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .cornerRadius(8)
                        .frame(height: 200)
                }
            } else if let mediaURL = mediaURL {
                if isVideo {
                    VideoPlayer(player: AVPlayer(url: mediaURL))
                        .frame(height: 200)
                        .cornerRadius(8)
                } else {
                    AsyncImage(url: mediaURL) { image in
                        image
                            .resizable()
                            .aspectRatio(contentMode: .fit)
                            .cornerRadius(8)
                    } placeholder: {
                        ProgressView()
                    }
                    .frame(height: 200)
                }
            }
        }
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
            NavigationView {
                List {
                    Section {
                        VStack(alignment: .leading, spacing: 16) {
                            Text(title)
                                .font(Theme.mainFont())
                                .foregroundColor(Theme.mainTextColor)
                                .textCase(.none)
                                .padding(.bottom, 8)
                            
                            Text(message)
                                .font(Theme.secondaryFont())
                                .foregroundColor(Theme.secondaryTextColor)
                                .textCase(.none)
                            
                            mediaView
                            
                            if let linkURL = linkURL, let linkText = linkText {
                                Link(destination: linkURL) {
                                    HStack {
                                        Text(linkText)
                                            .font(Theme.secondaryFont())
                                            .foregroundColor(Theme.mainColor)
                                            .textCase(.none)
                                        Image(systemName: "arrow.up.right")
                                            .font(Theme.subFont())
                                            .foregroundColor(Theme.mainColor)
                                    }
                                }
                                .padding(.top, 8)
                            }
                        }
                        .padding(.horizontal, 20)
                        .padding(.vertical, 16)
                    }
                    .listRowBackground(Theme.secondaryBackground)
                    .listRowInsets(EdgeInsets())
                }
                .listStyle(.plain)
                .scrollContentBackground(.hidden)
                .background(Theme.mainBackground)
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .navigationBarTrailing) {
                        Button {
                            showingInfo = false
                        } label: {
                            Text("Done")
                                .font(Theme.secondaryFont())
                                .foregroundColor(Theme.mainColor)
                                .textCase(.none)
                        }
                    }
                }
            }
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
        NavigationView {
            SettingsView()
                .environmentObject(globalSettings)
        }
    }
} 
