import AppKit
import AVFoundation
import AudioToolbox
import CoreAudio

private enum RecorderError: Error, LocalizedError {
    case permissionDenied
    case missingDevice(String)
    case coreAudio(String, OSStatus)
    case invalidFormat(String)
    case noAudioTrack(String)
    case cannotExport
    case missingFFmpeg
    case exportFailed(String)

    var errorDescription: String? {
        switch self {
        case .permissionDenied:
            return "Microphone access is disabled. Enable Meeting Recorder in System Settings → Privacy & Security → Microphone."
        case .missingDevice(let name):
            return "The audio device “\(name)” is unavailable."
        case .coreAudio(let operation, let status):
            return "\(operation) failed with Core Audio status \(status)."
        case .invalidFormat(let name):
            return "\(name) did not provide a usable input format."
        case .noAudioTrack(let name):
            return "The captured \(name) file contains no audio track."
        case .cannotExport:
            return "macOS could not create the M4A exporter."
        case .missingFFmpeg:
            return "The final M4A mixer requires ffmpeg, but it was not found in /opt/homebrew/bin or /usr/local/bin."
        case .exportFailed(let message):
            return "Creating the M4A failed: \(message)"
        }
    }
}

private enum AudioDevices {
    static func id(named wantedName: String) -> AudioDeviceID? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var byteCount: UInt32 = 0
        let system = AudioObjectID(kAudioObjectSystemObject)
        guard AudioObjectGetPropertyDataSize(system, &address, 0, nil, &byteCount) == noErr else {
            return nil
        }
        var devices = [AudioDeviceID](
            repeating: 0,
            count: Int(byteCount) / MemoryLayout<AudioDeviceID>.size
        )
        guard AudioObjectGetPropertyData(system, &address, 0, nil, &byteCount, &devices) == noErr else {
            return nil
        }
        return devices.first { name(of: $0) == wantedName }
    }

    private static func name(of device: AudioDeviceID) -> String? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioObjectPropertyName,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        let storageSize = MemoryLayout<Unmanaged<CFString>?>.size
        let storage = UnsafeMutableRawPointer.allocate(
            byteCount: storageSize,
            alignment: MemoryLayout<Unmanaged<CFString>?>.alignment
        )
        defer { storage.deallocate() }
        storage.initializeMemory(as: UInt8.self, repeating: 0, count: storageSize)
        var size = UInt32(storageSize)
        guard AudioObjectGetPropertyData(device, &address, 0, nil, &size, storage) == noErr,
              let value = storage.load(as: Unmanaged<CFString>?.self) else {
            return nil
        }
        return value.takeUnretainedValue() as String
    }
}

private final class DeviceCapture {
    private let deviceName: String
    private let engine = AVAudioEngine()
    private let fileLock = NSLock()
    private var file: AVAudioFile?
    private(set) var peak: Float = 0
    private(set) var frameCount: AVAudioFramePosition = 0

    init(deviceName: String) {
        self.deviceName = deviceName
    }

    func start(writingTo url: URL) throws {
        guard let deviceID = AudioDevices.id(named: deviceName) else {
            throw RecorderError.missingDevice(deviceName)
        }

        // Capture the device raw, without Apple Voice Processing. Voice
        // Processing is a full-duplex acoustic echo canceller that needs a
        // valid echo reference (audio playing out the speakers). A capture-
        // only recorder provides none, so the AEC cancels the microphone's
        // own signal and deletes the local voice from the recording. The
        // physical microphone and BlackHole are therefore both opened as
        // plain input-only streams. Voice Isolation for the live call is
        // owned by the meeting application and the system mic modes in
        // Control Center, not by this recorder.
        let input = engine.inputNode
        guard let audioUnit = input.audioUnit else {
            throw RecorderError.invalidFormat(deviceName)
        }
        var selectedDevice = deviceID
        let status = AudioUnitSetProperty(
            audioUnit,
            kAudioOutputUnitProperty_CurrentDevice,
            kAudioUnitScope_Global,
            0,
            &selectedDevice,
            UInt32(MemoryLayout<AudioDeviceID>.size)
        )
        guard status == noErr else {
            throw RecorderError.coreAudio("Selecting \(deviceName)", status)
        }

        let format = input.outputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0 else {
            throw RecorderError.invalidFormat(deviceName)
        }

        let captureFile = try AVAudioFile(forWriting: url, settings: format.settings)
        fileLock.lock()
        file = captureFile
        peak = 0
        frameCount = 0
        fileLock.unlock()

        input.installTap(onBus: 0, bufferSize: 1024, format: format) { [weak self] buffer, _ in
            guard let self else { return }
            self.fileLock.lock()
            defer { self.fileLock.unlock() }
            guard let file = self.file else { return }
            do {
                try file.write(from: buffer)
                self.frameCount += AVAudioFramePosition(buffer.frameLength)
                if let channels = buffer.floatChannelData {
                    for channel in 0..<Int(buffer.format.channelCount) {
                        for frame in 0..<Int(buffer.frameLength) {
                            self.peak = max(self.peak, abs(channels[channel][frame]))
                        }
                    }
                }
            } catch {
                NSLog("Meeting Recorder write error for %@: %@", self.deviceName, error.localizedDescription)
            }
        }

        engine.prepare()
        do {
            try engine.start()
        } catch {
            input.removeTap(onBus: 0)
            fileLock.lock()
            file = nil
            fileLock.unlock()
            throw error
        }
    }

    func stop() {
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        fileLock.lock()
        file = nil
        fileLock.unlock()
    }
}

