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
    /// Overrides `DS.popupOpacity` for the popups below (the Appearance preview follows the slider live).
    @Entry var dsPopupOpacity: Double? = nil
}

/// Glass material (§2.2): blur, a tint fill, a 0.5 pt `edge` outline and a 1 pt `glassHighlight` inner top edge.
/// With Increase Contrast it becomes a solid `window` fill with a 1 pt `separatorHigh` outline (§11). With Reduce
/// Transparency the system blur turns flat grey under the tint, so it is a solid `window` fill there too.
///
/// `popup` marks a correction popup (card, bubble, toast): it follows Settings › Appearance › Popup opacity
/// (`DS.popupOpacity`). The menu-bar popover and Settings keep the standard glass.
struct GlassBackground<S: Shape>: View {
    let shape: S
    var tint: Color = DS.glass
    var highlight = true
    var popup = false
    @Environment(\.dsGlassBlending) private var blending
    @Environment(\.dsGlassBlur) private var blur
    @Environment(\.dsPopupOpacity) private var opacityOverride
    @Environment(\.colorSchemeContrast) private var contrast
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    var body: some View {
        let o = opacityOverride ?? DS.popupOpacity
        let glass = popup ? DS.popupGlass(o) : 1
        let solid = popup ? DS.popupSolid(o) : 0
        // Fading blur and tint each by `glass` would let less backdrop through than one layer at `glass`
        // (the two fades multiply). The blur's alpha is solved so both together cover exactly `glass`.
        let blurAlpha = glass < 1 ? DS.popupBlurAlpha(glass: glass, tintAlpha: DS.alpha(of: tint)) : 1
        if contrast.isIncreased {
            shape.fill(DS.window).overlay(shape.stroke(DS.separatorHigh, lineWidth: 1))
        } else if reduceTransparency {
            shape.fill(DS.window).overlay(shape.stroke(DS.edge, lineWidth: 1))
        } else {
            ZStack {
                Group {
                    if blur {
                        VisualEffectBlur(material: .popover, blending: blending).clipShape(shape)
                    } else {
                        shape.fill(DS.window.opacity(0.9))
                    }
                }
                .opacity(blurAlpha)
                shape.fill(tint).opacity(glass)
                if solid > 0 { shape.fill(DS.window.opacity(solid)) }
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
/// Contrast, so the island's edge shows against a dark menu bar or wallpaper. Below the default popup opacity
/// (`DS.popupHUD`) the fill lets the menu bar show through; never with Increase Contrast or Reduce Transparency.
struct HUDBackground<S: Shape>: View {
    let shape: S
    @Environment(\.dsPopupOpacity) private var opacityOverride
    @Environment(\.colorSchemeContrast) private var contrast
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    var body: some View {
        let fill = contrast.isIncreased || reduceTransparency ? 1 : DS.popupHUD(opacityOverride ?? DS.popupOpacity)
        let ring = shape.stroke(contrast.isIncreased ? DS.hudRingHigh : DS.hudRing, lineWidth: 1)
        if fill >= 1 {
            shape.fill(DS.hud).overlay(ring).dsShadow(DS.islandShadow)
        } else {
            // A translucent fill would show its own shadow through it (darker toward the bottom). The shadow
            // comes from an opaque copy of the shape with the shape itself cut out, so only the outside shows.
            ZStack {
                shape.fill(Color.black)
                    .dsShadow(DS.islandShadow)
                    .mask {
                        ZStack {
                            Rectangle().padding(-64)
                            shape.blendMode(.destinationOut)
                        }
                        .compositingGroup()
                    }
                shape.fill(DS.hud.opacity(fill)).overlay(ring)
            }
        }
    }
}
