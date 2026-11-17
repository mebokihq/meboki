import AppKit
import SwiftUI

/// The menu-bar status item (design_code.md §6). A left-click calls `onLeftClick` (the popover); a right-click
/// or Control-click pops up `menu` (the debug items). The icon shows four states:
/// - idle: the template `text.badge.checkmark`,
/// - checking: `menuPulse` plus a 6 pt brand dot top-right with a 1.5 pt ring in the menu-bar text color,
/// - open (popover showing): the system highlight,
/// - paused in the frontmost app: the dot turns `catPunctuation`, no pulse.
@MainActor
final class StatusItem: NSObject {
    var onLeftClick: (() -> Void)?
    /// Called right before the right-click menu opens (refresh its items, close the popover).
    var onMenuWillOpen: (() -> Void)?
    let menu: NSMenu

    private let item: NSStatusItem
    private var dot: NSView?
    private var appearanceObservation: NSKeyValueObservation?

    /// A check is running.
    var isChecking = false { didSet { if isChecking != oldValue { update() } } }
    /// Checks are paused in the frontmost app.
    var isPaused = false { didSet { if isPaused != oldValue { update() } } }
    /// The popover is showing.
    var isOpen = false { didSet { if isOpen != oldValue { updateHighlight() } } }

    init(menu: NSMenu) {
        self.menu = menu
        item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        super.init()
        guard let button = item.button else { return }
        button.image = NSImage(systemSymbolName: "text.badge.checkmark", accessibilityDescription: "Meboki")
        button.image?.isTemplate = true
        button.target = self
        button.action = #selector(clicked)
        // The popover opens on mouse-down, as Control Center does. The menu opens on right mouse-up, through
        // the status item's own menu path (`NSMenu.popUp(positioning:at:in:)` would activate Meboki).
        button.sendAction(on: [.leftMouseDown, .rightMouseUp])
        button.wantsLayer = true
        button.setAccessibilityLabel("Meboki")
        button.setAccessibilityHelp("Click for controls. Right-click for the debug menu.")
        // The menu bar turns light or dark with the wallpaper: the dot's ring follows the menu-bar text color.
        appearanceObservation = button.observe(\.effectiveAppearance) { [weak self] _, _ in
            DispatchQueue.main.async { self?.update() }
        }
    }

    var button: NSStatusBarButton? { item.button }

    /// Settings › General › Show in menu bar.
    var isVisible: Bool {
        get { item.isVisible }
        set { item.isVisible = newValue }
    }

    /// The status item's frame on screen (the button's window spans the menu-bar height).
    var screenFrame: CGRect? {
        guard let button, let window = button.window else { return nil }
        return window.convertToScreen(button.convert(button.bounds, to: nil))
    }

    var screen: NSScreen? { item.button?.window?.screen }

    /// Shows the tooltip while a check runs ("Checking paragraph 2 of 3…").
    func setToolTip(_ text: String?) { item.button?.toolTip = text }

    @objc private func clicked() {
        let event = NSApp.currentEvent
        let right = event?.type == .rightMouseUp
            || (event?.type == .leftMouseDown && event?.modifierFlags.contains(.control) == true)
        if right {
            showMenu()
        } else {
            onLeftClick?()
            updateHighlight()
        }
    }

    /// Opens the debug menu under the icon. With `item.menu` set, a click on the button shows the menu the
    /// system way (placement, highlight, no activation); `performClick` returns when the menu closes.
    func showMenu() {
        guard let button = item.button else { return }
        onMenuWillOpen?()
        item.menu = menu
        button.performClick(nil)
        item.menu = nil
        updateHighlight()
    }

    /// The button highlights itself while the mouse is down and clears it on mouse-up, so the popover's
    /// pressed look is set again once that tracking is over (default run-loop mode, after mouse-up).
    private func updateHighlight() {
        item.button?.highlight(isOpen)
        RunLoop.main.perform(inModes: [.default]) { [weak self] in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.item.button?.highlight(self.isOpen)
            }
        }
    }

    private func update() {
        guard let button = item.button else { return }
        let showDot = isChecking || isPaused
        if showDot {
            let d = dot ?? makeDot(in: button)
            let b = button.bounds
            // HTML: a 6 pt dot at right 3, top 2 of the icon box, plus a 1.5 pt ring outside it.
            let size: CGFloat = 9
            d.frame = CGRect(x: b.maxX - 3 - 6 - 1.5, y: button.isFlipped ? 2 - 1.5 : b.maxY - 2 - 6 - 1.5,
                             width: size, height: size)
            button.effectiveAppearance.performAsCurrentDrawingAppearance {
                d.layer?.backgroundColor = NSColor.labelColor.cgColor
                d.layer?.sublayers?.first?.backgroundColor = NSColor(isChecking ? DS.brand : DS.catPunctuation).cgColor
            }
        } else {
            dot?.removeFromSuperview()
            dot = nil
        }
        if isChecking, !DS.Motion.reduceMotion {
            if button.layer?.animation(forKey: "menuPulse") == nil {
                let pulse = CABasicAnimation(keyPath: "opacity")
                pulse.fromValue = 1
                pulse.toValue = 0.35
                pulse.duration = 0.5
                pulse.autoreverses = true
                pulse.repeatCount = .infinity
                pulse.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
                button.layer?.add(pulse, forKey: "menuPulse")
            }
        } else {
            button.layer?.removeAnimation(forKey: "menuPulse")
        }
        var label = "Meboki"
        if isChecking { label += ", checking" } else if isPaused { label += ", paused in this app" }
        button.setAccessibilityLabel(label)
    }

    private func makeDot(in button: NSView) -> NSView {
        let ring = NSView(frame: CGRect(x: 0, y: 0, width: 9, height: 9))
        ring.wantsLayer = true
        ring.layer?.cornerRadius = 4.5
        let fill = CALayer()
        fill.frame = CGRect(x: 1.5, y: 1.5, width: 6, height: 6)
        fill.cornerRadius = 3
        ring.layer?.addSublayer(fill)
        button.addSubview(ring)
        dot = ring
        return ring
    }
}
