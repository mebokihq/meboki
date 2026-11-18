import AppKit
import MebokiCore
import SwiftUI

/// The one-time licence notice (PLAN.md §6 "App-side licensing" › "Where the user meets the paywall"): "Your trial
/// has ended", or, for a key that was refunded, cancelled or expired, "This licence is no longer valid".
/// Same window chrome as the onboarding window.
enum LicenceNoticeVariant: Equatable {
    case trialEnded
    case revoked
    case expired
}

struct LicenceNoticeActions {
    var buy: () -> Void = {}
    var enterKey: () -> Void = {}
    var continueFree: () -> Void = {}
}

struct TrialEndedView: View {
    let variant: LicenceNoticeVariant
    let hotkey: String
    let actions: LicenceNoticeActions

    private var isTrial: Bool { variant == .trialEnded }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            PageHeader(symbol: isTrial ? "hourglass" : "exclamationmark.triangle.fill",
                       color: isTrial ? 0x8E8E93 : 0xFF5A5F,
                       title: isTrial ? "Your trial has ended" : "This licence is no longer valid",
                       subtitle: subtitle)
            if isTrial {
                HStack(alignment: .top, spacing: 12) {
                    column("Still free", symbol: "checkmark", tint: DS.ok, items: [
                        "Check with \(hotkey)", "All models and your own API key",
                        "Apply, Apply all, Ignore", "Privacy settings"])
                    column("Needs a licence", symbol: "lock.fill", tint: DS.textSecondary, items: [
                        "Underlines as you type", "Bubble and island popups",
                        "Check for and casual mode", "Per-app On and Casual"])
                }
                .padding(.bottom, 14)
                HStack(spacing: 7) {
                    Image(systemName: "lock").font(.system(size: 12))
                    Text("Free mode reads text only when you press \(hotkey).")
                }
                .font(.system(size: 12))
                .foregroundStyle(DS.textSecondary)
                .padding(.leading, 2)
            } else {
                HStack(spacing: 6) {
                    Text("Questions:")
                    Button(LicenceManager.supportEmail) { Self.openMail() }.buttonStyle(.dsLink).padding(.leading, -6)
                }
                .font(.system(size: 12.5))
                .foregroundStyle(DS.textSecondary)
                .padding(.leading, 60)
            }
            Spacer(minLength: 22)
            HStack(spacing: 10) {
                Button("Continue in Free Mode") { actions.continueFree() }.buttonStyle(.dsGhost)
                Spacer(minLength: 0)
                if isTrial { Button("Enter Licence Key") { actions.enterKey() }.buttonStyle(.dsSecondary) }
                Button("Buy a Licence") { actions.buy() }
                    .buttonStyle(.dsPrimary)
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(EdgeInsets(top: 48, leading: 36, bottom: 24, trailing: 36))
        .frame(width: TrialEndedWindowController.width, height: Self.height(variant), alignment: .topLeading)
        .background(DS.window)
        .ignoresSafeArea()
    }

    static func height(_ variant: LicenceNoticeVariant) -> CGFloat { variant == .trialEnded ? 400 : 244 }

    private var subtitle: String {
        switch variant {
        case .trialEnded: LicenceText.trialEnded
        case .revoked: "It was refunded or cancelled, so Meboki is in free mode."
        case .expired: "It has expired, so Meboki is in free mode."
        }
    }

