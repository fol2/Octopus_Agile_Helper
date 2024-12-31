import Foundation
import SwiftUI

// MARK: - Supported App Languages
enum Language: String, Codable, CaseIterable {
    // Instead of hardcoding languages, we'll compute them dynamically
    static var allCases: [Language] {
        // Get all available localizations from the app bundle
        let availableLocalizations = Bundle.main.localizations
            .filter { $0 != "Base" } // Exclude "Base" localization
        
        // Convert to Language cases, fallback to .english if conversion fails
        return availableLocalizations.compactMap { Language(rawValue: $0) }
    }
    
    // Define cases for type safety, but the actual supported languages
    // will be determined by the available .lproj folders and Localizable.xcstrings
    case english = "en"
    case traditionalChinese = "zh-Hant"
    case simplifiedChinese = "zh-Hans"
    case spanish = "es"
    case french = "fr"
    case german = "de"
    case italian = "it"
    case japanese = "ja"
    case korean = "ko"
    case portuguese = "pt-PT"
    case dutch = "nl"
    case polish = "pl"
    case russian = "ru"
    case turkish = "tr"
    case arabic = "ar"
    case czech = "cs"
    case danish = "da"
    case finnish = "fi"
    case greek = "el"
    case hebrew = "he"
    case hindi = "hi"
    case hungarian = "hu"
    case indonesian = "id"
    case norwegian = "nb"
    case romanian = "ro"
    case slovak = "sk"
    case swedish = "sv"
    case thai = "th"
    case ukrainian = "uk"
    case vietnamese = "vi"
    
    var displayName: String {
        switch self {
        case .traditionalChinese:
            return "繁體中文"
        case .simplifiedChinese:
            return "简体中文"
        default:
            // Use the language name in its own language (autonym)
            return self.localizedName(in: self.locale)
        }
    }
    
    // Get language name localized in a specific language
    func localizedName(in locale: Locale) -> String {
        locale.localizedString(forLanguageCode: self.rawValue) ??
        locale.localizedString(forIdentifier: self.rawValue) ??
        self.rawValue
    }
    
    // Get language name in its own language (autonym)
    var autonym: String {
        self.displayName  // Use our custom display name that handles Chinese variants
    }
    
    // Get both localized name and autonym if they're different
    var displayNameWithAutonym: String {
        self.autonym  // Just use the native name
    }
    
    var locale: Locale {
        Locale(identifier: self.rawValue)
    }
    
    static func systemPreferred() -> Language {
        // Get the user's preferred languages in order
        let preferredLanguages = Locale.preferredLanguages
        
        // Try to find the first preferred language that we support
        for language in preferredLanguages {
            // Convert to base language if needed (e.g., "en-US" -> "en")
            let baseLanguage = language.components(separatedBy: "-").first ?? language
            if let supported = Language(rawValue: baseLanguage) {
                return supported
            }
            // Also try the full language code
            if let supported = Language(rawValue: language) {
                return supported
            }
        }
        
        // Fallback to English if no match found
        return .english
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
            // 2. No saved settings => use system preferred language
            let matchedLanguage = Language.systemPreferred()
            
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
        return Language.systemPreferred()
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