import AVFoundation
import Foundation

/// Owns the two independent captures (mic + BlackHole) and the ffmpeg encode
/// into a centered M4A + a per-source (L=mic/R=remote) M4A.
final class MeetingRecorder {
    var micDeviceName: String
    private var mic: DeviceCapture
    private var meeting: DeviceCapture
    private var temporaryDirectory: URL?
    private var micURL: URL?
    private var meetingURL: URL?
    private(set) var destinationURL: URL?
    private(set) var isRecording = false
    private var savedDefaultInput: AudioDeviceID?

    init(micDeviceName: String = "External Microphone") {
        self.micDeviceName = micDeviceName
        self.mic = DeviceCapture(deviceName: micDeviceName)
        self.meeting = DeviceCapture(deviceName: "BlackHole 2ch")
    }

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

            let micID = AudioDevices.inputID(named: micDeviceName)
            let isBt = micID.map { AudioDevices.isBluetooth($0) } ?? false

            if isBt {
                // Bluetooth: use AUHAL (bypasses AVAudioEngine installTap crash).
                // No need to set system default — AUHAL talks directly to the device.
                mic = DeviceCapture(deviceName: micDeviceName, useAUHAL: true)
            } else {
                // Non-Bluetooth: set the system default to the chosen mic BEFORE
                // starting any engine, then capture via AVAudioEngine.
                savedDefaultInput = AudioDevices.defaultInputDeviceID()
                if let micID = micID {
                    try AudioDevices.setDefaultInputDevice(micID)
                }
                mic = DeviceCapture(deviceName: micDeviceName, useSystemDefault: true)
            }

            meeting = DeviceCapture(deviceName: "BlackHole 2ch")
            try meeting.start(writingTo: newMeetingURL)
            do {
                try mic.start(writingTo: newMicURL)
            } catch {
                meeting.stop()
                restoreDefaultInput()
                throw error
            }

            temporaryDirectory = temp
            micURL = newMicURL
            meetingURL = newMeetingURL
            destinationURL = destination
            isRecording = true
            completion(.success(()))
        } catch {
            restoreDefaultInput()
            completion(.failure(error))
        }
    }

    private func restoreDefaultInput() {
        if let saved = savedDefaultInput {
            try? AudioDevices.setDefaultInputDevice(saved)
        }
        savedDefaultInput = nil
    }

    func stop(completion: @escaping (Result<URL, Error>) -> Void) {
        guard isRecording,
              let destinationURL,
              let micURL,
              let meetingURL else { return }
        mic.stop()
        meeting.stop()
        isRecording = false
        restoreDefaultInput()

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

        let stem = destination.deletingPathExtension().lastPathComponent
        let sourcesURL = destination.deletingLastPathComponent()
            .appendingPathComponent("\(stem)-sources.m4a")

        try? FileManager.default.removeItem(at: destination)
        try? FileManager.default.removeItem(at: sourcesURL)

        let meetingHasAudio = meeting.frameCount > 0

        // If meeting has audio: single ffmpeg pass (mix + amerge).
        // If not: two passes (mix from mic only, sources from mic with -ac 2).
        if meetingHasAudio {
            runFFmpeg(
                ffmpegPath: ffmpegPath,
                args: [
                    "-hide_banner", "-loglevel", "error", "-y",
                    "-i", micURL.path, "-i", meetingURL.path,
                    "-filter_complex",
                    "[0:a]aformat=sample_rates=48000:channel_layouts=mono[m0];" +
                    "[1:a]aformat=sample_rates=48000:channel_layouts=mono[r0];" +
                    "[m0]asplit=2[m1][m2];[r0]asplit=2[r1][r2];" +
                    "[m1][r1]amix=inputs=2:duration=longest:normalize=0,aformat=channel_layouts=stereo,alimiter=limit=0.95[mix];" +
                    "[m2][r2]amerge=inputs=2,aformat=channel_layouts=stereo,alimiter=limit=0.95[src]",
                    "-map", "[mix]", "-c:a", "aac", "-b:a", "192k", destination.path,
                    "-map", "[src]", "-c:a", "aac", "-b:a", "192k", sourcesURL.path
                ],
                destination: destination, sources: sourcesURL,
                completion: completion
            )
        } else {
            // No meeting audio: mix is just mic, sources is mic duplicated to stereo.
            runFFmpeg(
                ffmpegPath: ffmpegPath,
                args: [
                    "-hide_banner", "-loglevel", "error", "-y",
                    "-i", micURL.path,
                    "-filter_complex", "[0:a]aformat=channel_layouts=stereo,alimiter=limit=0.95[mix]",
                    "-map", "[mix]", "-c:a", "aac", "-b:a", "192k", destination.path
                ],
                destination: destination, sources: nil,
                completion: { _ in
                    // Then create sources from just the mic (duplicated to stereo).
                    self.runFFmpeg(
                        ffmpegPath: ffmpegPath,
                        args: [
                            "-hide_banner", "-loglevel", "error", "-y",
                            "-i", micURL.path,
                            "-ac", "2", "-c:a", "aac", "-b:a", "192k", sourcesURL.path
                        ],
                        destination: sourcesURL, sources: nil,
                        completion: completion
                    )
                }
            )
        }
    }

    private func runFFmpeg(
        ffmpegPath: String,
        args: [String],
        destination: URL,
        sources: URL?,
        completion: @escaping (Result<Void, Error>) -> Void
    ) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: ffmpegPath)
        process.arguments = args
        let errorPipe = Pipe()
        process.standardError = errorPipe
        process.terminationHandler = { process in
            let data = errorPipe.fileHandleForReading.readDataToEndOfFile()
            let details = String(data: data, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            DispatchQueue.main.async {
                if process.terminationStatus == 0,
                   FileManager.default.fileExists(atPath: destination.path) {
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