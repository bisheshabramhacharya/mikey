# Mikey — Product & Technical Spec

**Mikey** is a lightweight macOS menu-bar app that records college lectures
through the microphone and transcribes them on demand with on-device Whisper.
Personal tool for one user. Domain terms are defined in `/CONTEXT.md` — this
spec uses that vocabulary.

- **Platform:** macOS (Apple Silicon), native Swift app, menu-bar only agent
  (`LSUIElement`, no Dock icon).
- **Stack:** Swift + SwiftUI/AppKit, AVAudioEngine for capture, WhisperKit
  (SPM) for on-device transcription.
- **Hard requirements:** lightweight, free to run, fully local/private,
  survives the lid closing, never loses a recording.

---

## 1. Core loop

1. User clicks the menu-bar icon → menu shows the 3 configured Courses plus
   **Quick Record**.
2. Picking a Course starts recording immediately. Icon becomes an animated
   "recording" state with elapsed time.
3. Recording stops when the user chooses **Stop**, or automatically at
   **75:00**. A macOS notification confirms the stop.
4. The `.m4a` lands in `Archive/<Course>/YYYY-MM-DD_HH-mm.m4a`.
5. Later — whenever — the user opens the menu and hits **Transcribe** on a
   pending Session, or **Transcribe All Pending**. Whisper runs in the
   background and writes `<same-name>.md` next to the audio.

That's the whole product. Everything else is in service of that loop being
trustworthy and zero-friction.

## 2. Menu bar anatomy

### Idle state
- Icon: static Mikey glyph.
- Menu:
  - `▶ <Course 1>` / `▶ <Course 2>` / `▶ <Course 3>` — start a Session
  - `▶ Quick Record` — start a courseless Session → `Archive/Unsorted/`
  - Separator
  - `Pending` submenu or section listing each pending Session
    (`<Course> · <date>`) with a `Transcribe` action, plus
    `Transcribe All Pending` when >1 pending
  - `Open Archive Folder`
  - `Edit Courses (config.json)` — opens the config in the default editor
  - `Launch at Login` toggle
  - `Quit Mikey`

### Recording state
- Icon: animated (pulsing red dot) + elapsed `mm:ss` in the menu bar.
- Menu:
  - `■ Stop Recording — <Course> · mm:ss`
  - Live input-level meter (so a glance confirms the mic hears the room)
  - `Open Archive Folder`, `Quit` (Quit while recording warns; see §7)

### Transcribing state
- Menu shows progress per job (`CHEM 101 · 09-15 — transcribing… 40%`).
- Recording can still start/stop while a transcription runs in background.

## 3. Recording engine

- **Source:** system default input device (built-in or whatever macOS has
  selected). Mic permission requested on first record attempt.
- **Capture:** AVAudioEngine input tap → gain-boost stage → AAC `.m4a` written
  incrementally to its final Archive path (never to a temp buffer). Incremental
  writes mean a crash/force-quit at 60:00 still leaves 60 min of playable audio.
- **Gain:** a configurable boost applied in the capture pipeline so a professor
  across a lecture hall stays intelligible to Whisper. Default ~+12 dB with
  soft limiting to prevent clipping; tuned during dogfooding.
- **Auto-stop:** hard cap at 75:00. Timer starts at first captured sample.
  On auto-stop, save + notify `Recording auto-stopped (75:00)`.
- **Sleep prevention:** while recording, hold a `PreventUserIdleSystemSleep`
  assertion so the Mac cannot sleep mid-lecture. Released on stop.
- **Level meter:** RMS level from the tap drives the menu-bar meter.

## 4. Archive layout

```
~/Documents/Mikey/
├── config.json
├── CHEM-101/
│   ├── 2026-09-15_10-30.m4a
│   ├── 2026-09-15_10-30.md
│   └── 2026-09-17_10-30.m4a        ← pending (no .md yet)
├── MATH-240/
├── PHYS-150/
└── Unsorted/
    └── 2026-09-16_18-02.m4a        ← Quick Record
```

- Course folder names are slugified course names from config.
- Filename = local date + start time (`YYYY-MM-DD_HH-mm`). Collision (same
  course, same minute) appends `-2`.
