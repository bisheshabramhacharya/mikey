# T09 — Resilience, permissions & polish

**Depends on:** T04, T07

## Context
The grab-bag that makes Mikey trustworthy in a real lecture hall (spec §7–8):
permission flows, disk checks, crash recovery, launch-at-login, and the
remaining error surfaces.

## Scope
- **Crash recovery:** on launch, any `*.recording` marker in the Archive ⇒
  previous Session died mid-capture. Remove the marker, keep the `.m4a`,
  and show a menu note/notification "Recovered an interrupted recording" —
  it stays pending like any other.
- **Disk space:** before `start()`, require ≥500 MB free on the Archive
  volume (`URL.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])`);
  otherwise refuse with menu alert.
- **Mic permission denied:** menu item `⚠ Microphone access needed — Open
  System Settings` deep-linking
  `x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone`.
- **Launch at Login:** toggle in menu via `SMAppService.mainApp`
  (`.register()`/`.unregister()`), persisted — not in config.json.
- **Input device change mid-recording:** config-change handler from T03;
  if it can't reattach, stop + notify "Recording stopped — mic changed" and
  keep the partial file.
- **Menu-bar icon set:** final idle glyph + recording frames (tint-animated
  or two-asset pulse) — replace T04 placeholder with intended assets.
- Error copy: every failure surfaces as a plain-language menu line or
  notification — never a silent no-op.

## Implementation notes
- `SMAppService` requires no helper-target gymnastics on modern macOS —
  verify on the dev machine's macOS version.
- Recovered-file UX is deliberately thin: file kept, pending, one notice.
  Don't build a recovery dialog.
- This ticket is the right place to bump `gainDB` default if dogfooding
  shows clipping/quietness (config already supports it).

## Acceptance criteria
- [ ] `kill -9` mid-recording → next launch recovers: marker gone, file
      intact, user notified, session pending.
- [ ] <500 MB free → record attempt refuses with clear message.
- [ ] Revoked mic permission → menu offers the System Settings deep link.
- [ ] Launch-at-Login toggle works and survives reboot.
- [ ] Every spec §7 row has an implemented behavior (check them off in
      code review).

## Edge cases
- Marker present but `.m4a` deleted by user → remove marker silently.
- Toggle launch-at-login then delete the app → standard macOS cleanup; no
  work needed.
