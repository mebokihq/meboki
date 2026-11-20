import AppKit
import MebokiCore
import SwiftUI

// MARK: - Content

/// One fix as the island shows it: category dot and "old → new".
struct IslandFix: Equatable {
    var category: FixCategory
    var swap: FixSwap
}

/// The island's review state (design_code.md §5.6).
struct IslandReview: Equatable {
    var fix: IslandFix
    /// "{Category} · {reason}", or the category alone when Explain each fix is off.
    var reason: String
    /// Up to three other pending fixes, in reading order.
    var upcoming: [IslandFix]
    /// "n/N": the current fix's position among the pending fixes, and the pending count.
    var position: Int
    var pending: Int
    /// A newer Meboki waits (§8.10 "Popup badge"): the pill in the main row, and from day 7 the banner in
    /// the expanded part.
    var update: UpdateNudge.Badge?
}

/// What the island shows: checking (§5.2), review (§5.6), done (§5.7) or a message (§5.8).
enum IslandContent: Equatable {
    case checking(model: String)
    case review(IslandReview)
    case done(title: String, detail: String?)
    case message(kind: MessageKind, title: String, detail: String?, symbol: String?, actionTitle: String?)

    var isReview: Bool {
        if case .review = self { return true }
        return false
    }
}

struct IslandActions {
    var applyAll: () -> Void = {}
    var applyOne: () -> Void = {}
    var skip: () -> Void = {}
    /// A click on the main row: pin the expanded part open, or unpin it.
    var togglePin: () -> Void = {}
    /// The message's pill button.
    var messageAction: () -> Void = {}
    /// The update badge.
    var update: () -> Void = {}
}

/// Hover, pin and appearance state that changes without re-sizing the window.
@MainActor
final class IslandModel: ObservableObject {
    @Published var hovering = false
    @Published var pinned = false
    @Published var shown = false
    var expanded: Bool { hovering || pinned }
}

// MARK: - Views

/// Root of the island window. In review the window is sized for the expanded island (an invisible copy), so
/// the visible one can grow downward inside it without moving the window; its transparent part lets clicks
/// through.
struct IslandRoot: View {
    let content: IslandContent?
    var actions = IslandActions()
    @ObservedObject var model: IslandModel

    var body: some View {
        if let content {
            ZStack(alignment: .top) {
                if content.isReview {
                    IslandView(content: content, expanded: true).hidden()
                }
                IslandView(content: content, expanded: content.isReview && model.expanded, actions: actions,
                           onHover: { [model] in model.hovering = $0 })
                    .modifier(IslandInModifier(active: !model.shown, reduceMotion: DS.Motion.reduceMotion))
            }
        }
    }
}

/// `islandIn`: from scale (0.6, 0.5) and opacity 0; a plain fade with Reduce Motion.
struct IslandInModifier: ViewModifier {
    let active: Bool
    var reduceMotion = false
    func body(content: Content) -> some View {
        content
            .opacity(active ? 0 : 1)
            .scaleEffect(x: active && !reduceMotion ? 0.6 : 1, y: active && !reduceMotion ? 0.5 : 1)
    }
}

/// The island (§5.6): an opaque dark capsule, radius 26, width hugging its content between 380 and 580. In
/// review, the expanded part (reason, next fixes, buttons) slides open below the main row.
struct IslandView: View {
    let content: IslandContent
    var expanded = false
    var actions = IslandActions()
    var onHover: (Bool) -> Void = { _ in }
    @Environment(\.accessibilityDifferentiateWithoutColor) private var withoutColor

    static let minWidth: CGFloat = 380
    static let maxWidth: CGFloat = 580
    private var shape: RoundedRectangle { RoundedRectangle(cornerRadius: DS.Radius.island, style: .continuous) }

    var body: some View {
        IslandStack(reveal: expanded ? 1 : 0, minWidth: Self.minWidth, maxWidth: Self.maxWidth) {
            mainRow
            if case .review(let r) = content {
                IslandMore(review: r, actions: actions)
                    .allowsHitTesting(expanded)
                    .accessibilityHidden(!expanded)
            }
        }
        .animation(DS.Motion.reduceMotion ? nil : DS.Motion.islandExpand, value: expanded)
        .clipShape(shape)
        .background(HUDBackground(shape: shape))
        .contentShape(shape)
        .onHover(perform: onHover)
    }

