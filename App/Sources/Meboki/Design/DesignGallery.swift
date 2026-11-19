#if DEBUG
import AppKit
import MebokiCore
import SwiftUI

/// DEBUG-only component gallery (design_code.md §14 stage 1): every token-based component in light and dark,
/// side by side over the reference wallpaper. Open it from the status menu (debug builds) or run
/// `.build/debug/Meboki --gallery`, which shows only this window and prints its window number for
/// `screencapture -l`.
@MainActor
enum DesignGallery {
    private static var window: NSWindow?

    static func show(activate: Bool) {
        if window == nil {
            let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1120, height: 940),
                             styleMask: [.titled, .closable, .resizable, .miniaturizable], backing: .buffered, defer: false)
            w.title = "Component Gallery"
            w.isReleasedWhenClosed = false
            let stack = NSStackView(views: [column(.light), column(.dark)])
            stack.distribution = .fillEqually
            stack.spacing = 0
            w.contentView = stack
            w.center()
            window = w
        }
        if activate {
            NSApp.activate()
            window?.makeKeyAndOrderFront(nil)
        } else {
            window?.orderFrontRegardless()
        }
    }

    static var windowNumber: Int { window?.windowNumber ?? 0 }

    private static func column(_ scheme: ColorScheme) -> NSView {
        let host = NSHostingView(rootView: GalleryColumn()
            .environment(\.colorScheme, scheme)
            .environment(\.dsGlassBlending, .withinWindow))
        host.appearance = NSAppearance(named: scheme == .dark ? .darkAqua : .aqua)
        return host
    }
}

/// DEBUG `--contrast-probe` (stage 10, §11): the glass tints over flat backdrops (white, black, mid grey, a
/// bright and a dark color), light theme on top, dark below, for measuring the real material + tint with
/// `screencapture -l` and checking secondary-text contrast. Borderless, so pixel positions are exact: each
/// cell is `cell` pt, the glass sits in its middle. Rows: `glass`, `glassStrong`, `sidebar`.
@MainActor
enum ContrastProbe {
    static let cell = CGSize(width: 120, height: 90)
    static let backdrops: [UInt32] = [0xFFFFFF, 0x000000, 0x808080, 0xFF77A9, 0x1E3A8A]
    private static var window: NSWindow?

    static func show() {
        let size = CGSize(width: cell.width * CGFloat(backdrops.count), height: cell.height * 3)
        let w = NSWindow(contentRect: NSRect(origin: .zero, size: CGSize(width: size.width, height: size.height * 2)),
                         styleMask: [.borderless], backing: .buffered, defer: false)
        w.isReleasedWhenClosed = false
        let stack = NSStackView(views: [host(.light), host(.dark)])
        stack.orientation = .vertical
        stack.spacing = 0
        w.contentView = stack
        w.center()
        w.orderFrontRegardless()
        window = w
        print("probe window \(w.windowNumber) \(Int(size.width))x\(Int(size.height * 2))")
        fflush(stdout)
    }

    private static func host(_ scheme: ColorScheme) -> NSView {
        let tints = [DS.glass, DS.glassStrong, DS.sidebar]
        let view = VStack(spacing: 0) {
            ForEach(tints.indices, id: \.self) { row in
                HStack(spacing: 0) {
                    ForEach(backdrops.indices, id: \.self) { col in
                        ZStack {
                            Color(nsColor: .hex(backdrops[col]))
                            GlassBackground(shape: Rectangle(), tint: tints[row], highlight: false)
                                .frame(width: 60, height: 40)
                        }
                        .frame(width: cell.width, height: cell.height)
                    }
                }
            }
        }
        .environment(\.colorScheme, scheme)
        .environment(\.dsGlassBlending, .withinWindow)
        let h = NSHostingView(rootView: view)
        h.appearance = NSAppearance(named: scheme == .dark ? .darkAqua : .aqua)
        return h
    }
}

