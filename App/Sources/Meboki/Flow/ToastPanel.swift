import AppKit
import SwiftUI

/// One toast: the done line (§5.7) or a message (§5.8).
struct ToastContent {
    var kind: MessageKind
    var title: String
    var detail: String?
    var symbol: String?
    var actionTitle: String?
    var action: (() -> Void)?
    /// Done 2.8 s, messages 4 s (§5.7, §5.8).
    var duration: TimeInterval = 4
}

/// Root of the toast window. The action button runs the action, then dismisses the toast.
struct ToastRoot: View {
    let content: ToastContent?
    var dismiss: () -> Void = {}
    @ObservedObject var appear: AppearModel

    var body: some View {
        if let c = content {
            ToastView(kind: c.kind, title: c.title, detail: c.detail, symbol: c.symbol,
                      actionTitle: c.actionTitle,
                      action: c.action.map { action in { action(); dismiss() } })
                .modifier(PopInModifier(active: !appear.shown))
        }
    }
}

/// A glass toast below the field frame (14 pt gap, left-aligned with the field; above it when there's no
/// room). Never becomes key, so the user can keep typing. Hides after its duration, on Esc, or on a click
/// outside.
@MainActor
final class ToastPanel {
    private let appear = AppearModel()
    private let announcer = Announcer()
    private let hosted: HostedPanel<ToastRoot>
    private var panel: NSPanel { hosted.panel }
    private var timer: Timer?
    private var keyMonitor: Any?
    private var mouseMonitor: Any?
    /// Bumped on every show and hide, so a fade or timer from an older toast doesn't hide a newer one.
    private var generation = 0

    init() {
        hosted = HostedPanel(ToastRoot(content: nil, appear: appear), canBecomeKey: false)
        hosted.panel.setAccessibilityLabel("Meboki message")
    }

    var isVisible: Bool { panel.isVisible }
    var windowNumber: Int { panel.windowNumber }
    var frame: CGRect { panel.frame }

    func show(_ content: ToastContent, field: CGRect?) {
        generation += 1
        let gen = generation
        let wasVisible = panel.isVisible
        if !wasVisible { appear.shown = false }
        let root = ToastRoot(content: content, dismiss: { [weak self] in self?.hide() }, appear: appear)
        let size = hosted.setRoot(root)
        hosted.place(shapeOrigin: PanelGeometry.origin(for: size, field: field, gap: 14))
        panel.alphaValue = 1
        if !wasVisible {
            panel.orderFrontRegardless()
            DispatchQueue.main.async { [weak self] in
                guard let self, self.generation == gen else { return }
                withAnimation(DS.Motion.popIn) { self.appear.shown = true }
            }
        }
        installMonitors()
        announcer.reset()
        announcer.announce(Announcer.messageText(title: content.title, detail: content.detail), from: panel)
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: content.duration, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.generation == gen else { return }
                self.hide()
            }
        }
    }

    /// Fades out over 0.2 s (instant with Reduce Motion, or when `animated` is false).
    func hide(animated: Bool = true) {
        generation += 1
        let gen = generation
        timer?.invalidate()
        timer = nil
        removeMonitors()
        guard panel.isVisible else { return }
        if !animated || DS.Motion.reduceMotion {
            panel.orderOut(nil)
            appear.shown = false
            return
        }
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.2
            panel.animator().alphaValue = 0
        }, completionHandler: { [weak self] in
            MainActor.assumeIsolated {
                guard let self, self.generation == gen else { return }
                self.panel.orderOut(nil)
                self.panel.alphaValue = 1
                self.appear.shown = false
            }
        })
    }

    private func installMonitors() {
        removeMonitors()
        // Observe only: Esc and clicks still reach the app under them. Clicks on the toast itself are local
        // events, so they never reach this global monitor.
        keyMonitor = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard event.keyCode == 53 else { return }
            MainActor.assumeIsolated { self?.hide() }
        }
        mouseMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            MainActor.assumeIsolated { self?.hide() }
        }
    }

    private func removeMonitors() {
        if let m = keyMonitor { NSEvent.removeMonitor(m) }
        if let m = mouseMonitor { NSEvent.removeMonitor(m) }
        keyMonitor = nil
        mouseMonitor = nil
    }
}
