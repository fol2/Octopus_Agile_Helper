import Foundation

/// Represents different components of the app for targeted debugging
public enum LogComponent: String {
    case widget = "WIDGET"
    case widgetCache = "WIDGET CACHE"
    case ratesViewModel = "RATES VM"
    case ratesRepository = "RATES REPO"
    case stateChanges = "STATE CHANGES"
    case tariffViewModel = "TARIFF VM"
    case cardManagement = "CardManagement"

    var isEnabled: Bool {
        switch self {
        case .widget: return DebugLogger.isWidgetLoggingEnabled
        case .widgetCache: return DebugLogger.isWidgetCacheLoggingEnabled
        case .ratesViewModel: return DebugLogger.isRatesVMLoggingEnabled
        case .ratesRepository: return DebugLogger.isRatesRepoLoggingEnabled
        case .stateChanges: return DebugLogger.isStateChangesLoggingEnabled
        case .tariffViewModel: return DebugLogger.isTariffVMLoggingEnabled
        case .cardManagement: return DebugLogger.isCardManagementLoggingEnabled
        }
    }
}

/// Central debug logging facility for the Octopus Helper app and its widget
public final class DebugLogger {
    // MARK: - Debug Flags

    /// Master switch for all debug logging
    public static var isDebugLoggingEnabled = true

    /// Component-specific switches
    public static var isWidgetLoggingEnabled = false
    public static var isWidgetCacheLoggingEnabled = false
    public static var isRatesVMLoggingEnabled = true
    public static var isRatesRepoLoggingEnabled = true
    public static var isStateChangesLoggingEnabled = true
    public static var isTariffVMLoggingEnabled = true
    public static var isCardManagementLoggingEnabled = true

    // MARK: - Logging Methods

    /// Log a debug message for a specific component
    /// - Parameters:
    ///   - message: The message to log
    ///   - component: The component generating the log
    ///   - function: The function name (automatically captured)
    ///   - line: The line number (automatically captured)
    public static func debug(
        _ message: String,
        component: LogComponent,
        function: String = #function,
        line: Int = #line
    ) {
        guard isDebugLoggingEnabled && component.isEnabled else { return }

        let timestamp = DateFormatter.localizedString(
            from: Date(),
            dateStyle: .none,
            timeStyle: .medium
        )

        print("[\(timestamp)] \(component.rawValue) [\(function):\(line)]: \(message)")
    }

    /// Enable logging for specific components
    /// - Parameter components: The components to enable
    public static func enableLogging(for components: LogComponent...) {
        isDebugLoggingEnabled = true
        components.forEach { component in
            switch component {
            case .widget:
                isWidgetLoggingEnabled = true
            case .widgetCache:
                isWidgetCacheLoggingEnabled = true
            case .ratesViewModel:
                isRatesVMLoggingEnabled = true
            case .ratesRepository:
                isRatesRepoLoggingEnabled = true
            case .stateChanges:
                isStateChangesLoggingEnabled = true
            case .tariffViewModel:
                isTariffVMLoggingEnabled = true
            case .cardManagement:
                isCardManagementLoggingEnabled = true
            }
        }
    }

    /// Disable logging for specific components
    /// - Parameter components: The components to disable
    public static func disableLogging(for components: LogComponent...) {
        components.forEach { component in
            switch component {
            case .widget:
                isWidgetLoggingEnabled = false
            case .widgetCache:
                isWidgetCacheLoggingEnabled = false
            case .ratesViewModel:
                isRatesVMLoggingEnabled = false
            case .ratesRepository:
                isRatesRepoLoggingEnabled = false
            case .stateChanges:
                isStateChangesLoggingEnabled = false
            case .tariffViewModel:
                isTariffVMLoggingEnabled = false
            case .cardManagement:
                isCardManagementLoggingEnabled = false
            }
        }

        // If all components are disabled, disable master switch
        if !isWidgetLoggingEnabled && !isWidgetCacheLoggingEnabled && !isRatesVMLoggingEnabled
            && !isRatesRepoLoggingEnabled && !isStateChangesLoggingEnabled
            && !isTariffVMLoggingEnabled && !isCardManagementLoggingEnabled
        {
            isDebugLoggingEnabled = false
        }
    }

    // MARK: - Structured Logging

    /// Shared instance for structured logging
    public static let shared = DebugLogger()

    // Cache for deduplication
    private var recentLogs: [(message: String, timestamp: Date)] = []
    private let deduplicationWindow: TimeInterval = 0.1  // 100ms window

    /// Log a structured debug message with details
    /// - Parameters:
    ///   - message: The main message to log
    ///   - details: A dictionary of additional details to log
    ///   - component: The component generating the log (optional)
    ///   - function: The function name (automatically captured)
    ///   - line: The line number (automatically captured)
    public func log(
        _ message: String,
        details: [String: Any],
        component: LogComponent? = .tariffViewModel,
        function: String = #function,
        line: Int = #line
    ) {
        guard Self.isDebugLoggingEnabled && (component?.isEnabled ?? true) else { return }

        // Create a unique key for this log
        let logKey = "\(message)|\(function)|\(line)"
        let now = Date()

        // Clean up old entries
        recentLogs = recentLogs.filter { now.timeIntervalSince($0.timestamp) < deduplicationWindow }

        // Check for duplicates
        guard !recentLogs.contains(where: { $0.message == logKey }) else {
            return
        }

        // Add to recent logs
        recentLogs.append((logKey, now))

        let timestamp = DateFormatter.localizedString(
            from: now,
            dateStyle: .none,
            timeStyle: .medium
        )

        let componentStr = component.map { "[\($0.rawValue)]" } ?? ""
        print("[\(timestamp)]\(componentStr) [\(function):\(line)]:")
        print("  Message: \(message)")
        print("  Details:")
        details.forEach { key, value in
            print("    - \(key): \(value)")
        }
    }
}
