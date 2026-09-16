import Foundation
import Testing
@testable import Mikey

/// The `Launch at Login` toggle (SPEC §2, §5): state is read from the
/// login-items registration — which is also the persistence — and a failed
/// update lands in `lastError` like every other menu action.
@MainActor
struct LaunchAtLoginTests {
    private struct StubError: Error {}

    private let tempDir: URL
    private let launchAtLogin: FakeLaunchAtLogin

    init() throws {
        tempDir = FileManager.default.temporaryDirectory
            .appending(path: "mikey-tests-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        launchAtLogin = FakeLaunchAtLogin()
    }

    private func cleanup() {
        try? FileManager.default.removeItem(at: tempDir)
    }

    /// An AppState whose Archive lives in `tempDir`, sharing the suite's
    /// fake registration database.
    private func makeAppState() -> AppState {
        AppState(
            sessions: SessionController(
                engine: FakeRecordingEngine(),
                archive: Archive(root: tempDir),
                clock: FixedClock(now: Date()),
                notifier: FakeNotifier()
            ),
            launchAtLogin: launchAtLogin
        )
    }

    @Test func toggleOnRegisters() {
        defer { cleanup() }
        let appState = makeAppState()
        #expect(appState.launchAtLoginEnabled == false)

        appState.setLaunchAtLogin(true)

        #expect(launchAtLogin.setEnabledCalls == [true])
        #expect(launchAtLogin.isEnabled)
        #expect(appState.launchAtLoginEnabled)
        #expect(appState.lastError == nil)
    }

    @Test func toggleOffUnregisters() {
        defer { cleanup() }
        launchAtLogin.isEnabled = true
        let appState = makeAppState()
        #expect(appState.launchAtLoginEnabled)

        appState.setLaunchAtLogin(false)

        #expect(launchAtLogin.setEnabledCalls == [false])
        #expect(!launchAtLogin.isEnabled)
        #expect(!appState.launchAtLoginEnabled)
    }

    @Test func failedUpdateReportsErrorAndKeepsTrueState() {
        defer { cleanup() }
        launchAtLogin.setEnabledError = StubError()
        let appState = makeAppState()

        appState.setLaunchAtLogin(true)

        #expect(appState.lastError != nil)
        // The registration never changed, so the toggle re-reads off —
        // not the requested state.
        #expect(!launchAtLogin.isEnabled)
        #expect(!appState.launchAtLoginEnabled)
    }

    @Test func registrationIsRereadFromTheStoreOnLaunch() {
        defer { cleanup() }
        launchAtLogin.isEnabled = true // as a previous run's toggle left it

        let appState = makeAppState()

        // A fresh AppState shows the persisted registration — nothing is
        // held in memory or mirrored into config.json.
        #expect(appState.launchAtLoginEnabled)
    }

    @Test func menuOpenReflectsExternalChange() {
        defer { cleanup() }
        let appState = makeAppState()
        #expect(!appState.launchAtLoginEnabled)

        // The user flipped the item in System Settings between menu opens.
        launchAtLogin.isEnabled = true
        appState.reloadConfig()

        #expect(appState.launchAtLoginEnabled)
    }
}
