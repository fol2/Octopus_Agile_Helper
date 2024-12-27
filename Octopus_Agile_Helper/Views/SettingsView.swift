import SwiftUI

struct SettingsView: View {
    @AppStorage("apiKey") private var apiKey: String = ""
    @AppStorage("selectedLanguage") private var selectedLanguage: String = "English"
    @AppStorage("averageHours") private var averageHours: Double = 2.0
    @AppStorage("postcode") private var postcode: String = ""
    
    private let languages = ["English", "Other"]
    
    var body: some View {
        Form {
            Section(header: Text("Region Lookup")) {
                TextField("Postcode", text: $postcode)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled(true)
                    .textCase(.uppercase)
                    .onChange(of: postcode) { newValue in
                        print("DEBUG: Postcode changed to: \(newValue)")
                        UserDefaults.standard.synchronize()
                    }
            }
            
            Section(header: Text("API Configuration")) {
                SecureField("API Key", text: $apiKey)
            }
            
            Section(header: Text("Preferences")) {
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

struct SettingsView_Previews: PreviewProvider {
    static var previews: some View {
        NavigationView {
            SettingsView()
        }
    }
} 
