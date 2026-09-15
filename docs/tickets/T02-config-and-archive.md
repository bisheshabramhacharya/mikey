# T02 — Config file + Archive bootstrap

**Depends on:** T01
**Blocks:** T04 (needs courses), T05 (needs layout)

## Context
The Archive is the source of truth (spec §4–5): course folders, `Unsorted/`,
and `config.json`. The 3 course names come from the config — never hardcoded.
Config is reloaded every time the menu opens so `Edit Courses` needs no
file-watcher.

## Scope
- `MikeyConfig` (Codable): `courses: [String]`, `autoStopMinutes: Int = 75`,
  `gainDB: Double = 12`, `whisperModel: String = "large-v3-turbo"`,
  `archivePath: String = "~/Documents/Mikey"`.
- `ConfigStore`:
  - `archiveURL` resolved from `archivePath` (expand `~`).
  - `load()` → decode; on **missing file** write defaults then decode; on
    **decode error** surface `ConfigError` state to the menu.
  - `ensureArchiveLayout()` → create Archive root, one slugified folder per
    course, `Unsorted/`, and `config.json` if absent.
  - `slugify("CHEM 101") → "CHEM-101"` — uppercase alnum, spaces/others → `-`.
- Menu additions (idle state): the 3 course items (labels from config, still
  no-ops), `Open Archive Folder` (may just `NSWorkspace.shared.open` — actual
  ticket T05 wires it), `Edit Courses (config.json)` → open in default editor.
- Error state: corrupt config → menu shows `⚠ Config error — Edit config.json`,
  course items hidden; only Quick Record path + fix action remain.

## Implementation notes
- Reload config in `MenuBarExtra`'s menu on appear — simplest correct
  invalidation.
- Slug collisions after slugify (e.g. "CHEM 101" and "CHEM-101") → append
  `-2`, deterministic.
- Never delete or rename existing folders when courses change — old data
  stays put (spec §7).

## Acceptance criteria
- [ ] First launch creates `~/Documents/Mikey/` with `config.json`, 3 course
      folders, `Unsorted/`.
- [ ] Editing course names in `config.json` changes menu items on next open.
- [ ] Corrupting `config.json` produces the ⚠ menu state; fixing it recovers.
- [ ] `Edit Courses` opens the file in the default `.json` editor.

## Edge cases
- `courses` empty → all items hidden except Quick Record.
- `archivePath` pointing somewhere unwritable → surface as config error.
