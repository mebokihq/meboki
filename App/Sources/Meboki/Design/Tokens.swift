import AppKit
import SwiftUI

/// Design tokens from design_code.md §2. The HTML reference (docs/design/meboki-design.html) is the source
/// of truth for every value; 1 CSS px = 1 pt. Views outside `Design/` use these and never a literal color.
enum DS {}

// MARK: - Colors (§2.1)

extension DS {
    /// A color with a light and a dark value, resolved against the view's effective appearance.
    static func dynamic(_ name: String, light: NSColor, dark: NSColor) -> Color {
        Color(nsColor: NSColor(name: NSColor.Name("DS." + name)) { appearance in
            appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? dark : light
        })
    }

    /// Brand and category colors follow the color tone (Settings › Appearance, `ColorTone`).
    static var brand: Color { palette.brand }
    static var brand2: Color { palette.brand2 }
    static var brandSoft: Color { palette.brandSoft }

    static let text = dynamic("text", light: .hex(0x1D1D1F), dark: .hex(0xF5F5F7))
    /// Raised from the HTML's .64 / .62 in stage 10 so secondary text is ≥ 4.5:1 on every surface (§11), including
    /// glass over black or white wallpapers and the popover's `control` tiles (measured with `--contrast-probe`).
    static let textSecondary = dynamic("textSecondary", light: .rgba(60, 60, 67, 0.80), dark: .rgba(235, 235, 245, 0.68))
    static let textTertiary = dynamic("textTertiary", light: .rgba(60, 60, 67, 0.38), dark: .rgba(235, 235, 245, 0.32))
    static let separator = dynamic("separator", light: .rgba(60, 60, 67, 0.13), dark: .rgba(255, 255, 255, 0.10))
    /// Separator lines and outlines with Increase Contrast on (§11): 1 pt, about 3:1 on `window`.
    static let separatorHigh = dynamic("separatorHigh", light: .rgba(60, 60, 67, 0.55), dark: .rgba(255, 255, 255, 0.42))

    static let window = dynamic("window", light: .hex(0xFCFCFD), dark: .hex(0x1E1D21))
    static let sidebar = dynamic("sidebar", light: .rgba(240, 238, 244, 0.78), dark: .rgba(40, 38, 46, 0.72))
    /// Tint raised from the HTML's .62 in stage 10 (§11): over a white wallpaper the dark glass was too light for
    /// secondary text, over a black one the light glass too dark.
    static let glass = dynamic("glass", light: .rgba(255, 255, 255, 0.70), dark: .rgba(36, 34, 40, 0.74))
    static let glassStrong = dynamic("glassStrong", light: .rgba(255, 255, 255, 0.86), dark: .rgba(34, 32, 38, 0.88))
    static let glassHighlight = dynamic("glassHighlight", light: .rgba(255, 255, 255, 0.9), dark: .rgba(255, 255, 255, 0.14))
    static let edge = dynamic("edge", light: .rgba(0, 0, 0, 0.10), dark: .rgba(0, 0, 0, 0.5))

    static let control = dynamic("control", light: .rgba(118, 118, 128, 0.12), dark: .rgba(118, 118, 128, 0.24))
    static let control2 = dynamic("control2", light: .rgba(120, 120, 128, 0.26), dark: .rgba(120, 120, 128, 0.38))
    static let controlOn = dynamic("controlOn", light: .hex(0xFFFFFF), dark: .hex(0x5A5A60))
    static let field = dynamic("field", light: .hex(0xFFFFFF), dark: .hex(0x2A2930))
    static let hover = dynamic("hover", light: .rgba(0, 0, 0, 0.05), dark: .rgba(255, 255, 255, 0.06))
    static let group = dynamic("group", light: .rgba(0, 0, 0, 0.035), dark: .rgba(255, 255, 255, 0.05))

    static var catSpelling: Color { palette.catSpelling }
    static var catGrammar: Color { palette.catGrammar }
    static var catClarity: Color { palette.catClarity }
    static var catPunctuation: Color { palette.catPunctuation }
    static var catRewrite: Color { palette.catRewrite }
    static let ok = dynamic("ok", light: .hex(0x22B14C), dark: .hex(0x30D158))

