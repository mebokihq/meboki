import AppKit
import SwiftUI

/// `NSVisualEffectView` for SwiftUI. Popups use `.behindWindow` so they blur the desktop and the target app;
/// the DEBUG gallery uses `.withinWindow` so the glass blurs its own backdrop.
struct VisualEffectBlur: NSViewRepresentable {
    var material: NSVisualEffectView.Material = .popover
    var blending: NSVisualEffectView.BlendingMode = .behindWindow

    func makeNSView(context: Context) -> NSVisualEffectView {
        let v = NSVisualEffectView()
        v.state = .active
        v.isEmphasized = false
        return v
    }

    func updateNSView(_ v: NSVisualEffectView, context: Context) {
        v.material = material
        v.blendingMode = blending
        // Follow the SwiftUI color scheme, so a view forced to light or dark gets a matching material.
        v.appearance = NSAppearance(named: context.environment.colorScheme == .dark ? .darkAqua : .aqua)
    }
}

extension EnvironmentValues {
    /// Blending mode for every `GlassBackground` below; the gallery sets `.withinWindow`.
    @Entry var dsGlassBlending: NSVisualEffectView.BlendingMode = .behindWindow
    /// False draws glass without the system blur (a translucent `window` fill under the tint): for popups drawn
    /// scaled inside a SwiftUI scene (`PopupPreview`), where an `NSVisualEffectView` doesn't follow the scale.
    @Entry var dsGlassBlur = true
}

/// Glass material (§2.2): blur, a tint fill, a 0.5 pt `edge` outline and a 1 pt `glassHighlight` inner top edge.
/// With Increase Contrast it becomes a solid `window` fill with a 1 pt `separatorHigh` outline (§11). With Reduce
/// Transparency the system blur turns flat grey under the tint, so it is a solid `window` fill there too.
struct GlassBackground<S: Shape>: View {
    let shape: S
    var tint: Color = DS.glass
    var highlight = true
    @Environment(\.dsGlassBlending) private var blending
    @Environment(\.dsGlassBlur) private var blur
    @Environment(\.colorSchemeContrast) private var contrast
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    var body: some View {
        if contrast.isIncreased {
            shape.fill(DS.window).overlay(shape.stroke(DS.separatorHigh, lineWidth: 1))
        } else if reduceTransparency {
            shape.fill(DS.window).overlay(shape.stroke(DS.edge, lineWidth: 1))
        } else {
            ZStack {
                if blur {
                    VisualEffectBlur(material: .popover, blending: blending).clipShape(shape)
                } else {
                    shape.fill(DS.window.opacity(0.9))
                }
                shape.fill(tint)
                if highlight { InnerTopHighlight(shape: shape, color: DS.glassHighlight) }
            }
            // A centered 1 pt stroke puts 0.5 pt outside the shape, like CSS `0 0 0 .5px`.
            .overlay(shape.stroke(DS.edge, lineWidth: 1))
        }
    }
}

/// A hairline between sections: 0.5 pt `separator`, or 1 pt `separatorHigh` with Increase Contrast (§11).
/// `color` overrides the normal color (the island uses `hudControl`; with Increase Contrast, `hudRingHigh`).
struct DSSeparator: View {
    var color: Color = DS.separator
    var highColor: Color = DS.separatorHigh
    @Environment(\.colorSchemeContrast) private var contrast

    var body: some View {
        Rectangle().fill(contrast.isIncreased ? highColor : color).frame(height: contrast.isIncreased ? 1 : 0.5)
    }
}

/// CSS `inset 0 1px 0 color`: the shape minus itself shifted down 1 pt, which leaves a thin crescent at the top.
struct InnerTopHighlight<S: Shape>: View {
    let shape: S
    let color: Color
    var body: some View {
        GeometryReader { geo in
            let rect = CGRect(origin: .zero, size: geo.size)
            let outer = shape.path(in: rect)
            let inner = shape.path(in: rect.offsetBy(dx: 0, dy: 1))
            outer.subtracting(inner).fill(color)
        }
        .allowsHitTesting(false)
    }
}

/// Opaque island background (§2.2 HUD) with its ring and shadow. The ring is brighter with Increase
/// Contrast, so the island's edge shows against a dark menu bar or wallpaper.
struct HUDBackground<S: Shape>: View {
    let shape: S
    @Environment(\.colorSchemeContrast) private var contrast
    var body: some View {
        shape.fill(DS.hud)
            .overlay(shape.stroke(contrast.isIncreased ? DS.hudRingHigh : DS.hudRing, lineWidth: 1))
            .dsShadow(DS.islandShadow)
    }
}
