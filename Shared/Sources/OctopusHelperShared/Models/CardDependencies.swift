import SwiftUI

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
}
