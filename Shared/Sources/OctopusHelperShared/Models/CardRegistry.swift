import SwiftUI

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
    public let makeView: (Any) -> AnyView
    public let iconName: String
    public let defaultIsEnabled: Bool
    public let defaultIsPurchased: Bool
    public let defaultSortOrder: Int
    public let mediaItems: [MediaItem]
    public let learnMoreURL: URL?

    public init(
        id: CardType,
        displayNameKey: String,
        descriptionKey: String,
        isPremium: Bool,
        makeView: @escaping (Any) -> AnyView,
        iconName: String,
        defaultIsEnabled: Bool = true,
        defaultIsPurchased: Bool = true,
        defaultSortOrder: Int,
        mediaItems: [MediaItem] = [],
        learnMoreURL: URL? = nil
    ) {
        self.id = id
        self.displayNameKey = displayNameKey
        self.descriptionKey = descriptionKey
        self.isPremium = isPremium
        self.makeView = makeView
        self.iconName = iconName
        self.defaultIsEnabled = defaultIsEnabled
        self.defaultIsPurchased = defaultIsPurchased
        self.defaultSortOrder = defaultSortOrder
        self.mediaItems = mediaItems
        self.learnMoreURL = learnMoreURL
    }
}

/// Central registry for all card definitions and metadata
public final class CardRegistry {
    public static let shared = CardRegistry()

    // A dictionary mapping CardType -> CardDefinition
    private var definitions: [CardType: CardDefinition] = [:]

    private init() {
        // The actual card registrations will be done by the app
        // We'll keep this empty in the shared package
    }

    public func register(_ definition: CardDefinition) {
        definitions[definition.id] = definition
    }

    /// Public accessor to fetch a card definition (if it exists)
    public func definition(for type: CardType) -> CardDefinition? {
        definitions[type]
    }
    
    /// Register cards for widgets
    public func registerWidgetCards() {
        register(
            CardDefinition(
                id: .currentRate,
                displayNameKey: "Current Rate",
                descriptionKey: "Displays the ongoing rate for the current half-hour slot.",
                isPremium: false,
                makeView: { _ in AnyView(EmptyView()) },  // Widget doesn't need the view
                iconName: "clock.fill",
                defaultSortOrder: 1,
                mediaItems: []
            )
        )
    }
}
