# T05 — Session store: archive scan, pending detection, open-in-Finder

**Depends on:** T02
**Blocks:** T07

## Context
No database — the filesystem is the model (spec §4). This ticket reads the
Archive into `Session` values the menu renders: which sessions exist, which
are pending, newest first.

## Scope
- `struct Session`: `course: String?` (nil ⇒ Unsorted), `date: Date`,
  `audioURL: URL`, `transcriptURL: URL?`, `isPending: Bool` (audio exists,
  no transcript), `hasRecordingMarker: Bool` (crashed mid-capture — T09).
- `SessionStore`:
  - `scan()` → walk Archive folders (course folders from config slugs +
    `Unsorted/`), map `*.m4a` → `Session`, check sibling `.md`.
  - Results sorted by filename date desc.
  - Called on menu open + after stop/transcription completes.
- `Open Archive Folder` menu item → `NSWorkspace.shared.open(archiveURL)`.
- `Session` display name: `<Course or "Unsorted"> · MMM d, h:mm a`
  (parse from filename, fall back to file creation date).

## Implementation notes
- Pure `FileManager` scanning — ignore `.recording` markers, `config.json`,
  and anything that isn't `.m4a`/`.md`.
- A `.md` with no `.m4a` (user deleted audio) → ignore silently.
- Scan cost is trivial at this scale — no caching needed, but keep `scan()`
  synchronous-fast (hundreds of files max).

## Acceptance criteria
- [ ] Recorded sessions appear in the menu grouped/listed correctly.
- [ ] `.m4a` without `.md` shows as pending; writing the `.md` flips it on
      next scan.
- [ ] `Unsorted/` sessions appear labeled as Unsorted.
- [ ] Open Archive reveals the folder in Finder.
- [ ] Deleted files disappear from menu on next open (no stale state).

## Edge cases
- Hand-renamed files still list (parse failure → fallback date sort).
- Folder deleted under the app → scan just returns fewer sessions.
