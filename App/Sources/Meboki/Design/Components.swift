import SwiftUI

// Shared components from design_code.md §4. Build every screen from these; values come from DS tokens.

extension EnvironmentValues {
    /// True inside a gradient or colored button: keycaps switch to a translucent white fill at full opacity.
    @Entry var dsOnAccent = false
    /// Overrides the keycap fill (at full opacity), e.g. `DS.hudKbd` on the island's dark buttons.
    @Entry var dsKbdFill: Color? = nil
}

// MARK: - Keycap

/// Keycap: 11 pt medium, padding 3 × 5, radius 5. Glyphs: ⏎ ⇧⏎ ⇥ ⌘⏎ ⌃⌥G ← → Esc.
struct Kbd: View {
    let glyph: String
    var font: Font = DS.Font.kbd
    @Environment(\.dsOnAccent) private var onAccent
    @Environment(\.dsKbdFill) private var fillOverride
    @Environment(\.colorSchemeContrast) private var contrast

    init(_ glyph: String, font: Font = DS.Font.kbd) {
        self.glyph = glyph
        self.font = font
    }

    var body: some View {
        Text(glyph)
            .font(font)
            .lineLimit(1)
            .fixedSize()
            .padding(.vertical, 3)
            .padding(.horizontal, 5)
            .background(RoundedRectangle(cornerRadius: DS.Radius.kbd, style: .continuous)
                .fill(fillOverride ?? (onAccent ? DS.kbdOnAccent : DS.control)))
            .opacity(onAccent || fillOverride != nil || contrast.isIncreased ? 1 : 0.8)
            .accessibilityHidden(true)
    }

    /// The keys as VoiceOver should say them (§11): "⇧⏎" → "Shift Return", "⌃⌥G" → "Control Option G".
    /// The keycap itself is hidden from VoiceOver; the button's label carries the key instead.
    static func spoken(_ glyphs: String) -> String {
        let names: [Character: String] = [
            "⌃": "Control", "⌥": "Option", "⇧": "Shift", "⌘": "Command", "⏎": "Return", "↩": "Return",
            "⌤": "Enter", "⇥": "Tab", "⌫": "Delete", "⌦": "Forward Delete", "⎋": "Escape", "←": "Left Arrow",
            "→": "Right Arrow", "↑": "Up Arrow", "↓": "Down Arrow", ",": "Comma", ".": "Period", "/": "Slash",
            ";": "Semicolon", "'": "Quote", "[": "Left Bracket", "]": "Right Bracket", "\\": "Backslash",
            "-": "Minus", "=": "Equals", "`": "Grave Accent",
        ]
        if glyphs == "Esc" { return "Escape" }
        var words: [String] = []
        var rest = ""
        for c in glyphs {
            if c == " " {
                if !rest.isEmpty { words.append(rest); rest = "" }
            } else if let name = names[c] {
                if !rest.isEmpty { words.append(rest); rest = "" }
                words.append(name)
            } else {
                rest.append(c)
            }
        }
        if !rest.isEmpty { words.append(rest == "Esc" ? "Escape" : rest) }
        return words.joined(separator: " ")
    }
}

extension View {
    /// VoiceOver label for a button that shows a keycap: "Apply all 6 fixes, Return" (§11).
    func dsKeyLabel(_ title: String, kbd: String?) -> some View {
        accessibilityLabel(kbd.map { "\(title), \(Kbd.spoken($0))" } ?? title)
    }
}

/// Button content: optional SF Symbol, title, optional trailing keycap (gap 7). The keycap is hidden from
/// VoiceOver, so a button with one sets its label with `dsKeyLabel` ("Ignore, Tab", §11).
struct DSLabel: View {
    let title: String
    var systemImage: String?
    var kbd: String?

    init(_ title: String, systemImage: String? = nil, kbd: String? = nil) {
        self.title = title
        self.systemImage = systemImage
        self.kbd = kbd
    }

    var body: some View {
        HStack(spacing: 7) {
            if let systemImage { Image(systemName: systemImage).fontWeight(.semibold).accessibilityHidden(true) }
            Text(title)
            if let kbd { Kbd(kbd) }
        }
    }
}

