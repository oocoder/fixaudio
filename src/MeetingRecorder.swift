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

    func start(writingTo url: URL, voiceProcessing: Bool = false) throws {
        guard let deviceID = AudioDevices.id(named: deviceName) else {
            throw RecorderError.missingDevice(deviceName)
        }

        let input = engine.inputNode
        try input.setVoiceProcessingEnabled(voiceProcessing)
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
    var useVoiceProcessing = UserDefaults.standard.object(
        forKey: "useAppleVoiceProcessing"
    ) as? Bool ?? true {
        didSet {
            UserDefaults.standard.set(
                useVoiceProcessing,
                forKey: "useAppleVoiceProcessing"
            )
        }
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

            try meeting.start(writingTo: newMeetingURL)
            do {
                try mic.start(writingTo: newMicURL, voiceProcessing: useVoiceProcessing)
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

        export(microphone: micURL, meeting: meetingURL, destination: destinationURL) { [weak self] result in
            if case .success = result, let temp = self?.temporaryDirectory {
                try? FileManager.default.removeItem(at: temp)
            }
            self?.temporaryDirectory = nil
            completion(result.map { destinationURL })
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

        try? FileManager.default.removeItem(at: destination)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: ffmpegPath)
        process.arguments = [
            "-hide_banner", "-loglevel", "error", "-y",
            "-i", micURL.path,
            "-i", meetingURL.path,
            "-filter_complex",
            "[0:a]aformat=sample_rates=48000:channel_layouts=stereo[local];" +
            "[1:a]aformat=sample_rates=48000:channel_layouts=stereo[remote];" +
            "[local][remote]amix=inputs=2:duration=longest:normalize=0," +
            "alimiter=limit=0.95[out]",
            "-map", "[out]",
            "-c:a", "aac", "-b:a", "192k",
            destination.path
        ]
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

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
    private let menu = NSMenu()
    private let status = NSMenuItem(title: "Ready", action: nil, keyEquivalent: "")
    private lazy var recordItem = NSMenuItem(
        title: "Start Meeting Recording…",
        action: #selector(toggleRecording),
        keyEquivalent: "r"
    )
    private lazy var transcribeItem = NSMenuItem(
        title: "Transcribe Last Recording",
        action: #selector(transcribeLastRecording),
        keyEquivalent: "t"
    )
    private lazy var voiceProcessingItem = NSMenuItem(
        title: "Apple Voice Processing",
        action: #selector(toggleVoiceProcessing),
        keyEquivalent: ""
    )
    private lazy var microphoneModeItem = NSMenuItem(
        title: "Microphone Mode: Checking…",
        action: #selector(openMicrophoneModes),
        keyEquivalent: ""
    )
    private let recorder = MeetingRecorder()
    private var lastRecording: URL?

    func applicationDidFinishLaunching(_ notification: Notification) {
        statusItem.button?.image = NSImage(
            systemSymbolName: "record.circle",
            accessibilityDescription: "Meeting Recorder"
        )
        statusItem.menu = menu
        menu.delegate = self
        status.isEnabled = false
        recordItem.target = self
        transcribeItem.target = self
        voiceProcessingItem.target = self
        microphoneModeItem.target = self
        transcribeItem.isEnabled = false

        menu.addItem(status)
        menu.addItem(.separator())
        menu.addItem(recordItem)
        menu.addItem(transcribeItem)
        menu.addItem(.separator())
        menu.addItem(voiceProcessingItem)
        menu.addItem(microphoneModeItem)
        menu.addItem(.separator())
        let quit = NSMenuItem(
            title: "Quit Meeting Recorder",
            action: #selector(NSApplication.terminate(_:)),
            keyEquivalent: "q"
        )
        menu.addItem(quit)
        refreshMicrophoneMode()
    }

    func menuWillOpen(_ menu: NSMenu) {
        refreshMicrophoneMode()
    }

    @objc private func toggleVoiceProcessing() {
        guard !recorder.isRecording else { return }
        recorder.useVoiceProcessing.toggle()
        voiceProcessingItem.state = recorder.useVoiceProcessing ? .on : .off
        if recorder.useVoiceProcessing {
            show(
                title: "Apple Voice Processing enabled",
                message: "The next recording will use Apple's voice-processing audio path. Select the microphone mode from the Microphone Mode menu item.",
                style: .informational
            )
            AVCaptureDevice.showSystemUserInterface(.microphoneModes)
        }
    }

    @objc private func openMicrophoneModes() {
        AVCaptureDevice.showSystemUserInterface(.microphoneModes)
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in
            self?.refreshMicrophoneMode()
        }
    }

    private func refreshMicrophoneMode() {
        let preferred = Self.microphoneModeName(AVCaptureDevice.preferredMicrophoneMode)
        let active = Self.microphoneModeName(AVCaptureDevice.activeMicrophoneMode)
        microphoneModeItem.title = preferred == active
            ? "Microphone Mode: \(active)…"
            : "Microphone Mode: \(active) (preferred: \(preferred))…"
        voiceProcessingItem.state = recorder.useVoiceProcessing ? .on : .off
        voiceProcessingItem.isEnabled = !recorder.isRecording
        microphoneModeItem.isEnabled = !recorder.isRecording
    }

    private static func microphoneModeName(_ mode: AVCaptureDevice.MicrophoneMode) -> String {
        switch mode {
        case .standard: return "Standard"
        case .voiceIsolation: return "Voice Isolation"
        case .wideSpectrum: return "Wide Spectrum"
        @unknown default: return "Unknown"
        }
    }

    @objc private func toggleRecording() {
        if recorder.isRecording {
            recordItem.isEnabled = false
            status.title = "Finishing M4A…"
            recorder.stop { [weak self] result in
                guard let self else { return }
                self.recordItem.isEnabled = true
                self.recordItem.title = "Start Meeting Recording…"
                self.refreshMicrophoneMode()
                self.statusItem.button?.image = NSImage(
                    systemSymbolName: "record.circle",
                    accessibilityDescription: "Meeting Recorder"
                )
                switch result {
                case .success(let url):
                    self.lastRecording = url
                    self.transcribeItem.isEnabled = true
                    self.status.title = "Saved \(url.lastPathComponent)"
                    self.show(title: "Recording saved", message: "\(url.path)\n\n\(self.recorder.diagnosticSummary)", style: .informational)
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
                self.statusItem.button?.image = NSImage(
                    systemSymbolName: "record.circle.fill",
                    accessibilityDescription: "Recording in progress"
                )
                self.voiceProcessingItem.isEnabled = false
                self.microphoneModeItem.isEnabled = false
            case .failure(let error):
                self.status.title = "Could not start"
                self.refreshMicrophoneMode()
                self.show(title: "Recording could not start", message: error.localizedDescription, style: .critical)
            }
        }
    }

    @objc private func transcribeLastRecording() {
        guard let lastRecording else { return }
        guard let script = transcriptionScript() else { return }
        let process = Process()
        process.executableURL = script
        process.arguments = [lastRecording.path]
        process.currentDirectoryURL = lastRecording.deletingLastPathComponent()
        do {
            try process.run()
            status.title = "Transcription started for \(lastRecording.lastPathComponent)"
        } catch {
            show(title: "Transcription could not start", message: error.localizedDescription, style: .critical)
        }
    }

    private func transcriptionScript() -> URL? {
        let preferenceKey = "transcriptionScriptPath"
        if let savedPath = UserDefaults.standard.string(forKey: preferenceKey),
           FileManager.default.isExecutableFile(atPath: savedPath) {
            return URL(fileURLWithPath: savedPath)
        }

        let panel = NSOpenPanel()
        panel.title = "Choose a transcription script"
        panel.message = "Select an executable script that accepts the M4A path as its first argument. This choice is saved locally."
        panel.prompt = "Choose Script"
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        NSApp.activate(ignoringOtherApps: true)
        guard panel.runModal() == .OK, let selected = panel.url else { return nil }
        guard FileManager.default.isExecutableFile(atPath: selected.path) else {
            show(
                title: "Script is not executable",
                message: "Make the script executable with chmod +x, then choose it again.",
                style: .critical
            )
            return nil
        }
        UserDefaults.standard.set(selected.path, forKey: preferenceKey)
        return selected
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
