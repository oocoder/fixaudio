import Foundation
import FluidAudio

/// native-transcriber (FluidAudio) — offline ASR + speaker diarization.
///
/// Pipeline: offline VBx diarization (pyannote-equivalent, no speaker cap) →
/// for each speaker segment, slice the audio and run Parakeet ASR (CoreML/ANE) →
/// emit `[start - end] SPEAKER_xx: text`, matching the Python audio2text format.
@main
struct NativeTranscriber {
    static func main() async {
        let args = CommandLine.arguments
        if args.contains("--version") || args.contains("-v") {
            print("native-transcriber \(appVersion) (FluidAudio)")
            return
        }
        guard args.count > 1 else {
            print("usage: native-transcriber <audio.m4a>")
            return
        }
        let path = args[1]
        guard FileManager.default.fileExists(atPath: path) else {
            print("error: file not found: \(path)")
            return
        }
        let url = URL(fileURLWithPath: path)

        do {
            // 1) Diarization — offline VBx (segmentation + WeSpeaker + VBx
            //    clustering). No speaker cap; the pyannote-equivalent, best offline.
            print("loading diarizer (offline VBx)...")
            let diar = OfflineDiarizerManager()
            try await diar.prepareModels()
            print("diarizing...")
            let dResult = try await diar.process(url)
            let segments = dResult.segments.map {
                SpeakerSeg(start: Double($0.startTimeSeconds),
                            end: Double($0.endTimeSeconds),
                            speaker: "\($0.speakerId)")
            }.sorted { $0.start < $1.start }

            // 2) Load 16 kHz mono Float32 samples for per-segment slicing.
            let samples = try AudioConverter().resampleAudioFile(url)
            let sr = 16000

            // 3) ASR (Parakeet CoreML/ANE)
            print("loading parakeet asr...")
            let asrModels = try await AsrModels.downloadAndLoad(version: .v3)
            let asr = AsrManager()
            try await asr.loadModels(asrModels)

            // 4) Transcribe each diarization segment's slice and label by speaker.
            print("transcribing \(segments.count) segments...")
            for seg in segments {
                let s = max(0, Int(seg.start * Double(sr)))
                let e = min(samples.count, Int(seg.end * Double(sr)))
                guard e - s > Int(0.2 * Double(sr)) else { continue }
                let slice = Array(samples[s..<e])
                var decoderState = TdtDecoderState.make()
                let res = try await asr.transcribe(slice, decoderState: &decoderState)
                let text = res.text.trimmingCharacters(in: .whitespacesAndNewlines)
                if !text.isEmpty {
                    print(String(format: "[%.2fs - %.2fs] SPEAKER_%@: %@",
                                 seg.start, seg.end, seg.speaker, text))
                }
            }
            print("done.")
        } catch {
            print("error: \(error)")
        }
    }

    struct SpeakerSeg { let start: Double; let end: Double; let speaker: String }
}