    @ViewBuilder private var mainRow: some View {
        HStack(spacing: 10) {
            switch content {
            case .checking(let model):
                WaveBars()
                Text("Checking").font(DS.Font.islandStrong).foregroundStyle(DS.hudText)
                Spacer(minLength: 10)
                Text("\(model) · on this Mac").font(DS.Font.link).foregroundStyle(DS.hudSecondary).lineLimit(1)
            case .review(let r):
                reviewRow(r)
            case .done(let title, let detail):
                StatusCircle(kind: .success)
                Text(title).font(DS.Font.islandStrong).foregroundStyle(DS.hudText).lineLimit(1)
                Spacer(minLength: 10)
                if let detail {
                    Text(detail).font(DS.Font.link).foregroundStyle(DS.hudSecondary).lineLimit(1)
                }
            case .message(let kind, let title, let detail, let symbol, let actionTitle):
                StatusCircle(kind: kind, symbol: symbol, fill: kind == .info ? DS.hudInfo : nil)
                messageText(title, detail)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
                if let actionTitle {
                    Button(action: actions.messageAction) { Text(actionTitle) }
                        .buttonStyle(IslandPillStyle(trailing: 10))
                }
            }
        }
        .font(DS.Font.island)
        .padding(EdgeInsets(top: 10, leading: 16, bottom: 10, trailing: 12))
        .frame(minHeight: 48)
        // A click on the main row (outside its button) pins the expanded part open, or closes it.
        .contentShape(Rectangle())
        .onTapGesture { if content.isReview { actions.togglePin() } }
        .accessibilityElement(children: content.isReview ? .contain : .combine)
        // VoiceOver can't hover: this action opens the expanded part (reason, next fixes, Skip, Apply this).
        .accessibilityAction(named: expanded ? "Hide details" : "Show details") {
            if content.isReview { actions.togglePin() }
        }
    }

    @ViewBuilder private func reviewRow(_ r: IslandReview) -> some View {
        Circle()
            .fill(r.fix.category.color)
            .frame(width: 9, height: 9)
            .shadow(color: r.fix.category.color, radius: 5)
            .help(r.fix.category.title)
            .accessibilityHidden(true)
        // The collapsed island marks the category by its dot only; the expanded reason line names it. With
        // Differentiate Without Color on, the name shows here too (§11: never by color alone).
        if withoutColor || DS.A11y.forceDifferentiateWithoutColor {
            Text(r.fix.category.title)
                .font(DS.Font.chip)
                .foregroundStyle(DS.hudSecondary)
                .fixedSize()
                .accessibilityHidden(true)
        }
        IslandSwap(swap: r.fix.swap, font: DS.Font.island, strongFont: DS.Font.islandStrong)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("\(r.fix.category.title): \(Self.spoken(r.fix.swap))")
        Spacer(minLength: 10)
        if let update = r.update { UpdatePill(badge: update, hud: true, action: actions.update) }
        Button(action: r.pending > 1 ? actions.applyAll : actions.applyOne) {
            HStack(spacing: 6) {
                Text(r.pending > 1 ? "Apply all \(r.pending)" : "Apply")
                Kbd("⏎").environment(\.dsOnAccent, true)
            }
        }
        .buttonStyle(IslandPillStyle())
        .dsKeyLabel(r.pending > 1 ? "Apply all \(r.pending) fixes" : "Apply", kbd: "⏎")
        Text("\(r.position)/\(r.pending)")
            .font(.system(size: 12))
            .monospacedDigit()
            .foregroundStyle(DS.hudSecondary)
            .padding(.horizontal, 4)
            .accessibilityLabel("Fix \(r.position) of \(r.pending)")
    }

    private func messageText(_ title: String, _ detail: String?) -> Text {
        var t = Text(title).font(.system(size: 15, weight: .medium)).foregroundColor(DS.hudText)
        if let detail {
            t = t + Text(" · " + detail).font(DS.Font.link).foregroundColor(DS.hudSecondary)
        }
        return t
    }

    static func spoken(_ swap: FixSwap) -> String {
        if swap.new.isEmpty { return "remove “\(swap.old)”" }
        if swap.old.isEmpty { return "add “\(swap.new)”" }
        return "“\(swap.old)” to “\(swap.new)”"
    }
}

/// "old → new": the original struck through in `hudSecondary`, the replacement in `hudText`. A deletion shows
/// only the struck original, an insertion "+ new".
private struct IslandSwap: View {
    let swap: FixSwap
    let font: Font
    let strongFont: Font
    var gap: CGFloat = 10
    /// The main row strikes the original through; the list of next fixes doesn't.
    var strike = true

