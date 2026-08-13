# native-transcriber (1.0-alpha.1)

A side experiment: run meeting transcription **natively in Swift on Apple
Silicon** using [mlx-audio-swift](https://github.com/Blaizzy/mlx-audio-swift) —
Parakeet ASR (`mlx-community/parakeet-tdt-0.6b-v3`) + Sortformer speaker
diarization (`mlx-community/diar_streaming_sortformer_4spk-v2.1-fp16`). This
mirrors the Python `parakeet-mlx + pyannote` pipeline in `~/projects/audio2text`
but as a self-contained Swift tool, with no conda/python/script dependency.

> **Status:** alpha scaffold, intentionally experimental.

## ⚠️ Toolchain gate (read first)

`mlx-audio-swift` declares `swift-tools-version 6.2`. It will **not resolve** on
Swift 6.1 (Xcode 16.x / macOS 15). Confirmed:

```
error: package 'mlx-audio-swift' is using Swift tools version 6.2.0
       but the installed version is 6.1.0
```

**Build this with Xcode 26 / Swift 6.2 (macOS 26).** Until the machine is on
that toolchain, `swift build` will fail at dependency resolution. The code here
is written against the verified `mlx-audio-swift` API but is **not
compile-verified on Swift 6.1** — expect small adjustments (esp. Swift 6
Sendable rules and the exact audio-array / ASR segment-timestamp types) on the
first real build.

## Build & run (on Xcode 26 / Swift 6.2)

```sh
cd experiments/native-transcriber
swift build -c release
.build/release/native-transcriber --version
.build/release/native-transcriber transcribe /path/to/meeting.m4a
.build/release/native-transcriber live
```

First run downloads models from HuggingFace (multi-GB). Microphone access for
`live` may require granting Terminal/the binary microphone permission.

## Commands

- `transcribe <audio>` — Parakeet ASR + Sortformer diarization of a file.
  Prints the transcript and per-speaker segments. Speaker-label **merge** is a
  TODO pending the Parakeet segment-timestamp API (see `FileTranscriber.swift`).
- `live` — live mic transcription. The input tap only buffers samples; a
  background loop runs ASR on fixed-size chunks (the "delay queue"), keeping
  inference off the realtime thread (low UI pressure). If inference is slower
  than realtime, chunks queue rather than block.

## Validation plan (once it builds)

1. `transcribe` on a recording, diff the transcript against the Python
   `audio2text.py` output for the same file — validates ASR parity (same model
   weights) and diarization quality (Sortformer vs pyannote).
2. Confirm the Parakeet segment-timestamp API, then implement the speaker-label
   merge (`merge_transcription_with_speakers` from `audio2text.py`).
3. `live` against a real call: measure latency and whether the delay queue keeps
   the capture tap responsive under slower-than-realtime inference.

## Why native

The Meeting Recorder previously launched an external transcription script,
which is not portable (every user needs the conda env, models, and PATH set up).
A native Swift/MLX path makes transcription self-contained. This experiment
de-risks that before anything is wired into the recorder.