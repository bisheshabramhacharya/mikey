# Mikey — Tickets

Build order (each ticket lists its dependencies):

| # | Ticket | Depends on |
|---|--------|-----------|
| T01 | Menu-bar app scaffold | — |
| T02 | Config file + Archive bootstrap | T01 |
| T03 | Audio capture engine | T01 |
| T04 | Session lifecycle (start/stop/75-min cap) | T02, T03 |
| T05 | Session store + pending detection | T02 |
| T06 | WhisperKit transcriber + Markdown writer | T05 |
| T07 | Transcription queue + menu UX | T06 |
| T08 | Quick Record (Unsorted) | T04, T05 |
| T09 | Resilience, permissions & polish | T04, T07 |
| T10 | Dogfood checklist + README | all |

Critical path: T01 → T02 → T03 → T04 → T05 → T06 → T07.
T08/T09 can run in parallel with T06–T07 once T04/T05 land.

Vocabulary: `/CONTEXT.md`. Requirements: `/docs/SPEC.md`.
