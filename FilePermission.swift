import Foundation
import AppKit

/// Helpers for checking and requesting access to the folder macOS saves
/// screenshots into. Non-sandboxed builds rely on macOS's TCC "Files and
/// Folders" prompt, which fires the first time we enumerate or read from
/// Desktop (or wherever the user has set `com.apple.screencapture location`).
enum FilePermission {
    /// Resolves to the folder macOS is currently writing screenshots into.
    /// Falls back to `~/Desktop` — the system default.
    static var screenshotFolderURL: URL {
        if let location = UserDefaults(suiteName: "com.apple.screencapture")?
            .string(forKey: "location"), !location.isEmpty {
            return URL(fileURLWithPath: (location as NSString).expandingTildeInPath)
        }
        return FileManager.default
            .urls(for: .desktopDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory() + "/Desktop")
    }

    /// True if we can enumerate the screenshot folder. Use as a live check.
    static var hasScreenshotFolderAccess: Bool {
        (try? FileManager.default.contentsOfDirectory(
            at: screenshotFolderURL,
            includingPropertiesForKeys: nil
        )) != nil
    }

    /// Touches the screenshot folder. On first call macOS pops its TCC prompt
    /// for "Files and Folders — Desktop" (or whichever folder is configured).
    /// After the user clicks Allow we never see the prompt again.
    static func requestAccess() {
        _ = try? FileManager.default.contentsOfDirectory(
            at: screenshotFolderURL,
            includingPropertiesForKeys: nil
        )
    }
}