    /// Island colors: dark in both themes.
    static let hud = dynamic("hud", light: .hex(0x0D0C10), dark: .hex(0x000000))
    static let hudText = Color(nsColor: .hex(0xF5F5F7))
    static let hudSecondary = Color(nsColor: .rgba(235, 235, 245, 0.6))
    /// Island secondary-button fill and divider (`rgba(255,255,255,.12)` in the HTML).
    static let hudControl = Color(nsColor: .rgba(255, 255, 255, 0.12))
    /// Keycap fill on the island's dark buttons (`.island kbd`, `rgba(255,255,255,.14)`).
    static let hudKbd = Color(nsColor: .rgba(255, 255, 255, 0.14))
    /// The island's 0.5 pt ring (`rgba(255,255,255,.08)`).
    static let hudRing = Color(nsColor: .rgba(255, 255, 255, 0.08))
    /// The island's ring and divider with Increase Contrast on.
    static let hudRingHigh = Color(nsColor: .rgba(255, 255, 255, 0.42))
    /// Gray status circle for info messages on the island (`--m-sec` in the dark theme).
    static let hudInfo = Color(nsColor: .rgba(235, 235, 245, 0.62))

    /// Constant white for text and glyphs on the brand gradient or a category fill.
    static let onAccent = Color.white
    /// Keycap fill on a gradient or colored button.
    static let kbdOnAccent = Color.white.opacity(0.24)
    /// 1 pt inner top highlight on primary buttons.
    static let primaryHighlight = Color.white.opacity(0.35)
    /// Small drop shadows inside controls (segment thumb, switch knob).
    static let thumbShadow = Color.black.opacity(0.16)
    static let thumbRing = Color.black.opacity(0.05)
    static let knobShadow = Color.black.opacity(0.3)
}

// MARK: - Color tone (Settings › Appearance)

/// How vivid the brand and category colors are. Each tone keeps the hue of the original colors and lowers their
/// chroma in OKLCH (Current 100 %, Eased 88 %, Muted 76 % and −1 lightness, Dusty 64 % and −3 lightness);
/// the hex values below were computed once from the originals.
enum ColorTone: String, CaseIterable, Identifiable, Sendable {
    case current, eased, muted, dusty

    var id: String { rawValue }

    var title: String {
        switch self {
        case .current: "Vivid"
        case .eased: "Eased"
        case .muted: "Muted"
        case .dusty: "Dusty"
        }
    }

    var detail: String {
        switch self {
        case .current: "Full macOS colors."
        case .eased: "A touch calmer, same feel."
        case .muted: "Clearly softer, still bright."
        case .dusty: "Quiet, slightly greyed."
        }
    }
}

extension DS {
    /// Brand and category colors of one tone.
    struct Palette {
        let brand, brand2, brandSoft: Color
        let catSpelling, catGrammar, catClarity, catPunctuation, catRewrite: Color
    }

    /// The tone in use. Set on the main actor by `AppSettings.colorTone`; read wherever a color is drawn.
    nonisolated(unsafe) static var tone: ColorTone = .current

    static var palette: Palette { palettes[tone] ?? palettes[.current]! }

    static func palette(_ tone: ColorTone) -> Palette { palettes[tone] ?? palettes[.current]! }

