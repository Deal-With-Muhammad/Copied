import SwiftUI
import AppKit

struct ContentView: View {
    @StateObject private var clipboard = ClipboardManager.shared
    @State private var searchText = ""
    @State private var selectedID: UUID?
    @State private var hoveredID: UUID?
    /// Token that bumps every time we want the list to auto-scroll to the
    /// selected row. Hover never bumps it, so resting the cursor on an item
    /// doesn't drag the list around.
    @State private var keyboardScrollToken: Int = 0
    @State private var accessibilityTrusted: Bool = AccessibilityHelper.isTrusted()
    @State private var autoCopyScreenshots: Bool = ScreenshotWatcher.isEnabled
    @FocusState private var searchFocused: Bool

    private var filteredItems: [ClipboardItem] {
        let items = clipboard.items
        guard !searchText.isEmpty else { return items }
        let q = searchText.lowercased()
        return items.filter { item in
            if item.isImage { return "image screenshot".contains(q) }
            return item.text.lowercased().contains(q)
        }
    }

    private var pinned: [ClipboardItem] { filteredItems.filter { $0.isPinned } }
    private var unpinned: [ClipboardItem] { filteredItems.filter { !$0.isPinned } }

    var body: some View {
        ZStack(alignment: .topLeading) {
            background
            VStack(spacing: 0) {
                if !accessibilityTrusted {
                    accessibilityBanner
                        .padding(.horizontal, 12)
                        .padding(.top, 12)
                }
                searchBar
                    .padding(.horizontal, 12)
                    .padding(.top, accessibilityTrusted ? 12 : 10)
                    .padding(.bottom, 10)

                if filteredItems.isEmpty {
                    emptyState
                } else {
                    itemsScroll
                }

                footer
            }
        }
        .frame(width: 380, height: 540)
        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .stroke(Color.white.opacity(0.08), lineWidth: 0.5)
        )
        .onAppear {
            clipboard.startMonitoring()
            searchFocused = true
            if selectedID == nil { selectedID = filteredItems.first?.id }
            accessibilityTrusted = AccessibilityHelper.isTrusted()
        }
        .onChange(of: searchText) { _, _ in
            selectedID = filteredItems.first?.id
        }
        .background(KeyHandler(
            onMoveDown: { moveSelection(by: 1); keyboardScrollToken &+= 1 },
            onMoveUp: { moveSelection(by: -1); keyboardScrollToken &+= 1 },
            onSubmit: { pasteSelected() },
            onCopySelected: { copySelected() },
            onDeleteSelected: { deleteSelected() },
            onPickIndex: { i in pickByIndex(i) }
        ))
    }

    // MARK: Background

    private var background: some View {
        ZStack {
            VisualEffectBlur(material: .hudWindow, blendingMode: .behindWindow)
            Color(red: 0.06, green: 0.06, blue: 0.08).opacity(0.82)
        }
        .ignoresSafeArea()
    }

    // MARK: Search

    private var searchBar: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 12, weight: .medium))
                .foregroundColor(.white.opacity(0.4))

            TextField("Search clipboard…", text: $searchText)
                .font(.system(size: 13))
                .foregroundColor(.white.opacity(0.92))
                .textFieldStyle(.plain)
                .focused($searchFocused)
                .onSubmit { pasteSelected() }

            if !searchText.isEmpty {
                Button(action: { searchText = "" }) {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 12))
                        .foregroundColor(.white.opacity(0.35))
                }
                .buttonStyle(.plain)
            } else {
                Text("⌘⇧V")
                    .font(.system(size: 10, weight: .medium, design: .monospaced))
                    .foregroundColor(.white.opacity(0.35))
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(
                        RoundedRectangle(cornerRadius: 4)
                            .fill(Color.white.opacity(0.06))
                            .overlay(
                                RoundedRectangle(cornerRadius: 4)
                                    .stroke(Color.white.opacity(0.10), lineWidth: 0.5)
                            )
                    )
            }
        }
        .padding(.horizontal, 11)
        .padding(.vertical, 9)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Color.white.opacity(0.06))
                .overlay(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .stroke(Color.white.opacity(0.10), lineWidth: 0.5)
                )
        )
    }

    // MARK: Items list

    private var itemsScroll: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 4) {
                    if !pinned.isEmpty {
                        sectionHeader("PINNED", systemImage: "pin.fill")
                        ForEach(pinned) { item in
                            row(for: item)
                        }
                        if !unpinned.isEmpty {
                            sectionHeader("RECENT", systemImage: "clock")
                                .padding(.top, 6)
                        }
                    } else {
                        sectionHeader("RECENT", systemImage: "clock")
                    }

                    ForEach(Array(unpinned.enumerated()), id: \.element.id) { index, item in
                        row(for: item, shortcutNumber: index < 9 ? index + 1 : nil)
                    }
                }
                .padding(.horizontal, 8)
                .padding(.bottom, 8)
            }
            .onChange(of: keyboardScrollToken) { _, _ in
                guard let id = selectedID else { return }
                withAnimation(.easeOut(duration: 0.12)) {
                    proxy.scrollTo(id, anchor: .center)
                }
            }
        }
    }

    private func sectionHeader(_ title: String, systemImage: String) -> some View {
        HStack(spacing: 5) {
            Image(systemName: systemImage)
                .font(.system(size: 8, weight: .bold))
            Text(title)
                .font(.system(size: 9.5, weight: .bold))
                .tracking(1.0)
            Spacer()
        }
        .foregroundColor(.white.opacity(0.32))
        .padding(.horizontal, 8)
        .padding(.top, 6)
        .padding(.bottom, 2)
    }

    private func row(for item: ClipboardItem, shortcutNumber: Int? = nil) -> some View {
        ClipboardRow(
            item: item,
            isSelected: selectedID == item.id,
            isHovered: hoveredID == item.id,
            shortcutNumber: shortcutNumber,
            onTap: {
                selectedID = item.id
                paste(item)
            },
            onPin: { clipboard.togglePin(item) },
            onDelete: { clipboard.remove(item) },
            onCopy: { copy(item) },
            onHover: { hovering in
                hoveredID = hovering ? item.id : (hoveredID == item.id ? nil : hoveredID)
            }
        )
        .id(item.id)
    }

    // MARK: Accessibility banner

    private var accessibilityBanner: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top, spacing: 9) {
                Image(systemName: "exclamationmark.shield.fill")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(Color(red: 1.0, green: 0.78, blue: 0.36))
                    .padding(.top, 1)
                VStack(alignment: .leading, spacing: 3) {
                    Text("Enable Accessibility to paste")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundColor(.white.opacity(0.92))
                    Text("Click below — Settings opens to the Accessibility list. Find Copied and turn the toggle on.")
                        .font(.system(size: 10.5))
                        .foregroundColor(.white.opacity(0.55))
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
            }

            HStack(spacing: 6) {
                bannerButton("Open Accessibility Settings", primary: true) {
                    AccessibilityHelper.requestAccess()
                }
                bannerButton("Recheck", primary: false) {
                    accessibilityTrusted = AccessibilityHelper.isTrusted()
                }
                Spacer()
            }
        }
        .padding(10)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Color(red: 1.0, green: 0.78, blue: 0.36).opacity(0.10))
                .overlay(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .stroke(Color(red: 1.0, green: 0.78, blue: 0.36).opacity(0.25), lineWidth: 0.5)
                )
        )
    }

    private func bannerButton(_ label: String, primary: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(label)
                .font(.system(size: 11, weight: .medium))
                .foregroundColor(primary ? .white : .white.opacity(0.75))
                .padding(.horizontal, 10)
                .padding(.vertical, 4)
                .background(
                    RoundedRectangle(cornerRadius: 5)
                        .fill(primary
                              ? Color(red: 0.49, green: 0.40, blue: 1.0).opacity(0.85)
                              : Color.white.opacity(0.08))
                )
        }
        .buttonStyle(.plain)
    }

    // MARK: Empty state

    private var emptyState: some View {
        VStack(spacing: 10) {
            Spacer()
            Image(systemName: searchText.isEmpty ? "doc.on.clipboard" : "magnifyingglass")
                .font(.system(size: 34, weight: .light))
                .foregroundColor(.white.opacity(0.18))
            Text(searchText.isEmpty ? "Your clipboard is empty" : "No matches")
                .font(.system(size: 13, weight: .medium))
                .foregroundColor(.white.opacity(0.55))
            Text(searchText.isEmpty
                 ? "Copy something — it will show up here."
                 : "Try a different search term.")
                .font(.system(size: 11))
                .foregroundColor(.white.opacity(0.32))
            Spacer()
        }
        .frame(maxWidth: .infinity)
    }

    // MARK: Footer

    private var footer: some View {
        HStack(spacing: 8) {
            footerHint(key: "↵", label: "Paste")
            footerHint(key: "⌘C", label: "Copy")
            footerHint(key: "⌘1-9", label: "Quick")
            Spacer()
            Menu {
                Toggle("Auto-copy screenshots (⌘⇧3/4/5)", isOn: Binding(
                    get: { autoCopyScreenshots },
                    set: { newValue in
                        autoCopyScreenshots = newValue
                        ScreenshotWatcher.isEnabled = newValue
                    }
                ))
                Divider()
                Button("Show Welcome…") {
                    OnboardingController.shared.show()
                }
                Button("Clear unpinned", action: { clipboard.clearUnpinned() })
                Divider()
                Button("Quit Copied") { NSApp.terminate(nil) }
            } label: {
                Image(systemName: "ellipsis.circle")
                    .font(.system(size: 13))
                    .foregroundColor(.white.opacity(0.45))
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .frame(width: 22)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(
            Color.black.opacity(0.18)
                .overlay(
                    Rectangle()
                        .fill(Color.white.opacity(0.06))
                        .frame(height: 0.5),
                    alignment: .top
                )
        )
    }

    private func footerHint(key: String, label: String) -> some View {
        HStack(spacing: 3) {
            Text(key)
                .font(.system(size: 9, weight: .semibold, design: .monospaced))
                .foregroundColor(.white.opacity(0.55))
                .padding(.horizontal, 4)
                .padding(.vertical, 1.5)
                .background(
                    RoundedRectangle(cornerRadius: 3)
                        .fill(Color.white.opacity(0.08))
                        .overlay(
                            RoundedRectangle(cornerRadius: 3)
                                .stroke(Color.white.opacity(0.10), lineWidth: 0.5)
                        )
                )
            Text(label)
                .font(.system(size: 9.5))
                .foregroundColor(.white.opacity(0.40))
        }
    }

    // MARK: Actions

    private func paste(_ item: ClipboardItem) {
        if let panel = NSApp.windows.first(where: { $0 is FloatingPanel }) as? FloatingPanel {
            panel.hide()
        }
        PasteService.shared.paste(item)
    }

    private func copy(_ item: ClipboardItem) {
        PasteService.shared.copy(item)
    }

    private func copySelected() {
        guard let id = selectedID, let item = filteredItems.first(where: { $0.id == id }) else { return }
        copy(item)
    }

    private func pasteSelected() {
        guard let id = selectedID, let item = filteredItems.first(where: { $0.id == id }) else {
            if let first = filteredItems.first { paste(first) }
            return
        }
        paste(item)
    }

    private func deleteSelected() {
        guard let id = selectedID, let item = filteredItems.first(where: { $0.id == id }) else { return }
        let next = nextSelectionAfterDelete()
        clipboard.remove(item)
        selectedID = next
    }

    private func nextSelectionAfterDelete() -> UUID? {
        guard let id = selectedID,
              let idx = filteredItems.firstIndex(where: { $0.id == id }) else { return nil }
        if idx + 1 < filteredItems.count { return filteredItems[idx + 1].id }
        if idx > 0 { return filteredItems[idx - 1].id }
        return nil
    }

    private func moveSelection(by offset: Int) {
        guard !filteredItems.isEmpty else { return }
        let currentIndex = filteredItems.firstIndex(where: { $0.id == selectedID }) ?? 0
        let next = max(0, min(filteredItems.count - 1, currentIndex + offset))
        selectedID = filteredItems[next].id
    }

    private func pickByIndex(_ i: Int) {
        let unpinnedFiltered = filteredItems.filter { !$0.isPinned }
        guard i >= 0, i < unpinnedFiltered.count else { return }
        paste(unpinnedFiltered[i])
    }
}

// MARK: - Row

struct ClipboardRow: View {
    let item: ClipboardItem
    let isSelected: Bool
    let isHovered: Bool
    let shortcutNumber: Int?
    let onTap: () -> Void
    let onPin: () -> Void
    let onDelete: () -> Void
    let onCopy: () -> Void
    let onHover: (Bool) -> Void

    var body: some View {
        Button(action: onTap) {
            HStack(alignment: .top, spacing: 10) {
                icon
                    .frame(width: 36, height: 36)
                    .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))

                VStack(alignment: .leading, spacing: 2) {
                    primaryLabel
                    metadata
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                trailingActions
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .background(rowBackground)
            .overlay(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .stroke(isSelected ? accentColor.opacity(0.45) : Color.clear, lineWidth: 1)
            )
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover(perform: onHover)
        .contextMenu {
            Button("Paste", action: onTap)
            Button("Copy", action: onCopy)
            Button(item.isPinned ? "Unpin" : "Pin", action: onPin)
            Divider()
            Button("Delete", role: .destructive, action: onDelete)
        }
    }

    private var rowBackground: some View {
        Group {
            if isSelected {
                accentColor.opacity(0.16)
            } else if isHovered {
                Color.white.opacity(0.05)
            } else {
                Color.clear
            }
        }
    }

    @ViewBuilder
    private var icon: some View {
        if item.isImage, let nsImage = item.image {
            Image(nsImage: nsImage)
                .resizable()
                .aspectRatio(contentMode: .fill)
                .background(Color.black.opacity(0.4))
        } else {
            ZStack {
                kindColor.opacity(0.14)
                Image(systemName: kindSymbol)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundColor(kindColor.opacity(0.9))
            }
        }
    }

    @ViewBuilder
    private var primaryLabel: some View {
        if item.isImage {
            HStack(spacing: 6) {
                Text("Screenshot")
                    .font(.system(size: 12.5, weight: .medium))
                    .foregroundColor(.white.opacity(0.92))
                if let dims = item.imageDimensionLabel {
                    Text(dims)
                        .font(.system(size: 10.5, design: .monospaced))
                        .foregroundColor(.white.opacity(0.40))
                }
            }
        } else {
            Text(displayText)
                .font(.system(size: 12.5))
                .foregroundColor(.white.opacity(0.92))
                .lineLimit(2)
                .truncationMode(.tail)
        }
    }

    private var metadata: some View {
        HStack(spacing: 6) {
            Text(relativeTime(item.timestamp))
                .font(.system(size: 10.5, design: .monospaced))
                .foregroundColor(.white.opacity(0.36))
            if let app = item.sourceAppName, !app.isEmpty {
                Text("·").foregroundColor(.white.opacity(0.25))
                Text(app)
                    .font(.system(size: 10.5))
                    .foregroundColor(.white.opacity(0.36))
                    .lineLimit(1)
            }
            kindBadge
        }
    }

    @ViewBuilder
    private var kindBadge: some View {
        if item.kind != .text && item.kind != .image {
            Text(item.kind.rawValue.uppercased())
                .font(.system(size: 8.5, weight: .bold, design: .monospaced))
                .tracking(0.5)
                .foregroundColor(kindColor)
                .padding(.horizontal, 4)
                .padding(.vertical, 1)
                .background(
                    RoundedRectangle(cornerRadius: 3)
                        .fill(kindColor.opacity(0.16))
                )
        }
    }

    @ViewBuilder
    private var trailingActions: some View {
        if isHovered || isSelected {
            HStack(spacing: 4) {
                actionChip(icon: item.isPinned ? "pin.slash.fill" : "pin.fill",
                           color: accentColor, action: onPin)
                actionChip(icon: "trash.fill",
                           color: Color(red: 1.0, green: 0.42, blue: 0.42),
                           action: onDelete)
            }
        } else if item.isPinned {
            Image(systemName: "pin.fill")
                .font(.system(size: 9))
                .foregroundColor(accentColor.opacity(0.7))
                .rotationEffect(.degrees(45))
                .padding(.top, 2)
        } else if let n = shortcutNumber {
            Text("⌘\(n)")
                .font(.system(size: 9, weight: .medium, design: .monospaced))
                .foregroundColor(.white.opacity(0.30))
                .padding(.horizontal, 4)
                .padding(.vertical, 2)
                .background(
                    RoundedRectangle(cornerRadius: 3)
                        .fill(Color.white.opacity(0.05))
                )
        }
    }

    private func actionChip(icon: String, color: Color, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: 9, weight: .semibold))
                .foregroundColor(color)
                .frame(width: 22, height: 22)
                .background(
                    Circle().fill(color.opacity(0.14))
                )
                .overlay(
                    Circle().stroke(color.opacity(0.30), lineWidth: 0.5)
                )
        }
        .buttonStyle(.plain)
    }

    // MARK: Helpers

    private var displayText: String {
        if item.kind == .url || item.kind == .email {
            return item.text.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        let collapsed = item.text
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
            .joined(separator: " ↵ ")
        return collapsed.isEmpty ? item.text : collapsed
    }

    private var accentColor: Color { Color(red: 0.49, green: 0.40, blue: 1.0) }

    private var kindColor: Color {
        switch item.kind {
        case .text: return Color.white
        case .image: return Color(red: 0.35, green: 0.71, blue: 1.0)
        case .url: return Color(red: 0.40, green: 0.78, blue: 1.0)
        case .email: return Color(red: 1.0, green: 0.72, blue: 0.36)
        case .color: return Color(red: 0.95, green: 0.55, blue: 0.85)
        case .file: return Color(red: 0.78, green: 0.78, blue: 0.78)
        case .code: return Color(red: 0.55, green: 0.85, blue: 0.55)
        }
    }

    private var kindSymbol: String {
        switch item.kind {
        case .text: return "text.alignleft"
        case .image: return "photo"
        case .url: return "link"
        case .email: return "envelope"
        case .color: return "paintpalette"
        case .file: return "doc"
        case .code: return "chevron.left.forwardslash.chevron.right"
        }
    }

    private func relativeTime(_ date: Date) -> String {
        let seconds = Int(-date.timeIntervalSinceNow)
        if seconds < 5 { return "now" }
        if seconds < 60 { return "\(seconds)s" }
        if seconds < 3600 { return "\(seconds / 60)m" }
        if seconds < 86400 { return "\(seconds / 3600)h" }
        return "\(seconds / 86400)d"
    }
}

