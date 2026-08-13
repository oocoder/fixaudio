import Foundation
import MLXAudioCore
import MLXAudioSTT
import MLXAudioVAD

/// File transcription: Parakeet ASR + Sortformer diarization.
///
/// The ASR model is the same `mlx-community/parakeet-tdt-0.6b-v3` weights used
/// by the Python parakeet-mlx pipeline, so ASR parity is expected. Diarization
/// is Sortformer (NVIDIA NeMo) instead of pyannote — quality for 2-party calls
/// must be validated by diffing this output against the Python pipeline.
enum FileTranscriber {
    static func transcribe(path: String) async {
        guard FileManager.default.fileExists(atPath: path) else {
            print("error: file not found: \(path)")
            return
        }
        let url = URL(fileURLWithPath: path)
        do {
            let (sampleRate, audio) = try loadAudioArray(from: url)
            print("loading parakeet-tdt-0.6b-v3…")
            let asr = try await ParakeetModel.fromPretrained("mlx-community/parakeet-tdt-0.6b-v3")
            print("transcribing (\(sampleRate) Hz)…")
            let output = asr.generate(audio: audio)
            print("---- transcript ----")
            print(output.text)

            print("---- diarization (Sortformer) ----")
            let diar = try await SortformerModel.fromPretrained(
                "mlx-community/diar_streaming_sortformer_4spk-v2.1-fp16")
            let d = try await diar.generate(audio: audio, threshold: 0.5)
            for seg in d.segments {
                print(String(format: "speaker %@  %.2f - %.2f",
                             "\(seg.speaker)", seg.start, seg.end))
            }

            // TODO(merge): assign each ASR segment a speaker by maximum
            // time-overlap with the diarization segments (mirrors
            // audio2text.py's merge_transcription_with_speakers). Requires the
            // Parakeet segment-timestamp API; the basic generate() returns
            // output.text only — see MLXAudioSTT/Models/Parakeet/ParakeetAlignment.
            print("note: speaker-label merge pending ASR segment-timestamp API")
        } catch {
            print("error: \(error.localizedDescription)")
        }
    }
}