    /// (light, dark) per token and tone.
    private static let palettes: [ColorTone: Palette] = {
        typealias Pair = (UInt32, UInt32)
        func make(_ t: ColorTone, brand: Pair, brand2: Pair, spelling: Pair, grammar: Pair, clarity: Pair,
                  punctuation: Pair, rewrite: Pair) -> Palette {
            func c(_ name: String, _ p: Pair, _ a: (CGFloat, CGFloat) = (1, 1)) -> Color {
                dynamic("\(name).\(t.rawValue)", light: .hex(p.0, a.0), dark: .hex(p.1, a.1))
            }
            return Palette(brand: c("brand", brand), brand2: c("brand2", brand2),
                           brandSoft: c("brandSoft", brand, (0.12, 0.16)),
                           catSpelling: c("catSpelling", spelling), catGrammar: c("catGrammar", grammar),
                           catClarity: c("catClarity", clarity), catPunctuation: c("catPunctuation", punctuation),
                           catRewrite: c("catRewrite", rewrite))
        }
        return [
            .current: make(.current, brand: (0xFF3D6E, 0xFF5C85), brand2: (0xFF8A3D, 0xFF9A55),
                           spelling: (0xFF3B30, 0xFF453A), grammar: (0x007AFF, 0x0A84FF), clarity: (0xAF52DE, 0xBF5AF2),
                           punctuation: (0xFF9500, 0xFF9F0A), rewrite: (0x30B0C7, 0x40CBE0)),
            .eased: make(.eased, brand: (0xF45073, 0xF56888), brand2: (0xF69050, 0xF79E64),
                         spelling: (0xF44E40, 0xF45548), grammar: (0x267DF0, 0x2C86F1), clarity: (0xAA5BD4, 0xBA64E7),
                         punctuation: (0xF79A38, 0xF7A33C), rewrite: (0x48AEC2, 0x58C9DB)),
            .muted: make(.muted, brand: (0xE55A74, 0xE76E88), brand2: (0xEA925D, 0xEC9F6E),
                         spelling: (0xE5594B, 0xE55F51), grammar: (0x357CDE, 0x3B85E0), clarity: (0xA260C6, 0xB169D8),
                         punctuation: (0xEB9B4D, 0xECA451), rewrite: (0x56A9BA, 0x68C3D3)),
            .dusty: make(.dusty, brand: (0xD36073, 0xD67185), brand2: (0xDA9066, 0xDD9D74),
                         spelling: (0xD25F51, 0xD36357), grammar: (0x3E78C9, 0x4480CB), clarity: (0x9761B5, 0xA66BC6),
                         punctuation: (0xDB995B, 0xDDA15F), rewrite: (0x5EA1AF, 0x71BBC8)),
        ]
    }()
}

// MARK: - Gradients

extension DS {
    /// Brand gradient: 135° (top-left → bottom-right), `brand2` → `brand`. Text on it is always white.
    static var brandGradient: LinearGradient {
        LinearGradient(colors: [brand2, brand], startPoint: .topLeading, endPoint: .bottomTrailing)
    }
    /// Horizontal variant used by thin bars (meter, download bar, current progress dot).
    static var brandGradientHorizontal: LinearGradient {
        LinearGradient(colors: [brand2, brand], startPoint: .leading, endPoint: .trailing)
    }
    /// App icon gradient (145°).
    static var appIconGradient: LinearGradient {
        LinearGradient(colors: [brand2, brand], startPoint: UnitPoint(x: 0.21, y: 0), endPoint: UnitPoint(x: 0.79, y: 1))
    }

    /// Model glyph gradients (§3), keyed by catalog model ID prefix.
    static func modelGradient(for modelID: String) -> LinearGradient {
        let pair: (UInt32, UInt32)
        switch modelID {
        case let id where id.hasPrefix("gemma-4-e4b"): pair = (0x4F8BFF, 0x22C3B5)
        case let id where id.hasPrefix("gemma-4-e2b"): pair = (0x22C3B5, 0x7CD957)
        case let id where id.hasPrefix("qwen"): pair = (0x8B5CF6, 0xEC4899)
        case let id where id.hasPrefix("llama"): pair = (0x0866FF, 0x5AC8FA)
        default: pair = (0x8E8E93, 0x636366)
        }
        return LinearGradient(colors: [Color(nsColor: .hex(pair.0)), Color(nsColor: .hex(pair.1))],
                              startPoint: .topLeading, endPoint: .bottomTrailing)
    }
}

// MARK: - Shadows (§2.3)

/// One CSS box-shadow layer. SwiftUI shadows have no spread, so a negative spread is approximated by a
/// smaller radius (blur / 2) and a lower opacity; the result was compared with the screenshots by eye.
struct DSShadow {
    let color: Color
    let radius: CGFloat
    let x: CGFloat
    let y: CGFloat
}