// MARK: - Buttons

/// Capsule buttons: primary (brand gradient), secondary (`control`), ghost (transparent, `hover` on hover).
/// Height 30 / padding 14 / 13 pt medium; small: 26 / 11 / 12 pt. Pressed scale .97, hover brightness .96.
struct DSButtonStyle: ButtonStyle {
    enum Kind { case primary, secondary, ghost }
    var kind: Kind = .secondary
    var small = false

    func makeBody(configuration: Configuration) -> some View {
        DSButtonBody(configuration: configuration, kind: kind, small: small)
    }
}

private struct DSButtonBody: View {
    let configuration: ButtonStyleConfiguration
    let kind: DSButtonStyle.Kind
    let small: Bool
    @State private var hovering = false
    @Environment(\.isEnabled) private var isEnabled

    var body: some View {
        configuration.label
            .font(small ? DS.Font.small : DS.Font.bodyMedium)
            .lineLimit(1)
            .foregroundStyle(kind == .primary ? DS.onAccent : DS.text)
            .padding(.horizontal, small ? 11 : 14)
            .frame(height: small ? 26 : 30)
            .background { background }
            .environment(\.dsOnAccent, kind == .primary)
            .brightness(hovering && isEnabled && kind != .ghost ? -0.04 : 0)
            .scaleEffect(configuration.isPressed && isEnabled ? 0.97 : 1)
            .opacity(isEnabled ? 1 : 0.4)
            .contentShape(Capsule())
            .onHover { hovering = $0 }
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
            .animation(.easeOut(duration: 0.12), value: hovering)
    }

    @ViewBuilder private var background: some View {
        switch kind {
        case .primary:
            Capsule().fill(DS.brandGradient)
                .overlay(InnerTopHighlight(shape: Capsule(), color: DS.primaryHighlight))
                .dsShadow(DS.primaryShadow)
        case .secondary:
            Capsule().fill(DS.control)
        case .ghost:
            Capsule().fill(hovering && isEnabled ? DS.hover : Color.clear)
        }
    }
}

/// Link button: 12.5 pt `textSecondary`, padding 4 × 6, radius 6, `hover` fill. Strong: brand, semibold.
struct DSLinkButtonStyle: ButtonStyle {
    var strong = false
    func makeBody(configuration: Configuration) -> some View {
        DSLinkBody(configuration: configuration, strong: strong)
    }
}

private struct DSLinkBody: View {
    let configuration: ButtonStyleConfiguration
    let strong: Bool
    @State private var hovering = false

    var body: some View {
        configuration.label
            .font(strong ? DS.Font.linkStrong : DS.Font.link)
            .foregroundStyle(strong ? DS.brand : DS.textSecondary)
            .padding(.vertical, 4)
            .padding(.horizontal, 6)
            .background(RoundedRectangle(cornerRadius: DS.Radius.link, style: .continuous)
                .fill(hovering ? DS.hover : Color.clear))
            .opacity(configuration.isPressed ? 0.7 : 1)
            .contentShape(Rectangle())
            .onHover { hovering = $0 }
    }
}

extension ButtonStyle where Self == DSButtonStyle {
    static var dsPrimary: DSButtonStyle { DSButtonStyle(kind: .primary) }
    static var dsSecondary: DSButtonStyle { DSButtonStyle(kind: .secondary) }
    static var dsGhost: DSButtonStyle { DSButtonStyle(kind: .ghost) }
    static func ds(_ kind: DSButtonStyle.Kind, small: Bool = false) -> DSButtonStyle { DSButtonStyle(kind: kind, small: small) }
}

extension ButtonStyle where Self == DSLinkButtonStyle {
    static var dsLink: DSLinkButtonStyle { DSLinkButtonStyle() }
    static var dsLinkStrong: DSLinkButtonStyle { DSLinkButtonStyle(strong: true) }
}

// MARK: - Segmented

