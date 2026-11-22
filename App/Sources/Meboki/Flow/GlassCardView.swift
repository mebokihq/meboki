import AppKit
import MebokiCore
import SwiftUI

extension FixCategory {
    /// Category color (§2.1). Never the brand color.
    var color: Color { color(in: DS.palette) }

    /// The category color in a given tone (Settings › Appearance swatches).
    func color(in p: DS.Palette) -> Color {
        switch self {
        case .spelling: p.catSpelling
        case .grammar: p.catGrammar
        case .clarity: p.catClarity
        case .punctuation: p.catPunctuation
        case .rewrite: p.catRewrite
        }
    }
}

/// Everything the glass card shows for the current fix (design_code.md §5.4).
struct CardState: Equatable {
    var category: FixCategory
    var swap: FixSwap
    /// Nil hides the reason line (Settings › Writing › Explain each fix, from stage 5 on).
    var reason: String?
    /// One dot per fix in the session.
    var dots: [ProgressDots.Dot]
    /// "n of N": the current fix's position among the pending fixes, and the pending count.
    var position: Int
    var pending: Int
    /// "On this Mac · Gemma 4 E4B · 0.8 s", or "OpenRouter · Claude Haiku 5.5 · 0.8 s" in cloud mode.
    var footer: String
    /// A cloud model checked the text: the footer shows a cloud instead of the lock.
    var cloud = false
    /// A newer Meboki waits (§8.10 "Popup badge"): the green pill, and from day 7 the banner.
    var update: UpdateNudge.Badge?
}

struct CardActions {
    var applyAll: () -> Void = {}
    var applyOne: () -> Void = {}
    var ignore: () -> Void = {}
    var update: () -> Void = {}
    /// A click on a pending progress dot: make fix `index` (into the session's fixes) current.
    var select: (Int) -> Void = { _ in }
}

/// Root of the card window: the card for `state`, popping in when `appear.shown` turns true.
struct GlassCardRoot: View {
    let state: CardState?
    var actions = CardActions()
    @ObservedObject var appear: AppearModel

    var body: some View {
        if let state {
            GlassCard(state: state, actions: actions)
                .modifier(PopInModifier(active: !appear.shown))
        }
    }
}

/// The glass card: width 420, padding 16 16 12, gap 12, radius 22, glass material and window shadow.
struct GlassCard: View {
    let state: CardState
    var actions = CardActions()

    /// Above this many fixes the dots would crowd the header; the "n of N" count stays.
    static let maxDots = 14
    static let maxDotsWithUpdate = 8

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
            SwapLine(swap: state.swap, color: state.category.color)
            if let reason = state.reason, !reason.isEmpty {
                Text(reason)
                    .font(DS.Font.body)
                    .foregroundStyle(DS.textSecondary)
                    .lineSpacing(DS.reasonLineSpacing)
                    .fixedSize(horizontal: false, vertical: true)
            }
            buttons.padding(.top, 2)
            // From day 7 the update banner takes the footer's place (§8.10 "Popup badge").
            if let update = state.update, update.level == .banner {
                UpdateBanner(badge: update, action: actions.update)
            } else {
                VStack(alignment: .leading, spacing: 10) {
                    DSSeparator()
                    PrivacyLine(text: state.footer, symbol: state.cloud ? "cloud" : "lock")
                }
            }
        }
        .padding(EdgeInsets(top: 16, leading: 16, bottom: 12, trailing: 16))
        .frame(width: 420, alignment: .leading)
        .background(GlassBackground(shape: RoundedRectangle(cornerRadius: DS.Radius.card, style: .continuous),
                                    popup: true))
        .dsShadow(DS.windowShadow)
    }

    private var header: some View {
        HStack(spacing: 10) {
            CategoryChip(title: state.category.title, color: state.category.color)
            if let update = state.update { UpdatePill(badge: update, action: actions.update) }
            Spacer(minLength: 0)
            // The pill takes room from the dots.
            if state.dots.count <= (state.update == nil ? Self.maxDots : Self.maxDotsWithUpdate) {
                ProgressDots(dots: state.dots, onSelect: actions.select)
            }
            Text("\(state.position) of \(state.pending)")
                .font(.system(size: 12))
                .monospacedDigit()
                .foregroundStyle(DS.textSecondary)
                .accessibilityLabel("Fix \(state.position) of \(state.pending)")
        }
    }

    @ViewBuilder private var buttons: some View {
        HStack(spacing: 8) {
            Button(action: actions.ignore) { DSLabel("Ignore", kbd: "⇥") }.buttonStyle(.dsGhost)
                .dsKeyLabel("Ignore", kbd: "⇥")
            Spacer(minLength: 0)
            if state.pending > 1 {
                Button(action: actions.applyOne) { DSLabel("Apply", kbd: "⇧⏎") }.buttonStyle(.dsSecondary)
                    .dsKeyLabel("Apply this fix", kbd: "⇧⏎")
                Button(action: actions.applyAll) { DSLabel("Apply all \(state.pending)", kbd: "⏎") }.buttonStyle(.dsPrimary)
                    .dsKeyLabel("Apply all \(state.pending) fixes", kbd: "⏎")
            } else {
                Button(action: actions.applyOne) { DSLabel("Apply", kbd: "⏎") }.buttonStyle(.dsPrimary)
                    .dsKeyLabel("Apply", kbd: "⏎")
            }
        }
    }
}

