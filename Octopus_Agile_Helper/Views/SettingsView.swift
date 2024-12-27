import SwiftUI
import Foundation

struct SettingsView: View {
    @EnvironmentObject var globalSettings: GlobalSettingsManager
    
    private let languages = ["English", "Other"]
    
    var body: some View {
        Form {
            Section(header: HStack {
                Text("Region Lookup")
                Spacer()
                InfoButton(message: "Postcode determines your region for accurate rates. Default is region 'H'.")
            }) {
                TextField("Postcode", text: $globalSettings.settings.postcode)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled(true)
                    .textCase(.uppercase)
            }
            
            Section(header: HStack {
                Text("API Configuration")
                Spacer()
                InfoButton(message: "API Key is optional for viewing rates. Required for personal data access. Get it from your Octopus Energy dashboard under 'API Access'.")
            }) {
                SecureField("API Key", text: $globalSettings.settings.apiKey)
            }
            
            Section(header: HStack {
                Text("Preferences")
                Spacer()
                InfoButton(message: "Set language and rate display preferences.")
            }) {
                Picker("Language", selection: $globalSettings.settings.selectedLanguage) {
                    ForEach(languages, id: \.self) { language in
                        Text(language)
                    }
                }
                
                Toggle("Display Rates in Pounds (£)", isOn: $globalSettings.settings.showRatesInPounds)
            }
        }
        .navigationTitle("Settings")
        .onAppear {
            print("DEBUG: Settings loaded - API Key length: \(globalSettings.settings.apiKey.count)")
            print("DEBUG: Settings loaded - Selected Language: \(globalSettings.settings.selectedLanguage)")
            print("DEBUG: Settings loaded - Postcode: \(globalSettings.settings.postcode)")
            print("DEBUG: Settings loaded - Show Rates in Pounds: \(globalSettings.settings.showRatesInPounds)")
        }
    }
}

struct InfoButton: View {
    let message: String
    @State private var showingInfo = false
    
    var body: some View {
        Button(action: {
            showingInfo.toggle()
        }) {
            Image(systemName: "info.circle")
                .foregroundColor(.blue)
        }
        .popover(isPresented: $showingInfo) {
            Text(message)
                .padding()
                .presentationCompactAdaptation(.popover)
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
