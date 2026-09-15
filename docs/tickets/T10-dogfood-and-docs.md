# T10 — Dogfood checklist + README

**Depends on:** all of the above

## Context
Mikey exists to be used in a real lecture hall. This ticket is the shakedown:
one full real-world pass plus the docs to rebuild/run it later.

## Scope
- `README.md` at repo root: what Mikey is, build/run steps (Xcode), how
  config works, archive layout, where the Whisper model lives, how to
  change courses next semester.
- **Dogfood run** (the real acceptance test):
  1. Full 75-min in-person lecture: start from menu bar, verify animated
     icon + timer at a glance, auto-stop + notification.
  2. Close lid immediately after class → open later → session pending.
  3. Transcribe → `.md` readable, timestamps sane, professor intelligible
     from seat distance.
  4. Tune `gainDB` in config if transcript shows the audio was too
     quiet/clipping; note the chosen value.
  5. Quick Record a short session → lands in Unsorted.
  6. Reboot → launch-at-login works, menu state correct.
- Fix-forward: anything broken above becomes a follow-up ticket, not a
  shrug.
- Verify spec §8 claims on-device: idle RAM/CPU roughly zero, binary size
  sane, no network besides the one model download.

## Acceptance criteria
- [ ] One real lecture recorded + transcribed end-to-end.
- [ ] README lets a future-you rebuild and reconfigure without this repo's
      git history.
- [ ] Gain default updated in `config.json` template if tuning changed it.
- [ ] Known issues either fixed or written down as new tickets.

## Edge cases
- If Whisper accuracy on real hall audio is poor → evaluate bigger model or
  seat position before shipping; capture findings in the ticket.