extension DS {
    static let windowShadow: [DSShadow] = [
        DSShadow(color: dynamic("shadow1", light: .rgba(70, 20, 50, 0.30), dark: .rgba(0, 0, 0, 0.55)), radius: 30, x: 0, y: 26),
        DSShadow(color: dynamic("shadow2", light: .rgba(70, 20, 50, 0.20), dark: .rgba(0, 0, 0, 0.45)), radius: 9, x: 0, y: 8),
    ]
    static let islandShadow: [DSShadow] = [DSShadow(color: .black.opacity(0.45), radius: 16, x: 0, y: 14)]
    /// `0 4 12 -4 brand`
    static var primaryShadow: DSShadow { DSShadow(color: brand.opacity(0.7), radius: 4, x: 0, y: 3) }
    /// `0 8 20 -8 brand` (popover check button)
    static var checkButtonShadow: DSShadow { DSShadow(color: brand.opacity(0.7), radius: 7, x: 0, y: 6) }
}

extension View {
    func dsShadow(_ layers: [DSShadow]) -> some View {
        layers.reduce(AnyView(self)) { view, s in AnyView(view.shadow(color: s.color, radius: s.radius, x: s.x, y: s.y)) }
    }

    func dsShadow(_ s: DSShadow) -> some View {
        shadow(color: s.color, radius: s.radius, x: s.x, y: s.y)
    }
}

// MARK: - Typography (§2.4)

extension DS {
    enum Font {
        static let swap = SwiftUI.Font.system(size: 24, weight: .semibold)
        static let aboutTitle = SwiftUI.Font.system(size: 24, weight: .bold)
        static let paneTitle = SwiftUI.Font.system(size: 20, weight: .bold)
        static let bubbleSuggestion = SwiftUI.Font.system(size: 19, weight: .semibold)
        static let island = SwiftUI.Font.system(size: 15)
        static let islandStrong = SwiftUI.Font.system(size: 15, weight: .semibold)
        static let popoverCheck = SwiftUI.Font.system(size: 14.5, weight: .semibold)
        static let popoverApp = SwiftUI.Font.system(size: 14, weight: .semibold)
        static let toast = SwiftUI.Font.system(size: 13.5, weight: .medium)
        static let toastDetail = SwiftUI.Font.system(size: 13.5)
        static let body = SwiftUI.Font.system(size: 13)
        static let bodyMedium = SwiftUI.Font.system(size: 13, weight: .medium)
        static let bodySemibold = SwiftUI.Font.system(size: 13, weight: .semibold)
        static let link = SwiftUI.Font.system(size: 12.5)
        static let linkStrong = SwiftUI.Font.system(size: 12.5, weight: .semibold)
        static let small = SwiftUI.Font.system(size: 12, weight: .medium)
        static let chip = SwiftUI.Font.system(size: 12, weight: .semibold)
        static let caption = SwiftUI.Font.system(size: 11.5)
        static let pill = SwiftUI.Font.system(size: 11.5, weight: .semibold)
        static let kbd = SwiftUI.Font.system(size: 11, weight: .medium)
        static let footnote = SwiftUI.Font.system(size: 11)
    }

    /// Line spacing (extra points) for ~1.4 line height at 13 pt, and 1.45 for reason lines.
    static let bodyLineSpacing: CGFloat = 5
    static let reasonLineSpacing: CGFloat = 6
}

// MARK: - Radii and spacing (§2.5)

extension DS {
    enum Radius {
        static let island: CGFloat = 26
        static let popover: CGFloat = 24
        static let card: CGFloat = 22
        static let bubble: CGFloat = 18
        static let window: CGFloat = 18
        static let tile: CGFloat = 16
        static let group: CGFloat = 14
        static let suggestion: CGFloat = 12
        static let highlight: CGFloat = 10
        static let field: CGFloat = 9
        static let glyph: CGFloat = 9
        static let row: CGFloat = 8
        static let link: CGFloat = 6
        static let iconSquare: CGFloat = 6
        static let kbd: CGFloat = 5
        static let underline: CGFloat = 5
    }

    /// Spacing scale: 2, 4, 6, 8, 10, 12, 14, 16, 18, 24.
    enum Space {
        static let xxs: CGFloat = 2
        static let xs: CGFloat = 4
        static let s6: CGFloat = 6
        static let s: CGFloat = 8
        static let s10: CGFloat = 10
        static let m: CGFloat = 12
        static let s14: CGFloat = 14
        static let l: CGFloat = 16
        static let s18: CGFloat = 18
        static let xl: CGFloat = 24
    }
}

