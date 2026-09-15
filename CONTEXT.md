# Mikey — Domain Glossary

A lightweight macOS menu-bar app that records college lectures and transcribes
them on demand. Personal tool for one user (a student), not a product.

## Terms

### Mikey
The app itself. Lives in the macOS menu bar. Records lecture audio via the
microphone and produces transcripts on demand.

### Course
One of the student's in-person classes (e.g. "CHEM 101"). Exactly three Courses
are configured via a `config.json` inside the Archive. A Course owns a folder
in the Archive and is the thing the user picks in the menu bar before recording.

### Session
A single recorded class meeting. A Session normally belongs to one Course, but
may be courseless (see Quick Record). A Session has one Recording and, once the
user asks for it, one Transcript.

### Quick Record
A Session started without picking a Course. Its files land in `Archive/Unsorted/`
and the user files them later. Covers guest talks, review sessions, anything
that isn't one of the three Courses.

### Recording
The audio artifact of a Session — one `.m4a` file on disk, captured from the
microphone with gain boosted so a distant speaker stays intelligible. Written
incrementally during capture so a crash or force-quit never loses the lecture.

### Transcript
The text artifact produced from a Recording — a timestamped Markdown file
(`<session>.md` next to its `.m4a`). Generated **on demand**, never
automatically — a Recording may exist for days before its Transcript does, or
never get one. Transcription runs on-device via Whisper: free, private, and
unlimited in length. Cheap/free transcription is a hard requirement.

### Pending
A Recording with no Transcript yet. The set of pending Sessions is the
Transcription Queue.

### Transcription Queue
The implicit backlog of pending Sessions, derived by scanning the Archive for
`.m4a` files without a matching `.md`. Jobs are triggered from the menu
("Transcribe" on one Session, or "Transcribe All Pending") and run in the
background, one at a time. If the Mac sleeps mid-job (the lid closes when class
ends), the Session simply stays pending — transcription is idempotent and
resumes on the next trigger. No networking; remote offload is a deferred v2 idea.

### Archive
The folder-based "brain" of all Sessions at a local path
(`~/Documents/Mikey`), organized as
`<Archive>/<Course>/<Session files>` plus `Archive/Unsorted/` and
`Archive/config.json`. Browsed via Finder — there is no full GUI; the menu bar
offers "open folder" access to it.

## Invariants

- A Session never exceeds **75 minutes**. Recording auto-stops at 75:00;
  the user can always stop earlier by hand.
- Audio capture is **microphone only**. No system audio.
- Sessions **never auto-start**. The user always presses the button.
- Recordings are kept permanently in the Archive regardless of whether they
  are ever transcribed.