/// Capsule track `control`, padding 2; items 12 pt medium, padding 4 × 12; selected thumb `controlOn` with shadow.
struct DSSegmented<Value: Hashable>: View {
    @Binding var selection: Value
    let options: [(value: Value, label: String)]
    /// Options that can't be picked now (free mode): drawn dimmed with a lock; a tap calls `onLockedTap` and
    /// leaves the selection alone.
    var locked: Set<Value> = []
    var onLockedTap: () -> Void = {}
    @Namespace private var thumb

    var body: some View {
        HStack(spacing: 0) {
            ForEach(options.indices, id: \.self) { i in
                let option = options[i]
                let selected = option.value == selection
                let isLocked = locked.contains(option.value)
                HStack(spacing: 4) {
                    if isLocked { Image(systemName: "lock.fill").font(.system(size: 8, weight: .semibold)) }
                    Text(option.label)
                }
                    .font(DS.Font.small)
                    .foregroundStyle(DS.text)
                    .opacity(isLocked ? 0.5 : 1)
                    .lineLimit(1)
                    .padding(.vertical, 4)
                    .padding(.horizontal, 12)
                    .background {
                        if selected {
                            Capsule().fill(DS.controlOn)
                                .shadow(color: DS.thumbShadow, radius: 1.5, x: 0, y: 1)
                                .overlay(Capsule().stroke(DS.thumbRing, lineWidth: 0.5))
                                .matchedGeometryEffect(id: "thumb", in: thumb)
                        }
                    }
                    .contentShape(Capsule())
                    .onTapGesture {
                        if isLocked { onLockedTap(); return }
                        withAnimation(DS.Motion.reduceMotion ? nil : .snappy(duration: 0.2)) { selection = option.value }
                    }
                    .accessibilityElement()
                    .accessibilityLabel(isLocked ? "\(option.label), needs a licence" : option.label)
                    .accessibilityAddTraits(selected ? [.isButton, .isSelected] : .isButton)
            }
        }
        .padding(2)
        .background(Capsule().fill(DS.control))
        .fixedSize()
    }
}

// MARK: - Switch

/// 36 × 21 capsule. Off `control2`, on brand gradient. 17 pt white knob, 2 pt inset, travels 15 pt.
struct DSSwitchStyle: ToggleStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: DS.Space.m) {
            configuration.label
            DSSwitchTrack(isOn: configuration.isOn)
                .onTapGesture { withAnimation(DS.Motion.reduceMotion ? nil : DS.Motion.switchKnob) { configuration.isOn.toggle() } }
        }
    }
}

private struct DSSwitchTrack: View {
    let isOn: Bool
    var body: some View {
        ZStack(alignment: .leading) {
            Capsule().fill(DS.control2)
            Capsule().fill(DS.brandGradient).opacity(isOn ? 1 : 0)
            Circle()
                .fill(Color.white)
                .frame(width: 17, height: 17)
                .shadow(color: DS.knobShadow, radius: 1.5, x: 0, y: 1)
                .offset(x: isOn ? 17 : 2)
        }
        .frame(width: 36, height: 21)
        .contentShape(Capsule())
    }
}

extension ToggleStyle where Self == DSSwitchStyle {
    static var dsSwitch: DSSwitchStyle { DSSwitchStyle() }
}

// MARK: - Chips and pills

/// Category chip: capsule, padding 3 9 3 7, 12 pt semibold, category color on a 14% fill, leading 7 pt dot.
struct CategoryChip: View {
    let title: String
    let color: Color

    var body: some View {
        HStack(spacing: 6) {
            Circle().fill(color).frame(width: 7, height: 7)
            Text(title).font(DS.Font.chip).lineLimit(1)
        }
        .foregroundStyle(color)
        .padding(EdgeInsets(top: 3, leading: 7, bottom: 3, trailing: 9))
        .background(Capsule().fill(color.opacity(0.14)))
    }
}

/// Pill: capsule, padding 3 × 9, 11.5 pt semibold. Neutral, success or brand.
struct Pill: View {
    enum Kind { case neutral, success, brand }
    let title: String
    var kind: Kind = .neutral

