import SwiftUI

struct SettingsView: View {
    @AppStorage("apiKey") private var apiKey: String = ""
    @AppStorage("selectedLanguage") private var selectedLanguage: String = "English"
    @AppStorage("averageHours") private var averageHours: Double = 2.0
    
    private let languages = ["English", "Other"]
    
    var body: some View {
        Form {
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
    }
}

struct SettingsView_Previews: PreviewProvider {
    static var previews: some View {
        NavigationView {
            SettingsView()
        }
    }
} 
