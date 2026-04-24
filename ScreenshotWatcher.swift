import Cocoa

/// Makes `⌘⇧3/4/5` land on the clipboard without the user holding Control.
///
/// Why the previous approaches failed:
/// - `NSMetadataQuery` on `kMDItemIsScreenCapture`: Spotlight indexing is
///   laggy and, under sandbox/TCC, often never fires on Desktop.
/// - Direct `DispatchSource` watch on `~/Desktop`: needs Files-and-Folders
///   permission. Even when granted the first time, macOS can silently revoke
///   for ad-hoc-signed apps; and the first screenshot gets consumed by the
///   TCC prompt itself.
///
/// What this implementation does instead: take over `com.apple.screencapture
/// location`, pointing it at a folder inside our own Application Support
/// directory (no TCC required). Every screenshot lands there; we read it,
/// push it to the pasteboard, delete the file. On disable/quit we restore
/// the user's original location so nothing is left dangling.
final class ScreenshotWatcher {
    static let shared = ScreenshotWatcher()

    static let preferenceKey = "JCAutoCopyScreenshots"
    private static let originalLocationKey = "JCOriginalScreencaptureLocation"
    private static let defaultSentinel = "__macos_default__"

    private var source: DispatchSourceFileSystemObject?
    private var folderFD: CInt = -1
    private var watchedFolder: URL?
    private var knownFiles: Set<URL> = []
    private var processing: Set<URL> = []
    private let queue = DispatchQueue(
        label: "com.jugnoo.JugnooClipboard.screenshotWatcher",
        qos: .userInitiated
    )

    /// Where we tell macOS to save screenshots while auto-copy is enabled.
    /// Lives inside the app's data directory — no TCC required.
    private var captureFolder: URL {
        let fm = FileManager.default
        let appSupport = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let dir = appSupport.appendingPathComponent("JugnooClipboard/Captures",
                                                    isDirectory: true)
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    static var isEnabled: Bool {
        get {
            let defaults = UserDefaults.standard
            if defaults.object(forKey: preferenceKey) == nil { return true }
            return defaults.bool(forKey: preferenceKey)
        }
        set {
            UserDefaults.standard.set(newValue, forKey: preferenceKey)
            if newValue {
                ScreenshotWatcher.shared.start()
            } else {
                ScreenshotWatcher.shared.stop()
            }
        }
    }

    // MARK: - Lifecycle

    func start() {
        teardownWatch()
        redirectScreencapture()
        watchFolder(captureFolder)
    }

    func stop() {
        teardownWatch()
        restoreScreencapture()
    }

    /// Called from `applicationWillTerminate`. Always restore the user's
    /// preference so a crash or force-quit doesn't leave screenshots forever
    /// disappearing into our Application Support folder.
    func tearDownForShutdown() {
        teardownWatch()
        restoreScreencapture()
    }

    private func teardownWatch() {
        source?.cancel()
        source = nil
        if folderFD >= 0 { close(folderFD); folderFD = -1 }
        watchedFolder = nil
        knownFiles.removeAll()
        processing.removeAll()
    }

    // MARK: - Redirect

    private func redirectScreencapture() {
        let current = readScreencaptureLocation()

        // Remember the user's original location the first time we take over,
        // so we can put it back when the toggle is disabled.
        if UserDefaults.standard.string(forKey: Self.originalLocationKey) == nil {
            if let current, !current.contains("JugnooClipboard") {
                UserDefaults.standard.set(current, forKey: Self.originalLocationKey)
            } else if current == nil {
                UserDefaults.standard.set(Self.defaultSentinel, forKey: Self.originalLocationKey)
            }
        }

        // Only write if we need to — a no-op `defaults write` still touches
        // the file, which would churn the pasteboard monitor for nothing.
        if current != captureFolder.path {
            writeScreencaptureLocation(captureFolder.path)
        }
    }

    private func restoreScreencapture() {
        guard let saved = UserDefaults.standard.string(forKey: Self.originalLocationKey) else {
            return
        }
        if saved == Self.defaultSentinel {
            deleteScreencaptureLocation()
        } else {
            writeScreencaptureLocation(saved)
        }
        UserDefaults.standard.removeObject(forKey: Self.originalLocationKey)
    }

    private func readScreencaptureLocation() -> String? {
        UserDefaults(suiteName: "com.apple.screencapture")?.string(forKey: "location")
    }

    private func writeScreencaptureLocation(_ path: String) {
        runDefaults(["write", "com.apple.screencapture", "location", "-string", path])
    }

    private func deleteScreencaptureLocation() {
        runDefaults(["delete", "com.apple.screencapture", "location"])
    }

    private func runDefaults(_ args: [String]) {
        let task = Process()
        task.launchPath = "/usr/bin/defaults"
        task.arguments = args
        do { try task.run() } catch { NSLog("defaults \(args) failed: \(error)") }
        task.waitUntilExit()
    }

    // MARK: - Folder watcher

    private func watchFolder(_ folder: URL) {
        let fd = open(folder.path, O_EVTONLY)
        guard fd >= 0 else {
            NSLog("ScreenshotWatcher: could not open \(folder.path) (errno=\(errno))")
            return
        }
        folderFD = fd
        watchedFolder = folder
        knownFiles = Set(listFiles(in: folder))

        let src = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fd,
            eventMask: [.write, .extend, .rename, .attrib],
            queue: queue
        )
        src.setEventHandler { [weak self] in self?.handleDirectoryChange() }
        src.setCancelHandler { [weak self] in
            if let self, self.folderFD >= 0 {
                close(self.folderFD)
                self.folderFD = -1
            }
        }
        source = src
        src.resume()
    }

    private func handleDirectoryChange() {
        guard let folder = watchedFolder else { return }
        let current = Set(listFiles(in: folder))
        let added = current.subtracting(knownFiles)
        knownFiles = current
        guard !added.isEmpty else { return }

        for url in added where processing.insert(url).inserted {
            copyToPasteboard(url, attempt: 0)
        }
    }

    private func listFiles(in folder: URL) -> [URL] {
        guard let items = try? FileManager.default.contentsOfDirectory(
            at: folder,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles, .skipsSubdirectoryDescendants]
        ) else { return [] }
        return items.filter { url in
            (try? url.resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile == true
        }
    }

    // MARK: - Copy

    private func copyToPasteboard(_ url: URL, attempt: Int) {
        queue.asyncAfter(deadline: .now() + Double(attempt) * 0.1) { [weak self] in
            guard let self else { return }

            // Retry briefly — `screencapture` may still be writing / renaming.
            guard let data = try? Data(contentsOf: url),
                  let image = NSImage(data: data),
                  image.size.width > 0 else {
                if attempt < 10 {
                    self.copyToPasteboard(url, attempt: attempt + 1)
                } else {
                    NSLog("ScreenshotWatcher: gave up on \(url.lastPathComponent)")
                    self.processing.remove(url)
                }
                return
            }

            DispatchQueue.main.async {
                let pb = NSPasteboard.general
                pb.clearContents()
                pb.writeObjects([image])
            }

            // Keep our capture folder small — we already copied the image onto
            // the pasteboard (and into the clipboard history). If the user
            // wanted a file, they can paste into Preview / Finder / anywhere.
            try? FileManager.default.removeItem(at: url)
            self.knownFiles.remove(url)
            self.processing.remove(url)
        }
    }
}
