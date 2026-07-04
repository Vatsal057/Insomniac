import SwiftUI
import AppKit
import ApplicationServices

/// Shows the first-launch onboarding window.
@MainActor
final class OnboardingManager {
    static let shared = OnboardingManager()
    private var window: NSWindow?

    private init() {}

    func show(onFinish: @escaping () -> Void) {
        if let window, window.isVisible {
            window.makeKeyAndOrderFront(nil)
            return
        }

        let view = OnboardingView { [weak self] in
            self?.window?.close()
            self?.window = nil
            onFinish()
        }

        let hosting = NSHostingController(rootView: view)
        let window = NSWindow(contentViewController: hosting)
        window.title = "Welcome to Insomniac"
        window.styleMask = [.titled, .closable]
        window.isReleasedWhenClosed = false
        window.setContentSize(NSSize(width: 520, height: 480))
        window.center()
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        self.window = window
    }
}

struct OnboardingView: View {
    let onFinish: () -> Void

    @State private var page = 0
    @State private var isAccessibilityTrusted = AXIsProcessTrusted()

    private let pageCount = 3

    var body: some View {
        VStack(spacing: 0) {
            Group {
                switch page {
                case 0: welcomePage
                case 1: usagePage
                default: permissionsPage
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .padding(32)

            Divider()

            HStack {
                if page > 0 {
                    Button("Back") { page -= 1 }
                }
                Spacer()
                HStack(spacing: 6) {
                    ForEach(0..<pageCount, id: \.self) { index in
                        Circle()
                            .fill(index == page ? Color.accentColor : Color.secondary.opacity(0.3))
                            .frame(width: 7, height: 7)
                    }
                }
                Spacer()
                if page < pageCount - 1 {
                    Button("Continue") { page += 1 }
                        .keyboardShortcut(.defaultAction)
                } else {
                    Button("Get Started") { onFinish() }
                        .keyboardShortcut(.defaultAction)
                }
            }
            .padding(16)
        }
        .frame(width: 520, height: 480)
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            isAccessibilityTrusted = AXIsProcessTrusted()
        }
    }

    private var welcomePage: some View {
        VStack(spacing: 18) {
            Image(systemName: "moon.zzz.fill")
                .font(.system(size: 56))
                .foregroundStyle(.orange)
            Text("Welcome to Insomniac")
                .font(.largeTitle.bold())
            Text("Insomniac keeps your Mac awake — for downloads, builds, presentations, or anything that shouldn't be interrupted. It even works with the lid closed.")
                .font(.body)
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
                .frame(maxWidth: 400)
            Text("It lives entirely in your menu bar. No dock icon, no clutter.")
                .font(.callout)
                .multilineTextAlignment(.center)
                .foregroundStyle(.tertiary)
        }
    }

    private var usagePage: some View {
        VStack(alignment: .leading, spacing: 22) {
            Text("How to use it")
                .font(.title.bold())
                .frame(maxWidth: .infinity, alignment: .center)

            onboardingRow(
                icon: "cursorarrow.click",
                title: "Left-click the menu bar icon",
                detail: "Toggles sleep prevention on or off using your default duration."
            )
            onboardingRow(
                icon: "contextualmenu.and.cursorarrow",
                title: "Right-click for the menu",
                detail: "Pick a duration (30 min – 8 hours or indefinite), open Settings, or quit."
            )
            onboardingRow(
                icon: "keyboard",
                title: "Press ⌘⌥I from anywhere",
                detail: "A global shortcut toggles sleep prevention without touching the mouse. Customizable in Settings."
            )
            onboardingRow(
                icon: "cursorarrow.motionlines",
                title: "Optional: cursor jiggler & clicker",
                detail: "Keep presence apps active while a session runs. Enable in Settings → Cursor."
            )
        }
    }

    private var permissionsPage: some View {
        VStack(alignment: .leading, spacing: 22) {
            Text("One-time permissions")
                .font(.title.bold())
                .frame(maxWidth: .infinity, alignment: .center)

            onboardingRow(
                icon: "lock.shield",
                title: "Administrator password (once)",
                detail: "The first time you enable sleep prevention, macOS asks for your password so Insomniac can run pmset. This adds a single sudoers entry for pmset only — you can remove it anytime. Prefer to skip this? Turn on caffeinate mode in Settings."
            )

            VStack(alignment: .leading, spacing: 8) {
                onboardingRow(
                    icon: "hand.raised",
                    title: "Accessibility (only for cursor tools)",
                    detail: "The cursor jiggler and clicker need Accessibility access to move the mouse. Skip this if you don't use them."
                )
                if isAccessibilityTrusted {
                    Label("Accessibility access granted", systemImage: "checkmark.circle.fill")
                        .font(.callout)
                        .foregroundStyle(.green)
                        .padding(.leading, 44)
                } else {
                    Button("Open Accessibility Settings…") {
                        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
                            NSWorkspace.shared.open(url)
                        }
                    }
                    .padding(.leading, 44)
                }
            }

            Text("Insomniac collects no data. Everything stays on your Mac.")
                .font(.callout)
                .foregroundStyle(.tertiary)
                .frame(maxWidth: .infinity, alignment: .center)
                .padding(.top, 8)
        }
    }

    private func onboardingRow(icon: String, title: String, detail: String) -> some View {
        HStack(alignment: .top, spacing: 14) {
            Image(systemName: icon)
                .font(.system(size: 22))
                .foregroundStyle(Color.accentColor)
                .frame(width: 30)
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.headline)
                Text(detail)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}
