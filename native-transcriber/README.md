# native-transcriber CLI (1.0-alpha.3)

Native meeting transcription on Apple Silicon via
[FluidAudio](https://github.com/FluidInference/FluidAudio) — Parakeet ASR
(CoreML/ANE) + speaker diarization, all native Swift, **no Python**.

## Production CLI

**Builds and runs on macOS 15 / Swift 6.** Validated end-to-end on M2 Pro /
macOS 15.4 with a real 1:1 recording: correct `You` / `Remote` labels, including
overlapping speech. No macOS 26 / Swift 6.2 required.

## Modes

```sh
# Per-source from a recorder v0.5 -sources.m4a (L=mic, R=remote):
#   splits L/R -> mic="You", remote=diarized "Remote", merged by timestamp.
native-transcriber recording-sources.m4a

# Per-source from two already-separated files:
native-transcriber mic.caf remote.caf
```

Pipeline: offline VBx diarization (pyannote-equivalent, no speaker cap) on the
remote side → Parakeet v3 ASR per segment → `[start - end] SPEAKER: text`. The
mic side is single-speaker → labeled "You" directly.

## Build & run

```sh
cd native-transcriber
swift build
./.build/debug/native-transcriber /path/to/recording-sources.m4a
```

First run downloads models (Parakeet CoreML ~1 GB + diarization ~100 MB) to
`~/Library/Application Support/FluidAudio/Models/`; later runs are fast.

## Validated result (test10, 1:1 with overlap)

```
[0.00s - 6.16s]   You:      Testing, one, two, three, testing...
[11.00s - 17.88s] Remote_B: Your call has been forwarded to voicemail...
[17.95s - 20.51s] You:      Testing, one, two, three, testing.
[18.00s - 20.00s] Remote_B: When you have finished recording you may hang up.
```

You and Remote are correctly separated; the overlap at ~18–20.5s shows both.
Compare to diarizing the mixed M4A (the legacy approach), where every diarizer
merged/mislabeled speakers — the per-source design fixes that.

## Recorder pairing (fixaudio Meeting Recorder v0.5)

The recorder writes two files: `<stem>.m4a` (centered stereo, for listening) and
`<stem>-sources.m4a` (L = mic, R = remote, for this transcriber). Feed the
`-sources` file to `native-transcriber`.

## Out of scope for 1.0-alpha
- @Generable / FoundationModels structured extraction (needs macOS 26+).
- Bundling models (auto-download from HuggingFace).
- Live streaming (post-process is the primary path).