private final class MeetingRecorder {
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

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
    private let menu = NSMenu()
    private let status = NSMenuItem(title: "Ready", action: nil, keyEquivalent: "")
    private lazy var recordItem = NSMenuItem(
        title: "Start Meeting Recording…",
        action: #selector(toggleRecording),
        keyEquivalent: "r"
    )
    private let recorder = MeetingRecorder()
    private lazy var transcribeItem = NSMenuItem(
        title: "Transcribe Last Recording",
        action: #selector(transcribeLastRecording),
        keyEquivalent: "t"
    )
    private var lastSourcesURL: URL?
    private var iconAnimator: StatusIconAnimator!
    private var isTranscribing = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        iconAnimator = StatusIconAnimator(statusItem: statusItem)
        statusItem.menu = menu
        menu.delegate = self
        status.isEnabled = false
        recordItem.target = self
        transcribeItem.target = self

        menu.addItem(status)
        menu.addItem(.separator())
        menu.addItem(recordItem)
        menu.addItem(transcribeItem)
        menu.addItem(.separator())
        let quit = NSMenuItem(
            title: "Quit Meeting Recorder",
            action: #selector(NSApplication.terminate(_:)),
            keyEquivalent: "q"
        )
        menu.addItem(quit)
        updateTranscribeItemState()
    }

    func menuWillOpen(_ menu: NSMenu) {
        updateTranscribeItemState()
    }

    private func updateTranscribeItemState() {
        let exists = lastSourcesURL.map { FileManager.default.fileExists(atPath: $0.path) } ?? false
        transcribeItem.isEnabled = !isTranscribing && !recorder.isRecording && exists
    }

    @objc private func toggleRecording() {
        if recorder.isRecording {
            recordItem.isEnabled = false
            status.title = "Finishing M4A…"
            recorder.stop { [weak self] result in
                guard let self else { return }
                self.recordItem.isEnabled = true
                self.recordItem.title = "Start Meeting Recording…"
                self.iconAnimator.setIdle()
                switch result {
                case .success(let url):
                    self.status.title = "Saved \(url.lastPathComponent)"
                    let stem = url.deletingPathExtension().lastPathComponent
                    self.lastSourcesURL = url.deletingLastPathComponent()
                        .appendingPathComponent("\(stem)-sources.m4a")
                    NSLog("Meeting Recorder saved %@ %@", url.path, self.recorder.diagnosticSummary)
                    self.updateTranscribeItemState()
                case .failure(let error):
                    self.status.title = "Export failed"
                    self.show(title: "Recording failed", message: error.localizedDescription, style: .critical)
                }
            }
            return
        }

        let panel = NSSavePanel()
        panel.allowedContentTypes = [.mpeg4Audio]
        panel.canCreateDirectories = true
        panel.nameFieldStringValue = "meeting-\(Self.timestamp()).m4a"
        NSApp.activate(ignoringOtherApps: true)
        guard panel.runModal() == .OK, let destination = panel.url else { return }

        status.title = "Starting capture…"
        recordItem.isEnabled = false
        recorder.start(destination: destination) { [weak self] result in
            guard let self else { return }
            self.recordItem.isEnabled = true
            switch result {
            case .success:
                self.status.title = "Recording microphone + meeting audio"
                self.recordItem.title = "Stop and Save Recording"
                self.iconAnimator.startRecording()
            case .failure(let error):
                self.status.title = "Could not start"
                self.show(title: "Recording could not start", message: error.localizedDescription, style: .critical)
            }
        }
    }

    @objc private func transcribeLastRecording() {
        guard let sourcesURL = lastSourcesURL,
              FileManager.default.fileExists(atPath: sourcesURL.path) else {
            show(title: "Nothing to transcribe",
                 message: "The per-source file is missing. Record a meeting first.",
                 style: .warning)
            return
        }
        isTranscribing = true
        updateTranscribeItemState()
        status.title = "Transcribing…"
        iconAnimator.startTranscribing()
        let stem = sourcesURL.deletingPathExtension().lastPathComponent
            .replacingOccurrences(of: "-sources", with: "")
        let outURL = sourcesURL.deletingLastPathComponent()
            .appendingPathComponent("\(stem).txt")
        Transcriber.run(
            sourcesURL: sourcesURL,
            progress: { [weak self] phase, _ in
                DispatchQueue.main.async {
                    self?.status.title = "Transcribing… \(phase)"
                }
            },
            completion: { [weak self] result in
                DispatchQueue.main.async {
                    self?.isTranscribing = false
                    self?.iconAnimator.setIdle()
                    switch result {
                    case .success(let segs):
                        let text = segs.map {
                            String(format: "[%.2fs - %.2fs] %@: %@", $0.start, $0.end, $0.speaker, $0.text)
                        }.joined(separator: "\n")
                        do {
                            try text.write(to: outURL, atomically: true, encoding: .utf8)
                            self?.status.title = "Transcript saved \(outURL.lastPathComponent)"
                        } catch {
                            self?.status.title = "Transcript write failed"
                            self?.show(title: "Could not save transcript",
                                       message: error.localizedDescription, style: .critical)
                        }
                    case .failure(let error):
                        self?.status.title = "Transcription failed"
                        self?.show(title: "Transcription failed",
                                   message: "\(error)", style: .critical)
                    }
                    self?.updateTranscribeItemState()
                }
            })
    }

    private func show(title: String, message: String, style: NSAlert.Style) {
        let alert = NSAlert()
        alert.alertStyle = style
        alert.messageText = title
        alert.informativeText = message
        NSApp.activate(ignoringOtherApps: true)
        alert.runModal()
    }

    private static func timestamp() -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd-HHmmss"
        return formatter.string(from: Date())
    }
}

let application = NSApplication.shared
let delegate = AppDelegate()
application.delegate = delegate
application.run()
