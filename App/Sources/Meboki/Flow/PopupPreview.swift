import MebokiCore
import SwiftUI

/// A looping demo of one correction popup style (design_code.md §8.1, §8.8), like the HTML reference's flow demo:
/// a small desktop with a note, the mistakes get underlined, the pointer clicks one (card and bubble) or the
/// island drops in by itself, ⏎ applies all fixes, the words change with the green flash. The popups are the real
/// views (`GlassCard`, `AnchoredBubble`, `IslandView`) drawn on a 900 × 440 canvas and scaled to fit. With Reduce
/// Motion it shows one still frame with the popup open.
struct PopupPreview: View {
    let style: PopupStyle
    /// Settings › Writing › Explain each fix: the reason line in the popups.
    var reasons = true

    static let canvas = CGSize(width: 900, height: 440)

    @State private var phase: Phase = .clean

    enum Phase: Int, Comparable {
        case clean, checking, underlined, pointing, open, pressing, applied
        static func < (a: Phase, b: Phase) -> Bool { a.rawValue < b.rawValue }
    }

    var body: some View {
        GeometryReader { geo in
            let scale = min(geo.size.width / Self.canvas.width, geo.size.height / Self.canvas.height)
            PreviewScene(style: style, reasons: reasons, phase: phase)
                .frame(width: Self.canvas.width, height: Self.canvas.height)
                .scaleEffect(scale, anchor: .topLeading)
                .frame(width: geo.size.width, height: geo.size.height, alignment: .topLeading)
        }
        .aspectRatio(Self.canvas.width / Self.canvas.height, contentMode: .fit)
        .clipShape(RoundedRectangle(cornerRadius: DS.Radius.suggestion, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: DS.Radius.suggestion, style: .continuous)
            .strokeBorder(DS.separator, lineWidth: 0.5))
        .environment(\.dsGlassBlur, false)
        .allowsHitTesting(false)
        .task(id: style) { await run() }
        .accessibilityElement()
        .accessibilityLabel("Preview of the \(style.title) style")
        .accessibilityValue(description)
    }

    private var description: String {
        switch style {
        case .card: "Click an underlined word: a glass card opens under it. Return applies all fixes."
        case .bubble: "Click an underlined word: a small bubble points at it. Return applies all fixes."
        case .island: "After a check, a dark island under the menu bar shows each fix. Return applies all fixes."
        }
    }

    /// The loop: clean text → (island: checking) → underlines → pointer to the word → popup → ⏎ → applied.
    private func run() async {
        if DS.Motion.reduceMotion {
            phase = .open
            return
        }
        let island = style == .island
        while !Task.isCancelled {
            set(.clean, animated: false)
            guard await pause(1.0) else { return }
            if island {
                set(.checking)
                guard await pause(1.3) else { return }
            }
            set(.underlined)
            guard await pause(island ? 0.5 : 1.0) else { return }
            if !island {
                set(.pointing)
                guard await pause(0.9) else { return }
            }
            set(.open)
            guard await pause(2.6) else { return }
            set(.pressing)
            guard await pause(0.7) else { return }
            set(.applied)
            guard await pause(2.4) else { return }
        }
    }

    private func set(_ p: Phase, animated: Bool = true) {
        if animated {
            withAnimation(p == .pointing ? .easeInOut(duration: 0.8) : DS.Motion.popInSpring) { phase = p }
        } else {
            var t = Transaction()
            t.disablesAnimations = true
            withTransaction(t) { phase = p }
        }
    }

    private func pause(_ seconds: Double) async -> Bool {
        try? await Task.sleep(for: .seconds(seconds))
        return !Task.isCancelled
    }
}

// MARK: - Sample

private struct PreviewFix {
    let id: Int
    let old: String
    let new: String
    let category: FixCategory
    let reason: String

    static let all = [
        PreviewFix(id: 0, old: "Their", new: "They're", category: .grammar,
                   reason: "“Their” shows possession. Here you mean “they are”."),
        PreviewFix(id: 1, old: "tomorow", new: "tomorrow", category: .spelling,
                   reason: "“Tomorrow” is spelled with two r’s."),
        PreviewFix(id: 2, old: "we was", new: "we were", category: .grammar, reason: "Use “were” with “we”."),
    ]
}

private struct WordBoundsKey: PreferenceKey {
    static let defaultValue: [Int: Anchor<CGRect>] = [:]
    static func reduce(value: inout [Int: Anchor<CGRect>], nextValue: () -> [Int: Anchor<CGRect>]) {
        value.merge(nextValue()) { $1 }
    }
}

// MARK: - Scene

private struct PreviewScene: View {
    let style: PopupStyle
    let reasons: Bool
    let phase: PopupPreview.Phase

    /// The fix the popup shows: the clicked word for card and bubble, the first fix for the island.
    private var focus: PreviewFix { PreviewFix.all[style == .island ? 0 : 1] }
    private var popupOpen: Bool { phase == .open || phase == .pressing || (style == .island && phase == .underlined) }

