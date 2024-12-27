import Foundation
import SwiftUI

enum Language: String, CaseIterable {
    case english = "en"
    case traditionalChinese = "zh-Hant"
    
    var displayName: String {
        switch self {
        case .english:
            return "English"
        case .traditionalChinese:
            return "繁體中文"
        }
    }
    
    var locale: Locale {
        return Locale(identifier: self.rawValue)
    }
}

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
        selectedLanguage: Language.english.displayName,
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
    @AppStorage("selectedLanguage") private var storedLanguage: String = Language.english.displayName
    @Published var settings: GlobalSettings {
        didSet {
            saveSettings()
            if oldValue.selectedLanguage != settings.selectedLanguage {
                storedLanguage = settings.selectedLanguage
                if let language = Language.allCases.first(where: { $0.displayName == settings.selectedLanguage }) {
                    locale = language.locale
                }
            }
        }
    }
    
    @Published var locale: Locale = Language.english.locale
    private let userDefaultsKey = "GlobalSettings"

    init() {
        if let data = UserDefaults.standard.data(forKey: userDefaultsKey),
           let decoded = try? JSONDecoder().decode(GlobalSettings.self, from: data) {
            self.settings = decoded
            if let language = Language.allCases.first(where: { $0.displayName == decoded.selectedLanguage }) {
                self.locale = language.locale
            }
        } else {
            self.settings = .defaultSettings
            self.locale = Language.english.locale
        }
    }
    
    func saveSettings() {
        if let encoded = try? JSONEncoder().encode(settings) {
            UserDefaults.standard.set(encoded, forKey: userDefaultsKey)
        }
    }
} 