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
                InfoButton(message: "Postcode determines your region for accurate rates. Default is region 'H'.")
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
                InfoButton(message: "API Key is optional for viewing rates. Required for personal data access. Get it from your Octopus Energy dashboard under 'API Access'.")
            }) {
                SecureField("API Key", text: $apiKey)
            }
            
            Section(header: HStack {
                Text("Preferences")
                Spacer()
                InfoButton(message: "Set language and average hours for rate calculations.")
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
