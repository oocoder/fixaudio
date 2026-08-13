# native-transcriber (1.0-alpha.2)

A side experiment: native meeting transcription on Apple Silicon via
[FluidAudio](https://github.com/FluidInference/FluidAudio) — Parakeet ASR
(CoreML/ANE) + speaker diarization, all native Swift, **no Python**.

## Status

**Builds and runs on macOS 15 / Swift 6 (Apple Silicon).** Verified on an M2 Pro
/ macOS 15.4 / Swift 6.1: Parakeet loads on CPU+ANE, diarization runs, a
speaker-attributed transcript is produced. No macOS 26 / Swift 6.2 required
(unlike `mlx-audio-swift` and `soniqo/speech-swift`, which need Swift 6.2).

## What it does

`native-transcriber <audio>`:
1. Diarizes the file with FluidAudio's **offline VBx** pipeline
   (segmentation + WeSpeaker + VBx clustering — the pyannote-equivalent, no
   speaker cap).
2. Slices the audio by each diarization segment and runs **Parakeet v3** ASR
   (CoreML/ANE) on each slice.
3. Emits `[start - end] SPEAKER_xx: text` — the same format as the Python
   `audio2text` pipeline, for direct comparison.

## Build & run

```sh
cd experiments/native-transcriber
swift build
./.build/debug/native-transcriber /path/to/meeting.m4a
```

First run downloads models (Parakeet CoreML ~1 GB + diarization ~100 MB) to
`~/Library/Application Support/FluidAudio/Models/`; later runs are fast.

## Comparison vs the Python pipeline (test6, the mixed M4A)

| | ASR text | Diarization (on the mix) |
|---|---|---|
| Python (parakeet-mlx + pyannote) | correct | found 2 speakers, **mislabeled** |
| FluidAudio (Parakeet + VBx) | correct (parity) | found **1 speaker** (merged) |

Both diarizers fail on the **mixed-down** M4A because the recorder's `ffmpeg
amix` sums your mic + the remote into both channels — you and the remote are in
both channels and you speak over each other, so no diarizer can cleanly separate
them. This is the third confirmation that **diarizing the mix is the wrong
approach**.

## The fix (next): per-source transcription

The recorder captures the two sides **separately** before mixing
(`microphone.caf` = You, `meeting.caf` = the remote/BlackHole). The correct
design keeps those per-source files and transcribes each:

```
External Microphone  →  Parakeet        →  You: …                 (exact, 1 speaker)
Meeting Output        →  VBx/LS-EEND     →  Remote A / B / C / …   (diarize the N-1 others)
```

Diarizing the **meeting-output source** (which doesn't contain You) is far
easier and can't mislabel You — which is exactly what broke on the mix. This
needs the recorder to retain per-source files; test6's sources were already
deleted after the mix, so a **fresh recording** is needed to validate it.

## Out of scope for 1.0-alpha
- @Generable / FoundationModels structured extraction (needs macOS 26+).
- Bundling models (they auto-download from HuggingFace).
- Live streaming (post-process is the primary path; live is an optional later
  preview).