// MARK: - Accessibility display settings (§11)

extension DS {
    enum A11y {
        #if DEBUG
        /// DEBUG launch flags that force the display settings, so the gallery and the demo popups can be
        /// checked without changing System Settings › Accessibility on the test Mac.
        static let forceReduceMotion = CommandLine.arguments.contains("--reduce-motion")
        static let forceIncreaseContrast = CommandLine.arguments.contains("--increase-contrast")
        static let forceDifferentiateWithoutColor = CommandLine.arguments.contains("--differentiate-without-color")
        #else
        static let forceReduceMotion = false
        static let forceIncreaseContrast = false
        static let forceDifferentiateWithoutColor = false
        #endif

        /// Increase Contrast, for AppKit drawing (SwiftUI views use `\.colorSchemeContrast`, see `isIncreased`).
        @MainActor static var increaseContrast: Bool {
            forceIncreaseContrast || NSWorkspace.shared.accessibilityDisplayShouldIncreaseContrast
        }
    }
}

extension ColorSchemeContrast {
    /// Increase Contrast is on (or forced by the DEBUG `--increase-contrast` flag).
    var isIncreased: Bool { self == .increased || DS.A11y.forceIncreaseContrast }
}

// MARK: - Motion (§2.6)

extension DS {
    enum Motion {
        /// `NSWorkspace` Reduce Motion setting; read each time so a change applies without a relaunch.
        @MainActor static var reduceMotion: Bool {
            A11y.forceReduceMotion || NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        }

        static let fade = Animation.easeOut(duration: 0.15)
        /// Card, bubble, toasts, popover appear.
        static let popInSpring = Animation.spring(response: 0.32, dampingFraction: 0.72)
        static let islandInCurve = Animation.timingCurve(0.2, 1.3, 0.4, 1, duration: 0.45)
        static let islandExpand = Animation.timingCurve(0.3, 1.1, 0.4, 1, duration: 0.32)
        static let switchKnob = Animation.timingCurve(0.3, 1.4, 0.5, 1, duration: 0.22)
        static let appliedFlashDuration: TimeInterval = 1.4
        static let wave = Animation.easeInOut(duration: 0.45).repeatForever(autoreverses: true)
        static let waveStagger: TimeInterval = 0.15
        static let spinner = Animation.linear(duration: 0.7).repeatForever(autoreverses: false)
        static let menuPulse = Animation.easeInOut(duration: 0.5).repeatForever(autoreverses: true)

        /// `popIn`, or a plain fade with Reduce Motion.
        @MainActor static var popIn: Animation { reduceMotion ? fade : popInSpring }
        /// `islandIn`, or a plain fade with Reduce Motion.
        @MainActor static var islandIn: Animation { reduceMotion ? fade : islandInCurve }
        /// Applied-word flash, or none with Reduce Motion.
        @MainActor static var appliedFlash: Animation? { reduceMotion ? nil : .easeOut(duration: appliedFlashDuration) }
    }
}

/// `popIn` transition: from opacity 0, y −6, scale .96 (fade only with Reduce Motion).
struct PopInModifier: ViewModifier {
    let active: Bool
    func body(content: Content) -> some View {
        let move = active && !DS.Motion.reduceMotion
        content.opacity(active ? 0 : 1).scaleEffect(move ? 0.96 : 1).offset(y: move ? -6 : 0)
    }
}

extension AnyTransition {
    @MainActor static var dsPopIn: AnyTransition {
        DS.Motion.reduceMotion ? .opacity
            : .modifier(active: PopInModifier(active: true), identity: PopInModifier(active: false))
    }
}

// MARK: - NSColor helpers (Design/ only)

extension NSColor {
    static func hex(_ rgb: UInt32, _ alpha: CGFloat = 1) -> NSColor {
        NSColor(srgbRed: CGFloat((rgb >> 16) & 0xFF) / 255, green: CGFloat((rgb >> 8) & 0xFF) / 255,
                blue: CGFloat(rgb & 0xFF) / 255, alpha: alpha)
    }

    static func rgba(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat, _ a: CGFloat) -> NSColor {
        NSColor(srgbRed: r / 255, green: g / 255, blue: b / 255, alpha: a)
    }
}
