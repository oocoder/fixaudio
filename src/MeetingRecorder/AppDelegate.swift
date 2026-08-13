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
    private var lastSourcesURL: URL?
    private var iconAnimator: StatusIconAnimator!
    private var isTranscribing = false

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
            status.title = "Nothing to transcribe — record a meeting first"
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