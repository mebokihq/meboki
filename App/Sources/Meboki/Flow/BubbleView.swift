import AppKit
import MebokiCore
import SwiftUI

/// Where the bubble's tip sits: `x` from the bubble's left edge to the tip's square, on the top edge
/// (bubble below the word) or the bottom edge (bubble above it).
struct BubbleTip: Equatable {
    var x: CGFloat = 28
    var above = false
}

struct BubbleActions {
    var applyAll: () -> Void = {}
    var applyOne: () -> Void = {}
    var ignore: () -> Void = {}
    var previous: () -> Void = {}
    var next: () -> Void = {}
    var update: () -> Void = {}
}

/// Root of the bubble window: the bubble for `state`, popping in when `appear.shown` turns true.
struct BubbleRoot: View {
    let state: CardState?
    var tip = BubbleTip()
    var actions = BubbleActions()
    @ObservedObject var appear: AppearModel

    var body: some View {
        if let state {
            AnchoredBubble(state: state, tip: tip, actions: actions)
                .modifier(PopInModifier(active: !appear.shown))
        }
    }
}

/// The anchored bubble (design_code.md §5.5): width 280, padding 12, gap 10, radius 18, glass with the
/// `glassStrong` tint, window shadow, and a tip pointing at the word's center.
struct AnchoredBubble: View {
    let state: CardState
    var tip = BubbleTip()
    var actions = BubbleActions()

    static let width: CGFloat = 280
    private var color: Color { state.category.color }
    private var shape: RoundedRectangle { RoundedRectangle(cornerRadius: DS.Radius.bubble, style: .continuous) }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            topRow
            suggestion
            if let reason = state.reason, !reason.isEmpty {
                Text(reason)
                    .font(DS.Font.body)
                    .foregroundStyle(DS.textSecondary)
                    .lineSpacing(DS.reasonLineSpacing)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let update = state.update, update.level == .banner {
                UpdateBanner(badge: update, compact: true, action: actions.update)
            }
            footer
        }
        .padding(12)
        .frame(width: Self.width, alignment: .leading)
        .background(GlassBackground(shape: shape, tint: DS.glassStrong, popup: true))
        .overlay(alignment: tip.above ? .bottomLeading : .topLeading) {
            BubbleTipView(above: tip.above)
                .offset(x: tip.x, y: tip.above ? 7 : -7)
        }
        .dsShadow(DS.windowShadow)
    }

    /// Category dot and name · spacer · ‹ n/N ›
    private var topRow: some View {
        HStack(spacing: 6) {
            Circle().fill(color).frame(width: 8, height: 8)
            Text(state.category.title).font(DS.Font.chip).foregroundStyle(color)
            // The bubble is 280 wide: "Update" without the version (§8.10 "Popup badge").
            if let update = state.update { UpdatePill(badge: update, compact: true, action: actions.update) }
            Spacer(minLength: 0)
            Button(action: actions.previous) { Text("‹") }
                .buttonStyle(BubbleNavStyle())
                .dsKeyLabel("Previous fix", kbd: "←")
            Text("\(state.position)/\(state.pending)")
                .font(.system(size: 12))
                .monospacedDigit()
                .foregroundStyle(DS.textSecondary)
                .accessibilityLabel("Fix \(state.position) of \(state.pending)")
            Button(action: actions.next) { Text("›") }
                .buttonStyle(BubbleNavStyle())
                .dsKeyLabel("Next fix", kbd: "→")
        }
    }

    /// The replacement on the category color; a click applies only this fix.
    private var suggestion: some View {
        Button(action: actions.applyOne) {
            HStack(spacing: 10) {
                suggestionText
                    .font(DS.Font.bubbleSuggestion)
                    .lineLimit(3)
                    .multilineTextAlignment(.leading)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
                Kbd(state.pending > 1 ? "⇧⏎" : "⏎")
                    .environment(\.dsOnAccent, true)
            }
            .foregroundStyle(DS.onAccent)
            .padding(.vertical, 10)
            .padding(.horizontal, 12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: DS.Radius.suggestion, style: .continuous).fill(color))
            .shadow(color: color.opacity(0.55), radius: 6, x: 0, y: 6)
            .contentShape(RoundedRectangle(cornerRadius: DS.Radius.suggestion, style: .continuous))
        }
        .buttonStyle(BubbleSuggestionStyle())
        .dsKeyLabel(accessibilityText, kbd: state.pending > 1 ? "⇧⏎" : "⏎")
    }

    /// The new text; a deletion shows the old text struck through.
    private var suggestionText: Text {
        if state.swap.new.isEmpty { return Text(state.swap.old).strikethrough(true, color: DS.onAccent) }
        return Text(state.swap.old.isEmpty ? "+ " + state.swap.new : state.swap.new)
    }

    private var footer: some View {
        HStack(spacing: 0) {
            Button(action: actions.ignore) { DSLabel("Ignore", kbd: "⇥") }
                .buttonStyle(DSLinkButtonStyle())
                .dsKeyLabel("Ignore", kbd: "⇥")
            Spacer(minLength: 0)
            if state.pending > 1 {
                Button(action: actions.applyAll) { DSLabel("Fix all \(state.pending)", kbd: "⏎") }
                    .buttonStyle(DSLinkButtonStyle(strong: true))
                    .dsKeyLabel("Fix all \(state.pending)", kbd: "⏎")
            }
        }
    }

    private var accessibilityText: String {
        if state.swap.new.isEmpty { return "Remove “\(state.swap.old)”" }
        if state.swap.old.isEmpty { return "Add “\(state.swap.new)”" }
        return "Replace “\(state.swap.old)” with “\(state.swap.new)”"
    }
}

