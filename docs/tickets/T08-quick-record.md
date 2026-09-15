# T08 — Quick Record (courseless sessions)

**Depends on:** T04, T05

## Context
A Session doesn't require a Course (spec §2, CONTEXT.md `Quick Record`):
guest talks, review sessions, anything outside the 3 configured classes.
Files land in `Archive/Unsorted/`; the user files them by hand later.

## Scope
- `▶ Quick Record` menu item (idle state, after the 3 course items).
- `RecordingController.start(course: nil)` → path `Archive/Unsorted/YYYY-MM-DD_HH-mm.m4a`;
  everything else identical to a course recording (gain, cap, marker,
  notification says "Quick Record").
- Menu while a Quick Record runs shows `■ Stop Recording — Unsorted · mm:ss`.
- Session store already treats folder `Unsorted` ⇒ `course: nil` (T05) —
  verify labeling reads "Unsorted" everywhere (menu rows, notifications,
  transcript header via T06).

## Implementation notes
- This should be near-zero new logic — mostly plumbing `nil` course through
  existing paths and checking labels. If it isn't, the earlier abstractions
  are wrong; flag it.
- Display name: "Unsorted" in menus; transcript header `# Unsorted — <date>`.

## Acceptance criteria
- [ ] Quick Record produces a correctly-named `.m4a` in `Unsorted/`.
- [ ] It appears in the pending list labeled Unsorted and transcribes like
      any other session.
- [ ] All four record entry points (3 courses + Quick Record) behave
      identically aside from destination folder and labels.

## Edge cases
- `Unsorted/` folder deleted by user → recreated on next Quick Record.
- Quick Record while a course recording runs → impossible by construction
  (single-session state machine).
