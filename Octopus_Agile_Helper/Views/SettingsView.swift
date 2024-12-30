import SwiftUI
import Foundation

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
            Section(header: HStack {
                Text(LocalizedStringKey("Region Lookup"))
                    .font(Theme.secondaryFont())
                    .foregroundColor(Theme.secondaryTextColor)
                Spacer()
                InfoButton(message: LocalizedStringKey("Postcode determines your region for accurate rates. Default is region 'H'."))
            }) {
                TextField(LocalizedStringKey("Postcode"), text: $globalSettings.settings.postcode, prompt: Text(LocalizedStringKey("Postcode"))
                    .foregroundColor(Theme.secondaryTextColor))
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled(true)
                    .textCase(.uppercase)
                    .font(Theme.secondaryFont())
                    .foregroundColor(Theme.mainTextColor)
                    .customListRow()
            }
            
            Section(header: HStack {
                Text(LocalizedStringKey("API Configuration"))
                    .font(Theme.secondaryFont())
                    .foregroundColor(Theme.secondaryTextColor)
                Spacer()
                InfoButton(message: LocalizedStringKey("API Key is optional for viewing rates. Required for personal data access. Get it from your Octopus Energy dashboard under 'API Access'."))
            }) {
                SecureField(LocalizedStringKey("API Key"), text: $globalSettings.settings.apiKey, prompt: Text(LocalizedStringKey("API Key"))
                    .foregroundColor(Theme.secondaryTextColor))
                    .font(Theme.secondaryFont())
                    .foregroundColor(Theme.mainTextColor)
                    .customListRow()
            }
            
            Section(header: HStack {
                Text(LocalizedStringKey("Preferences"))
                    .font(Theme.secondaryFont())
                    .foregroundColor(Theme.secondaryTextColor)
                Spacer()
                InfoButton(message: LocalizedStringKey("Set language and rate display preferences."))
            }) {
                Picker(LocalizedStringKey("Language"), selection: $globalSettings.settings.selectedLanguage) {
                    ForEach(Language.allCases, id: \.self) { lang in
                        Text(lang.displayName)
                            .font(Theme.secondaryFont())
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
                Text(LocalizedStringKey("Cards"))
                    .font(Theme.secondaryFont())
                    .foregroundColor(Theme.secondaryTextColor)
                Spacer()
                InfoButton(message: LocalizedStringKey("Manage which cards are shown and their order."))
            }) {
                NavigationLink(destination: CardManagementView()) {
                    HStack {
                        Text(LocalizedStringKey("Manage Cards"))
                            .font(Theme.secondaryFont())
                            .foregroundColor(Theme.mainTextColor)
                        Spacer()
                        Text(LocalizedStringKey("\(globalSettings.settings.cardSettings.filter { $0.isEnabled }.count) Active"))
                            .font(Theme.subFont())
                            .foregroundColor(Theme.secondaryTextColor)
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
    @State private var showingInfo = false
    @EnvironmentObject var globalSettings: GlobalSettingsManager
    @State private var refreshID = UUID()
    
    var body: some View {
        Button(action: {
            showingInfo.toggle()
        }) {
            Image(systemName: "info.circle")
                .font(Theme.subFont())
                .foregroundColor(Theme.secondaryTextColor)
        }
        .popover(isPresented: $showingInfo) {
            Text(message)
                .font(Theme.secondaryFont())
                .foregroundColor(Theme.mainTextColor)
                .padding()
                .background(Theme.secondaryBackground)
                .presentationCompactAdaptation(.popover)
                .environment(\.locale, globalSettings.locale)
                .id(refreshID)
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
