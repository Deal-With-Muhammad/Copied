import Cocoa

/// Watches the real folder where macOS saves screenshots (Desktop by default,
/// or wherever `com.apple.screencapture location` is set) and copies each new
/// screenshot to the clipboard. No file redirection — the user's screenshot
/// stays where they expect it.
///
/// Detection is filename-prefix + xattr based, so we don't grab unrelated
/// images that happen to land on the Desktop.
final class ScreenshotWatcher {
    static let shared = ScreenshotWatcher()

    static let preferenceKey = "JCAutoCopyScreenshots"

    private var source: DispatchSourceFileSystemObject?
    private var folderFD: CInt = -1
    private var watchedFolder: URL?
    private var knownFiles: Set<String> = []
    private var processing: Set<String> = []
    private let queue = DispatchQueue(
        label: "com.jugnoo.Copied.screenshotWatcher",
        qos: .userInitiated
    )

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

    /// Where macOS is currently saving screenshots. Reads
    /// `com.apple.screencapture location`; falls back to ~/Desktop.
    var screenshotFolder: URL {
        if let path = UserDefaults(suiteName: "com.apple.screencapture")?
            .string(forKey: "location"),
           !path.isEmpty {
            return URL(fileURLWithPath: (path as NSString).expandingTildeInPath)
        }
        return FileManager.default
            .urls(for: .desktopDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory() + "/Desktop")
    }

    // MARK: - Lifecycle

    func start() {
        teardownWatch()
        let folder = screenshotFolder
        // Touch the folder once so macOS's TCC prompt for Desktop fires now,
        // not silently next time a screenshot lands.
        _ = try? FileManager.default.contentsOfDirectory(at: folder,
                                                        includingPropertiesForKeys: nil)
        watchFolder(folder)
    }

    func stop() {
        teardownWatch()
    }

    func tearDownForShutdown() {
        teardownWatch()
    }

    private func teardownWatch() {
        source?.cancel()
        source = nil
        if folderFD >= 0 { close(folderFD); folderFD = -1 }
        watchedFolder = nil
        knownFiles.removeAll()
        processing.removeAll()
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
        knownFiles = Set(listFiles(in: folder).map { $0.path })

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
        let current = listFiles(in: folder)
        let currentPaths = Set(current.map { $0.path })
        let added = currentPaths.subtracting(knownFiles)
        knownFiles = currentPaths
        guard !added.isEmpty else { return }

        for path in added where processing.insert(path).inserted {
            copyToPasteboard(URL(fileURLWithPath: path), attempt: 0)
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

    // MARK: - Classification

    private func isLikelyScreenshot(_ url: URL) -> Bool {
        let ext = url.pathExtension.lowercased()
        guard ["png", "jpg", "jpeg", "heic", "tiff", "tif", "pdf"].contains(ext) else {
            return false
        }
        // macOS sets this xattr on every screencapture-produced file, regardless
        // of locale or filename. It's the definitive signal.
        if hasScreenCaptureXattr(url) { return true }

        // Xattr can be a beat late on very fast SSDs — fall back to the locale
        // prefixes macOS uses for screencapture output.
        let lower = url.lastPathComponent.lowercased()
        return lower.hasPrefix("screenshot")
            || lower.hasPrefix("screen shot")
            || lower.hasPrefix("cleanshot")
            || lower.hasPrefix("snip ")
    }

    private func hasScreenCaptureXattr(_ url: URL) -> Bool {
        let name = "com.apple.metadata:kMDItemIsScreenCapture"
        return url.withUnsafeFileSystemRepresentation { ptr -> Bool in
            guard let ptr else { return false }
            return getxattr(ptr, name, nil, 0, 0, 0) > 0
        }
    }

    // MARK: - Copy

    private func copyToPasteboard(_ url: URL, attempt: Int) {
        queue.asyncAfter(deadline: .now() + Double(attempt) * 0.1) { [weak self] in
            guard let self else { return }

            // Screenshots land in two phases: file appears, then xattr is set.
            // Re-check classification on each attempt so we catch the xattr.
            guard self.isLikelyScreenshot(url) else {
                if attempt < 8 {
                    self.copyToPasteboard(url, attempt: attempt + 1)
                } else {
                    self.processing.remove(url.path)
                }
                return
            }

            guard let data = try? Data(contentsOf: url),
                  let image = NSImage(data: data),
                  image.size.width > 0 else {
                if attempt < 12 {
                    self.copyToPasteboard(url, attempt: attempt + 1)
                } else {
                    self.processing.remove(url.path)
                }
                return
            }

            DispatchQueue.main.async {
                let pb = NSPasteboard.general
                pb.clearContents()
                pb.writeObjects([image])
            }

            // Leave the file where the user expects it (Desktop, etc.).
            self.processing.remove(url.path)
        }
    }
}