// MARK: - Key handler (NSView bridge for arrow / number keys)

struct KeyHandler: NSViewRepresentable {
    var onMoveDown: () -> Void
    var onMoveUp: () -> Void
    var onSubmit: () -> Void
    var onCopySelected: () -> Void
    var onDeleteSelected: () -> Void
    var onPickIndex: (Int) -> Void

    func makeNSView(context: Context) -> KeyCatcherView {
        let v = KeyCatcherView()
        v.onMoveDown = onMoveDown
        v.onMoveUp = onMoveUp
        v.onSubmit = onSubmit
        v.onCopySelected = onCopySelected
        v.onDeleteSelected = onDeleteSelected
        v.onPickIndex = onPickIndex
        return v
    }

    func updateNSView(_ nsView: KeyCatcherView, context: Context) {
        nsView.onMoveDown = onMoveDown
        nsView.onMoveUp = onMoveUp
        nsView.onSubmit = onSubmit
        nsView.onCopySelected = onCopySelected
        nsView.onDeleteSelected = onDeleteSelected
        nsView.onPickIndex = onPickIndex
    }
}

final class KeyCatcherView: NSView {
    var onMoveDown: (() -> Void)?
    var onMoveUp: (() -> Void)?
    var onSubmit: (() -> Void)?
    var onCopySelected: (() -> Void)?
    var onDeleteSelected: (() -> Void)?
    var onPickIndex: ((Int) -> Void)?