    var body: some View {
        ZStack(alignment: .topLeading) {
            Wallpaper()
            MenuBarStrip()
            editor
                .offset(x: 56, y: 58)
            if phase == .applied, style != .island {
                ToastView(kind: .success, title: "3 fixes applied", detail: "⌘Z undoes")
                    .frame(width: 560)
                    .offset(x: 56, y: 330)
                    .transition(.opacity.combined(with: .offset(y: 8)))
            }
            if phase == .pressing || phase == .applied {
                keyPress
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
                    .padding(18)
                    .opacity(phase == .pressing ? 1 : 0)
            }
            if style == .island { island }
        }
        .overlayPreferenceValue(WordBoundsKey.self) { anchors in
            GeometryReader { geo in
                if let a = anchors[focus.id] {
                    let r = geo[a]
                    if style != .island, popupOpen { popup(at: r) }
                    if style != .island, phase >= .underlined, phase < .applied { pointer(word: r) }
                }
            }
        }
        .clipped()
    }

    // MARK: Editor window

    private var editor: some View {
        let shape = RoundedRectangle(cornerRadius: DS.Radius.window, style: .continuous)
        return VStack(alignment: .leading, spacing: 0) {
            ZStack {
                HStack(spacing: 8) {
                    ForEach([0xFF5F57, 0xFEBC2E, 0x28C840] as [UInt32], id: \.self) { c in
                        Circle().fill(Color(nsColor: .hex(c))).frame(width: 12, height: 12)
                    }
                    Spacer()
                }
                Text("Note to Maya").font(.system(size: 13, weight: .semibold)).foregroundStyle(DS.text)
            }
            .padding(.horizontal, 18)
            .frame(height: 44)
            DSSeparator()
            VStack(alignment: .leading, spacing: 13) {
                Text("Hi Maya,")
                HStack(spacing: 0) {
                    word(PreviewFix.all[0])
                    Text(" going to review the proposal ")
                    word(PreviewFix.all[1])
                    Text(", and")
                }
                HStack(spacing: 0) {
                    word(PreviewFix.all[2])
                    Text(" hoping you could join the call.")
                }
                Text("Thanks,").padding(.top, 13)
                Text("Alex")
            }
            .font(.system(size: 17))
            .foregroundStyle(DS.text)
            .padding(EdgeInsets(top: 22, leading: 30, bottom: 0, trailing: 30))
            Spacer(minLength: 0)
        }
        .frame(width: 560, height: 330, alignment: .topLeading)
        .background(shape.fill(DS.window))
        .clipShape(shape)
        .overlay(shape.stroke(DS.edge, lineWidth: 1))
        .dsShadow(DS.windowShadow)
    }

    private func word(_ fix: PreviewFix) -> some View {
        let applied = phase == .applied
        let current = popupOpen && fix.id == focus.id
        return Group {
            // A new view per state, so the highlight never animates from the old word's frame.
            if applied {
                AppliedWord(text: fix.new)
            } else {
                Text(fix.old)
                    .padding(.horizontal, 1)
                    .background(RoundedRectangle(cornerRadius: 4, style: .continuous)
                        .fill(current ? fix.category.color.opacity(0.16) : .clear))
            }
        }
        .transition(.identity)
            .overlay(alignment: .bottom) {
                WaveLine()
                    .trim(from: 0, to: phase >= .underlined && !applied ? 1 : 0)
                    .stroke(fix.category.color, style: StrokeStyle(lineWidth: 1.5, lineCap: .round))
                    .frame(height: 4)
                    .offset(y: 5)
                    .animation(applied ? DS.Motion.fade : .easeOut(duration: 0.45).delay(Double(fix.id) * 0.12),
                               value: phase >= .underlined && !applied)
            }
            .anchorPreference(key: WordBoundsKey.self, value: .bounds) { [fix.id: $0] }
    }

    // MARK: Popups

    @ViewBuilder private func popup(at r: CGRect) -> some View {
        let fix = focus
        let state = CardState(category: fix.category, swap: FixSwap(old: fix.old, new: fix.new),
                              reason: reasons ? fix.reason : nil,
                              dots: style == .card ? [.pending, .current, .pending] : [],
                              position: 2, pending: 3,
                              footer: style == .card ? "On this Mac · Gemma 4 E4B · 1.4 s" : "")
        switch style {
        case .card:
            GlassCard(state: state)
                .fixedSize()
                .offset(x: r.minX - 24, y: r.maxY + 12)
                .transition(.scale(scale: 0.94, anchor: .top).combined(with: .opacity))
        case .bubble:
            let tip = BubbleTip(x: 34)
            AnchoredBubble(state: state, tip: tip)
                .fixedSize()
                .offset(x: r.midX - tip.x - 7, y: r.maxY + 13)
                .transition(.scale(scale: 0.9, anchor: .topLeading).combined(with: .opacity))
        case .island:
            EmptyView()
        }
    }