    var body: some View {
        HStack(spacing: gap) {
            if !swap.old.isEmpty {
                Text(swap.old)
                    .font(font)
                    .strikethrough(strike || swap.new.isEmpty, color: DS.hudSecondary)
                    .foregroundStyle(DS.hudSecondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            if !swap.old.isEmpty, !swap.new.isEmpty {
                Text("→").font(font).foregroundStyle(DS.hudSecondary)
            }
            if !swap.new.isEmpty {
                Text(swap.old.isEmpty ? "+ " + swap.new : swap.new)
                    .font(strongFont)
                    .foregroundStyle(DS.hudText)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .layoutPriority(1)
            }
        }
    }
}

/// The expanded part: reason line, up to three next fixes, and Skip / Apply this / Apply all.
private struct IslandMore: View {
    let review: IslandReview
    let actions: IslandActions
    @Environment(\.accessibilityDifferentiateWithoutColor) private var withoutColor

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(review.reason)
                .font(DS.Font.body)
                .foregroundStyle(DS.hudSecondary)
                .fixedSize(horizontal: false, vertical: true)
            if !review.upcoming.isEmpty {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(Array(review.upcoming.enumerated()), id: \.offset) { _, fix in
                        HStack(spacing: 8) {
                            Circle().fill(fix.category.color).frame(width: 6, height: 6)
                            if withoutColor || DS.A11y.forceDifferentiateWithoutColor {
                                Text(fix.category.title).font(.system(size: 11.5, weight: .semibold))
                                    .foregroundStyle(DS.hudSecondary).fixedSize()
                            }
                            IslandSwap(swap: fix.swap, font: DS.Font.link,
                                       strongFont: .system(size: 12.5, weight: .medium), gap: 5, strike: false)
                        }
                        .padding(.vertical, 1.5)
                        .accessibilityElement(children: .ignore)
                        .accessibilityLabel("Next: \(fix.category.title), \(IslandView.spoken(fix.swap))")
                    }
                }
                .padding(.top, 8)
                .frame(maxWidth: .infinity, alignment: .leading)
                .overlay(alignment: .top) { DSSeparator(color: DS.hudControl, highColor: DS.hudRingHigh) }
            }
            if let update = review.update, update.level == .banner {
                UpdateBanner(badge: update, hud: true, action: actions.update)
            }
            HStack(spacing: 6) {
                Spacer(minLength: 0)
                Button(action: actions.skip) { label("Skip", "⇥") }
                    .buttonStyle(IslandButtonStyle())
                    .dsKeyLabel("Skip", kbd: "⇥")
                if review.pending > 1 {
                    Button(action: actions.applyOne) { label("Apply this", "⇧⏎") }
                        .buttonStyle(IslandButtonStyle())
                        .dsKeyLabel("Apply this fix", kbd: "⇧⏎")
                    Button(action: actions.applyAll) { label("Apply all \(review.pending)", "⏎") }
                        .buttonStyle(IslandButtonStyle(primary: true))
                        .dsKeyLabel("Apply all \(review.pending) fixes", kbd: "⏎")
                } else {
                    Button(action: actions.applyOne) { label("Apply", "⏎") }
                        .buttonStyle(IslandButtonStyle(primary: true))
                        .dsKeyLabel("Apply", kbd: "⏎")
                }
            }
        }
        .padding(EdgeInsets(top: 2, leading: 16, bottom: 14, trailing: 16))
    }

    private func label(_ title: String, _ kbd: String) -> some View {
        HStack(spacing: 6) {
            Text(title)
            Kbd(kbd)
        }
    }
}

/// Lays out the main row and, below it, the expanded part, whose height counts `reveal` (0…1) of its own.
/// `reveal` is animatable, so the island grows and shrinks with the `islandExpand` curve. The width hugs the
/// widest child (the expanded part counts even when closed, as in the HTML), between `minWidth` and `maxWidth`.
struct IslandStack: Layout {
    var reveal: CGFloat
    var minWidth: CGFloat
    var maxWidth: CGFloat

    var animatableData: CGFloat {
        get { reveal }
        set { reveal = newValue }
    }

