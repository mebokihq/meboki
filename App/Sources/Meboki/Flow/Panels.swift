import AppKit
import MebokiCore
import SwiftUI

/// Accepts key events (Return / Tab / Esc / arrows) without activating Meboki, so the target app stays
/// frontmost and ⌘Z there still undoes a fix.
final class KeyPanel: NSPanel {
    override var canBecomeKey: Bool { true }
}

/// A hosting view that takes the first click, so buttons work in a panel of an app that isn't active.
final class FirstMouseHostingView<Content: View>: NSHostingView<Content> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

/// The card or toast window: borderless, transparent, non-activating, floating, on every Space. The SwiftUI
/// content draws its own glass and shadow, so the window is larger than the visible shape by
/// `PanelGeometry.inset` on each side.
///
/// Content is set with `setRoot`, which replaces the hosting view's root synchronously, so the window can be
/// sized for the new content right away (a `@Published` change would only render on the next run-loop pass).
@MainActor
final class HostedPanel<Content: View> {
    let panel: NSPanel
    private let host: FirstMouseHostingView<Inset<Content>>

    init(_ root: Content, canBecomeKey: Bool) {
        let style: NSWindow.StyleMask = [.borderless, .nonactivatingPanel]
        panel = canBecomeKey
            ? KeyPanel(contentRect: .zero, styleMask: style, backing: .buffered, defer: true)
            : NSPanel(contentRect: .zero, styleMask: style, backing: .buffered, defer: true)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.isFloatingPanel = true
        panel.level = .floating
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.becomesKeyOnlyIfNeeded = false
        panel.animationBehavior = .none
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        host = FirstMouseHostingView(rootView: Inset(content: root))
        // Intrinsic size only: `setRoot` sizes the window itself (no min/max constraints fighting it).
        host.sizingOptions = [.intrinsicContentSize]
        panel.contentView = host
    }

    /// Replaces the content, sizes the window to it, and returns the size of the visible shape (no inset).
    @discardableResult
    func setRoot(_ root: Content) -> CGSize {
        host.rootView = Inset(content: root)
        host.layoutSubtreeIfNeeded()
        let fit = host.intrinsicContentSize
        if fit.width > 0, fit.height > 0, fit.width.isFinite, fit.height.isFinite { panel.setContentSize(fit) }
        let i = PanelGeometry.inset
        return CGSize(width: panel.frame.width - i.leading - i.trailing, height: panel.frame.height - i.top - i.bottom)
    }

    /// Moves the window so its visible shape (not the transparent inset) has its bottom-left corner at `origin`.
    /// `animated` slides it there (0.2 s ease-out), for a card moving from one word to another.
    func place(shapeOrigin origin: CGPoint, animated: Bool = false) {
        let i = PanelGeometry.inset
        let target = CGPoint(x: origin.x - i.leading, y: origin.y - i.bottom)
        guard animated, panel.frame.origin != target else {
            panel.setFrameOrigin(target)
            return
        }
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.2
            ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
            panel.animator().setFrame(CGRect(origin: target, size: panel.frame.size), display: true)
        }
    }
}

struct Inset<Content: View>: View {
    let content: Content
    @ObservedObject private var look = PopupLook.shared
    var body: some View {
        content.padding(PanelGeometry.inset)
            // The panels live for the whole run and SwiftUI skips redrawing a glass background whose inputs
            // didn't change, so a static read of `DS.popupOpacity` would keep the value the panel first drew with.
            .environment(\.dsPopupOpacity, look.opacity)
    }
}

/// The popup opacity the popup panels draw with (`Inset`). Set by `AppSettings.popupOpacity`, so a change
/// reaches panels already created, even while one is on screen.
@MainActor
final class PopupLook: ObservableObject {
    static let shared = PopupLook()
    @Published var opacity = DS.popupOpacity
}

/// Drives the `popIn` appearance of a panel's content; layout doesn't change with it.
@MainActor
final class AppearModel: ObservableObject {
    @Published var shown = false
}

enum PanelGeometry {
    /// Room around the visible shape for the window shadow (`DS.windowShadow`: up to 30 pt blur, 26 pt down).
    /// The blur reaches about twice its radius, so a smaller inset clips the shadow to a visible rectangle.
    static let inset = EdgeInsets(top: 40, leading: 64, bottom: 104, trailing: 64)

    /// Origin (Cocoa, bottom-left) for a shape of `size` anchored to `field` (a field frame or a word rect):
    /// its left edge at `field.minX + dx` and `gap` below it. If that crosses the bottom of the visible screen
    /// frame, above the field instead. If neither fits (a field as tall as the screen), at the bottom of the
    /// visible frame. Always clamped to the visible frame with `margin`. Without a field frame, anchored below
    /// the mouse pointer.
    static func origin(for size: CGSize, field: CGRect?, gap: CGFloat, dx: CGFloat = 0, margin: CGFloat = 12) -> CGPoint {
        let anchor = field ?? CGRect(origin: NSEvent.mouseLocation, size: .zero).insetBy(dx: 0, dy: -8)
        let center = CGPoint(x: anchor.midX, y: anchor.midY)
        let screen = NSScreen.screens.first { $0.frame.contains(center) }
            ?? NSScreen.screens.first { $0.frame.intersects(anchor) }
            ?? NSScreen.main
        let visible = screen?.visibleFrame ?? CGRect(x: 0, y: 0, width: 1440, height: 900)

        var y = anchor.minY - gap - size.height
        if y < visible.minY + margin {
            let above = anchor.maxY + gap
            y = above + size.height <= visible.maxY - margin ? above : visible.minY + margin
        }
        var x = anchor.minX + dx
        x = max(visible.minX + margin, min(x, visible.maxX - margin - size.width))
        y = max(visible.minY + margin, min(y, visible.maxY - margin - size.height))
        return CGPoint(x: x, y: y)
    }
}

