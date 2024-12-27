import Foundation

enum CardType: String, Codable, CaseIterable {
    case currentRate
    case lowestUpcoming
    case highestUpcoming
    case averageUpcoming
}

struct CardConfig: Identifiable, Codable {
    let id: UUID
    let cardType: CardType
    var isEnabled: Bool
    var isPurchased: Bool
    var sortOrder: Int
}

struct GlobalSettings: Codable {
    var postcode: String
    var apiKey: String
    var selectedLanguage: String
    var showRatesInPounds: Bool
    var cardSettings: [CardConfig]
}

extension GlobalSettings {
    static let defaultSettings = GlobalSettings(
        postcode: "",
        apiKey: "",
        selectedLanguage: "English",
        showRatesInPounds: false,
        cardSettings: [
            CardConfig(id: UUID(), cardType: .currentRate, isEnabled: true, isPurchased: true, sortOrder: 1),
            CardConfig(id: UUID(), cardType: .lowestUpcoming, isEnabled: true, isPurchased: true, sortOrder: 2),
            CardConfig(id: UUID(), cardType: .highestUpcoming, isEnabled: true, isPurchased: true, sortOrder: 3),
            CardConfig(id: UUID(), cardType: .averageUpcoming, isEnabled: true, isPurchased: true, sortOrder: 4)
        ]
    )
}

class GlobalSettingsManager: ObservableObject {
    @Published var settings: GlobalSettings {
        didSet {
            saveSettings()
        }
    }
    
    private let userDefaultsKey = "GlobalSettings"

    init() {
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