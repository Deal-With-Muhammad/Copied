import Cocoa

/// Handles writing items to the system pasteboard and simulating ⌘V into the
/// previously-focused application. Focus restoration is the bit that was
/// missing before — without it, ⌘V is delivered to no key window and silently
/// drops on the floor.
final class PasteService {
    static let shared = PasteService()

    /// The app that owned the keyboard when the panel was opened. Captured by
    /// `FloatingPanel.show()`. We re-activate it before firing ⌘V.
    var previousApp: NSRunningApplication?

    /// Write `item` to the pasteboard, restore focus to the previous app, then
    /// simulate ⌘V. Use this for the click-to-paste action.
    func paste(_ item: ClipboardItem) {
        ClipboardManager.shared.willPaste()
        item.writeToPasteboard()
        restoreFocusAndPaste()
    }

    /// Write `item` to the pasteboard without pasting. Use for ⌘C-style copy.
    func copy(_ item: ClipboardItem) {
        ClipboardManager.shared.willPaste()
        item.writeToPasteboard()
    }

    private func restoreFocusAndPaste() {
        // Without Accessibility we can't post synthetic events. Prompt and bail
        // — the item is on the pasteboard, so a manual ⌘V still works.
        guard AccessibilityHelper.isTrusted(prompt: true) else { return }

        let target = previousApp
        let isOurApp = target?.bundleIdentifier == Bundle.main.bundleIdentifier
        if let target, !isOurApp {
            target.activate()
        }
        // Give AppKit a couple of run-loop turns to hand the key window back to
        // the target app before posting the synthetic ⌘V.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) {
            self.simulatePaste()
        }
    }

    /// Posts a synthetic ⌘V into the HID event tap. Requires Accessibility
    /// permission (granted on first launch via `AXIsProcessTrustedWithOptions`).
    func simulatePaste() {
        let src = CGEventSource(stateID: .combinedSessionState)
        let vKey: CGKeyCode = 0x09
        let down = CGEvent(keyboardEventSource: src, virtualKey: vKey, keyDown: true)
        let up   = CGEvent(keyboardEventSource: src, virtualKey: vKey, keyDown: false)
        down?.flags = .maskCommand
        up?.flags   = .maskCommand
        down?.post(tap: .cghidEventTap)
        up?.post(tap: .cghidEventTap)
    }
}
