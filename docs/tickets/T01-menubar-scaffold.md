# T01 — Menu-bar app scaffold

**Depends on:** nothing
**Blocks:** T02, T03

## Context
Mikey is a menu-bar-only macOS agent: no Dock icon, no main window. Everything
hangs off one menu-bar extra. This ticket produces a runnable shell that every
other ticket plugs into. Per spec §1–2.

## Scope
- New Xcode project: macOS app target, SwiftUI lifecycle, deployment target
  macOS 15+ (developer machine runs macOS 26 / Darwin 25).
- `LSUIElement = YES` in Info.plist (agent app — no Dock icon, no Cmd-Tab).
- No app sandbox (personal tool; mic permission still works via
  `NSMicrophoneUsageDescription` + runtime request — T03).
- `MenuBarExtra` with `.menuBarExtraStyle(.menu)` as the entire UI surface.
- `MikeyApp` entry point + a root `MenuContentView` that will grow sections
  per later tickets. For now: title item "Mikey", `Quit Mikey` (`⌘Q`).
- Static menu-bar icon (SF Symbol placeholder, e.g. `mic` or a small asset).
- App state object (`AppState: ObservableObject`) as the single source the
  menu renders from — recording state, pending list, config. Stub values now.

## Implementation notes
- `MenuBarExtra(isInserted:)` label is where the icon + (later) elapsed time
  live — keep the label a dedicated `MenuBarLabelView` so T04 can animate it.
- Keep bundle id personal (`com.bishesha.mikey` or similar).
- `NSMicrophoneUsageDescription` string added to Info.plist in this ticket so
  T03 doesn't touch plist plumbing: "Mikey records lectures through your mic."
- Git-init the folder; `.gitignore` for Xcode (`xcuserdata`, `DerivedData`).

## Acceptance criteria
- [ ] Builds and runs from Xcode; icon appears in menu bar, nothing in Dock.
- [ ] Clicking icon shows menu with "Mikey" and "Quit Mikey"; Quit exits.
- [ ] App survives sleep/wake while running.
- [ ] `AppState` exists and menu renders from it.

## Edge cases
- macOS may hide the icon if the menu bar is crowded — acceptable; note in
  README (Bartender-style tools exist).
