import AppKit

/// Animates the menu-bar status icon with two STATIONARY fill-pulse animations
/// (no movement/rotation), distinguished by symbol and speed:
/// - idle: a hollow record.circle.
/// - recording: a slow fill-pulse on record.circle (a heartbeat).
/// - transcribing: a faster fill-pulse on text.bubble (a "typing" pulse).
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
        startPulse(interval: 0.7)
    }

    func startTranscribing() {
        stop()
        mode = .transcribing
        startPulse(interval: 0.45)
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    private func startPulse(interval: TimeInterval) {
        fill = false
        timer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
            self?.tick()
        }
        tick()
    }

    private func tick() {
        fill.toggle()
        switch mode {
        case .idle:
            break
        case .recording:
            setImage(symbol: fill ? "record.circle.fill" : "record.circle")
        case .transcribing:
            setImage(symbol: fill ? "text.bubble.fill" : "text.bubble")
        }
    }

    private func setImage(symbol: String) {
        guard let img = NSImage(systemSymbolName: symbol, accessibilityDescription: nil) else { return }
        img.isTemplate = true
        statusItem.button?.image = img
    }
}