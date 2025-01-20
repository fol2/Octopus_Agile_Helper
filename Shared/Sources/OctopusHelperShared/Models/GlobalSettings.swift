import Foundation
import SwiftUI

// MARK: - Supported App Languages
public enum Language: String, Codable, CaseIterable {
    // Instead of hardcoding languages, we'll compute them dynamically
    public static var allCases: [Language] {
        // Get all available localizations from the app bundle
        let availableLocalizations = Bundle.main.localizations
            .filter { $0 != "Base" }  // Exclude "Base" localization

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

    public var displayName: String {
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
    public func localizedName(in locale: Locale) -> String {
        locale.localizedString(forLanguageCode: self.rawValue) ?? locale.localizedString(
            forIdentifier: self.rawValue) ?? self.rawValue
    }

    // Get language name in its own language (autonym)
    public var autonym: String {
        self.displayName  // Use our custom display name that handles Chinese variants
    }

    // Get both localized name and autonym if they're different
    public var displayNameWithAutonym: String {
        self.autonym  // Just use the native name
    }

    public var locale: Locale {
        Locale(identifier: self.rawValue)
    }

    public static func systemPreferred() -> Language {
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

// MARK: - Card Configuration
public struct CardConfig: Identifiable, Codable, Equatable {
    public let id: UUID
    public let cardType: CardType
    public var isEnabled: Bool
    public var isPurchased: Bool
    public var sortOrder: Int

    public init(id: UUID, cardType: CardType, isEnabled: Bool, isPurchased: Bool, sortOrder: Int) {
        self.id = id
        self.cardType = cardType
        self.isEnabled = isEnabled
        self.isPurchased = isPurchased
        self.sortOrder = sortOrder
    }
}

// MARK: - Global Settings
public struct GlobalSettings: Codable, Equatable {
    public var regionInput: String  // Can be either postcode or region code
    public var apiKey: String
    public var selectedLanguage: Language
    public var showRatesInPounds: Bool
    public var showRatesWithVAT: Bool
    public var cardSettings: [CardConfig]
    public var currentAgileCode: String  // Non-optional, always has a value
    public var electricityMPAN: String?
    public var electricityMeterSerialNumber: String?

    // New Fields for Account-based logic
    /// If user chooses the "Account Number" approach:
    public var accountNumber: String?

    /// Optionally store the entire account JSON (raw) for reference or debugging
    public var accountData: Data?

    /// The effective region to use for API calls - returns "H" if regionInput is empty
    public var effectiveRegion: String {
        let cleaned = regionInput.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()

        // If empty, return default region "H"
        guard !cleaned.isEmpty else { return "H" }

        // If it's a single letter A-P, it's already a valid region code
        if cleaned.count == 1 && cleaned >= "A" && cleaned <= "P" {
            return cleaned
        }

        // For postcodes, check the cache
        if let cacheData = UserDefaults.standard.data(forKey: "postcode_region_cache"),
            let cache = try? JSONDecoder().decode([String: String].self, from: cacheData),
            let region = cache[cleaned]
        {
            return region
        }

        // If no cached result, return "H" as fallback
        return "H"
    }

    public init(
        regionInput: String,
        apiKey: String,
        selectedLanguage: Language,
        showRatesInPounds: Bool,
        showRatesWithVAT: Bool,
        cardSettings: [CardConfig],
        currentAgileCode: String = "",
        electricityMPAN: String? = nil,
        electricityMeterSerialNumber: String? = nil,
        accountNumber: String? = nil,
        accountData: Data? = nil
    ) {
        self.regionInput = regionInput
        self.apiKey = apiKey
        self.selectedLanguage = selectedLanguage
        self.showRatesInPounds = showRatesInPounds
        self.showRatesWithVAT = showRatesWithVAT
        self.cardSettings = cardSettings
        self.currentAgileCode = currentAgileCode
        self.electricityMPAN = electricityMPAN
        self.electricityMeterSerialNumber = electricityMeterSerialNumber
        self.accountNumber = accountNumber
        self.accountData = accountData
    }

    // MARK: - Equatable
    public static func == (lhs: GlobalSettings, rhs: GlobalSettings) -> Bool {
        lhs.regionInput == rhs.regionInput && lhs.apiKey == rhs.apiKey
            && lhs.selectedLanguage == rhs.selectedLanguage
            && lhs.showRatesInPounds == rhs.showRatesInPounds
            && lhs.showRatesWithVAT == rhs.showRatesWithVAT && lhs.cardSettings == rhs.cardSettings
            && lhs.currentAgileCode == rhs.currentAgileCode
            && lhs.electricityMPAN == rhs.electricityMPAN
            && lhs.electricityMeterSerialNumber == rhs.electricityMeterSerialNumber
            && lhs.accountNumber == rhs.accountNumber && lhs.accountData == rhs.accountData
    }
}

// Provide a default "empty" settings object
extension GlobalSettings {
    public static let defaultSettings = GlobalSettings(
        regionInput: "",
        apiKey: "",
        selectedLanguage: .english,
        showRatesInPounds: false,
        showRatesWithVAT: true,
        cardSettings: [],
        currentAgileCode: "",
        electricityMPAN: nil,
        electricityMeterSerialNumber: nil,
        accountNumber: nil,
        accountData: nil
    )
}

// MARK: - Manager (ObservableObject)
public class GlobalSettingsManager: ObservableObject {
    private var isSaving = false
    private var isLoading = false  // New flag to track loading state

    @Published public var settings: GlobalSettings {
        didSet {
            // Skip saving if we're loading or already saving
            guard !isLoading && !isSaving else { return }

            isSaving = true

            // Only log when regionInput changes
            if oldValue.regionInput != settings.regionInput {
                print(
                    "GlobalSettingsManager: settings changed to regionInput=\(settings.regionInput) => effectiveRegion=\(settings.effectiveRegion)"
                )
            }

            saveSettings()
            if oldValue.selectedLanguage != settings.selectedLanguage {
                locale = settings.selectedLanguage.locale
            }
            isSaving = false
        }
    }

    @Published public var locale: Locale
    private let userDefaultsKey = "GlobalSettings"

    // -------------------------------------------
    // MARK: - Initialization
    // -------------------------------------------
    public init() {
        isLoading = true  // Set loading flag

        // 1. Attempt to load from UserDefaults
        if let data = UserDefaults.standard.data(forKey: userDefaultsKey),
            let decoded = try? JSONDecoder().decode(GlobalSettings.self, from: data)
        {
            // We have existing settings
            self.settings = decoded
            self.locale = decoded.selectedLanguage.locale
        } else {
            // 2. No saved settings => use system preferred language
            let matchedLanguage = Language.systemPreferred()

            self.settings = GlobalSettings(
                regionInput: "",
                apiKey: "",
                selectedLanguage: matchedLanguage,
                showRatesInPounds: false,
                showRatesWithVAT: true,
                cardSettings: [],
                currentAgileCode: "",
                electricityMPAN: nil,
                electricityMeterSerialNumber: nil,
                accountNumber: nil,
                accountData: nil
            )
            self.locale = matchedLanguage.locale
        }

        // 3. Merge any missing cards without triggering saves
        let oldSettings = self.settings
        mergeMissingCards()

        // Only save if cards were actually added
        if oldSettings != self.settings {
            saveSettings()
        }

        isLoading = false  // Clear loading flag
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
        // This is just sample logic. If you don't have a CardRegistry, remove or adapt.
        let registry = CardRegistry.shared
        var changed = false

        let existingTypes = Set(settings.cardSettings.map { $0.cardType })

        for cardType in CardType.allCases {
            if let definition = registry.definition(for: cardType),
                !existingTypes.contains(cardType)
            {
                let newConfig = CardConfig(
                    id: UUID(),
                    cardType: definition.id,  // or cardType if you prefer
                    isEnabled: definition.defaultIsEnabled,
                    isPurchased: definition.defaultIsPurchased,
                    sortOrder: definition.defaultSortOrder
                )

                settings.cardSettings.append(newConfig)
                changed = true
            }
        }

        settings.cardSettings.sort { $0.sortOrder < $1.sortOrder }
    }

    // -------------------------------------------
    // MARK: - Save Settings
    // -------------------------------------------
    public func saveSettings() {
        if let encoded = try? JSONEncoder().encode(settings) {
            // Save to standard UserDefaults
            UserDefaults.standard.set(encoded, forKey: userDefaultsKey)

            // Also save to shared UserDefaults for widget access
            let sharedDefaults = UserDefaults(suiteName: "group.com.jamesto.octopus-agile-helper")
            sharedDefaults?.set(encoded, forKey: "user_settings")

            // Also save individual values for easier widget access
            sharedDefaults?.set(settings.regionInput, forKey: "selected_postcode")
            sharedDefaults?.set(settings.apiKey, forKey: "api_key")
            sharedDefaults?.set(settings.selectedLanguage.rawValue, forKey: "selected_language")
            sharedDefaults?.set(settings.showRatesInPounds, forKey: "show_rates_in_pounds")
            sharedDefaults?.set(settings.showRatesWithVAT, forKey: "show_rates_with_vat")
            sharedDefaults?.set(settings.currentAgileCode, forKey: "current_agile_code")
            sharedDefaults?.set(settings.electricityMPAN, forKey: "electricity_mpan")
            sharedDefaults?.set(
                settings.electricityMeterSerialNumber, forKey: "meter_serial_number")
            sharedDefaults?.set(settings.accountNumber, forKey: "account_number")
            sharedDefaults?.set(settings.accountData, forKey: "account_data")

            // Notify widget of changes
            #if !WIDGET
                if let widgetCenter = NSClassFromString("WidgetCenter") as? NSObject {
                    let selector = NSSelectorFromString("reloadAllTimelines")
                    if widgetCenter.responds(to: selector) {
                        widgetCenter.perform(selector)
                    }
                }
            #endif
        }
    }
}