    init(_ title: String, kind: Kind = .neutral) {
        self.title = title
        self.kind = kind
    }

    var body: some View {
        Text(title)
            .font(DS.Font.pill)
            .lineLimit(1)
            .foregroundStyle(foreground)
            .padding(.vertical, 3)
            .padding(.horizontal, 9)
            .background(Capsule().fill(fill))
    }

    private var foreground: Color {
        switch kind {
        case .neutral: DS.textSecondary
        case .success: DS.ok
        case .brand: DS.brand
        }
    }

    private var fill: Color {
        switch kind {
        case .neutral: DS.control
        case .success: DS.ok.opacity(0.16)
        case .brand: DS.brandSoft
        }
    }
}

// MARK: - Progress dots

/// 7 pt circles, gap 4. Pending `control2`, applied `ok`, skipped `textTertiary`, current 18 × 7 gradient pill.
struct ProgressDots: View {
    enum Dot { case pending, applied, skipped, current }
    let dots: [Dot]
    /// Applied and skipped dots differ by color only; with Differentiate Without Color the skipped ones are
    /// rings (§11). The "n of N" next to the dots says the count in words.
    @Environment(\.accessibilityDifferentiateWithoutColor) private var withoutColor

    var body: some View {
        HStack(spacing: 4) {
            ForEach(dots.indices, id: \.self) { i in
                switch dots[i] {
                case .current: Capsule().fill(DS.brandGradientHorizontal).frame(width: 18, height: 7)
                case .applied: Circle().fill(DS.ok).frame(width: 7, height: 7)
                case .skipped:
                    if withoutColor || DS.A11y.forceDifferentiateWithoutColor {
                        Circle().strokeBorder(DS.textTertiary, lineWidth: 1.5).frame(width: 7, height: 7)
                    } else {
                        Circle().fill(DS.textTertiary).frame(width: 7, height: 7)
                    }
                case .pending: Circle().fill(DS.control2).frame(width: 7, height: 7)
                }
            }
        }
        .animation(DS.Motion.reduceMotion ? nil : .snappy(duration: 0.25), value: dots)
        .accessibilityHidden(true)
    }
}

// MARK: - Status circle, toast

/// Message kind for toasts and island messages (§5.8).
enum MessageKind {
    case success, info, warning, error

    var fill: Color {
        switch self {
        case .success: DS.ok
        case .info: DS.textSecondary
        case .warning: DS.catPunctuation
        case .error: DS.catSpelling
        }
    }

    /// Default glyph; the HTML uses a lock for warnings (Accessibility, secure fields).
    var symbol: String {
        switch self {
        case .success: "checkmark"
        case .info: "info"
        case .warning: "lock"
        case .error: "exclamationmark.triangle"
        }
    }
}

/// 22 pt colored circle with a white glyph (toasts, island done/message).
struct StatusCircle: View {
    let kind: MessageKind
    var symbol: String?
    /// Overrides the kind's fill (the island's info circle uses `DS.hudInfo` on its dark capsule).
    var fill: Color?

    var body: some View {
        Circle()
            .fill(fill ?? kind.fill)
            .frame(width: 22, height: 22)
            .overlay(Image(systemName: symbol ?? kind.symbol)
                .font(.system(size: 11, weight: .bold))
                .foregroundStyle(DS.onAccent))
            .accessibilityHidden(true)
    }
}

/// Toast: glass capsule, padding 8 × 10, gap 10, 13.5 pt medium, max width 560, wraps to 2 lines.
/// Optional " · detail" in regular `textSecondary`, optional small primary button.
struct ToastView: View {
    let kind: MessageKind
    let title: String
    var detail: String?
    var symbol: String?
    var actionTitle: String?
    var action: (() -> Void)?

