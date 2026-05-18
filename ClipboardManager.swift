import Cocoa
import Combine
import CryptoKit

enum ClipboardKind: String, Codable {
    case text
    case image
    case url
    case email
    case color
    case file
    case code
}

struct ClipboardItem: Identifiable, Equatable, Codable {
    let id: UUID
    var text: String
    var timestamp: Date
    var isPinned: Bool
    var kind: ClipboardKind
    /// PNG data for images (preferred over TIFF for size + lossless display).
    var imageData: Data?
    var sourceAppBundleID: String?
    var sourceAppName: String?

    init(id: UUID = UUID(),
         text: String,
         timestamp: Date = Date(),
         isPinned: Bool = false,
         kind: ClipboardKind = .text,
         imageData: Data? = nil,
         sourceAppBundleID: String? = nil,
         sourceAppName: String? = nil) {
        self.id = id
        self.text = text
        self.timestamp = timestamp
        self.isPinned = isPinned
        self.kind = kind
        self.imageData = imageData
        self.sourceAppBundleID = sourceAppBundleID
        self.sourceAppName = sourceAppName
    }

    var isImage: Bool { kind == .image }

    /// Lazy NSImage decode for thumbnails.
    var image: NSImage? {
        guard let imageData else { return nil }
        return NSImage(data: imageData)
    }

    /// A short preview string for image rows ("Image · 1024×768").
    var imageDimensionLabel: String? {
        guard let img = image else { return nil }
        let size = img.representations.first.map { CGSize(width: $0.pixelsWide, height: $0.pixelsHigh) } ?? img.size
        return "\(Int(size.width)) × \(Int(size.height))"
    }

    /// Restore this item to the system pasteboard. Called immediately before
    /// simulating ⌘V — guarantees the right content is there even if the user
    /// has copied something else since.
    func writeToPasteboard() {
        let pb = NSPasteboard.general
        pb.clearContents()
        if isImage, let imageData, let img = NSImage(data: imageData) {
            pb.writeObjects([img])
        } else {
            pb.setString(text, forType: .string)
        }
    }
}

final class ClipboardManager: ObservableObject {
    static let shared = ClipboardManager()

    @Published private(set) var items: [ClipboardItem] = []

    var pinnedItems: [ClipboardItem] { items.filter { $0.isPinned } }
    var unpinnedItems: [ClipboardItem] { items.filter { !$0.isPinned } }

    private var lastChangeCount = NSPasteboard.general.changeCount
    private var timer: Timer?
    private let maxUnpinnedItems = 50

    /// Window during which we ignore pasteboard changes — set when we paste so
    /// we don't re-record our own write.
    private var suppressUntil: Date = .distantPast

    private let storageURL: URL
    private var saveTask: DispatchWorkItem?

    init() {
        let fm = FileManager.default
        let appSupport = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let dir = appSupport.appendingPathComponent("Copied", isDirectory: true)
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        storageURL = dir.appendingPathComponent("history.json")
        load()
    }

    // MARK: - Monitoring

    func startMonitoring() {
        guard timer == nil else { return }
        lastChangeCount = NSPasteboard.general.changeCount
        timer = Timer.scheduledTimer(withTimeInterval: 0.4, repeats: true) { [weak self] _ in
            self?.checkClipboard()
        }
    }

    func stopMonitoring() {
        timer?.invalidate()
        timer = nil
    }

    /// Suppresses pasteboard monitoring around a programmatic paste so the
    /// item we just pasted doesn't get recorded as a "new" copy.
    func willPaste() {
        suppressUntil = Date().addingTimeInterval(1.5)
    }