    private func column(_ title: String, symbol: String, tint: Color, items: [String]) -> some View {
        VStack(alignment: .leading, spacing: 9) {
            Text(title).font(DS.Font.bodySemibold).foregroundStyle(DS.text)
            ForEach(items, id: \.self) { item in
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Image(systemName: symbol).font(.system(size: 9.5, weight: .bold)).foregroundStyle(tint)
                        .frame(width: 12)
                    Text(item).font(DS.Font.link).foregroundStyle(DS.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(RoundedRectangle(cornerRadius: DS.Radius.group, style: .continuous).fill(DS.group))
        .overlay(RoundedRectangle(cornerRadius: DS.Radius.group, style: .continuous).strokeBorder(DS.separator, lineWidth: 0.5))
        .accessibilityElement(children: .combine)
    }

    static func openMail() {
        if let url = URL(string: "mailto:\(LicenceManager.supportEmail)") { NSWorkspace.shared.open(url) }
    }
}

/// A hosting view that takes the first click even when Meboki isn't the active app: the window is shown
/// without activating, so its buttons must work on the first click.
private final class FirstClickHostingView<Content: View>: NSHostingView<Content> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

/// The notice window. It comes to the front without activating Meboki, so the keyboard stays in the app the
/// user is typing in. The app becomes a regular app while it is open (Dock icon, like Settings), which doesn't
/// activate it either.
@MainActor
final class TrialEndedWindowController: NSObject, NSWindowDelegate {
    static let width: CGFloat = 540

    private var window: NSWindow?
    private var actions: LicenceNoticeActions
    private let variant: LicenceNoticeVariant
    private let hotkey: String
    /// The window closed, however it closed.
    var onClose: (() -> Void)?
    private lazy var mainMenu = AppMenus.windowMenu(appName: "Meboki")

    init(variant: LicenceNoticeVariant, hotkey: String, actions: LicenceNoticeActions) {
        self.variant = variant
        self.hotkey = hotkey
        self.actions = actions
        super.init()
        self.actions = LicenceNoticeActions(
            buy: { [weak self] in actions.buy(); self?.close() },
            enterKey: { [weak self] in self?.close(); actions.enterKey() },
            continueFree: { [weak self] in actions.continueFree(); self?.close() })
    }

    var isVisible: Bool { window?.isVisible == true }
    var windowNumber: Int { window?.windowNumber ?? -1 }
    #if DEBUG
    var debugWindow: NSWindow? { window }
    #endif

    func show() {
        let w = window ?? makeWindow()
        window = w
        if !w.isVisible { w.center() }
        // Reachable like Settings (Dock icon, ⌘-Tab) but never activated: no NSApp.activate, no makeKey.
        if NSApp.activationPolicy() != .regular { NSApp.setActivationPolicy(.regular) }
        w.orderFrontRegardless()
    }

    func close() { window?.close() }

    private func makeWindow() -> NSWindow {
        let view = TrialEndedView(variant: variant, hotkey: hotkey, actions: actions)
        let host = FirstClickHostingView(rootView: view)
        host.sizingOptions = []
        let size = NSSize(width: Self.width, height: TrialEndedView.height(variant))
        let w = NSWindow(contentRect: NSRect(origin: .zero, size: size),
                         styleMask: [.titled, .closable, .fullSizeContentView],
                         backing: .buffered, defer: false)
        w.title = variant == .trialEnded ? "Your trial has ended" : "Licence"
        w.titleVisibility = .hidden
        w.titlebarAppearsTransparent = true
        w.isReleasedWhenClosed = false
        w.isMovableByWindowBackground = true
        w.collectionBehavior = [.fullScreenAuxiliary, .moveToActiveSpace]
        w.backgroundColor = NSColor(DS.window)
        w.standardWindowButton(.miniaturizeButton)?.isHidden = true
        w.standardWindowButton(.zoomButton)?.isHidden = true
        w.delegate = self
        w.contentView = host
        w.setContentSize(size)
        return w
    }

    func windowDidBecomeKey(_ notification: Notification) { NSApp.mainMenu = mainMenu }

    func windowDidResignKey(_ notification: Notification) {
        if NSApp.mainMenu === mainMenu { NSApp.mainMenu = nil }
    }

    func windowWillClose(_ notification: Notification) {
        if NSApp.mainMenu === mainMenu { NSApp.mainMenu = nil }
        AppMenus.windowClosed(window)
        onClose?()
    }
}