/// "tomorow → tomorrow": original 24 pt medium, struck through; arrow; replacement 24 pt semibold in the
/// category color on a 12% fill. A deletion shows only the struck original, an insertion "+ word".
/// Long rewrites drop to 17 pt and stack.
private struct SwapLine: View {
    let swap: FixSwap
    let color: Color

    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 12) { parts(size: 24, arrow: 20) }
                .fixedSize()
            VStack(alignment: .leading, spacing: 8) {
                if !swap.old.isEmpty { old(size: 17).lineLimit(4) }
                if !swap.new.isEmpty {
                    HStack(alignment: .firstTextBaseline, spacing: 10) {
                        if !swap.old.isEmpty { arrow(14) }
                        new(size: 17).lineLimit(6)
                    }
                }
            }
            .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.vertical, 4)
        .padding(.horizontal, 2)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityText)
    }

    @ViewBuilder private func parts(size: CGFloat, arrow arrowSize: CGFloat) -> some View {
        if !swap.old.isEmpty { old(size: size) }
        if !swap.old.isEmpty, !swap.new.isEmpty { arrow(arrowSize) }
        if !swap.new.isEmpty { new(size: size) }
    }

    private func old(size: CGFloat) -> some View {
        Text(swap.old)
            .font(.system(size: size, weight: .medium))
            .foregroundStyle(DS.textSecondary)
            .strikethrough(true, color: DS.catSpelling)
    }

    private func arrow(_ size: CGFloat) -> some View {
        Image(systemName: "arrow.right")
            .font(.system(size: size * 0.85, weight: .medium))
            .foregroundStyle(DS.textTertiary)
    }

    private func new(size: CGFloat) -> some View {
        Text(swap.old.isEmpty ? "+ " + swap.new : swap.new)
            .font(.system(size: size, weight: .semibold))
            .foregroundStyle(color)
            .padding(.vertical, 2)
            .padding(.horizontal, 10)
            .background(RoundedRectangle(cornerRadius: DS.Radius.highlight, style: .continuous).fill(color.opacity(0.12)))
    }

    private var accessibilityText: String {
        if swap.new.isEmpty { return "Remove “\(swap.old)”" }
        if swap.old.isEmpty { return "Add “\(swap.new)”" }
        return "Replace “\(swap.old)” with “\(swap.new)”"
    }
}

/// The card window: a non-activating `KeyPanel` that becomes key, so ⏎ ⇧⏎ ⇥ ← → Esc reach it while the
/// target app stays frontmost. It sits under the clicked word (§5.4), or below the field frame in the
/// no-bounds fallback. Clicks outside it are handled by the review session (`FieldWatcher`), not here.
@MainActor
final class CardPanel {
    /// Key and button handlers (set by `PopupController`).
    let keys = PopupKeys()

    private let appear = AppearModel()
    private let announcer = Announcer()
    private let hosted: HostedPanel<GlassCardRoot>
    private var panel: NSPanel { hosted.panel }

    init() {
        hosted = HostedPanel(GlassCardRoot(state: nil, appear: appear), canBecomeKey: true)
        hosted.panel.setAccessibilityLabel("Meboki fix")
    }

    private var actions: CardActions {
        CardActions(applyAll: { [weak self] in self?.keys.onApplyAll?() },
                    applyOne: { [weak self] in self?.keys.onApplyOne?() },
                    ignore: { [weak self] in self?.keys.onIgnore?() },
                    update: { [weak self] in self?.keys.onUpdate?() },
                    select: { [weak self] i in self?.keys.onSelect?(i) })
    }

    var isVisible: Bool { panel.isVisible }
    var isKey: Bool { panel.isKeyWindow }
    var windowNumber: Int { panel.windowNumber }
    var frame: CGRect { panel.frame }

    /// Shows `state` under `word` (§5.4: left edge 16 pt left of the word, top 10 pt below it; above the word
    /// when there's no room), or below `field` when there is no word rect (the fallback). Pops in when it
    /// wasn't visible; when it was, it slides to the new position without popping again.
    /// `makeKey: false` only for the DEBUG `--demo-popups` mode, which must not take the keyboard.
    func show(_ state: CardState, field: CGRect?, word: CGRect? = nil, makeKey: Bool = true) {
        let wasVisible = panel.isVisible
        if !wasVisible { appear.shown = false }
        let size = hosted.setRoot(GlassCardRoot(state: state, actions: actions, appear: appear))
        let origin = word.map { PanelGeometry.origin(for: size, field: $0, gap: 10, dx: -16) }
            ?? PanelGeometry.origin(for: size, field: field, gap: 10)
        hosted.place(shapeOrigin: origin, animated: wasVisible && !DS.Motion.reduceMotion)
        if !wasVisible {
            panel.alphaValue = 1
            panel.orderFrontRegardless()
            if makeKey { keys.install { [weak self] in self?.panel.windowNumber ?? -1 } }
            DispatchQueue.main.async { [weak self] in
                withAnimation(DS.Motion.popIn) { self?.appear.shown = true }
            }
        }
        if makeKey { panel.makeKey() }
        announcer.announce(Announcer.fixText(category: state.category, swap: state.swap, position: state.position,
                                             pending: state.pending), from: panel)
    }

    func hide() {
        keys.remove()
        panel.orderOut(nil)
        appear.shown = false
        announcer.reset()
    }
}