/// The tip: a 14 × 14 square turned 45° with a 3 pt radius on its outer corner, half outside the bubble,
/// filled like the bubble, with a 0.5 pt `edge` line on its two outer sides. With Increase Contrast (or Reduce
/// Transparency) the bubble is a solid `window` fill, and so is the tip, with a 1 pt `separatorHigh` line.
private struct BubbleTipView: View {
    let above: Bool
    @Environment(\.colorSchemeContrast) private var contrast
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.dsPopupOpacity) private var opacityOverride

    var body: some View {
        let high = contrast.isIncreased
        let solid = high || reduceTransparency
        let o = opacityOverride ?? DS.popupOpacity
        let shape = UnevenRoundedRectangle(topLeadingRadius: above ? 0 : 3, bottomTrailingRadius: above ? 3 : 0,
                                           style: .continuous)
        // A plain `glassStrong` fill (86–88% opaque), no blur: an `NSVisualEffectView` measured inside this
        // overlay trips an AppKit layout assertion, and the blur would barely show through anyway. It follows
        // the popup opacity like the bubble's glass (`DS.popupGlass`, `DS.popupSolid`).
        ZStack {
            if solid {
                shape.fill(DS.window)
            } else {
                // The tip has no blur, so its tint alone covers what the bubble's blur and tint cover together.
                let g = DS.popupGlass(o)
                shape.fill(DS.glassStrong).opacity(g < 1 ? min(1, g / max(0.01, DS.alpha(of: DS.glassStrong))) : 1)
                shape.fill(DS.window.opacity(DS.popupSolid(o)))
            }
            TipEdges(above: above).stroke(high ? DS.separatorHigh : DS.edge, lineWidth: high ? 1 : 0.5)
        }
        .frame(width: 14, height: 14)
        .rotationEffect(.degrees(45))
        // Only the half outside the bubble (plus a hair, to cover the bubble's edge line): the inner half
        // would show the tip's own glass over the bubble's.
        .clipShape(OutsideHalf(above: above))
        .accessibilityHidden(true)
    }
}

/// The part of the tip's 14 × 14 frame beyond the bubble's edge (its center line), with 0.75 pt overlap.
private struct OutsideHalf: Shape {
    let above: Bool
    func path(in r: CGRect) -> Path {
        let overlap: CGFloat = 0.75, reach: CGFloat = 4
        return Path(above
            ? CGRect(x: r.minX - reach, y: r.midY - overlap, width: r.width + 2 * reach, height: r.height / 2 + overlap + reach)
            : CGRect(x: r.minX - reach, y: r.minY - reach, width: r.width + 2 * reach, height: r.height / 2 + overlap + reach))
    }
}

