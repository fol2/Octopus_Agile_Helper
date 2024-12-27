import Foundation

struct CardSettings: Codable {
    var customAverageHours: Double
    var maxListCount: Int
}

extension CardSettings {
    static let defaultSettings = CardSettings(customAverageHours: 3.0, maxListCount: 10)
}

class CardSettingsManager: ObservableObject {
    @Published var settings: CardSettings {
        didSet {
            saveSettings()
        }
    }
    
    private let userDefaultsKey: String
    
    init(cardKey: String) {
        self.userDefaultsKey = "\(cardKey)Settings"
        
        // Attempt load
        if let data = UserDefaults.standard.data(forKey: userDefaultsKey),
           let decoded = try? JSONDecoder().decode(CardSettings.self, from: data) {
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