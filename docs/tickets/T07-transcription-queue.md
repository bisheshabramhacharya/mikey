# T07 — Transcription queue + menu UX

**Depends on:** T06
**Blocks:** T09

## Context
The user triggers transcription whenever it suits them — the lid's closed
right after class anyway (spec §6). This ticket wires the pending list,
per-session + all-pending actions, progress, and completion notifications.

## Scope
- `TranscriptionQueue` (serial, oldest-first):
  - `enqueue(session)`, `enqueueAllPending()`, `state` published:
    idle / downloadingModel(progress) / transcribing(session, progress).
  - One job at a time. Recording is unaffected while it runs.
- Menu (idle state) pending section:
  - Per pending Session: `<Course> · <date>` → `Transcribe` action.
  - `Transcribe All Pending (N)` when N > 1.
  - Active job row: `Transcribing <name>… 40%` with determinate progress.
  - First-ever trigger → `NSAlert`: "Mikey needs to download the Whisper
    model (~1.5 GB) once. Continue?" — don't download silently.
- Completion → notification "Transcript ready — <Course>"; activating the
  notification reveals the `.md` in Finder.
- Failure → notification "Transcription failed — <Course>" + session stays
  pending; menu shows a retry affordance.

## Implementation notes
- `UNUserNotificationCenterDelegate` on the app handles the reveal-file
  action (notification `userInfo` carries the `.md` path).
- Queue state is ephemeral — derived pending state (T05 scan) is what
  survives relaunch; no job persistence needed. A relaunch just shows the
  same pending list.
- Progress source: WhisperKit decode progress if exposed, else indeterminate
  spinner + elapsed time — verify what the API gives before building UI for
  it.

## Acceptance criteria
- [ ] `Transcribe` on a pending session produces its `.md` and a
      notification; clicking the notification reveals the file.
- [ ] `Transcribe All Pending` works through the backlog serially, oldest
      first, and the menu reflects each job in turn.
- [ ] Quitting mid-job → on relaunch the session is still pending, re-runs
      cleanly, no corrupt `.md`.
- [ ] Model-download consent prompt appears exactly once (first trigger).
- [ ] Recording can start/stop normally while a transcription runs.

## Edge cases
- All-pending where one job fails → continue with the rest; report failures
  at the end.
- Transcribe triggered while queue busy → enqueue, don't parallelize.
- New recording finishing while queue runs → joins pending list, not auto-added
  to the running batch.
