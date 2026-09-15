# T03 — Audio capture engine

**Depends on:** T01
**Blocks:** T04

## Context
The heart of Mikey (spec §3): mic → gain boost → incrementally-written `.m4a`
at its final Archive path. Incremental write is non-negotiable — a crash at
minute 60 must leave 60 minutes of playable audio.

## Scope
- `AudioRecorder` class:
  - `start(to url: URL, gainDB: Double) throws` — installs tap on
    `AVAudioEngine.sharedInputNode`, applies gain with soft limiting, writes
    AAC `.m4a` via `AVAudioFile`.
  - `stop()` — removes tap, closes file cleanly.
  - Publishes `level: Float` (post-gain RMS, smoothed ~10 Hz) for the meter.
  - Publishes `elapsed: TimeInterval` from first captured buffer.
- Gain: PCM multiply by `pow(10, gainDB/20)` with soft clip
  (`tanh`-style limiter or hard clamp at ±0.95 — simple, no dependencies).
- Permission: `AVCaptureDevice.requestAccess(for: .audio)`; denied → typed
  error the menu surfaces (T09 deep-links System Settings).
- `.recording` marker file: created next to the `.m4a` on start, deleted on
  clean `stop()` — lets T09 detect crashed recordings.

## Implementation notes
- Record at input native format → convert to 44.1 kHz mono AAC ~96 kbps
  (≈50 MB/75 min, plenty intelligible for Whisper).
- Write from the tap callback directly; `AVAudioFile.write(from:)` is
  incremental — verify with the force-quit test below.
- Handle `AVAudioEngineConfigurationChange` notification: re-install tap on
  the new default input rather than dying (spec §7).
- No recording session on simulator — needs real device testing.

## Acceptance criteria
- [ ] 5-min test recording produces playable `.m4a` with audible boost vs raw.
- [ ] Force-quit (`kill -9`) at ~60 s → file still opens and plays ~60 s of
      audio; `.recording` marker left behind.
- [ ] Clean stop deletes marker; file plays to full length.
- [ ] `level` tracks speech visibly (meter input works in a test harness).
- [ ] Permission denial produces a typed error, not a crash.

## Edge cases
- Input device unplugged mid-tap → config-change handler or typed error.
- Zero-length stop (start→stop instantly) → still writes a valid (tiny) file.
- Disk full mid-write → `stop()` + error surfaces; partial file stays.
