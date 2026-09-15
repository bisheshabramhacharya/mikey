import Foundation

/// A held assertion that the Mac may not *idle*-sleep mid-Session (SPEC §3 —
/// the lecture must survive the lid staying open through a long class).
/// `begin`/`end` bracket a recording; both are idempotent so every stop path —
/// manual stop, auto-stop, quit-confirm, or an abandoned start — can call
/// `end` unconditionally without over-releasing. Faked in tests.
public protocol SleepAssertion: AnyObject, Sendable {
    /// Acquires the no-idle-sleep assertion; a no-op if already held.
    func begin()
    /// Releases the assertion if held; a no-op otherwise.
    func end()
}

/// `SleepAssertion` over `ProcessInfo.beginActivity` with
/// `idleSystemSleepDisabled + userInitiated`: the system stays awake for the
/// user-initiated recording but can still sleep once it's released.
public final class ProcessInfoSleepAssertion: SleepAssertion, @unchecked Sendable {
    private let lock = NSLock()
    private var activity: (any NSObjectProtocol)?

    public init() {}

    public func begin() {
        lock.lock()
        defer { lock.unlock() }
        guard activity == nil else { return }
        activity = ProcessInfo.processInfo.beginActivity(
            options: [.idleSystemSleepDisabled, .userInitiated],
            reason: "Mikey is recording a lecture"
        )
    }

    public func end() {
        lock.lock()
        defer { lock.unlock() }
        guard let activity else { return }
        ProcessInfo.processInfo.endActivity(activity)
        self.activity = nil
    }
}