    private func width(_ subviews: Subviews) -> CGFloat {
        let ideal = subviews.map { $0.sizeThatFits(.unspecified).width }.max() ?? minWidth
        return min(max(ideal, minWidth), maxWidth)
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let w = width(subviews)
        var h: CGFloat = 0
        for (i, s) in subviews.enumerated() {
            let sh = s.sizeThatFits(ProposedViewSize(width: w, height: nil)).height
            h += i == 0 ? sh : sh * min(max(reveal, 0), 1)
        }
        return CGSize(width: w, height: h)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var y = bounds.minY
        for s in subviews {
            let h = s.sizeThatFits(ProposedViewSize(width: bounds.width, height: nil)).height
            s.place(at: CGPoint(x: bounds.minX, y: y), anchor: .topLeading,
                    proposal: ProposedViewSize(width: bounds.width, height: h))
            y += h
        }
    }
}

/// "Checking": four 3 × 16 bars in the brand gradient, scaleY .35 ↔ 1 over 0.9 s, staggered 0.15 s (`wave`).
/// Static with Reduce Motion.
struct WaveBars: View {
    private static let still: [CGFloat] = [0.55, 1, 0.75, 0.45]

    var body: some View {
        let reduce = DS.Motion.reduceMotion
        TimelineView(.animation(paused: reduce)) { ctx in
            let t = ctx.date.timeIntervalSinceReferenceDate
            HStack(spacing: 3) {
                ForEach(0..<4, id: \.self) { i in
                    let phase = (t - Double(i) * DS.Motion.waveStagger) / 0.9
                    let s = reduce ? Self.still[i] : 0.35 + 0.65 * (0.5 - 0.5 * cos(2 * .pi * phase))
                    RoundedRectangle(cornerRadius: 2, style: .continuous)
                        .fill(LinearGradient(colors: [DS.brand2, DS.brand], startPoint: .top, endPoint: .bottom))
                        .frame(width: 3, height: 16)
                        .scaleEffect(x: 1, y: s)
                }
            }
            .frame(height: 16)
        }
        .accessibilityHidden(true)
    }
}

/// The Apply-all pill (and the message button): capsule, brand gradient, white 12.5 pt semibold, padding
/// 4 6 4 10 (4 10 with no keycap).
private struct IslandPillStyle: ButtonStyle {
    var trailing: CGFloat = 6

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(DS.Font.linkStrong)
            .foregroundStyle(DS.onAccent)
            .environment(\.dsOnAccent, true)
            .padding(EdgeInsets(top: 4, leading: 10, bottom: 4, trailing: trailing))
            .frame(minHeight: 26)
            .background(Capsule().fill(DS.brandGradient))
            .contentShape(Capsule())
            .scaleEffect(configuration.isPressed ? 0.97 : 1)
            .opacity(configuration.isPressed ? 0.9 : 1)
    }
}

/// The expanded part's buttons: height 28, padding 0 12, capsule, `hudControl` fill (brand gradient for the
/// primary one), 12.5 pt medium in `hudText`, keycaps on a 14% white fill.
private struct IslandButtonStyle: ButtonStyle {
    var primary = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 12.5, weight: .medium))
            .foregroundStyle(DS.hudText)
            .environment(\.dsKbdFill, DS.hudKbd)
            .padding(.horizontal, 12)
            .frame(height: 28)
            .background {
                if primary { Capsule().fill(DS.brandGradient) } else { Capsule().fill(DS.hudControl) }
            }
            .contentShape(Capsule())
            .scaleEffect(configuration.isPressed ? 0.97 : 1)
            .opacity(configuration.isPressed ? 0.85 : 1)
    }
}

// MARK: - Panel

/// The island window (§5.6): a `KeyPanel` at `.statusBar` level, centered under the menu bar (or the notch)
/// of the screen that holds the target field, 8 pt below it. It shows the checking, review, done and message
/// states. In review it takes the keys (`PopupKeys`) once `makeKey` is called; keys it doesn't use are passed
/// on to the target app (`forwardKeys`), so typing and ⌘Z still reach the field.
@MainActor
final class IslandPanel {
    let keys = PopupKeys()

    private let model = IslandModel()
    private let announcer = Announcer()
    private let hosted: HostedPanel<IslandRoot>
    private var panel: NSPanel { hosted.panel }
    private var content: IslandContent?
    private var actions = IslandActions()
    private var messageAction: (() -> Void)?
    private var timer: Timer?
    private var dismissMonitors: [Any] = []
    /// The screen the island sits on for this session (picked from the field frame).
    private var screen: NSScreen?
    /// Bumped on every show and hide, so a fade or timer from an older state doesn't hide a newer one.
    private var generation = 0
    /// A fade-out is running (`hide`); a new state must stop it, or it would end at alpha 0.
    private var fading = false
    /// The visible shape's size for the current content, to place it again when the displays change.
    private var shapeSize: CGSize?

