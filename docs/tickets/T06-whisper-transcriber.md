# T06 — WhisperKit transcription engine + Markdown writer

**Depends on:** T05
**Blocks:** T07

## Context
On-demand, on-device, free transcription (spec §6). WhisperKit is a Swift
package wrapping CoreML-optimized Whisper — native fit for a Swift app.
This ticket is the engine only: file in → timestamped `.md` out. Queue/UX is
T07.

## Scope
- Add WhisperKit via SPM.
- `Transcriber` service:
  - `prepareModel(name:)` → download/verify model (`large-v3-turbo` default
    from config) into Application Support / WhisperKit cache; exposes
    `progress: Double` and `isReady`.
  - `transcribe(session:)` → async; returns/throws; renders Markdown.
  - Renders `**[mm:ss]** segment text` blocks (WhisperKit segments carry
    timestamps), header per spec §6: `# <Course> — <date time>`,
    `Duration: h:mm:ss · Model: <name>`.
  - **Atomic write:** render → write `<name>.md.tmp` → rename to `.md`.
    Interrupt mid-run ⇒ no `.md`, session stays pending.
  - Duration read via `AVAsset(audioURL).duration`.
- Course label for Unsorted sessions: `# Unsorted — <date>`.

## Implementation notes
- WhisperKit expects 16 kHz mono internally and handles resampling — feed it
  the `.m4a` path/samples directly per its API.
- Long-audio note: 75-min files run fine in one pass; if memory pressure
  appears on the dev machine, fall back to WhisperKit's chunked decode —
  decide during testing, don't pre-build chunking.
- Keep `Transcriber` protocol-shaped (`func transcribe(_ session:)`) so a
  remote engine could slot in later (spec §9 offload idea) — one protocol,
  one conformance, no abstraction farm.

## Acceptance criteria
- [ ] First run downloads the model with visible progress; cached after.
- [ ] A real 75-min `.m4a` produces a `.md` with header + timestamped
      segments; spot-check accuracy on quiet/distant speech.
- [ ] `kill -9` mid-transcription leaves no `.md` (only a `.tmp` at worst);
      re-run succeeds.
- [ ] Transcript sits next to its `.m4a` with matching basename.

## Edge cases
- Corrupt/truncated `.m4a` (crashed recording) → transcribe what decodes or
  typed error; never crash.
- Empty/inaudible audio → `.md` still written (header + whatever came out) —
  an empty transcript is a valid result.
- Model name in config doesn't exist → clear error, don't crash.
