import SwiftUI

/// Identifies which plan(s) a given card supports.
public enum SupportedPlan: String, Codable {
    case agile
    case flux
    case any
}

public struct MediaItem {
    public let localName: String?
    public let remoteURL: URL?
    public let youtubeID: String?
    public let caption: LocalizedStringKey?

    public var isVideo: Bool {
        if youtubeID != nil { return true }
        if let localName = localName {
            return Bundle.main.url(forResource: localName, withExtension: "mp4") != nil
        }
        if let remoteURL = remoteURL {
            let pathExtension = remoteURL.pathExtension.lowercased()
            return ["mp4", "mov", "m4v"].contains(pathExtension)
        }
        return false
    }

    public init(
        localName: String? = nil,
        remoteURL: URL? = nil,
        youtubeID: String? = nil,
        caption: LocalizedStringKey? = nil
    ) {
        self.localName = localName
        self.remoteURL = remoteURL
        self.youtubeID = youtubeID
        self.caption = caption
    }
}

/// Identifies a single card's metadata and how to produce its SwiftUI view
public final class CardDefinition {
    public let id: CardType
    public let displayNameKey: String
    public let descriptionKey: String
    public let isPremium: Bool
    public let makeView: (CardDependencies) -> AnyView
    public let makeWidgetView: (Any) -> AnyView  // Keep this as Any for now since widgets aren't affected
    public let iconName: String
    public let defaultIsEnabled: Bool
    public let defaultIsPurchased: Bool
    public let defaultSortOrder: Int
    public let mediaItems: [MediaItem]
    public let learnMoreURL: URL?
    public let supportedPlans: [SupportedPlan]

    public init(
        id: CardType,
        displayNameKey: String,
        descriptionKey: String,
        isPremium: Bool,
        makeView: @escaping (CardDependencies) -> AnyView,
        makeWidgetView: @escaping (Any) -> AnyView,
        iconName: String,
        defaultIsEnabled: Bool = true,
        defaultIsPurchased: Bool = true,
        defaultSortOrder: Int,
        mediaItems: [MediaItem] = [],
        learnMoreURL: URL? = nil,
        supportedPlans: [SupportedPlan] = [.any]
    ) {
        self.id = id
        self.displayNameKey = displayNameKey
        self.descriptionKey = descriptionKey
        self.isPremium = isPremium
        self.makeView = makeView
        self.makeWidgetView = makeWidgetView
        self.iconName = iconName
        self.defaultIsEnabled = defaultIsEnabled
        self.defaultIsPurchased = defaultIsPurchased
        self.defaultSortOrder = defaultSortOrder
        self.mediaItems = mediaItems
        self.learnMoreURL = learnMoreURL
        self.supportedPlans = supportedPlans
    }
}

/// Error thrown when a dependency is not found
public enum DependencyError: Error {
    case dependencyNotRegistered(String)
    case dependencyTypeMismatch(expected: String, actual: String)
}

/// A dynamic container for all dependencies that cards might need
public final class CardDependencies {
    private var container = [String: Any]()
    private let _refreshManager = CardRefreshManager.shared

    public init() {}

    /// Register a dependency with type checking
    public func register<T>(_ dependency: T) {
        let key = String(describing: T.self)
        container[key] = dependency
    }

    /// Resolve a dependency with type safety
    public func resolve<T>() throws -> T {
        let key = String(describing: T.self)
        guard let dependency = container[key] else {
            throw DependencyError.dependencyNotRegistered(key)
        }

        guard let typedDependency = dependency as? T else {
            throw DependencyError.dependencyTypeMismatch(
                expected: String(describing: T.self),
                actual: String(describing: type(of: dependency))
            )
        }

        return typedDependency
    }

    /// Safe accessor for dependencies with a default value
    public func resolveOrDefault<T>(_ defaultValue: T) -> T {
        (try? resolve() as T) ?? defaultValue
    }

    /// Built-in refresh manager that's always available
    public var refreshManager: CardRefreshManager {
        _refreshManager
    }

    /// Convenience accessors for common dependencies
    public var ratesViewModel: RatesViewModel {
        // This will crash if the dependency is not registered, which is what we want
        // to maintain backward compatibility with existing code that expects non-optional values
        try! resolve()
    }

    public var consumptionViewModel: ConsumptionViewModel {
        try! resolve()
    }

    public var globalTimer: GlobalTimer {
        try! resolve()
    }

    public var globalSettings: GlobalSettingsManager {
        try! resolve()
    }

    // MARK: - Factory Methods

    /// Creates a new instance of CardDependencies with all required dependencies registered
    @MainActor
    public static func createDependencies(
        ratesViewModel: RatesViewModel,
        consumptionViewModel: ConsumptionViewModel,
        globalTimer: GlobalTimer,
        globalSettings: GlobalSettingsManager
    ) -> CardDependencies {
        let dependencies = CardDependencies()
        dependencies.register(ratesViewModel)
        dependencies.register(consumptionViewModel)
        dependencies.register(globalTimer)
        dependencies.register(globalSettings)
        return dependencies
    }
}

/// Central registry for all card definitions and metadata
public final class CardRegistry: ObservableObject {
    public static let shared = CardRegistry()

    // A dictionary mapping CardType -> CardDefinition
    private var definitions: [CardType: CardDefinition] = [:]
    private var timer: GlobalTimer?

    @Published public private(set) var isReady: Bool = false

    private init() {
        registerAllCards()
        self.isReady = true
    }

    public func updateTimer(_ timer: GlobalTimer) {
        self.timer = timer
    }

    public func register(_ definition: CardDefinition) {
        definitions[definition.id] = definition
    }

    /// Public accessor to fetch a card definition (if it exists)
    public func definition(for type: CardType) -> CardDefinition? {
        definitions[type]
    }
}
