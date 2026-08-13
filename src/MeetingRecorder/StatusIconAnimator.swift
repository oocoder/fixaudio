import AppKit
import QuartzCore

/// Animates the menu-bar status icon to indicate state without a popup window.
/// Two distinct monochrome animations so the states are distinguishable even
/// without color:
/// - idle: a hollow record.circle.
/// - recording: a fill-pulse (record.circle ⇄ record.circle.fill) — a heartbeat.
/// - transcribing: a continuously rotating arrow.2.circlepath — a spinner.
final class StatusIconAnimator {
    private let statusItem: NSStatusItem
    private var timer: Timer?
    private var fill = false
    private enum Mode { case idle, recording, transcribing }
    private var mode: Mode = .idle

    init(statusItem: NSStatusItem) {
        self.statusItem = statusItem
        setIdle()
    }

    func setIdle() {
        stop()
        mode = .idle
        setImage(symbol: "record.circle")
    }

    func startRecording() {
        stop()
        mode = .recording
        fill = false
        timer = Timer.scheduledTimer(withTimeInterval: 0.7, repeats: true) { [weak self] _ in
            self?.tick()
        }
        tick()
    }

    func startTranscribing() {
        stop()
        mode = .transcribing
        setImage(symbol: "arrow.2.circlepath")
        startRotation()
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        statusItem.button?.layer?.removeAnimation(forKey: "rotate")
    }

    private func tick() {
        fill.toggle()
        setImage(symbol: fill ? "record.circle.fill" : "record.circle")
    }

    private func startRotation() {
        guard let button = statusItem.button else { return }
        button.wantsLayer = true
        let anim = CABasicAnimation(keyPath: "transform.rotation.z")
        anim.fromValue = 0
        anim.toValue = 2 * Double.pi
        anim.duration = 1.1
        anim.repeatCount = .infinity
        anim.isRemovedOnCompletion = false
        button.layer?.add(anim, forKey: "rotate")
    }

    private func setImage(symbol: String) {
        guard let img = NSImage(systemSymbolName: symbol, accessibilityDescription: nil) else { return }
        img.isTemplate = true
        statusItem.button?.image = img
    }
}