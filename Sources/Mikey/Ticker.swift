import Foundation

/// The single heartbeat that publishes "recording is live" updates into
/// `AppState` — elapsed `mm:ss`, the input-level meter, the pulsing menu-bar
/// indicator, and the auto-stop cap check all hang off this one timer, so the
/// views carry no timers of their own (SPEC §2).
@MainActor
public protocol Ticker: AnyObject {
    /// Fires `onTick` every `interval` seconds until `stop()` — or until the
    /// next `start`, which replaces the previous schedule.
    func start(
        every interval: TimeInterval,
        onTick: @escaping @MainActor @Sendable () -> Void
    )
    /// Stops the heartbeat. Safe to call when nothing is scheduled.
    func stop()
}

/// `Ticker` backed by a Foundation `Timer` on the main run loop's `.common`
/// modes. Common modes matter: while a menu is held open the run loop sits in
/// event-tracking mode, and a default-mode timer would freeze the elapsed time
/// and level meter exactly when the user is looking at them.
public final class TimerTicker: Ticker {
    private var timer: Timer?

    public init() {}

    public func start(
        every interval: TimeInterval,
        onTick: @escaping @MainActor @Sendable () -> Void
    ) {
        timer?.invalidate()
        // The protocol is @MainActor, so this always runs on the main thread
        // and the timer's block lands back on it — `assumeIsolated` is sound.
        let timer = Timer(timeInterval: interval, repeats: true) { _ in
            MainActor.assumeIsolated { onTick() }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    public func stop() {
        timer?.invalidate()
        timer = nil
    }
}
