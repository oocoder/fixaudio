# native-transcriber — next steps

## Done (1.0-alpha.2)
- Pivoted from `mlx-audio-swift` (needs Swift 6.2 / macOS 26) to **FluidAudio**
  (builds on macOS 15 / Swift 6). Verified end-to-end on M2 Pro / macOS 15.4.
- `transcribe <audio>`: offline VBx diarization + per-segment Parakeet ASR →
  speaker-attributed transcript in the Python audio2text format.
- Compared against the Python pipeline on test6: ASR parity confirmed;
  diarization on the mix fails for BOTH (3rd confirmation the mix is the problem).

## Next
1. Update the Meeting Recorder to **retain per-source files**
   (`microphone.*` = You, `meeting.*` = BlackHole/remotes) instead of deleting
   them after the mix. The mixed M4A can still be produced for playback.
2. Record a **fresh meeting** (sources are gone for test6). Run the per-source
   pipeline: Parakeet on the mic source → "You"; VBx/LS-EEND/Sortformer on the
   meeting-output source → "Remote A/B/C"; merge by timestamp.
3. Validate diarization on the **meeting-output source only** (no You in it) —
   this is where the diarizer should finally separate speakers correctly.
4. Optional: add LS-EEND/Sortformer paths to the experiment (overlap/stability)
   and a live preview mode (streaming ASR + diarization, delay-queue).

## Out of scope
- @Generable / FoundationModels (macOS 26+).
- Bundling models.