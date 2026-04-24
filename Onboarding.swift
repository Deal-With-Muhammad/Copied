import AppKit
import SwiftUI
import Combine

/// Owns the first-run welcome window. The window walks the user through the
/// two permissions we need (Accessibility + screenshot-folder access) with a
/// big call-to-action each, and auto-refreshes its status rows so the buttons
/// flip to green checks without the user having to hit "Recheck".
final class OnboardingController {
    static let shared = OnboardingController()

    static let completedKey = "JCOnboardingCompleted"

    private var windowController: NSWindowController?

    var isCompleted: Bool {
        UserDefaults.standard.bool(forKey: Self.completedKey)
    }

    func showIfNeeded() {
        guard !isCompleted else { return }
        show()
    }

    func show() {
        if let wc = windowController {
            wc.showWindow(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        let view = OnboardingView(onFinish: { [weak self] in
            UserDefaults.standard.set(true, forKey: Self.completedKey)
            self?.windowController?.close()
            self?.windowController = nil
        })

        let hosting = NSHostingController(rootView: view)
        let window = NSWindow(contentViewController: hosting)
        window.styleMask = [.titled, .closable, .fullSizeContentView]
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.isMovableByWindowBackground = true
        window.title = "Welcome"
        window.setContentSize(NSSize(width: 520, height: 620))
        window.center()
        window.isReleasedWhenClosed = false

        let wc = NSWindowController(window: window)
        windowController = wc
        wc.showWindow(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
}

// MARK: - View

private struct OnboardingView: View {
    let onFinish: () -> Void

    @State private var accessibilityOK = AccessibilityHelper.isTrusted()
    @State private var refreshTimer: Timer?

    private let purple = Color(red: 0.49, green: 0.40, blue: 1.0)
    private let cyan = Color(red: 0.35, green: 0.71, blue: 1.0)

    var body: some View {
        ZStack {
            backdrop
            VStack(spacing: 24) {
                header
                permissions
                Spacer(minLength: 0)
                footer
            }
            .padding(36)
        }
        .frame(width: 520, height: 620)
        .onAppear { startPolling() }
        .onDisappear { refreshTimer?.invalidate() }
    }

    private var backdrop: some View {
        ZStack {
            Color(red: 0.06, green: 0.06, blue: 0.08)
            RadialGradient(
                colors: [purple.opacity(0.28), Color.clear],
                center: .topLeading, startRadius: 20, endRadius: 420
            )
            RadialGradient(
                colors: [cyan.opacity(0.22), Color.clear],
                center: .bottomTrailing, startRadius: 20, endRadius: 420
            )
        }
        .ignoresSafeArea()
    }

    private var header: some View {
        VStack(spacing: 14) {
            ZStack {
                RoundedRectangle(cornerRadius: 22, style: .continuous)
                    .fill(LinearGradient(colors: [purple, cyan],
                                         startPoint: .topLeading,
                                         endPoint: .bottomTrailing))
                    .frame(width: 80, height: 80)
                    .shadow(color: purple.opacity(0.5), radius: 18, x: 0, y: 10)
                Image(systemName: "doc.on.clipboard.fill")
                    .font(.system(size: 36, weight: .medium))
                    .foregroundColor(.white)
            }
            VStack(spacing: 4) {
                Text("Welcome to JugnooClipboard")
                    .font(.system(size: 22, weight: .semibold))
                    .foregroundColor(.white)
                Text("Your Mac's clipboard history, always a ⌘⇧V away.")
                    .font(.system(size: 13))
                    .foregroundColor(.white.opacity(0.55))
            }
        }
        .padding(.top, 8)
    }

    private var permissions: some View {
        VStack(spacing: 10) {
            permissionRow(
                icon: "keyboard.fill",
                tint: purple,
                title: "Accessibility",
                subtitle: "Required to paste (⌘V) on your behalf.",
                granted: accessibilityOK,
                buttonTitle: accessibilityOK ? "Granted" : "Enable",
                action: {
                    AccessibilityHelper.requestAccess()
                }
            )
            infoRow(
                icon: "camera.viewfinder",
                tint: cyan,
                title: "Screenshots auto-copy",
                subtitle: "⌘⇧3, ⌘⇧4, ⌘⇧5 go straight to your clipboard. No permission needed — we route them through the app's cache. Your original save-to-Desktop setting is restored on quit."
            )
        }
    }

    private func infoRow(icon: String, tint: Color, title: String, subtitle: String) -> some View {
        HStack(spacing: 12) {
            ZStack {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(tint.opacity(0.18))
                    .frame(width: 42, height: 42)
                Image(systemName: icon)
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundColor(tint)
            }
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 5) {
                    Text(title)
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundColor(.white.opacity(0.92))
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 12))
                        .foregroundColor(.green.opacity(0.9))
                }
                Text(subtitle)
                    .font(.system(size: 11.5))
                    .foregroundColor(.white.opacity(0.48))
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color.white.opacity(0.05))
                .overlay(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .stroke(Color.white.opacity(0.08), lineWidth: 0.5)
                )
        )
    }

    private func permissionRow(
        icon: String,
        tint: Color,
        title: String,
        subtitle: String,
        granted: Bool,
        buttonTitle: String,
        action: @escaping () -> Void
    ) -> some View {
        HStack(spacing: 12) {
            ZStack {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(tint.opacity(0.18))
                    .frame(width: 42, height: 42)
                Image(systemName: icon)
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundColor(tint)
            }
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 5) {
                    Text(title)
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundColor(.white.opacity(0.92))
                    if granted {
                        Image(systemName: "checkmark.circle.fill")
                            .font(.system(size: 12))
                            .foregroundColor(.green.opacity(0.9))
                    }
                }
                Text(subtitle)
                    .font(.system(size: 11.5))
                    .foregroundColor(.white.opacity(0.48))
            }
            Spacer()
            Button(action: action) {
                Text(buttonTitle)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(granted ? .white.opacity(0.55) : .white)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 6)
                    .background(
                        RoundedRectangle(cornerRadius: 7)
                            .fill(granted ? Color.white.opacity(0.08) : tint.opacity(0.9))
                    )
            }
            .buttonStyle(.plain)
            .disabled(granted)
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color.white.opacity(0.05))
                .overlay(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .stroke(Color.white.opacity(0.08), lineWidth: 0.5)
                )
        )
    }

    private var footer: some View {
        VStack(spacing: 10) {
            Button(action: onFinish) {
                Text(allGranted ? "Get Started" : "Continue")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundColor(.white)
                    .frame(maxWidth: .infinity)
                    .frame(height: 42)
                    .background(
                        LinearGradient(colors: [purple, cyan],
                                       startPoint: .leading, endPoint: .trailing)
                    )
                    .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                    .shadow(color: purple.opacity(0.45), radius: 10, x: 0, y: 6)
            }
            .buttonStyle(.plain)

            HStack(spacing: 3) {
                Text("Press")
                Text("⌘⇧V")
                    .font(.system(size: 10, weight: .semibold, design: .monospaced))
                    .padding(.horizontal, 5)
                    .padding(.vertical, 1.5)
                    .background(
                        RoundedRectangle(cornerRadius: 3)
                            .fill(Color.white.opacity(0.10))
                    )
                Text("anywhere to open your clipboard.")
            }
            .font(.system(size: 11))
            .foregroundColor(.white.opacity(0.4))
        }
    }

    private var allGranted: Bool { accessibilityOK }

    private func startPolling() {
        refreshStatus()
        refreshTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { _ in
            refreshStatus()
        }
    }

    private func refreshStatus() {
        accessibilityOK = AccessibilityHelper.isTrusted()
    }
}
