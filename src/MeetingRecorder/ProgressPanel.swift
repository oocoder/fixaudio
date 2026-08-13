import AppKit

/// A small, non-activating floating panel with an indeterminate spinner and a
/// text label, used to show transcription progress for a menu-bar app with no
/// main window. All methods are main-thread safe.
final class ProgressPanel {
    private let panel: NSPanel
    private let label: NSTextField
    private let indicator: NSProgressIndicator

    init() {
        label = NSTextField(labelWithString: "")
        label.font = .systemFont(ofSize: 12, weight: .regular)
        label.lineBreakMode = .byTruncatingTail
        label.alignment = .center

        indicator = NSProgressIndicator()
        indicator.style = .spinning
        indicator.isIndeterminate = true
        indicator.controlSize = .small

        let view = NSView()
        view.addSubview(indicator)
        view.addSubview(label)

        indicator.translatesAutoresizingMaskIntoConstraints = false
        label.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            indicator.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            indicator.topAnchor.constraint(equalTo: view.topAnchor, constant: 12),
            label.topAnchor.constraint(equalTo: indicator.bottomAnchor, constant: 10),
            label.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 12),
            label.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -12),
            view.bottomAnchor.constraint(equalTo: label.bottomAnchor, constant: 12),
        ])

        panel = NSPanel(contentViewController: NSViewController())
        panel.contentViewController?.view = view
        panel.titleVisibility = .hidden
        panel.styleMask = [.titled, .nonactivatingPanel]
        panel.hidesOnDeactivate = false
        panel.level = .floating
        panel.isFloatingPanel = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
    }

    func show(_ text: String) {
        DispatchQueue.main.async {
            self.label.stringValue = text
            self.indicator.startAnimation(nil)
            self.panel.setContentSize(NSSize(width: 280, height: 70))
            if let screen = NSScreen.main {
                let f = self.panel.frame
                let x = screen.frame.midX - f.width / 2
                let y = screen.frame.maxY - 90
                self.panel.setFrameOrigin(NSPoint(x: x, y: y))
            }
            self.panel.orderFrontRegardless()
        }
    }

    func update(_ text: String) {
        DispatchQueue.main.async { self.label.stringValue = text }
    }

    func hide() {
        DispatchQueue.main.async {
            self.indicator.stopAnimation(nil)
            self.panel.orderOut(nil)
        }
    }
}