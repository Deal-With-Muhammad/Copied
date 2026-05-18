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

    /// Open Settings → Privacy & Security → Accessibility so the user can flip
    /// the switch without hunting through menus.
    static func openSettings() {
        let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!
        NSWorkspace.shared.open(url)
    }

    /// Get the user from "blocked on permissions" → "toggle is right there":
    ///
    /// 1. `AXIsProcessTrustedWithOptions(prompt: true)` — registers this
    ///    bundle in TCC's database so an entry appears in the Accessibility
    ///    list. macOS will also show its own prompt the first time.
    /// 2. Open Settings to the Accessibility pane so the user only needs to
    ///    flip the toggle next to "Copied".
    ///
    /// We don't reveal the app in Finder — that step was confusing and only
    /// helps when the bundle path is unfamiliar. Installing to /Applications
    /// (see `build.sh`) avoids that situation entirely.
    static func requestAccess() {
        _ = isTrusted(prompt: true)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
            openSettings()
        }
    }
}
