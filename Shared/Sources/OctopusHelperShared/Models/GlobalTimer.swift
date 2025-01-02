import Combine
import Foundation
import SwiftUI

public class GlobalTimer: ObservableObject {
    private var timer: Timer?
    @Published public var currentTime: Date = Date()

    public init() {}

    public func startTimer() {
        stopTimer()  // ensure no duplicate
        timer = Timer.scheduledTimer(
            withTimeInterval: 60,
            repeats: true
        ) { [weak self] _ in
            self?.currentTime = Date()
        }
        // Fire immediately to ensure current time
        currentTime = Date()
    }

    public func stopTimer() {
        timer?.invalidate()
        timer = nil
    }

    public func refreshTime() {
        currentTime = Date()
    }
}