- **Pending** is derived: an `.m4a` with no sibling `.md`. No database, no
  state files — the filesystem is the source of truth.
- `Open Archive Folder` reveals the Archive in Finder.

## 5. Configuration

`<Archive>/config.json`, created with defaults on first launch:

```json
{
  "courses": ["CHEM 101", "MATH 240", "PHYS 150"],
  "autoStopMinutes": 75,
  "gainDB": 12,
  "whisperModel": "large-v3-turbo",
  "archivePath": "~/Documents/Mikey"
}
```

- Reloaded each time the menu opens (no file-watcher needed).
- Invalid/missing config → menu shows `⚠ config error — click to fix` which
  opens the file; recording falls back to Quick Record only.
- `Launch at Login` uses `SMAppService` (stored as an app setting, not in
  config.json).

## 6. Transcription

- **Engine:** WhisperKit (Swift package, CoreML-accelerated Whisper on Apple
  Silicon). Default model `large-v3-turbo` (~1.5 GB, downloaded once on first
  transcription request, with progress shown in the menu).
- **Queue:** scan the Archive for pending Sessions. Jobs run strictly one at a
  time in a background task. Order: oldest first.
- **Triggers:** `Transcribe` on a pending Session; `Transcribe All Pending`.
  First-ever transcription prompts model download confirmation with size.
- **Interruptibility:** a job may be interrupted by sleep/quit at any point —
  the `.md` is only written on success (write to temp, atomic rename), so an
  interrupted job just stays pending. Re-triggering re-runs it cleanly.
- **Output format** (`<session>.md`):

```markdown
# CHEM 101 — 2026-09-15 10:30
Duration: 01:15:00 · Model: large-v3-turbo

**[00:00]** First transcript segment…
**[02:14]** Next segment…
```

- On completion: notification `Transcript ready — CHEM 101` (click → reveal
  file in Finder).
- Whisper is given the gain-boosted `.m4a` as-is (the boost lives in the file).

## 7. Edge cases & failure modes

| Scenario | Behavior |
|---|---|
| Lid closes mid-recording | Can't happen: sleep assertion held while recording. If somehow slept, recording file is still valid up to last flushed sample. |
| Lid closes mid-transcription | Job stays pending; resumes on next trigger. |
| App quit/crash mid-recording | `.m4a` already on disk, playable. On next launch, a "recovered" note marks the file; it stays pending for transcription. |
| Mic permission denied | Alert-style menu message + button to open System Settings → Privacy → Microphone. |
| No input device / device unplugged mid-recording | Recording continues on the new default device if possible; otherwise stop + notify + keep partial file. |
| Disk space low (<500 MB free at start) | Refuse to start with a clear menu alert. |
| User starts recording while one is running | Impossible by construction — menu swaps to Stop view. |
| Config missing/corrupt | Menu surfaces it; only Quick Record + Open/Fix config remain. |
| Whisper model download interrupted | Resumable download; retry on next transcription trigger. |
| Two sessions same course same minute | Filename `-2` suffix. |
| Semester change | Edit `config.json`; old folders/files are untouched. |

## 8. Non-functional

- **Lightweight:** agent app, <30 MB binary, near-zero idle CPU/RAM, no Dock
  icon, no Electron. Only significant resource use is the Whisper model on disk
  and a burst of compute per transcription.
- **Privacy:** audio never leaves the Mac. No accounts, no telemetry, no
  network except the one-time model download.
- **Reliability:** incremental file writes, atomic transcript writes, derived
  (not stored) pending state — nothing to get out of sync.
- **Storage:** ~60–90 MB per 75-min `.m4a`; a semester ≈ 2–3 GB per course.

## 9. Explicitly out of scope (v2 candidates)

- Doc/study-guide generation from transcripts (the Archive is designed for it).
- Remote transcription offload to a home machine.
- System audio capture (online lectures), speaker diarization, live captions.
- Schedule-based auto-start. Sessions **never** start on their own.
- Full transcript-browser GUI (Finder + editor is the browser for now).
- iCloud Drive archive.

## 10. Legal/practical note

Recording lectures may be governed by university policy or require professor
consent — worth checking syllabus/policy before first use. Mikey itself is
audio-only, local-only.