    init() {
        hosted = HostedPanel(IslandRoot(content: nil, model: model), canBecomeKey: true)
        panel.level = .statusBar
        panel.setAccessibilityLabel("Meboki")
    }

    /// Review callbacks for the buttons (the keys go through `keys`).
    func setActions(applyAll: @escaping () -> Void, applyOne: @escaping () -> Void, skip: @escaping () -> Void) {
        actions.applyAll = { [weak self] in self?.makeKey(); applyAll() }
        actions.applyOne = { [weak self] in self?.makeKey(); applyOne() }
        actions.skip = { [weak self] in self?.makeKey(); skip() }
    }

    var isVisible: Bool { panel.isVisible }
    var isKey: Bool { panel.isKeyWindow }
    var windowNumber: Int { panel.windowNumber }
    var frame: CGRect { panel.frame }

    func showChecking(model name: String, field: CGRect?) {
        present(.checking(model: name), field: field)
    }

    /// Shows the current fix. `makeKey` makes the island take ⏎ ⇧⏎ ⇥ ← → Esc (§5.6 Focus).
    func showReview(_ review: IslandReview, field: CGRect?, makeKey: Bool) {
        present(.review(review), field: field)
        if makeKey { self.makeKey() }
    }

    /// The done state (§5.7): hides after `duration` (fade 0.2 s), on Esc or a click outside.
    func showDone(title: String, detail: String?, field: CGRect?, duration: TimeInterval = 2.8) {
        present(.done(title: title, detail: detail), field: field)
        resignKeys()
        autoHide(after: duration)
    }

    /// A message (§5.8) in the island: hides after `duration`, on Esc or a click outside.
    func showMessage(kind: MessageKind, title: String, detail: String?, symbol: String?, actionTitle: String?,
                     action: (() -> Void)?, field: CGRect?, duration: TimeInterval) {
        messageAction = action
        present(.message(kind: kind, title: title, detail: detail, symbol: symbol,
                         actionTitle: action == nil ? nil : actionTitle), field: field)
        resignKeys()
        autoHide(after: duration)
    }

    /// Makes the island key (review keys) without activating Meboki.
    func makeKey() {
        guard panel.isVisible, content?.isReview == true else { return }
        keys.install { [weak self] in self?.panel.windowNumber ?? -1 }
        panel.makeKey()
    }

