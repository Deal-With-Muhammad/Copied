import Cocoa
import AppKit
import SwiftUI
import KeyboardShortcuts

@main
struct CopiedApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    var body: some Scene {
        Settings { EmptyView() }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem!
    private var floatingPanel: FloatingPanel?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)

        // Start monitoring the pasteboard immediately so history fills up even
        // before the panel is ever opened.
        ClipboardManager.shared.startMonitoring()

        // Auto-copy screenshots taken with ⌘⇧3/4/5 to the pasteboard.
        if ScreenshotWatcher.isEnabled {
            ScreenshotWatcher.shared.start()
        }

        setupStatusItem()
        setupFloatingPanel()

        KeyboardShortcuts.onKeyUp(for: .toggleClipboard) { [weak self] in
            self?.togglePanel()
        }

        // First-run onboarding walks the user through the permissions we need
        // before they try to paste and hit an invisible wall.
        if OnboardingController.shared.isCompleted {
            _ = AccessibilityHelper.isTrusted(prompt: true)
        } else {
            OnboardingController.shared.showIfNeeded()
        }
    }

    private func setupStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = statusItem.button {
            let img = NSImage(systemSymbolName: "doc.on.clipboard",
                              accessibilityDescription: "Clipboard")
            img?.isTemplate = true
            button.image = img
            button.action = #selector(togglePanel)
            button.target = self
        }
    }

    private func setupFloatingPanel() {
        floatingPanel = FloatingPanel()
        let host = NSHostingController(rootView: ContentView())
        floatingPanel?.contentViewController = host
    }

    @objc private func togglePanel() {
        guard let panel = floatingPanel else { return }
        if panel.isVisible {
            panel.hide()
        } else {
            panel.show()
        }
    }

    @objc func showOnboarding() {
        OnboardingController.shared.show()
    }

    func applicationWillTerminate(_ notification: Notification) {
        // Restore the user's `com.apple.screencapture location` so uninstalling
        // or quitting never leaves screenshots vanishing into our cache.
        ScreenshotWatcher.shared.tearDownForShutdown()
    }
}

extension KeyboardShortcuts.Name {
    static let toggleClipboard = Self("toggleClipboard",
                                      default: .init(.v, modifiers: [.command, .shift]))
}
