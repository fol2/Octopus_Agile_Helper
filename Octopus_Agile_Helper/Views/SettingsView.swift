import SwiftUI

struct SettingsView: View {
    @AppStorage("apiKey") private var apiKey: String = ""
    @AppStorage("selectedLanguage") private var selectedLanguage: String = "English"
    @AppStorage("averageHours") private var averageHours: Double = 2.0
    @AppStorage("postcode") private var postcode: String = ""
    
    private let languages = ["English", "Other"]
    
    var body: some View {
        Form {
            Section(header: HStack {
                Text("Region Lookup")
                Spacer()
                InfoButton(message: "Your postcode is used to determine your region for accurate Agile tariff rates. If not provided, region 'H' will be used as default. This doesn't affect your account or billing.")
            }) {
                TextField("Postcode", text: $postcode)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled(true)
                    .textCase(.uppercase)
                    .onChange(of: postcode) { newValue in
                        print("DEBUG: Postcode changed to: \(newValue)")
                        UserDefaults.standard.synchronize()
                    }
            }
            
            Section(header: HStack {
                Text("API Configuration")
                Spacer()
                InfoButton(message: "API Key is optional for viewing Agile rates. Only required if you want to access your personal consumption data. You can get your API key from your Octopus Energy online dashboard under 'API Access'.")
            }) {
                SecureField("API Key", text: $apiKey)
            }
            
            Section(header: HStack {
                Text("Preferences")
                Spacer()
                InfoButton(message: "Configure your preferences for language and time periods. Average Hours affects how the app calculates and displays average rates.")
            }) {
                Picker("Language", selection: $selectedLanguage) {
                    ForEach(languages, id: \.self) { language in
                        Text(language)
                    }
                }
                
                VStack(alignment: .leading) {
                    Text("Average Hours: \(String(format: "%.1f", averageHours))")
                    Slider(value: $averageHours, in: 0.5...24, step: 0.5)
                }
            }
        }
        .navigationTitle("Settings")
        .onAppear {
            print("DEBUG: Settings loaded - API Key length: \(apiKey.count)")
            print("DEBUG: Settings loaded - Average Hours: \(averageHours)")
            print("DEBUG: Settings loaded - Selected Language: \(selectedLanguage)")
            print("DEBUG: Settings loaded - Postcode: \(postcode)")
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
    static var previews: some View {
        NavigationView {
            SettingsView()
        }
    }
} 