    func hide(animated: Bool = true) {
        generation += 1
        let gen = generation
        timer?.invalidate()
        timer = nil
        removeDismissMonitors()
        keys.remove()
        messageAction = nil
        guard panel.isVisible else { return }
        let finish = { [weak self] in
            guard let self, self.generation == gen else { return }
            self.fading = false
            self.panel.orderOut(nil)
            self.panel.alphaValue = 1
            self.model.shown = false
            self.model.pinned = false
            self.model.hovering = false
            self.content = nil
            self.screen = nil
        }
        announcer.reset()
        if !animated || DS.Motion.reduceMotion {
            finish()
            return
        }
        fading = true
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.2
            panel.animator().alphaValue = 0
        }, completionHandler: { MainActor.assumeIsolated { finish() } })
    }

    // MARK: Private

    private func present(_ c: IslandContent, field: CGRect?) {
        generation += 1
        timer?.invalidate()
        timer = nil
        removeDismissMonitors()
        let wasVisible = panel.isVisible
        if !wasVisible {
            model.shown = false
            model.hovering = false
        }
        if !c.isReview { model.pinned = false }
        if field != nil || screen == nil { screen = Self.screen(for: field) }
        content = c
        var acts = actions
        acts.togglePin = { [weak self] in
            guard let self else { return }
            self.makeKey()
            withAnimation(DS.Motion.reduceMotion ? nil : DS.Motion.islandExpand) { self.model.pinned.toggle() }
        }
        acts.update = { [weak self] in self?.keys.onUpdate?() }
        acts.messageAction = { [weak self] in
            let action = self?.messageAction
            self?.hide()
            action?()
        }
        let size = hosted.setRoot(IslandRoot(content: c, actions: acts, model: model))
        shapeSize = size
        hosted.place(shapeOrigin: origin(for: size))
        if fading {
            // Replaces the running fade-out (its completion sees the newer generation and does nothing).
            fading = false
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = 0.01
                panel.animator().alphaValue = 1
            }
        } else {
            panel.alphaValue = 1
        }
        if !wasVisible {
            panel.orderFrontRegardless()
            DispatchQueue.main.async { [weak self] in
                guard let self, self.panel.isVisible, !self.model.shown else { return }
                withAnimation(DS.Motion.islandIn) { self.model.shown = true }
            }
        }
        announce(c)
    }

    /// VoiceOver (§11): the current fix when it changes, the done line and messages. Checking says nothing
    /// (the status item's label says "checking").
    private func announce(_ c: IslandContent) {
        switch c {
        case .checking:
            return
        case .review(let r):
            announcer.announce(Announcer.fixText(category: r.fix.category, swap: r.fix.swap, position: r.position,
                                                 pending: r.pending), from: panel)
        case .done(let title, let detail), .message(_, let title, let detail, _, _):
            announcer.reset()
            announcer.announce(Announcer.messageText(title: title, detail: detail), from: panel)
        }
    }

    /// The displays changed (§12): keep the island under its screen's menu bar, or move it to the screen that
    /// now holds the field (or the pointer) when its own screen is gone.
    func screensChanged(field: CGRect?) {
        guard panel.isVisible, let size = shapeSize else { return }
        if let s = screen, !NSScreen.screens.contains(s) { screen = nil }
        if screen == nil { screen = Self.screen(for: field) }
        hosted.place(shapeOrigin: origin(for: size))
    }

    /// The shape's bottom-left corner: centered under the menu bar (or the notch), its top 8 pt below it.
    private func origin(for size: CGSize) -> CGPoint {
        let s = screen ?? NSScreen.main
        let top = s.map(Self.anchor(on:)) ?? CGPoint(x: 720, y: 860)
        let visible = s?.visibleFrame ?? CGRect(x: 0, y: 0, width: 1440, height: 900)
        var x = top.x - size.width / 2
        x = max(visible.minX + 12, min(x, visible.maxX - 12 - size.width))
        return CGPoint(x: x, y: top.y - size.height)
    }

    /// Top center of the island on `screen`: under the notch on a notched display, else the screen's center,
    /// 8 pt below the menu bar.
    static func anchor(on screen: NSScreen) -> CGPoint {
        let f = screen.frame
        var menuBar = f.maxY - screen.visibleFrame.maxY
        if menuBar <= 0 { menuBar = NSStatusBar.system.thickness }  // menu bar hidden, or none on this screen
        menuBar = max(menuBar, screen.safeAreaInsets.top)
        var x = f.midX
        if let l = screen.auxiliaryTopLeftArea, let r = screen.auxiliaryTopRightArea {
            // The notch lies between the two unobscured top areas (widths only, whatever their origin).
            x = f.minX + (l.width + f.width - r.width) / 2
        }
        return CGPoint(x: x, y: f.maxY - menuBar - 8)
    }

    /// The screen holding `field`'s center, else the one with the pointer.
    private static func screen(for field: CGRect?) -> NSScreen? {
        let p = field.map { CGPoint(x: $0.midX, y: $0.midY) } ?? NSEvent.mouseLocation
        return NSScreen.screens.first { $0.frame.contains(p) }
            ?? field.flatMap { f in NSScreen.screens.first { $0.frame.intersects(f) } }
            ?? NSScreen.main
    }

    private func autoHide(after duration: TimeInterval) {
        let gen = generation
        timer = Timer.scheduledTimer(withTimeInterval: duration, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.generation == gen else { return }
                self.hide()
            }
        }
        // Observe only: Esc and clicks still reach the app under them. Clicks on the island are local events.
        if let m = NSEvent.addGlobalMonitorForEvents(matching: .keyDown, handler: { [weak self] e in
            guard e.keyCode == 53 else { return }
            MainActor.assumeIsolated { self?.hide() }
        }) { dismissMonitors.append(m) }
        if let m = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown], handler: { [weak self] _ in
            MainActor.assumeIsolated { self?.hide() }
        }) { dismissMonitors.append(m) }
    }

    private func removeDismissMonitors() {
        dismissMonitors.forEach { NSEvent.removeMonitor($0) }
        dismissMonitors = []
    }

    /// Done and message states take no keys: give the keyboard back to the app. Ordering a key window out
    /// drops its key status (Meboki is never the active app, so focus returns to the target app); it is
    /// ordered back in the same pass, so nothing flickers.
    private func resignKeys() {
        keys.remove()
        guard panel.isKeyWindow else { return }
        panel.orderOut(nil)
        panel.orderFrontRegardless()
    }
}
