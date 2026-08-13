import AppKit

/// Animates the menu-bar status icon to indicate state without a popup window:
/// idle (circle), recording (red pulsing circle), transcribing (blue pulsing
/// bubble). Color is attempted via tinted, non-template symbols; if the menu bar
/// renders them monochrome the fill pulse still conveys state.
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
        setImage(symbol: "record.circle", tint: nil)
    }

    func startRecording() {
        mode = .recording
        startPulse(interval: 0.7)
    }

    func startTranscribing() {
        mode = .transcribing
        startPulse(interval: 0.55)
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    private func startPulse(interval: TimeInterval) {
        stop()
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
            setImage(symbol: fill ? "record.circle.fill" : "record.circle", tint: .systemRed)
        case .transcribing:
            setImage(symbol: fill ? "text.bubble.fill" : "text.bubble", tint: .systemBlue)
        }
    }

    private func setImage(symbol: String, tint: NSColor?) {
        guard let img = NSImage(systemSymbolName: symbol, accessibilityDescription: nil) else { return }
        if let tint {
            let tinted = NSImage(size: img.size)
            tinted.lockFocus()
            tint.set()
            img.draw(in: NSRect(origin: .zero, size: img.size),
                     from: .zero, operation: .sourceOver, fraction: 1.0)
            tinted.unlockFocus()
            tinted.isTemplate = false
            statusItem.button?.image = tinted
        } else {
            img.isTemplate = true
            statusItem.button?.image = img
        }
    }
}