    var body: some View {
        HStack(spacing: 10) {
            StatusCircle(kind: kind, symbol: symbol)
            message
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.trailing, 6)
            if let actionTitle, let action {
                Button(actionTitle, action: action).buttonStyle(.ds(.primary, small: true))
            }
        }
        .padding(.vertical, 8)
        .padding(.horizontal, 10)
        .frame(maxWidth: 560, alignment: .leading)
        .fixedSize()
        .background(GlassBackground(shape: RoundedRectangle(cornerRadius: 999, style: .continuous)))
        .dsShadow(DS.windowShadow)
        .accessibilityElement(children: .combine)
    }

    private var message: Text {
        var t = Text(title).font(DS.Font.toast).foregroundColor(DS.text)
        if let detail {
            t = t + Text(" · " + detail).font(DS.Font.toastDetail).foregroundColor(DS.textSecondary)
        }
        return t
    }
}

// MARK: - Small pieces used across screens

/// "On this Mac · Gemma 4 E4B · 1.4 s": 11.5 pt `textSecondary` with a 12 pt lock.
struct PrivacyLine: View {
    let text: String
    /// "lock" on this Mac, "cloud" when a cloud model checks the text.
    var symbol = "lock"
    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: symbol).font(.system(size: 10.5, weight: .medium))
            Text(text).lineLimit(1)
        }
        .font(DS.Font.caption)
        .foregroundStyle(DS.textSecondary)
    }
}

/// 14 pt spinner: 2 pt ring, brand on 25% brand, 0.7 s per turn (static with Reduce Motion).
struct DSSpinner: View {
    @State private var turning = false
    var body: some View {
        ZStack {
            Circle().stroke(DS.brand.opacity(0.25), lineWidth: 2)
            Circle().trim(from: 0, to: 0.25).stroke(DS.brand, style: StrokeStyle(lineWidth: 2, lineCap: .butt))
                .rotationEffect(.degrees(turning ? 360 : 0))
        }
        .frame(width: 12, height: 12)
        .padding(1)
        .onAppear {
            guard !DS.Motion.reduceMotion else { return }
            withAnimation(DS.Motion.spinner) { turning = true }
        }
        .accessibilityLabel("Working")
    }
}

/// Meter / download bar: track `control2`, gradient fill. Height 5 (meter) or 6 (download).
struct DSMeter: View {
    let value: Double
    var height: CGFloat = 5

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(DS.control2)
                Capsule().fill(DS.brandGradientHorizontal)
                    .frame(width: max(0, min(1, value)) * geo.size.width)
            }
        }
        .frame(height: height)
        .accessibilityValue("\(Int((value * 100).rounded())) percent")
    }
}

/// Radio dot: 18 pt; off a 1.5 pt `control2` ring, on a 5 pt brand ring.
struct RadioDot: View {
    let isOn: Bool
    var body: some View {
        Circle()
            .strokeBorder(isOn ? DS.brand : DS.control2, lineWidth: isOn ? 5 : 1.5)
            .frame(width: 18, height: 18)
    }
}

/// App icon mock (§3): brand gradient at 145°, radius 25%, white check, inner top highlight, brand shadow.
struct AppIconView: View {
    var size: CGFloat = 34

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: size * 0.25, style: .continuous)
        shape.fill(DS.appIconGradient)
            .overlay(InnerTopHighlight(shape: shape, color: Color.white.opacity(0.45)))
            .overlay(Image(systemName: "checkmark")
                .font(.system(size: size * 0.42, weight: .bold))
                .foregroundStyle(DS.onAccent))
            .frame(width: size, height: size)
            .shadow(color: DS.brand.opacity(0.6), radius: 4, x: 0, y: 2)
            .accessibilityHidden(true)
    }
}

/// Model glyph: 30 pt rounded square (radius 9), model gradient, white bold initial.
struct ModelGlyph: View {
    let modelID: String
    let initial: String
    var size: CGFloat = 30

    var body: some View {
        RoundedRectangle(cornerRadius: DS.Radius.glyph, style: .continuous)
            .fill(DS.modelGradient(for: modelID))
            .overlay(Text(initial).font(.system(size: size * 0.47, weight: .bold)).foregroundStyle(DS.onAccent))
            .frame(width: size, height: size)
            .accessibilityHidden(true)
    }
}
