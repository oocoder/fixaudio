import Foundation
import FluidAudio

/// In-app per-source transcription (FluidAudio) for a recorder `-sources.m4a`
/// (L = mic/You, R = remote). Mirrors the native-transcriber experiment.
///
/// `progress(phase, fraction)` and `completion` are called from a background
/// task; callers that touch AppKit should dispatch to main inside their closures.
final class Transcriber {
    struct Seg { let start: Double; let end: Double; let speaker: String; let text: String }
    enum Side { case you, remote }

    static func run(sourcesURL: URL,
                    progress: @escaping (String, Double) -> Void,
                    completion: @escaping (Result<[Seg], Error>) -> Void) {
        Task {
            do {
                progress("Loading models…", 0)
                let asrModels = try await AsrModels.downloadAndLoad(version: .v3)
                let asr = AsrManager()
                try await asr.loadModels(asrModels)
                let diar = OfflineDiarizerManager()
                try await diar.prepareModels()

                progress("Splitting channels (L=You, R=remote)…", 0)
                let (micURL, remoteURL) = try splitChannels(of: sourcesURL)
                defer { try? FileManager.default.removeItem(at: micURL.deletingLastPathComponent()) }

                var segs: [Seg] = []
                segs += try await transcribeSide(url: micURL, diar: diar, asr: asr,
                                                 side: .you, progress: progress)
                segs += try await transcribeSide(url: remoteURL, diar: diar, asr: asr,
                                                 side: .remote, progress: progress)
                segs.sort { $0.start < $1.start }
                completion(.success(segs))
            } catch {
                completion(.failure(error))
            }
        }
    }

    /// Diarize the side, ASR each segment's slice, label per `side`.
    private static func transcribeSide(url: URL, diar: OfflineDiarizerManager,
                                       asr: AsrManager, side: Side,
                                       progress: @escaping (String, Double) -> Void) async throws -> [Seg] {
        let dResult = try await diar.process(url)
        let samples = try AudioConverter().resampleAudioFile(url)
        let sr = 16000
        let ordered = dResult.segments.sorted { $0.startTimeSeconds < $1.startTimeSeconds }
        let total = max(1, ordered.count)
        var out: [Seg] = []
        let prefix = side == .you ? "You" : "Remote"
        for (i, seg) in ordered.enumerated() {
            let s = max(0, Int(Double(seg.startTimeSeconds) * Double(sr)))
            let e = min(samples.count, Int(Double(seg.endTimeSeconds) * Double(sr)))
            guard e - s > Int(0.2 * Double(sr)) else { continue }
            var state = TdtDecoderState.make()
            let res = try await asr.transcribe(Array(samples[s..<e]), decoderState: &state)
            let text = res.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { continue }
            let speaker = side == .you ? "You" : "Remote_\(letter(forId: "\(seg.speakerId)"))"
            out.append(Seg(start: Double(seg.startTimeSeconds),
                            end: Double(seg.endTimeSeconds),
                            speaker: speaker, text: text))
            progress("\(prefix): segment \(i + 1)/\(total)", Double(i + 1) / Double(total))
        }
        return out
    }

    /// Split a 2-channel `-sources.m4a` (L=mic, R=remote) into two temp 16 kHz
    /// mono WAVs. Caller removes the temp directory.
    private static func splitChannels(of m4a: URL) throws -> (mic: URL, remote: URL) {
        let ffmpeg = ["/opt/homebrew/bin/ffmpeg", "/usr/local/bin/ffmpeg"].first {
            FileManager.default.isExecutableFile(atPath: $0)
        }
        guard let ffmpeg else {
            throw NSError(domain: "MeetingRecorder", code: 1,
                userInfo: [NSLocalizedDescriptionKey: "ffmpeg not found"])
        }
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("mr-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        let micURL = base.appendingPathComponent("mic.wav")
        let remoteURL = base.appendingPathComponent("remote.wav")
        let p = Process()
        p.executableURL = URL(fileURLWithPath: ffmpeg)
        p.arguments = ["-hide_banner", "-loglevel", "error", "-y",
                       "-i", m4a.path,
                       "-filter_complex", "[0:a]pan=mono|c0=c0[m];[0:a]pan=mono|c0=c1[r]",
                       "-map", "[m]", "-ar", "16000", "-ac", "1", micURL.path,
                       "-map", "[r]", "-ar", "16000", "-ac", "1", remoteURL.path]
        let err = Pipe(); p.standardError = err
        try p.run(); p.waitUntilExit()
        guard p.terminationStatus == 0,
              FileManager.default.fileExists(atPath: micURL.path),
              FileManager.default.fileExists(atPath: remoteURL.path) else {
            let msg = String(data: err.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
            throw NSError(domain: "MeetingRecorder", code: 2,
                userInfo: [NSLocalizedDescriptionKey: "ffmpeg channel split failed: \(msg)"])
        }
        return (micURL, remoteURL)
    }

    private static func letter(forId id: String) -> String {
        let n = Int(id.filter(\.isNumber)) ?? 0
        return String(UnicodeScalar(UInt8(65 + min(n, 25))))
    }
}