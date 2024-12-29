import Foundation
import SwiftUI

// MARK: - Supported App Languages
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

// MARK: - Card Types
enum CardType: String, Codable, CaseIterable {
    case currentRate
    case lowestUpcoming
    case highestUpcoming
    case averageUpcoming
    case interactiveChart
}

// MARK: - Card Configuration
struct CardConfig: Identifiable, Codable {
    let id: UUID
    let cardType: CardType
    var isEnabled: Bool
    var isPurchased: Bool
    var sortOrder: Int
}

// MARK: - Global Settings
struct GlobalSettings: Codable {
    var postcode: String
    var apiKey: String
    var selectedLanguage: Language
    var showRatesInPounds: Bool
    var cardSettings: [CardConfig]
}

// Provide a default “empty” settings object
extension GlobalSettings {
    static let defaultSettings = GlobalSettings(
        postcode: "",
        apiKey: "",
        selectedLanguage: .english,
        showRatesInPounds: false,
        cardSettings: []
    )
}

// MARK: - Manager (ObservableObject)
class GlobalSettingsManager: ObservableObject {
    
    @Published var settings: GlobalSettings {
        didSet {
            saveSettings()
            if oldValue.selectedLanguage != settings.selectedLanguage {
                locale = settings.selectedLanguage.locale
            }
        }
    }
    
    @Published var locale: Locale
    private let userDefaultsKey = "GlobalSettings"
    
    // -------------------------------------------
    // MARK: - Initialization
    // -------------------------------------------
    init() {
        // 1. Attempt to load from UserDefaults
        if let data = UserDefaults.standard.data(forKey: userDefaultsKey),
           let decoded = try? JSONDecoder().decode(GlobalSettings.self, from: data) {
            
            // We have existing settings
            self.settings = decoded
            self.locale = decoded.selectedLanguage.locale
            
        } else {
            // 2. No saved settings => pick the device’s best-matching language
            let matchedLanguage = GlobalSettingsManager.findBestSupportedLanguage()
            
            self.settings = GlobalSettings(
                postcode: "",
                apiKey: "",
                selectedLanguage: matchedLanguage,
                showRatesInPounds: false,
                cardSettings: []
            )
            self.locale = matchedLanguage.locale
        }
        
        // 3. Merge any missing cards
        mergeMissingCards()
    }
    
    // -------------------------------------------
    // MARK: - Helper: Best Matching Language
    // -------------------------------------------
    /// We make this `static` so it does not depend on `self`.
    private static func findBestSupportedLanguage() -> Language {
        let supportedIdentifiers = Language.allCases.map { $0.rawValue }
        let preferred = Bundle.preferredLocalizations(from: supportedIdentifiers)
        
        if let bestMatch = preferred.first,
           let lang = Language(rawValue: bestMatch) {
            return lang
        }
        
        return .english
    }
    
    // -------------------------------------------
    // MARK: - Merge Missing Cards Example
    // -------------------------------------------
    private func mergeMissingCards() {
        // This is just sample logic. If you don’t have a CardRegistry, remove or adapt.
        let registry = CardRegistry.shared
        var changed = false
        
        let existingTypes = Set(settings.cardSettings.map { $0.cardType })
        
        for cardType in CardType.allCases {
            if let definition = registry.definition(for: cardType),
               !existingTypes.contains(cardType) {
                
                let newConfig = CardConfig(
                    id: UUID(),
                    cardType: definition.id,             // or cardType if you prefer
                    isEnabled: definition.defaultIsEnabled,
                    isPurchased: definition.defaultIsPurchased,
                    sortOrder: definition.defaultSortOrder
                )
                
                settings.cardSettings.append(newConfig)
                changed = true
            }
        }
        
        settings.cardSettings.sort { $0.sortOrder < $1.sortOrder }
        
        if changed {
            saveSettings()
        }
    }
    
    // -------------------------------------------
    // MARK: - Save Settings
    // -------------------------------------------
    func saveSettings() {
        if let encoded = try? JSONEncoder().encode(settings) {
            UserDefaults.standard.set(encoded, forKey: userDefaultsKey)
        }
    }
}