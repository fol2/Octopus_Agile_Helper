import Foundation

struct GlobalSettings: Codable {
    var postcode: String
    var apiKey: String
    var selectedLanguage: String
    var showRatesInPounds: Bool
}

extension GlobalSettings {
    static let defaultSettings = GlobalSettings(postcode: "",
                                              apiKey: "",
                                              selectedLanguage: "English",
                                              showRatesInPounds: false)
}

class GlobalSettingsManager: ObservableObject {
    @Published var settings: GlobalSettings {
        didSet {
            saveSettings()
        }
    }
    
    private let userDefaultsKey = "GlobalSettings"

    init() {
        // Attempt load
        if let data = UserDefaults.standard.data(forKey: userDefaultsKey),
           let decoded = try? JSONDecoder().decode(GlobalSettings.self, from: data) {
            self.settings = decoded
        } else {
            self.settings = .defaultSettings
        }
    }
    
    func saveSettings() {
        if let encoded = try? JSONEncoder().encode(settings) {
            UserDefaults.standard.set(encoded, forKey: userDefaultsKey)
        }
    }
} 