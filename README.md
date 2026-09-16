# Mikey

A lightweight macOS menu-bar app that records college lectures through the mic
and transcribes them on demand with on-device Whisper. Personal tool.

Domain glossary: `CONTEXT.md`. Product spec: `docs/SPEC.md`.

## Requirements

- macOS 15+ on Apple Silicon — transcription is CoreML-accelerated.
- Microphone permission; macOS prompts the first time you record.
- ~1.5 GB once for the Whisper model (downloaded on the first transcription —
  see below). Everything else is fully offline: audio never leaves the Mac.
- To build: Command Line Tools (no Xcode needed — see the testing note below).

## Build, run, install

| Command | What it does |
|---|---|
| `swift run Mikey` | Build and run the menu-bar app — a debug binary with no `.app` bundle, so notifications are skipped, TCC may not prompt as a bundled app would, and Launch at Login has no bundle to register. Development only. |
| `Scripts/test.sh` | Build and **run** the test suite. Exits nonzero on failure. Passes extra args to Swift Testing (`--filter`, `--list-tests`, `--verbose`, …). |
| `Scripts/package-app.sh` | Build release, assemble `Mikey.app` (Info.plist: `LSUIElement`, `NSMicrophoneUsageDescription`), ad-hoc `codesign`. |

For daily use: `Scripts/package-app.sh`, move `Mikey.app` somewhere stable
(`/Applications` or `~/Applications`), and launch it once — a mic icon appears
in the menu bar (no Dock icon; it's an agent). Toggle **Launch at Login** in
the menu to keep it running across reboots: the toggle registers the bundle
via `SMAppService`, and the registration points at the bundle's current
location — so move the `.app` to its permanent home *first* (if you move it
afterwards, flip the toggle off and on again). The setting is an OS
registration, not a `config.json` key.

## The Archive

All audio and transcripts live under `~/Documents/Mikey` (the path
`config.json`'s `archivePath` records):

```
~/Documents/Mikey/
├── config.json
├── CHEM-101/
│   ├── 2026-09-15_10-30.m4a
│   ├── 2026-09-15_10-30.md       ← Transcript, written on demand
│   └── 2026-09-17_10-30.m4a      ← pending (no .md yet)
├── MATH-240/
├── PHYS-150/
└── Unsorted/                     ← Quick Record Sessions land here
```

- Filenames are `YYYY-MM-DD_HH-mm` of the Session start; a same-minute
  collision gets `-2`.
- **Pending** is derived, not stored: an `.m4a` with no sibling `.md`. The
  menu's Pending section is a live scan of these folders — there's no
  database.
- Sidecars you may glimpse mid-flight: `name.caf` is the live crash-proof
  capture (finalized to `.m4a` on stop) and `name.recording` marks an
  in-progress Session — a leftover pair means the last run died mid-capture,
  and the audio is recovered automatically on the next launch.
- Recordings are kept permanently. A 75-min `.m4a` is ~60–90 MB.
- **Open Archive Folder** in the menu reveals the Archive in Finder.

## config.json

Written with defaults on first launch, and re-read every time the menu opens
(**Edit Courses (config.json)** opens it in your editor) — edits apply with
no restart. The one exception: `gainDB` and `autoStopMinutes` are baked into
the capture pipeline at launch, so restart Mikey after changing those two.
All keys are required — a malformed file shows `⚠ Config error — click to
fix` in the menu, and only Quick Record plus the fix button stay live. The
file is never overwritten once it exists.

```json
{
  "courses": ["CHEM 101", "MATH 240", "PHYS 150"],
  "autoStopMinutes": 75,
  "gainDB": 12,
  "whisperModel": "large-v3-turbo",
  "archivePath": "~/Documents/Mikey"
}
```

| Key | Meaning |
|---|---|
| `courses` | The record actions in the menu, in order — your classes this semester. |
| `autoStopMinutes` | Hard cap on a Session: recording always auto-stops here (75 by spec). |
| `gainDB` | Mic boost in dB, soft-limited against clipping. Raise it if a distant speaker transcribes thin; lower it if the audio is hot. |
| `whisperModel` | WhisperKit variant — `large-v3-turbo`, `small`, `tiny`, or a full `openai_whisper-…` folder name (optionally a `_954MB`-style quantized suffix). |
| `archivePath` | Records where the Archive lives for anyone reading the folder — the config sits *inside* the Archive, so this key can't relocate it; move the folder itself. |

### Next semester

Edit `courses` via **Edit Courses (config.json)** — replace the entries with
the new classes. Course folders are slugified names (`"CHEM 101"` →
`CHEM-101/`); folders for Courses no longer in the config are left alone, so
last semester's recordings stay put and the new Courses get fresh folders.
Pending Sessions under an old folder still transcribe — they list under the
folder's own name.

## The Whisper model

Transcription runs on-device via WhisperKit (CoreML). The configured model —
`large-v3-turbo`, ~1.5 GB — downloads once, after the menu confirms the size,
into:

```
~/Library/Application Support/Mikey/WhisperModels/models/argmaxinc/whisperkit-coreml/<variant>/
```

An interrupted download resumes on the next transcription. Deleting that
folder frees the space but means a re-download. Nothing else in the app
touches the network.

## Verifying a build (dogfood checklist)

The automated suite (`Scripts/test.sh`) covers the logic seams; the items
below need a real Mac, a mic, and a lecture hall. Run them once after
packaging — roughly once a semester, or after any capture/transcription
change:

- [ ] `Scripts/package-app.sh` → move `Mikey.app` to `/Applications` →
  launch: mic icon in the menu bar, no Dock icon.
- [ ] Toggle **Launch at Login** on → it shows checked, and Mikey appears
  under System Settings → General → Login Items. Reboot → Mikey is back in
  the menu bar.
- [ ] First record → macOS asks for mic permission. While recording, the
  menu bar shows the pulsing red dot + elapsed `mm:ss`, and the menu's
  input-level meter moves with room sound.
- [ ] Record a real 75-minute lecture: auto-stop fires at 75:00 with a
  notification, and the `.m4a` plays start to finish.
- [ ] **Transcribe** the pending Session → model-download prompt (~1.5 GB,
  once) → progress in the menu → `.md` lands beside the `.m4a` → the
  "Transcript ready" notification reveals it in Finder.
- [ ] Read the transcript end-to-end — is a distant speaker intelligible?
  If it's too quiet or clipping, tune `gainDB` in `config.json` (then
  restart Mikey), re-transcribe, and carry the better value into
  `Config.standard.gainDB` / `GainStage.defaultGainDB`.
- [ ] Idle footprint: ~0% CPU and tens of MB RAM in Activity Monitor with
  the app idle; `nettop`/`lsof` shows no network after the one-time model
  download.
- [ ] Force-quit (`kill -9`) mid-recording → relaunch → the capture is
  recovered to a playable `.m4a` and listed as pending.
- [ ] Close the lid mid-recording — the sleep assertion should keep the Mac
  awake for the Session.
- [ ] Anything broken that this list didn't catch: file it as a follow-up
  issue.

## Layout

- `Sources/Mikey/` — library target with all app logic and the SwiftUI menu
  views (`AppState`, `SessionController`, `RecordingEngine`, `Archive`,
  `M4AWriter`, `MenuBarLabel`, `MenuContentView`, …).
- `Sources/MikeyApp/` — the executable target: just the `@main` SwiftUI `App`.
  Builds the `Mikey` binary.
- `Tests/MikeyTests/` — the test suite plus `Runner.swift` (see below).
- `Scripts/` — developer scripts.

## Testing on a CLT-only machine (no Xcode)

`swift test` does **not** run the suite here: XCTest is Xcode-only, so SwiftPM
produces an `.xctest` bundle (Mach-O `MH_BUNDLE`) with no host process to
execute it — it prints `Build complete!` having run zero tests.

Instead, `MikeyTests` is a plain executable target containing the test files
and `Runner.swift`, which calls `Testing.__swiftPMEntryPoint()` — the same
entry point SwiftPM's generated runner uses. Testing.framework ships in the
CLT at `/Library/Developer/CommandLineTools/Library/Developer/Frameworks`;
Package.swift wires up the search paths. `Scripts/test.sh` builds and runs it.
