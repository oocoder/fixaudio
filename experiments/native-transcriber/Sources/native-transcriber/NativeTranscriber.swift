import Foundation
import FluidAudio

/// native-transcriber (FluidAudio) — native ASR + speaker diarization.
///
/// Two modes:
/// - `native-transcriber <mix.m4a>`               diarize + ASR one file (mix mode)
/// - `native-transcriber <mic.caf> <remote.caf>`  per-source mode (the production
///   design): mic is single-speaker "You"; the remote/BlackHole side is diarized
///   into Remote_A / Remote_B / … ; both are merged by timestamp.
@main
struct NativeTranscriber {
    static func main() async {
        let args = CommandLine.arguments
        if args.contains("--version") || args.contains("-v") {
            print("native-transcriber \(appVersion) (FluidAudio)")
            return
        }
        let paths = args.dropFirst().filter { !$0.hasPrefix("--") }
        guard !paths.isEmpty else {
            print("usage:")
            print("  native-transcriber <mix.m4a>")
            print("  native-transcriber <mic.caf> <remote.caf>")
            return
        }
        for p in paths {
            guard FileManager.default.fileExists(atPath: p) else {
                print("error: file not found: \(p)")
                return
            }
        }
        // Run the (non-Sendable) FluidAudio work off the main actor.
        await run(paths: Array(paths))
    }

    /// Nonisolated: owns the FluidAudio managers so they never cross an actor
    /// boundary (they aren't Sendable).
    static func run(paths: [String]) async {
        do {
            print("loading parakeet asr...")
            let asrModels = try await AsrModels.downloadAndLoad(version: .v3)
            let asr = AsrManager()
            try await asr.loadModels(asrModels)
            print("loading diarizer (offline VBx)...")
            let diar = OfflineDiarizerManager()
            try await diar.prepareModels()

            var segments: [Seg]
            if paths.count == 1 {
                // Single 2-channel M4A (recorder v0.4: L = mic/You, R = remote).
                // Split channels into temp 16 kHz mono files, then per-source.
                let m4a = URL(fileURLWithPath: paths[0])
                print("splitting channels (L=You, R=remote)...")
                let (micURL, remoteURL) = try splitChannels(of: m4a)
                defer { try? FileManager.default.removeItem(at: micURL.deletingLastPathComponent()) }
                var all: [Seg] = []
                print("per-source: mic (L) -> You")
                all += try await transcribe(url: micURL, diar: diar, asr: asr, mode: .you)
                print("per-source: remote (R) -> diarized")
                all += try await transcribe(url: remoteURL, diar: diar, asr: asr, mode: .remote)
                all.sort { $0.start < $1.start }
                segments = all
            } else {
                // Per-source: mic = You (single speaker, ignore diarization IDs);
                // remote = diarized into Remote_A / Remote_B / …
                var all: [Seg] = []
                print("per-source: mic -> You")
                all += try await transcribe(
                    url: URL(fileURLWithPath: paths[0]), diar: diar, asr: asr, mode: .you)
                print("per-source: remote -> diarized")
                all += try await transcribe(
                    url: URL(fileURLWithPath: paths[1]), diar: diar, asr: asr, mode: .remote)
                all.sort { $0.start < $1.start }
                segments = all
            }

            print("--- transcript ---")
            for seg in segments {
                print(String(format: "[%.2fs - %.2fs] %@: %@",
                             seg.start, seg.end, seg.speaker, seg.text))
            }
            print("done. (\(segments.count) segments)")
        } catch {
            print("error: \(error)")
        }
    }

    /// Split a 2-channel M4A (L = mic, R = remote) into two temp 16 kHz mono
    /// WAVs in a temp directory. Caller removes the directory.
    static func splitChannels(of m4a: URL) throws -> (mic: URL, remote: URL) {
        let ffmpeg = ["/opt/homebrew/bin/ffmpeg", "/usr/local/bin/ffmpeg"].first {
            FileManager.default.isExecutableFile(atPath: $0)
        }
        guard let ffmpeg else { throw NSError(domain: "native-transcriber", code: 1,
            userInfo: [NSLocalizedDescriptionKey: "ffmpeg not found"]) }
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("nt-\(UUID().uuidString)", isDirectory: true)
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
            throw NSError(domain: "native-transcriber", code: 2,
                userInfo: [NSLocalizedDescriptionKey: "ffmpeg channel split failed: \(msg)"])
        }
        return (micURL, remoteURL)
    }

    enum LabelMode { case mix, you, remote }

    struct Seg: Sendable { let start: Double; let end: Double; let speaker: String; let text: String }

    /// Diarize the file (offline VBx), ASR each segment's slice, label per `mode`.
    /// Diarization segment timestamps carry through.
    static func transcribe(url: URL, diar: OfflineDiarizerManager,
                           asr: AsrManager, mode: LabelMode) async throws -> [Seg] {
        let dResult = try await diar.process(url)
        let samples = try AudioConverter().resampleAudioFile(url)
        let sr = 16000
        var out: [Seg] = []
        for seg in dResult.segments.sorted(by: { $0.startTimeSeconds < $1.startTimeSeconds }) {
            let s = max(0, Int(Double(seg.startTimeSeconds) * Double(sr)))
            let e = min(samples.count, Int(Double(seg.endTimeSeconds) * Double(sr)))
            guard e - s > Int(0.2 * Double(sr)) else { continue }
            var state = TdtDecoderState.make()
            let res = try await asr.transcribe(Array(samples[s..<e]), decoderState: &state)
            let text = res.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { continue }
            let speaker: String
            switch mode {
            case .mix:    speaker = "SPEAKER_\(seg.speakerId)"
            case .you:    speaker = "You"
            case .remote: speaker = "Remote_\(letter(forId: "\(seg.speakerId)"))"
            }
            out.append(Seg(start: Double(seg.startTimeSeconds),
                            end: Double(seg.endTimeSeconds),
                            speaker: speaker, text: text))
        }
        return out
    }

    /// Map a diarization speaker id ("0", "1", "S1", …) to a letter (A, B, …).
    static func letter(forId id: String) -> String {
        let digits = id.filter(\.isNumber)
        let n = Int(digits) ?? 0
        let scalar = UnicodeScalar(UInt8(65 + min(n, 25))) // 'A' + n
        return String(scalar)
    }
}