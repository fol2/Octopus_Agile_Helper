import Foundation
import SwiftUI

/// Represents supported app languages
enum Language: String, Codable, CaseIterable {
    case english = "en"
    case traditionalChinese = "zh-Hant"
    case simplifiedChinese = "zh-Hans"
    case spanish = "es"
    case french = "fr"
    
    var displayName: String {
        switch self {
        case .english:
            return "English"
        case .traditionalChinese:
            return "繁體中文"
        case .simplifiedChinese:
            return "简体中文"
        case .spanish:
            return "Español"
        case .french:
            return "Français"
        }
    }
    
    var locale: Locale {
        Locale(identifier: self.rawValue)
    }
}

enum CardType: String, Codable, CaseIterable {
    case currentRate
    case lowestUpcoming
    case highestUpcoming
    case averageUpcoming
    case interactiveChart
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
    var selectedLanguage: Language
    var showRatesInPounds: Bool
    var cardSettings: [CardConfig]
}

extension GlobalSettings {
    static let defaultSettings = GlobalSettings(
        postcode: "",
        apiKey: "",
        selectedLanguage: .english,
        showRatesInPounds: false,
        cardSettings: []  // Empty array - cards will be added by mergeMissingCards
    )
}

class GlobalSettingsManager: ObservableObject {
    @Published var settings: GlobalSettings {
        didSet {
            saveSettings()
            // Update locale if language changed
            if oldValue.selectedLanguage != settings.selectedLanguage {
                locale = settings.selectedLanguage.locale
            }
        }
    }
    
    @Published var locale: Locale
    private let userDefaultsKey = "GlobalSettings"
    
    init() {
        // Attempt to load from UserDefaults
        if let data = UserDefaults.standard.data(forKey: userDefaultsKey),
           let decoded = try? JSONDecoder().decode(GlobalSettings.self, from: data) {
            self.settings = decoded
            self.locale = decoded.selectedLanguage.locale
        } else {
            self.settings = .defaultSettings
            self.locale = Language.english.locale
        }
        
        // Merge any missing cards from the registry
        mergeMissingCards()
    }
    
    private func mergeMissingCards() {
        let registry = CardRegistry.shared
        var changed = false
        
        // Gather existing card types the user has
        let existingTypes = Set(settings.cardSettings.map { $0.cardType })
        
        // For each card definition in the registry
        for cardType in CardType.allCases {
            if let definition = registry.definition(for: cardType),
               !existingTypes.contains(cardType) {
                // It's missing from user settings—add a new CardConfig
                let newConfig = CardConfig(
                    id: UUID(),
                    cardType: definition.id,
                    isEnabled: definition.defaultIsEnabled,
                    isPurchased: definition.defaultIsPurchased,
                    sortOrder: definition.defaultSortOrder
                )
                settings.cardSettings.append(newConfig)
                changed = true
            }
        }
        
        // Keep them sorted by sortOrder
        settings.cardSettings.sort { $0.sortOrder < $1.sortOrder }
        
        if changed {
            saveSettings()
        }
    }
    
    func saveSettings() {
        if let encoded = try? JSONEncoder().encode(settings) {
            UserDefaults.standard.set(encoded, forKey: userDefaultsKey)
        }
    }
} 