import Combine
import SwiftUI

/// A simple shared manager that lets all "cards" subscribe
/// to the same .onReceive timers and scene-phase triggers.
@MainActor
public class CardRefreshManager: ObservableObject {
    public static let shared = CardRefreshManager()

    // Published events
    @Published public var minuteTick: Date? = nil
    @Published public var halfHourTick: Date? = nil
    @Published public var sceneActiveTick: Bool = false

    private var timerCancellable: AnyCancellable?
    @Environment(\.scenePhase) private var scenePhase

    public init() {
        // 1) Start a timer every second
        timerCancellable =
            Timer
            .publish(every: 1, on: .main, in: .common)
            .autoconnect()
            .sink { [weak self] _ in
                self?.handleTimer()
            }
    }

    /// Called by your App or ContentView when the app becomes active
    public func notifyAppBecameActive() {
        sceneActiveTick.toggle()
    }

    private func handleTimer() {
        let now = Date()
        let cal = Calendar.current
        let second = cal.component(.second, from: now)
        let minute = cal.component(.minute, from: now)
        // If second == 0 => publish "minuteTick"
        if second == 0 {
            minuteTick = now
            // If also minute == 0 or minute == 30 => publish "halfHourTick"
            if minute == 0 || minute == 30 {
                halfHourTick = now
            }
        }
    }
}
