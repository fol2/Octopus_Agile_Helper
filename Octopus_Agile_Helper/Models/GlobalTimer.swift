import Foundation
import Combine

class GlobalTimer: ObservableObject {
    private var timer: Timer?
    @Published var currentTime: Date = Date()
    
    func startTimer() {
        stopTimer() // ensure no duplicate
        timer = Timer.scheduledTimer(
            withTimeInterval: 60,
            repeats: true
        ) { [weak self] _ in
            self?.currentTime = Date()
        }
    }
    
    func stopTimer() {
        timer?.invalidate()
        timer = nil
    }
} 