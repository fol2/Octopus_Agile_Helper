import Foundation

/// Represents different components of the app for targeted debugging
public enum LogComponent: String {
    case widget = "WIDGET"
    case widgetCache = "WIDGET CACHE"
    case ratesViewModel = "RATES VM"
    case ratesRepository = "RATES REPO"
    case stateChanges = "STATE CHANGES"
    
    var isEnabled: Bool {
        switch self {
        case .widget: return DebugLogger.isWidgetLoggingEnabled
        case .widgetCache: return DebugLogger.isWidgetCacheLoggingEnabled
        case .ratesViewModel: return DebugLogger.isRatesVMLoggingEnabled
        case .ratesRepository: return DebugLogger.isRatesRepoLoggingEnabled
        case .stateChanges: return DebugLogger.isStateChangesLoggingEnabled
        }
    }
}

/// Central debug logging facility for the Octopus Helper app and its widget
public final class DebugLogger {
    // MARK: - Debug Flags
    
    /// Master switch for all debug logging
    public static var isDebugLoggingEnabled = false
    
    /// Component-specific switches
    public static var isWidgetLoggingEnabled = false
    public static var isWidgetCacheLoggingEnabled = false
    public static var isRatesVMLoggingEnabled = false
    public static var isRatesRepoLoggingEnabled = false
    public static var isStateChangesLoggingEnabled = false
    
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
            }
        }
        
        // If all components are disabled, disable master switch
        if !isWidgetLoggingEnabled && 
           !isWidgetCacheLoggingEnabled && 
           !isRatesVMLoggingEnabled && 
           !isRatesRepoLoggingEnabled &&
           !isStateChangesLoggingEnabled {
            isDebugLoggingEnabled = false
        }
    }
} 