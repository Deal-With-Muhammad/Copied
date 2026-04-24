import AppKit
import ApplicationServices

/// Wraps the macOS Accessibility trust check. Centralised so we don't sprinkle
/// `AXIsProcessTrusted` calls around — and so we can answer the live state any
/// time the UI asks (the first-launch result is not sticky).
enum AccessibilityHelper {
    /// Live trust check. Pass `prompt: true` to surface the system TCC dialog
    /// when the app isn't yet trusted.
    static func isTrusted(prompt: Bool = false) -> Bool {
        if prompt {
            let key = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
            return AXIsProcessTrustedWithOptions([key: true] as CFDictionary)
        }
        return AXIsProcessTrusted()
    }

    /// Open the Accessibility pane in System Settings so the user can flip the
    /// switch without hunting through menus.
    static func openSettings() {
        let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!
        NSWorkspace.shared.open(url)
    }

    /// Reveal the running app's bundle in Finder so the user can drag it into
    /// the Accessibility list's `+` picker. macOS only auto-adds an entry the
    /// first time `AXIsProcessTrustedWithOptions(prompt:)` fires for a given
    /// signature; for ad-hoc-signed builds the user often has to add it by
    /// hand, and the easiest way is drag-and-drop from Finder.
    static func revealAppInFinder() {
        let url = Bundle.main.bundleURL
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    /// One-shot "do everything we can to get the user un-stuck": trigger the
    /// system prompt (in case it's eligible), open Accessibility settings, and
    /// reveal the app in Finder so they can drag it into the list.
    static func requestAccess() {
        _ = isTrusted(prompt: true)
        openSettings()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
            revealAppInFinder()
        }
    }
}
