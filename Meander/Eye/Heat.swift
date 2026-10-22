import Foundation

/// Keeps Eye from overheating the phone. Eye works through photos more slowly when the phone is warm,
/// and the library pass stops while it's hot or in Low Power Mode, picking up again once it isn't.
enum Heat {
    /// Photos Eye works on at once: fewer as the phone warms up.
    static var width: Int {
        switch ProcessInfo.processInfo.thermalState {
        case .nominal: 8
        case .fair: 3
        default: 1
        }
    }

    /// Why the library pass should wait, or nil when it can go on.
    static var pauseReason: String? {
        if ProcessInfo.processInfo.isLowPowerModeEnabled { return "Paused in Low Power Mode" }
        switch ProcessInfo.processInfo.thermalState {
        case .serious, .critical: return "Paused while your phone cools down"
        default: return nil
        }
    }

    /// Returns once the phone is cool and out of Low Power Mode, or the task is cancelled.
    static func waitUntilReady() async {
        while pauseReason != nil, !Task.isCancelled {
            try? await Task.sleep(for: .seconds(20))
        }
    }
}