@MainActor
private enum GallerySamples {
    static func popover(paused: Bool) -> PopoverModel {
        let m = PopoverModel()
        m.status = paused ? PopoverStatus(kind: .paused, text: "Paused in Safari · Gemma 4 E4B")
            : PopoverStatus(kind: .ready, text: "Ready · Gemma 4 E4B")
        m.modelID = Catalog.gemma4E4B.id
        m.modelName = "Gemma 4 E4B"
        m.peakMemoryGB = 4.75
        m.paragraphSeconds = 1.4
        m.ramGB = 32
        m.appName = "Safari"
        m.appBundleID = "com.apple.Safari"
        return m
    }

    static func settings(paused: Bool) -> AppSettings {
        let defaults = UserDefaults(suiteName: "com.meboki.app.gallery.\(paused)")!
        defaults.removePersistentDomain(forName: "com.meboki.app.gallery.\(paused)")
        let s = AppSettings(defaults: defaults)
        s.underlineAsYouType = !paused
        if paused { s.setPaused(true, bundleID: "com.apple.Safari") }
        return s
    }
}

private struct GalleryColumn: View {
    @State private var variant = "US"
    @State private var level = "full"
    @State private var switchOn = true
    @State private var switchOff = false

    var body: some View {
        ScrollViewReader { proxy in
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                section("Buttons") {
                    HStack(spacing: 8) {
                        Button {} label: { DSLabel("Ignore", kbd: "⇥") }.buttonStyle(.dsGhost)
                        Button {} label: { DSLabel("Apply", kbd: "⇧⏎") }.buttonStyle(.dsSecondary)
                        Button {} label: { DSLabel("Apply all 6", kbd: "⏎") }.buttonStyle(.dsPrimary)
                    }
                    HStack(spacing: 8) {
                        Button("Pause") {}.buttonStyle(.ds(.secondary, small: true))
                        Button("Open System Settings") {}.buttonStyle(.ds(.primary, small: true))
                        Button {} label: { DSLabel("Download 3.3 GB", systemImage: "arrow.down.to.line") }.buttonStyle(.dsPrimary)
                    }
                    HStack(spacing: 8) {
                        Button("Disabled") {}.buttonStyle(.dsPrimary).disabled(true)
                        Button("Disabled") {}.buttonStyle(.dsSecondary).disabled(true)
                        Button("Show models folder") {}.buttonStyle(.dsLink)
                        Button {} label: { DSLabel("Fix all 6", kbd: "⏎") }.buttonStyle(.dsLinkStrong)
                    }
                }
                section("Keycaps") {
                    HStack(spacing: 6) {
                        ForEach(["⏎", "⇧⏎", "⇥", "⌘⏎", "⌃⌥G", "←", "→", "Esc"], id: \.self) { Kbd($0) }
                    }
                }
                section("Segmented · Switch") {
                    HStack(spacing: 16) {
                        DSSegmented(selection: $variant, options: [("US", "US"), ("UK", "UK")])
                        DSSegmented(selection: $level, options: [("spelling", "Spelling"), ("grammar", "Grammar"), ("full", "Full")])
                    }
                    HStack(spacing: 16) {
                        Toggle("On", isOn: $switchOn).toggleStyle(.dsSwitch)
                        Toggle("Off", isOn: $switchOff).toggleStyle(.dsSwitch)
                    }
                    .font(DS.Font.body).foregroundStyle(DS.text)
                }
                section("Chips · Pills · Progress") {
                    HStack(spacing: 6) {
                        CategoryChip(title: "Spelling", color: DS.catSpelling)
                        CategoryChip(title: "Grammar", color: DS.catGrammar)
                        CategoryChip(title: "Clarity", color: DS.catClarity)
                        CategoryChip(title: "Punctuation", color: DS.catPunctuation)
                    }
                    HStack(spacing: 6) {
                        Pill("Not rated")
                        Pill("In use", kind: .success)
                        Pill("Recommended", kind: .brand)
                    }
                    HStack(spacing: 10) {
                        ProgressDots(dots: [.applied, .skipped, .current, .pending, .pending, .pending])
                        Text("3 of 6").font(DS.Font.small).monospacedDigit().foregroundStyle(DS.textSecondary)
                        DSSpinner()
                        RadioDot(isOn: true)
                        RadioDot(isOn: false)
                    }
                    DSMeter(value: 0.53, height: 6).frame(width: 300)
                }
                section("Glass card") { cardShell }.id("card")
                section("Anchored bubble") { bubbleShell }.id("bubble")
                section("Island HUD") { islandShell }.id("island")
                section("Menu-bar popover") { popoverShell }.id("popover")
                section("Toasts") {
                    ToastView(kind: .success, title: "5 fixes applied · 1 kept", detail: "⌘Z undoes in the app")
                    ToastView(kind: .info, title: "The model is still loading. Try again in a moment.", detail: "Loading Gemma 4 E4B…")
                    ToastView(kind: .error, title: "Check failed: server returned 500", detail: "Details: menu › Show Meboki Log")
                    ToastView(kind: .warning, title: "Meboki needs Accessibility access to read this field.",
                              actionTitle: "Open System Settings", action: {})
                }
                section("Icons · HUD") {
                    HStack(spacing: 12) {
                        AppIconView(size: 34)
                        AppIconView(size: 56)
                        ModelGlyph(modelID: "gemma-4-e4b-q4_0", initial: "G")
                        ModelGlyph(modelID: "gemma-4-e2b-q4_0", initial: "G")
                        ModelGlyph(modelID: "qwen3.5-4b", initial: "Q")
                    }
                    HStack(spacing: 10) {
                        StatusCircle(kind: .success)
                        Text("5 fixes applied · 1 kept").font(DS.Font.islandStrong).foregroundStyle(DS.hudText)
                        Spacer()
                        Text("⌘Z undoes").font(DS.Font.link).foregroundStyle(DS.hudSecondary)
                    }
                    .padding(EdgeInsets(top: 10, leading: 16, bottom: 10, trailing: 16))
                    .frame(width: 420, height: 48)
                    .background(HUDBackground(shape: RoundedRectangle(cornerRadius: DS.Radius.island, style: .continuous)))
                }
                Color.clear.frame(height: 1).id("bottom")
            }
            .padding(24)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .onAppear {
            // `--gallery-bottom` (with `--gallery`): start scrolled to the end, for window screenshots.
            if CommandLine.arguments.contains("--gallery-bottom") {
                DispatchQueue.main.async { proxy.scrollTo("bottom", anchor: .bottom) }
            } else if CommandLine.arguments.contains("--gallery-card") {
                // `--gallery-card`: start at the glass card states (compare with `flow-card*` screenshots).
                DispatchQueue.main.async { proxy.scrollTo("card", anchor: .top) }
            } else if CommandLine.arguments.contains("--gallery-island") {
                // `--gallery-island`: start at the island states (compare with `flow-island*` screenshots).
                DispatchQueue.main.async { proxy.scrollTo("island", anchor: .top) }
            } else if CommandLine.arguments.contains("--gallery-popover") {
                // `--gallery-popover`: start at the popover (compare with `app-popover*` screenshots).
                DispatchQueue.main.async { proxy.scrollTo("popover", anchor: .top) }
            } else if CommandLine.arguments.contains("--gallery-bubble") {
                // `--gallery-bubble`: start at the bubble states (compare with `flow-bubble*` screenshots).
                DispatchQueue.main.async { proxy.scrollTo("bubble", anchor: .top) }
            }
        }
        }
        .background(Wallpaper())
    }

    /// The real card in the states of screenshots `flow-card`, `flow-card-progress` and `flow-card-last`.
    private var cardShell: some View {
        VStack(alignment: .leading, spacing: 18) {
            GlassCard(state: CardState(category: .spelling, swap: FixSwap(old: "tomorow", new: "tomorrow"),
                                       reason: "“Tomorrow” is spelled with two r’s.",
                                       dots: [.pending, .pending, .current, .pending, .pending, .pending],
                                       position: 3, pending: 6, footer: "On this Mac · Gemma 4 E4B · 1.4 s"))
            GlassCard(state: CardState(category: .grammar, swap: FixSwap(old: "we was", new: "we were"),
                                       reason: "Use “were” with “we”.",
                                       dots: [.applied, .skipped, .pending, .current, .pending, .pending],
                                       position: 2, pending: 4, footer: "On this Mac · Gemma 4 E4B · 1.4 s"))
            GlassCard(state: CardState(category: .grammar, swap: FixSwap(old: "joins", new: "join"),
                                       reason: "After “could”, use the base verb.",
                                       dots: [.applied, .applied, .applied, .applied, .current, .applied],
                                       position: 1, pending: 1, footer: "On this Mac · Gemma 4 E4B · 1.4 s"))
            GlassCard(state: CardState(category: .clarity,
                                       swap: FixSwap(old: "Could you please explain me the problem",
                                                     new: "Could you please explain the problem to me"),
                                       reason: "Grammar: “explain me the problem” → “explain the problem to me”.",
                                       dots: [.current, .pending], position: 1, pending: 2,
                                       footer: "On this Mac · Gemma 4 E4B · 0.8 s"))
        }
    }

    /// The real bubble in the states of `flow-bubble` (tip on the top edge) and `flow-bubble-last`, plus a
    /// deletion with the tip on the bottom edge (bubble above the word).
    private var bubbleShell: some View {
        VStack(alignment: .leading, spacing: 28) {
            AnchoredBubble(state: CardState(category: .grammar, swap: FixSwap(old: "Their", new: "They're"),
                                            reason: "“Their” shows possession. Here you mean “they are”.",
                                            dots: [], position: 1, pending: 6, footer: ""),
                           tip: BubbleTip(x: 28))
            AnchoredBubble(state: CardState(category: .grammar, swap: FixSwap(old: "we was", new: "we were"),
                                            reason: "Use “were” with “we”.", dots: [], position: 1, pending: 1,
                                            footer: ""),
                           tip: BubbleTip(x: 49))
            AnchoredBubble(state: CardState(category: .clarity, swap: FixSwap(old: "the", new: ""),
                                            reason: "The word “the” is repeated.", dots: [], position: 2, pending: 3,
                                            footer: ""),
                           tip: BubbleTip(x: 120, above: true))
        }
        .padding(.top, 8)
    }

    /// The real popover in the states of `app-popover` and `app-popover-paused` (sample settings, not the
    /// user's).
    private var popoverShell: some View {
        VStack(alignment: .leading, spacing: 18) {
            PopoverView(model: GallerySamples.popover(paused: false), settings: GallerySamples.settings(paused: false))
            PopoverView(model: GallerySamples.popover(paused: true), settings: GallerySamples.settings(paused: true))
        }
    }

    /// The real island in the states of `flow-island-checking`, `flow-island`, `flow-island-open`,
    /// `flow-island-last`, `flow-island-done` and `flow-island-msg`.
    private var islandShell: some View {
        let their = IslandFix(category: .grammar, swap: FixSwap(old: "Their", new: "They're"))
        let next = [IslandFix(category: .clarity, swap: FixSwap(old: "the the", new: "the")),
                    IslandFix(category: .spelling, swap: FixSwap(old: "tomorow", new: "tomorrow")),
                    IslandFix(category: .grammar, swap: FixSwap(old: "we was", new: "we were"))]
        let review = IslandReview(fix: their, reason: "Grammar · “Their” shows possession. Here you mean “they are”.",
                                  upcoming: next, position: 1, pending: 6)
        let last = IslandReview(fix: IslandFix(category: .punctuation, swap: FixSwap(old: "Lets", new: "Let's")),
                                reason: "Punctuation · “Let's” is short for “let us” and needs an apostrophe.",
                                upcoming: [], position: 1, pending: 1)
        return VStack(alignment: .leading, spacing: 18) {
            IslandView(content: .checking(model: "Gemma 4 E4B")).fixedSize()
            IslandView(content: .review(review)).fixedSize()
            IslandView(content: .review(review), expanded: true).fixedSize()
            IslandView(content: .review(last), expanded: true).fixedSize()
            IslandView(content: .done(title: "5 fixes applied · 1 kept", detail: "⌘Z undoes")).fixedSize()
            IslandView(content: .message(kind: .success, title: "No mistakes found.", detail: nil, symbol: nil,
                                         actionTitle: nil)).fixedSize()
            IslandView(content: .message(kind: .warning, title: "Meboki needs Accessibility access to read this field.",
                                         detail: nil, symbol: nil, actionTitle: "Open System Settings")).fixedSize()
        }
    }

    private func section<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title.uppercased()).font(DS.Font.chip).foregroundStyle(DS.textSecondary)
            content()
        }
    }
}
#endif