    private func checkClipboard() {
        let pb = NSPasteboard.general
        guard pb.changeCount != lastChangeCount else { return }
        lastChangeCount = pb.changeCount

        if Date() < suppressUntil { return }

        let frontApp = NSWorkspace.shared.frontmostApplication
        let bundleID = frontApp?.bundleIdentifier
        let appName  = frontApp?.localizedName

        // Image (screenshots, copied images)
        if let images = pb.readObjects(forClasses: [NSImage.self], options: nil) as? [NSImage],
           let image = images.first,
           let tiff = image.tiffRepresentation,
           let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]) {
            let hash = sha(png)
            if let first = unpinnedItems.first, first.isImage,
               let firstData = first.imageData, sha(firstData) == hash {
                return
            }
            insert(ClipboardItem(
                text: "Image",
                kind: .image,
                imageData: png,
                sourceAppBundleID: bundleID,
                sourceAppName: appName
            ))
            return
        }

        // Text
        if let text = pb.string(forType: .string), !text.isEmpty {
            // Move-to-top dedupe: if we already have this text, bump it.
            if let idx = items.firstIndex(where: { !$0.isImage && $0.text == text }) {
                bumpToTop(at: idx)
                return
            }
            insert(ClipboardItem(
                text: text,
                kind: detectKind(text),
                sourceAppBundleID: bundleID,
                sourceAppName: appName
            ))
        }
    }

    private func detectKind(_ text: String) -> ClipboardKind {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return .text }

        if !trimmed.contains("\n"),
           !trimmed.contains(" "),
           let url = URL(string: trimmed),
           let scheme = url.scheme?.lowercased(),
           ["http", "https", "ftp", "file"].contains(scheme) {
            return .url
        }

        if !trimmed.contains(" "), !trimmed.contains("\n"),
           trimmed.range(of: #"^[A-Z0-9._%+-]+@[A-Z0-9.-]+\.[A-Z]{2,}$"#,
                         options: [.regularExpression, .caseInsensitive]) != nil {
            return .email
        }

        if trimmed.range(of: #"^#?[0-9A-Fa-f]{6,8}$"#, options: .regularExpression) != nil {
            return .color
        }

        let codeMarkers = ["{", "}", "();", "=>", "function ", "import ", "def ",
                           "class ", "const ", "let ", "var ", "func ", "fn ",
                           "<html", "<div", "</"]
        let lower = trimmed.lowercased()
        let hits = codeMarkers.filter { lower.contains($0) }.count
        if hits >= 2 || (trimmed.contains("\n") && hits >= 1) { return .code }

        return .text
    }

    private func sha(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    // MARK: - Mutation

    private func insert(_ item: ClipboardItem) {
        let insertIndex = items.firstIndex(where: { !$0.isPinned }) ?? items.endIndex
        items.insert(item, at: insertIndex)
        enforceLimit()
        scheduleSave()
    }

    private func bumpToTop(at index: Int) {
        var item = items[index]
        item.timestamp = Date()
        items.remove(at: index)
        if item.isPinned {
            items.insert(item, at: 0)
        } else {
            let insertIndex = items.firstIndex(where: { !$0.isPinned }) ?? items.endIndex
            items.insert(item, at: insertIndex)
        }
        scheduleSave()
    }

    private func enforceLimit() {
        var unpinned = items.filter { !$0.isPinned }
        let pinned = items.filter { $0.isPinned }
        while unpinned.count > maxUnpinnedItems {
            unpinned.removeLast()
        }
        items = pinned + unpinned
    }

    func togglePin(_ item: ClipboardItem) {
        guard let index = items.firstIndex(where: { $0.id == item.id }) else { return }
        items[index].isPinned.toggle()
        let toggled = items.remove(at: index)
        if toggled.isPinned {
            items.insert(toggled, at: 0)
        } else {
            let insertIndex = items.firstIndex(where: { !$0.isPinned }) ?? items.endIndex
            items.insert(toggled, at: insertIndex)
        }
        enforceLimit()
        scheduleSave()
    }

    func remove(_ item: ClipboardItem) {
        items.removeAll { $0.id == item.id }
        scheduleSave()
    }

    func clearUnpinned() {
        items.removeAll { !$0.isPinned }
        scheduleSave()
    }

    // MARK: - Persistence

    private func scheduleSave() {
        saveTask?.cancel()
        let task = DispatchWorkItem { [weak self] in self?.save() }
        saveTask = task
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 0.6, execute: task)
    }

    private func save() {
        let snapshot = items
        do {
            let data = try JSONEncoder().encode(snapshot)
            try data.write(to: storageURL, options: .atomic)
        } catch {
            NSLog("Copied save failed: \(error)")
        }
    }

    private func load() {
        guard let data = try? Data(contentsOf: storageURL),
              let decoded = try? JSONDecoder().decode([ClipboardItem].self, from: data)
        else { return }
        items = decoded
    }
}