/// The two outer sides of the tip before rotation: top and left (pointing up), or bottom and right.
private struct TipEdges: Shape {
    let above: Bool
    func path(in r: CGRect) -> Path {
        var p = Path()
        let radius: CGFloat = 3
        if above {
            p.move(to: CGPoint(x: r.maxX, y: r.minY))
            p.addLine(to: CGPoint(x: r.maxX, y: r.maxY - radius))
            p.addQuadCurve(to: CGPoint(x: r.maxX - radius, y: r.maxY), control: CGPoint(x: r.maxX, y: r.maxY))
            p.addLine(to: CGPoint(x: r.minX, y: r.maxY))
        } else {
            p.move(to: CGPoint(x: r.minX, y: r.maxY))
            p.addLine(to: CGPoint(x: r.minX, y: r.minY + radius))
            p.addQuadCurve(to: CGPoint(x: r.minX + radius, y: r.minY), control: CGPoint(x: r.minX, y: r.minY))
            p.addLine(to: CGPoint(x: r.maxX, y: r.minY))
        }
        return p
    }
}

/// ‹ › : 22 × 22, radius 6, 16 pt glyph in `textSecondary`, `hover` fill on hover.
private struct BubbleNavStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        NavBody(configuration: configuration)
    }

    private struct NavBody: View {
        let configuration: Configuration
        @State private var hovering = false
        var body: some View {
            configuration.label
                .font(.system(size: 16))
                .foregroundStyle(DS.textSecondary)
                .frame(width: 22, height: 22)
                .background(RoundedRectangle(cornerRadius: DS.Radius.link, style: .continuous)
                    .fill(hovering ? DS.hover : Color.clear))
                .opacity(configuration.isPressed ? 0.7 : 1)
                .contentShape(Rectangle())
                .onHover { hovering = $0 }
        }
    }
}

/// The suggestion button: brightness up on hover (CSS `brightness(1.06)`), slight press scale.
private struct BubbleSuggestionStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        SuggestionBody(configuration: configuration)
    }

    private struct SuggestionBody: View {
        let configuration: Configuration
        @State private var hovering = false
        var body: some View {
            configuration.label
                .brightness(hovering ? 0.04 : 0)
                .scaleEffect(configuration.isPressed ? 0.98 : 1)
                .onHover { hovering = $0 }
        }
    }
}

/// The bubble window: the same non-activating `KeyPanel` as the card, with the same keys (§5.5).
@MainActor
final class BubblePanel {
    let keys = PopupKeys()

    private let appear = AppearModel()
    private let announcer = Announcer()
    private let hosted: HostedPanel<BubbleRoot>
    private var panel: NSPanel { hosted.panel }

    init() {
        hosted = HostedPanel(BubbleRoot(state: nil, appear: appear), canBecomeKey: true)
        hosted.panel.setAccessibilityLabel("Meboki fix")
    }

    private var actions: BubbleActions {
        BubbleActions(applyAll: { [weak self] in self?.keys.onApplyAll?() },
                      applyOne: { [weak self] in self?.keys.onApplyOne?() },
                      ignore: { [weak self] in self?.keys.onIgnore?() },
                      previous: { [weak self] in self?.keys.onPrevious?() },
                      next: { [weak self] in self?.keys.onNext?() },
                      update: { [weak self] in self?.keys.onUpdate?() })
    }

    var isVisible: Bool { panel.isVisible }
    var windowNumber: Int { panel.windowNumber }
    var frame: CGRect { panel.frame }

    /// Shows `state` pointing at `word` (§5.5): left edge at the word's center − 56, 12 pt below the word, or
    /// above it when there's no room; the tip points at the word's center. Pops in when it wasn't visible,
    /// slides when it was. `makeKey: false` only for the DEBUG demo.
    func show(_ state: CardState, word: CGRect, makeKey: Bool = true) {
        let wasVisible = panel.isVisible
        if !wasVisible { appear.shown = false }
        var tip = BubbleTip()
        let size = hosted.setRoot(BubbleRoot(state: state, tip: tip, actions: actions, appear: appear))
        let origin = PanelGeometry.origin(for: size, field: word, gap: 12, dx: word.width / 2 - 56)
        tip.above = origin.y > word.midY
        tip.x = max(14, min(word.midX - origin.x - 7, size.width - 28))
        hosted.setRoot(BubbleRoot(state: state, tip: tip, actions: actions, appear: appear))
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
