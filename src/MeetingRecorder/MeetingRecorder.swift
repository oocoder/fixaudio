import AVFoundation
import Foundation

/// Owns the two independent captures (mic + BlackHole) and the ffmpeg encode
/// into a centered M4A + a per-source (L=mic/R=remote) M4A.
final class MeetingRecorder {
    private let mic = DeviceCapture(deviceName: "External Microphone")
    private let meeting = DeviceCapture(deviceName: "BlackHole 2ch")
    private var temporaryDirectory: URL?
    private var micURL: URL?
    private var meetingURL: URL?
    private(set) var destinationURL: URL?
    private(set) var isRecording = false

    var diagnosticSummary: String {
        "micFrames=\(mic.frameCount), micPeak=\(mic.peak), meetingFrames=\(meeting.frameCount), meetingPeak=\(meeting.peak)"
    }

    func start(destination: URL, completion: @escaping (Result<Void, Error>) -> Void) {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized:
            doStart(destination: destination, completion: completion)
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .audio) { [weak self] granted in
                DispatchQueue.main.async {
                    guard granted else {
                        completion(.failure(RecorderError.permissionDenied))
                        return
                    }
                    self?.doStart(destination: destination, completion: completion)
                }
            }
        default:
            completion(.failure(RecorderError.permissionDenied))
        }
    }

    private func doStart(destination: URL, completion: (Result<Void, Error>) -> Void) {
        do {
            let temp = FileManager.default.temporaryDirectory
                .appendingPathComponent("fixaudio-\(UUID().uuidString)", isDirectory: true)
            try FileManager.default.createDirectory(at: temp, withIntermediateDirectories: true)
            let newMicURL = temp.appendingPathComponent("microphone.caf")
            let newMeetingURL = temp.appendingPathComponent("meeting.caf")

            try meeting.start(writingTo: newMeetingURL)
            do {
                try mic.start(writingTo: newMicURL)
            } catch {
                meeting.stop()
                throw error
            }

            temporaryDirectory = temp
            micURL = newMicURL
            meetingURL = newMeetingURL
            destinationURL = destination
            isRecording = true
            completion(.success(()))
        } catch {
            completion(.failure(error))
        }
    }

    func stop(completion: @escaping (Result<URL, Error>) -> Void) {
        guard isRecording,
              let destinationURL,
              let micURL,
              let meetingURL else { return }
        mic.stop()
        meeting.stop()
        isRecording = false

        let destination = destinationURL
        export(microphone: micURL, meeting: meetingURL, destination: destination) { [weak self] result in
            if case .success = result, let temp = self?.temporaryDirectory {
                try? FileManager.default.removeItem(at: temp)
            }
            self?.temporaryDirectory = nil
            completion(result.map { destination })
        }
    }

    private func export(
        microphone micURL: URL,
        meeting meetingURL: URL,
        destination: URL,
        completion: @escaping (Result<Void, Error>) -> Void
    ) {
        let candidates = ["/opt/homebrew/bin/ffmpeg", "/usr/local/bin/ffmpeg"]
        guard let ffmpegPath = candidates.first(where: {
            FileManager.default.isExecutableFile(atPath: $0)
        }) else {
            completion(.failure(RecorderError.missingFFmpeg))
            return
        }

        // Centered mix for playback + a 2-channel (L=mic, R=remote) file for
        // per-source transcription. Both written in one ffmpeg pass.
        let stem = destination.deletingPathExtension().lastPathComponent
        let sourcesURL = destination.deletingLastPathComponent()
            .appendingPathComponent("\(stem)-sources.m4a")

        try? FileManager.default.removeItem(at: destination)
        try? FileManager.default.removeItem(at: sourcesURL)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: ffmpegPath)
        process.arguments = [
            "-hide_banner", "-loglevel", "error", "-y",
            "-i", micURL.path,
            "-i", meetingURL.path,
            "-filter_complex",
            "[0:a]aformat=sample_rates=48000:channel_layouts=mono[m0];" +
            "[1:a]aformat=sample_rates=48000:channel_layouts=mono[r0];" +
            "[m0]asplit=2[m1][m2];[r0]asplit=2[r1][r2];" +
            "[m1][r1]amix=inputs=2:duration=longest:normalize=0,aformat=channel_layouts=stereo,alimiter=limit=0.95[mix];" +
            "[m2][r2]amerge=inputs=2,aformat=channel_layouts=stereo,alimiter=limit=0.95[src]",
            "-map", "[mix]", "-c:a", "aac", "-b:a", "192k", destination.path,
            "-map", "[src]", "-c:a", "aac", "-b:a", "192k", sourcesURL.path
        ]
        let errorPipe = Pipe()
        process.standardError = errorPipe
        process.terminationHandler = { process in
            let data = errorPipe.fileHandleForReading.readDataToEndOfFile()
            let details = String(data: data, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            DispatchQueue.main.async {
                if process.terminationStatus == 0,
                   FileManager.default.fileExists(atPath: destination.path),
                   FileManager.default.fileExists(atPath: sourcesURL.path) {
                    completion(.success(()))
                } else {
                    completion(.failure(RecorderError.exportFailed(
                        details?.isEmpty == false ? details! : "ffmpeg exited with status \(process.terminationStatus)"
                    )))
                }
            }
        }
        do {
            try process.run()
        } catch {
            completion(.failure(error))
        }
    }
}