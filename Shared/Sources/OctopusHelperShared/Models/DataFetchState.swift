//
//  DataFetchState.swift
//  Octopus_Agile_Helper
//
//  A single universal fetch status enum to replace ProductFetchStatus, FetchStatus, CombinedFetchStatus, etc.
//

import Foundation

public enum DataFetchState: Equatable {
    case idle
    case loading
    case partial       // e.g. partial data returned
    case success
    case failure(Error)

    public static func == (lhs: DataFetchState, rhs: DataFetchState) -> Bool {
        switch (lhs, rhs) {
        case (.idle, .idle),
             (.loading, .loading),
             (.partial, .partial),
             (.success, .success):
            return true
        case (.failure(let lhsError), .failure(let rhsError)):
            return lhsError.localizedDescription == rhsError.localizedDescription
        default:
            return false
        }
    }

    public var isLoading: Bool {
        if case .loading = self { return true }
        return false
    }

    public var isFailure: Bool {
        if case .failure = self { return true }
        return false
    }

    public var description: String {
        switch self {
        case .idle: return "Idle"
        case .loading: return "Loading..."
        case .partial: return "Partial Data"
        case .success: return "Complete"
        case .failure(let error): return "Error: \(error.localizedDescription)"
        }
    }
}