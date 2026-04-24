import Cocoa

/// Borderless, non-activating panel that hosts the clipboard UI. The panel
/// captures the previously frontmost app on show so PasteService can hand
/// keyboard focus back to it before simulating ⌘V.
final class FloatingPanel: NSPanel {
    private var clickOutsideMonitor: Any?
    private var localKeyMonitor: Any?

    init() {
        super.init(
            contentRect: NSRect(x: 0, y: 0, width: 380, height: 540),
            styleMask: [.borderless, .nonactivatingPanel, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        self.level = .floating
        self.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        self.backgroundColor = .clear
        self.isOpaque = false
        self.hasShadow = true
        self.isMovableByWindowBackground = false
        self.isFloatingPanel = true
        self.hidesOnDeactivate = false
        self.animationBehavior = .utilityWindow
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    func show() {
        // Remember who had focus so we can paste back into them.
        let prev = NSWorkspace.shared.frontmostApplication
        if prev?.bundleIdentifier != Bundle.main.bundleIdentifier {
            PasteService.shared.previousApp = prev
        }

        positionNearMouse()
        self.makeKeyAndOrderFront(nil)
        self.orderFrontRegardless()
        installMonitors()
    }

    func hide() {
        removeMonitors()
        self.orderOut(nil)
    }

    private func positionNearMouse() {
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first(where: { $0.frame.contains(mouse) })
            ?? NSScreen.main
            ?? NSScreen.screens.first
        guard let visible = screen?.visibleFrame else { return }

        var x = mouse.x - frame.width / 2
        var y = mouse.y - frame.height - 12
        x = max(visible.minX + 8, min(x, visible.maxX - frame.width - 8))
        y = max(visible.minY + 8, min(y, visible.maxY - frame.height - 8))
        self.setFrameOrigin(NSPoint(x: x, y: y))
    }

    private func installMonitors() {
        clickOutsideMonitor = NSEvent.addGlobalMonitorForEvents(
            matching: [.leftMouseDown, .rightMouseDown]
        ) { [weak self] _ in
            guard let self, self.isVisible else { return }
            let loc = NSEvent.mouseLocation
            if !self.frame.contains(loc) {
                DispatchQueue.main.async { self.hide() }
            }
        }

        // Esc closes the panel; everything else passes through to SwiftUI.
        localKeyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            if event.keyCode == 53 {
                self?.hide()
                return nil
            }
            return event
        }
    }

    private func removeMonitors() {
        if let m = clickOutsideMonitor { NSEvent.removeMonitor(m); clickOutsideMonitor = nil }
        if let m = localKeyMonitor { NSEvent.removeMonitor(m); localKeyMonitor = nil }
    }
}
