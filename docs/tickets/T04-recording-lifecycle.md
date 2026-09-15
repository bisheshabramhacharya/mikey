# T04 — Session lifecycle: start, stop, auto-stop, menu states

**Depends on:** T02, T03
**Blocks:** T08, T09

## Context
The core loop's state machine (spec §1–3): idle → recording → saved. This
ticket makes pressing a course name actually record, keeps the Mac awake, and
enforces the 75-minute invariant.

## Scope
- `RecordingController` owning `enum State { idle, recording(Session) }`:
  - `start(course:)` → compute file URL
    (`Archive/<slug>/YYYY-MM-DD_HH-mm.m4a`, `-2` suffix on collision) →
    `AudioRecorder.start` → hold sleep assertion → start 1 s ticker.
  - `stop()` → `AudioRecorder.stop()` → delete `.recording` marker →
    release assertion → back to idle.
  - Auto-stop: at `autoStopMinutes` (default 75) elapsed → same path as
    manual stop + `UNUserNotificationCenter` notification
    "Recording auto-stopped (75:00) — <Course>".
- Menu-bar label while recording: pulsing indicator (alternate icon between
  `mic.fill` / `record.circle` or two tint states every ~1 s via the ticker)
  + elapsed `mm:ss` text.
- Recording-state menu: `■ Stop Recording — <Course> · mm:ss`, live level
  meter (bar or 5-segment dots from `recorder.level`), Open Archive, Quit.
- Quit while recording → `NSAlert` "Stop recording and quit?" — stop+clean
  finalize on confirm, cancel otherwise.
- `UNUserNotificationCenter` permission requested lazily on first record.

## Implementation notes
- Sleep: `IOPMAssertionCreateWithName(kIOPMAssertionTypePreventUserIdleSystemSleep)`
  or `ProcessInfo.processInfo.beginActivity(options: [.idleSystemSleepDisabled, .userInitiated])`
  — latter is simpler Swift; use it.
- Elapsed/level driven by one `Timer` publishing into `AppState` — don't
  create per-view timers.
- Single recording by construction: when `state == .recording`, the course
  items are replaced by the Stop view (spec §7).

## Acceptance criteria
- [ ] Clicking a course starts recording within ~0.5 s; icon animates, elapsed
      counts up in the menu bar.
- [ ] Manual stop works at any point; file lands correctly named in the
      course folder.
- [ ] Auto-stop fires at the configured cap with notification.
- [ ] Mac does not sleep during a (shortened-for-test) recording; assertion
      released after.
- [ ] Level meter animates with real input.
- [ ] Quit-during-recording prompts; confirm leaves a valid file.

## Edge cases
- `autoStopMinutes` changed in config mid-recording → applies next session;
  don't retroactively change the running timer.
- Start fails (mic denied/disk) → state stays idle, error surfaces in menu.
