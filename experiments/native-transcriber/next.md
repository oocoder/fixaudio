# native-transcriber — next steps

## Done
- Swift Package scaffold (1.0-alpha.1) using mlx-audio-swift:
  Parakeet ASR + Sortformer diarization, file + live modes.
- Documented the Swift 6.2 / Xcode 26 toolchain gate (won't build on Swift 6.1).

## Blocked (toolchain)
- Compile-verify on this machine: **blocked** — needs Xcode 26 / Swift 6.2
  (macOS 26). On macOS 15.4 / Swift 6.1, `swift package resolve` fails on
  `mlx-audio-swift` (requires tools-version 6.2).

## Next (once on Xcode 26 / Swift 6.2)
1. `swift build -c release` — fix any Swift 6 Sendable adjustments and the
   exact audio-array type for `generate(audio:)`.
2. `transcribe <meeting.m4a>`; diff transcript vs `audio2text.py` output →
   validate ASR parity + Sortformer-vs-pyannote diarization quality.
3. Confirm the Parakeet segment-timestamp API; implement the speaker-label
   merge (port `merge_transcription_with_speakers` from `audio2text.py`).
4. `live`: measure chunk latency and capture-tap responsiveness under
   slower-than-realtime inference (the delay-queue hypothesis).
5. If validation passes, wire a transcription module into the Meeting Recorder
   (replace the removed script-proxy path) with first-run model-download UX.

## Out of scope for 1.0-alpha
- @Generable / FoundationModels structured extraction (needs macOS 26+, and
  not required for transcription).
- Bundling models into the binary (they auto-download from HuggingFace).