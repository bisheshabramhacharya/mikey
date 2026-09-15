# Mikey

A lightweight macOS menu-bar app that records college lectures through the mic
and transcribes them on demand with on-device Whisper. Personal tool.

Domain glossary: `CONTEXT.md`. Product spec: `docs/SPEC.md`.

## Layout

- `Sources/Mikey/` — library target with all app logic and the SwiftUI menu
  views (`AppState`, `SessionController`, `RecordingEngine`, `Archive`,
  `M4AWriter`, `MenuBarLabel`, `MenuContentView`, …).
- `Sources/MikeyApp/` — the executable target: just the `@main` SwiftUI `App`.
  Builds the `Mikey` binary.
- `Tests/MikeyTests/` — the test suite plus `Runner.swift` (see below).
- `Scripts/` — developer scripts.

## Commands

| Command | What it does |
|---|---|
| `swift run Mikey` | Build and run the menu-bar app (debug binary — no `.app` bundle, so notifications are skipped and TCC may not prompt as a bundled app would). |
| `Scripts/test.sh` | Build and **run** the test suite. Exits nonzero on failure. Passes extra args to Swift Testing (`--filter`, `--list-tests`, `--verbose`, …). |
| `Scripts/package-app.sh` | Build release, assemble `Mikey.app` (Info.plist: `LSUIElement`, `NSMicrophoneUsageDescription`), ad-hoc `codesign`. |

## Testing on a CLT-only machine (no Xcode)

`swift test` does **not** run the suite here: XCTest is Xcode-only, so SwiftPM
produces an `.xctest` bundle (Mach-O `MH_BUNDLE`) with no host process to
execute it — it prints `Build complete!` having run zero tests.

Instead, `MikeyTests` is a plain executable target containing the test files
and `Runner.swift`, which calls `Testing.__swiftPMEntryPoint()` — the same
entry point SwiftPM's generated runner uses. Testing.framework ships in the
CLT at `/Library/Developer/CommandLineTools/Library/Developer/Frameworks`;
Package.swift wires up the search paths. `Scripts/test.sh` builds and runs it.