/// The review keys of a popup window (card, bubble or island, §5.4, §5.10): ⏎ apply all · ⇧⏎ apply this ·
/// ⇥ ignore · ← ↑ previous · → ↓ next · Esc close. A local monitor, so it sees keys only while the popup is
/// key. Keys with ⌃ or ⌥, and any other key, pass through, or go to `forward` when it is set (the island
/// stays key through a review, so it hands typing and ⌘Z on to the target app).
@MainActor
final class PopupKeys {
    var onApplyAll: (() -> Void)?
    var onApplyOne: (() -> Void)?
    var onIgnore: (() -> Void)?
    var onPrevious: (() -> Void)?
    var onNext: (() -> Void)?
    var onClose: (() -> Void)?
    /// A click on the green update badge (§8.10 "Popup badge"); no key reaches it.
    var onUpdate: (() -> Void)?
    /// A click on a pending progress dot: jump to that fix (an index into the session's fixes).
    var onSelect: ((Int) -> Void)?
    /// Receives the key-down and key-up events this handler doesn't use, instead of the popup window.
    var forward: ((NSEvent) -> Void)?

    private var monitor: Any?

    /// Starts handling keys aimed at `window` (a window number).
    func install(for window: @escaping () -> Int) {
        remove()
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .keyUp]) { [weak self] event in
            let handled = MainActor.assumeIsolated { () -> Bool in
                guard let self, event.windowNumber == window() else { return false }
                if event.type == .keyUp {
                    guard let forward = self.forward, !Self.isReviewKey(event) else { return false }
                    forward(event)
                    return true
                }
                if self.handle(key: Int(event.keyCode), flags: event.modifierFlags) { return true }
                guard let forward = self.forward else { return false }
                forward(event)
                return true
            }
            return handled ? nil : event
        }
    }

    func remove() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
    }

    private static func isReviewKey(_ event: NSEvent) -> Bool {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        if flags.contains(.control) || flags.contains(.option) { return false }
        return [36, 76, 48, 53, 123, 124, 125, 126].contains(Int(event.keyCode))
    }

    private func handle(key: Int, flags: NSEvent.ModifierFlags) -> Bool {
        let flags = flags.intersection(.deviceIndependentFlagsMask)
        if flags.contains(.control) || flags.contains(.option) { return false }
        switch key {
        case 36, 76:  // Return, keypad Enter
            if flags.contains(.shift) { onApplyOne?() } else { onApplyAll?() }
        case 48: onIgnore?()  // Tab
        case 53: onClose?()  // Esc
        case 123, 126: onPrevious?()
        case 124, 125: onNext?()
        default: return false
        }
        return true
    }
}

/// VoiceOver announcements from the popups (design_code.md §11). Meboki's panels never take the focus
/// from the user's app, so VoiceOver wouldn't read them by itself; each popup says what it shows when it opens
/// or moves to another fix. Posting costs nothing when VoiceOver is off.
@MainActor
final class Announcer {
    private var last: String?

    /// "{Category}: {original} to {replacement}. {n} of {N}." A deletion says "remove {original}", an
    /// insertion "add {replacement}".
    static func fixText(category: FixCategory, swap: FixSwap, position: Int, pending: Int) -> String {
        let change: String
        if swap.new.isEmpty {
            change = "remove \(swap.old)"
        } else if swap.old.isEmpty {
            change = "add \(swap.new)"
        } else {
            change = "\(swap.old) to \(swap.new)"
        }
        return "\(category.title): \(change). \(position) of \(pending)."
    }

    /// A toast or island message: "No mistakes found." or "5 fixes applied · 1 kept. Command Z undoes".
    static func messageText(title: String, detail: String?) -> String {
        guard let detail, !detail.isEmpty else { return title }
        let spokenDetail = detail.replacingOccurrences(of: "⌘Z", with: "Command Z")
        return title + (title.hasSuffix(".") ? " " : ". ") + spokenDetail
    }

    /// Announces `text` unless it is what this popup said last (the same fix shown again after a relayout).
    func announce(_ text: String, from window: NSWindow) {
        guard text != last else { return }
        last = text
        NSAccessibility.post(element: window, notification: .announcementRequested, userInfo: [
            .announcement: text,
            .priority: NSAccessibilityPriorityLevel.high.rawValue,
        ])
    }

    /// The popup closed: its next opening is announced even when it shows the same fix.
    func reset() { last = nil }
}