    private var island: some View {
        let fixes = PreviewFix.all
        let content: IslandContent? = switch phase {
        case .checking: .checking(model: "Gemma 4 E4B")
        case .underlined, .open, .pressing:
            .review(IslandReview(fix: IslandFix(category: fixes[0].category, swap: FixSwap(old: fixes[0].old, new: fixes[0].new)),
                                 reason: fixes[0].category.title + (reasons ? " · " + fixes[0].reason : ""),
                                 upcoming: fixes.dropFirst().map { IslandFix(category: $0.category, swap: FixSwap(old: $0.old, new: $0.new)) },
                                 position: 1, pending: 3))
        case .applied: .done(title: "3 fixes applied", detail: "⌘Z undoes")
        case .clean, .pointing: nil
        }
        return ZStack {
            if let content {
                IslandView(content: content)
                    .fixedSize()
                    .transition(.scale(scale: 0.8, anchor: .top).combined(with: .opacity))
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 32)
    }

    /// The pointer: rests below the text, glides to the word, and clicks (a ring) when the popup opens.
    private func pointer(word r: CGRect) -> some View {
        let atWord = phase >= .pointing
        let tipPoint = atWord ? CGPoint(x: r.midX + 6, y: r.midY + 4) : CGPoint(x: r.midX + 150, y: r.maxY + 150)
        return ZStack(alignment: .topLeading) {
            // The click: a ring that grows and fades once, when the popup opens.
            Circle()
                .stroke(DS.brand.opacity(0.8), lineWidth: 2)
                .frame(width: 26, height: 26)
                .keyframeAnimator(initialValue: Ring(), trigger: phase >= .open) { content, v in
                    content.scaleEffect(v.scale).opacity(v.opacity)
                } keyframes: { _ in
                    KeyframeTrack(\.opacity) {
                        LinearKeyframe(1, duration: 0.01)
                        CubicKeyframe(0, duration: 0.5)
                    }
                    KeyframeTrack(\.scale) {
                        LinearKeyframe(0.4, duration: 0.01)
                        CubicKeyframe(1.5, duration: 0.5)
                    }
                }
                .offset(x: -13, y: -13)
            Image(systemName: "cursorarrow")
                .font(.system(size: 22, weight: .regular))
                .foregroundStyle(.black)
                .background(Image(systemName: "cursorarrow").font(.system(size: 22, weight: .black)).foregroundStyle(.white))
                .shadow(color: .black.opacity(0.3), radius: 2, x: 0, y: 1)
                .scaleEffect(phase == .open ? 0.9 : 1, anchor: .topLeading)
                .offset(x: -4, y: -3)
        }
        .offset(x: tipPoint.x, y: tipPoint.y)
    }

    /// "⏎ Apply all" keystroke badge, bottom right.
    private var keyPress: some View {
        HStack(spacing: 8) {
            Text("⏎")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(DS.hudText)
                .frame(width: 30, height: 26)
                .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(DS.hudKbd))
            Text("Apply all").font(.system(size: 14, weight: .medium)).foregroundStyle(DS.hudText)
        }
        .padding(.vertical, 7)
        .padding(.horizontal, 10)
        .background(Capsule().fill(DS.hud.opacity(0.85)))
        .scaleEffect(phase == .pressing ? 1 : 0.9)
    }
}

/// A fixed word: the green applied flash (§2.6), fading out.
private struct AppliedWord: View {
    let text: String
    @State private var flash = true

    var body: some View {
        Text(text)
            .padding(.horizontal, 1)
            .background(RoundedRectangle(cornerRadius: 4, style: .continuous).fill(DS.ok.opacity(flash ? 0.25 : 0)))
            .onAppear {
                withAnimation(.easeOut(duration: DS.Motion.appliedFlashDuration).delay(0.2)) { flash = false }
            }
    }
}

private struct Ring {
    var scale: CGFloat = 0.4
    var opacity: Double = 0
}

/// A fake menu bar: app menus on the left, Meboki's icon and the clock on the right.
private struct MenuBarStrip: View {
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        HStack(spacing: 18) {
            Text("Editor").fontWeight(.bold)
            ForEach(["File", "Edit", "View", "Window", "Help"], id: \.self) { Text($0) }
            Spacer()
            Image(systemName: "text.badge.checkmark")
            Image(systemName: "wifi")
            Image(systemName: "battery.100")
            Text("9:41")
        }
        .font(.system(size: 13))
        .foregroundStyle(DS.text)
        .padding(.horizontal, 18)
        .frame(height: 26)
        .background(scheme == .dark ? Color.black.opacity(0.3) : Color.white.opacity(0.35))
    }
}

/// The underline overlay's wavy line (`UnderlineOverlay.wave`) at a given curve (`DS.waveAmplitude`,
/// `DS.waveLength`; standard: wavelength 4 pt, amplitude 1.5 pt).
struct WaveLine: Shape {
    var curve: Double = DS.underlineCurve

    func path(in r: CGRect) -> Path {
        var p = Path()
        let y = r.midY, amp = DS.waveAmplitude(curve), half = DS.waveLength(curve) / 2
        p.move(to: CGPoint(x: r.minX, y: y))
        var x = r.minX, up = true
        while x < r.maxX {
            let next = min(x + half, r.maxX)
            p.addQuadCurve(to: CGPoint(x: next, y: y), control: CGPoint(x: (x + next) / 2, y: up ? y - amp * 2 : y + amp * 2))
            x = next
            up.toggle()
        }
        return p
    }
}
