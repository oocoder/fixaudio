# native-transcriber — next steps

## Done (1.0-alpha.3)
- FluidAudio backend (builds on macOS 15 / Swift 6; no macOS 26 needed).
- Per-source transcription: mic -> "You" (single speaker), remote side diarized
  (offline VBx, no speaker cap) -> "Remote_A/B/...", merged by timestamp.
- Channel-split mode: `native-transcriber <recorder-sources.m4a>` splits L=mic /
  R=remote and runs per-source. Also supports two-file input.
- Validated on test10 (1:1, with overlap): correct You/Remote labels, overlap
  shown on both sides. Diarizing the mixed M4A (legacy approach) failed for
  every diarizer — per-source fixes it.

## Next
1. Multi-party test: record a 4+ person meeting; the remote (R) side should
   diarize into Remote_A/B/C/... (VBx no-cap; or LS-EEND <=10 / Sortformer <=4
   if added). Validate speaker separation on the remote channel.
2. Add LS-EEND / Sortformer paths (overlap strength / streaming / identity
   stability) and an engine flag.
3. Wire transcription into the Meeting Recorder as a post-record action (run on
   the -sources.m4a), with first-run model-download UX.
4. Optional live preview (streaming ASR + diarization, delay-queue) as an
   ephemeral view; offline per-source remains authoritative.

## Out of scope
- @Generable / FoundationModels (macOS 26+).
- Bundling models.