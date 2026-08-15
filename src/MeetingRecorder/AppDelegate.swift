import AppKit
import AVFoundation
import Foundation

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
    private lazy var microphoneItem: NSMenuItem = {
        let item = NSMenuItem(title: "Microphone: …", action: nil, keyEquivalent: "")
        item.submenu = NSMenu()
        return item
    }()
    private var lastSourcesURL: URL?
    private var iconAnimator: StatusIconAnimator!
    private var isTranscribing = false

    private var micDeviceName: String {
        get { UserDefaults.standard.string(forKey: "micDeviceName") ?? "External Microphone" }
        set { UserDefaults.standard.set(newValue, forKey: "micDeviceName") }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        iconAnimator = StatusIconAnimator(statusItem: statusItem)
        statusItem.menu = menu
        menu.delegate = self
        menu.autoenablesItems = false
        status.isEnabled = false
        recordItem.target = self
        transcribeItem.target = self

        menu.addItem(status)
        menu.addItem(.separator())
        menu.addItem(recordItem)
        menu.addItem(transcribeItem)
        menu.addItem(microphoneItem)
        menu.addItem(.separator())
        let quit = NSMenuItem(
            title: "Quit Meeting Recorder",
            action: #selector(NSApplication.terminate(_:)),
            keyEquivalent: "q"
        )
        menu.addItem(quit)
        recorder.micDeviceName = micDeviceName
        updateMenuStates()
    }

    func menuWillOpen(_ menu: NSMenu) {
        updateMenuStates()
    }

    private func updateMenuStates() {
        let mics = AudioDevices.inputDeviceNames()
        let micID = AudioDevices.id(named: micDeviceName)
        let isBt = micID.map { AudioDevices.isBluetooth($0) } ?? false
        let micAvailable = mics.contains(micDeviceName) && !isBt
        let exists = lastSourcesURL.map { FileManager.default.fileExists(atPath: $0.path) } ?? false

        if recorder.isRecording {
            recordItem.isEnabled = !isTranscribing
        } else {
            recordItem.isEnabled = !isTranscribing && micAvailable
        }
        transcribeItem.isEnabled = !isTranscribing && !recorder.isRecording && exists
        microphoneItem.title = micAvailable ? "Microphone: \(micDeviceName)" : "Microphone: (none)"

        let submenu = NSMenu()
        if mics.isEmpty {
            submenu.addItem(NSMenuItem(title: "No microphones available", action: nil, keyEquivalent: ""))
        } else {
            for name in mics {
                let item = NSMenuItem(title: name, action: #selector(chooseMic(_:)), keyEquivalent: "")
                item.target = self
                item.representedObject = name
                if let id = AudioDevices.id(named: name), AudioDevices.isBluetooth(id) {
                    item.title = "\(name)  (Bluetooth — not compatible)"
                    item.isEnabled = false
                    item.state = .off
                } else {
                    item.state = (name == micDeviceName) ? .on : .off
                }
                submenu.addItem(item)
            }
        }
        microphoneItem.submenu = submenu
    }

    @objc private func chooseMic(_ sender: NSMenuItem) {
        guard let name = sender.representedObject as? String else { return }
        micDeviceName = name
        recorder.micDeviceName = name
        updateMenuStates()
    }

    @objc private func toggleRecording() {
        if recorder.isRecording {
            recordItem.isEnabled = false
            status.title = "Finishing M4A…"
            recorder.stop { [weak self] result in
                guard let self else { return }
                self.recordItem.title = "Start Meeting Recording…"
                self.iconAnimator.setIdle()
                switch result {
                case .success(let url):
                    self.status.title = "Saved \(url.lastPathComponent)"
                    let stem = url.deletingPathExtension().lastPathComponent
                    self.lastSourcesURL = url.deletingLastPathComponent()
                        .appendingPathComponent("\(stem)-sources.m4a")
                case .failure(let error):
                    self.status.title = "Export failed"
                    self.show(title: "Recording failed", message: error.localizedDescription, style: .critical)
                }
                self.updateMenuStates()
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
        recorder.micDeviceName = micDeviceName
        recorder.start(destination: destination) { [weak self] result in
            guard let self else { return }
            switch result {
            case .success:
                self.status.title = "Recording microphone + meeting audio"
                self.recordItem.title = "Stop and Save Recording"
                self.iconAnimator.startRecording()
            case .failure(let error):
                self.status.title = "Could not start"
                self.show(title: "Recording could not start", message: error.localizedDescription, style: .critical)
            }
            self.updateMenuStates()
        }
    }

    @objc private func transcribeLastRecording() {
        guard let sourcesURL = lastSourcesURL,
              FileManager.default.fileExists(atPath: sourcesURL.path) else {
            status.title = "Nothing to transcribe — record a meeting first"
            return
        }
        isTranscribing = true
        updateMenuStates()
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
                    self?.updateMenuStates()
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