    private var monitor: Any?

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if monitor != nil {
            NSEvent.removeMonitor(monitor!)
            monitor = nil
        }
        guard window != nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, self.window?.isKeyWindow == true else { return event }
            return self.handle(event) ? nil : event
        }
    }

    deinit {
        if let m = monitor { NSEvent.removeMonitor(m) }
    }

    private func handle(_ event: NSEvent) -> Bool {
        let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        let cmd = modifiers.contains(.command)

        switch event.keyCode {
        case 125: onMoveDown?(); return true                  // Down
        case 126: onMoveUp?(); return true                    // Up
        case 36, 76:                                          // Return / Enter
            onSubmit?(); return true
        case 51, 117:                                         // Backspace / Forward Delete
            if cmd { onDeleteSelected?(); return true }
            return false
        default: break
        }

        if cmd, let chars = event.charactersIgnoringModifiers {
            if chars == "c" { onCopySelected?(); return true }
            if let n = Int(chars), (1...9).contains(n) {
                onPickIndex?(n - 1); return true
            }
        }
        return false
    }
}

// MARK: - Visual Effect Blur

struct VisualEffectBlur: NSViewRepresentable {
    var material: NSVisualEffectView.Material
    var blendingMode: NSVisualEffectView.BlendingMode

    func makeNSView(context: Context) -> NSVisualEffectView {
        let v = NSVisualEffectView()
        v.material = material
        v.blendingMode = blendingMode
        v.state = .active
        return v
    }

    func updateNSView(_ nsView: NSVisualEffectView, context: Context) {}
}
