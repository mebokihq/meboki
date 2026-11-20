import MebokiCore
import SwiftUI

/// The green update badge on the correction popups (design_code.md §8.10 "Popup badge"). A newer version
/// waits: from the day it's found a pill sits in the popup's top row, and from day 7 a banner with an
/// Install button joins it. A click on either closes the popup and opens the update window. The fix keys
/// (⏎ ⇧⏎ ⇥) never reach the badge.
enum UpdateBadgeStyle {
    /// `ok` green, as a fixed color for the dark island (its dark-theme value).
    static let hudGreen = Color(nsColor: .hex(0x30D158))
    /// The Install button fill: a deeper green than `ok`, so the white label reads (≈ 4.5:1).
    static let buttonFill = Color(nsColor: .hex(0x178A3A))
}

/// Pill: capsule, padding 3 9 3 6, 11.5 pt semibold, `arrow.down.circle.fill` + "Update 1.0.3", in `ok` on
/// `ok` 16%. `compact` drops the version (the bubble's top row is 280 wide). `hud` uses the island's colors.
struct UpdatePill: View {
    let badge: UpdateNudge.Badge
    var compact = false
    var hud = false
    let action: () -> Void
    @State private var hovering = false

    private var green: Color { hud ? UpdateBadgeStyle.hudGreen : DS.ok }

    var body: some View {
        Button(action: action) {
            HStack(spacing: 4) {
                Image(systemName: "arrow.down.circle.fill").font(.system(size: 12, weight: .semibold))
                Text(compact ? "Update" : UpdateText.badge(badge.version))
                    .font(DS.Font.pill)
                    .monospacedDigit()
                    .lineLimit(1)
            }
            .foregroundStyle(green)
            .padding(EdgeInsets(top: 3, leading: 6, bottom: 3, trailing: 9))
            .background(Capsule().fill(green.opacity(hovering ? 0.26 : (hud ? 0.18 : 0.16))))
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .fixedSize()
        .onHover { hovering = $0 }
        .help(UpdateText.available(badge.version))
        .accessibilityLabel(UpdateText.available(badge.version))
        .accessibilityHint(UpdateText.badgeHint)
    }
}

/// Banner (day 7 on): radius 12, padding 9 10 9 12, `ok` 15% fill. A 22 pt `ok` circle with a white arrow,
/// "Meboki 1.0.3 is ready" (12.5 pt semibold) over "Found 9 days ago · you're on 1.0.2" (11.5 pt secondary),
/// and a small green "Install…" button. `compact` (the 280-wide bubble) drops the circle and the running
/// version: "Found 9 days ago".
struct UpdateBanner: View {
    let badge: UpdateNudge.Badge
    var compact = false
    var hud = false
    let action: () -> Void

    private var green: Color { hud ? UpdateBadgeStyle.hudGreen : DS.ok }

    var body: some View {
        HStack(spacing: 10) {
            if !compact { circle }
            VStack(alignment: .leading, spacing: 1) {
                Text(UpdateText.bannerTitle(badge.version))
                    .font(DS.Font.linkStrong)
                    .foregroundStyle(hud ? DS.hudText : DS.text)
                Text(compact ? UpdateText.found(daysWaiting: badge.daysWaiting)
                             : UpdateText.bannerDetail(daysWaiting: badge.daysWaiting, current: badge.current))
                    .font(DS.Font.caption)
                    .foregroundStyle(hud ? DS.hudSecondary : DS.textSecondary)
            }
            .lineLimit(1)
            .accessibilityElement(children: .combine)
            Spacer(minLength: 0)
            Button(action: action) { Text(UpdateText.bannerButton) }
                .buttonStyle(UpdateInstallButtonStyle())
                .accessibilityLabel("Install \(badge.version)")
                .accessibilityHint(UpdateText.badgeHint)
        }
        .padding(EdgeInsets(top: 9, leading: compact ? 10 : 12, bottom: 9, trailing: 10))
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(green.opacity(hud ? 0.16 : 0.15)))
    }

    private var circle: some View {
        Circle()
            .fill(green)
            .frame(width: 22, height: 22)
            .overlay(Image(systemName: "arrow.down").font(.system(size: 11, weight: .bold)).foregroundStyle(.white))
            .accessibilityHidden(true)
    }
}

/// Small capsule button (26 high, padding 11, 12 pt medium), white on the deep green.
private struct UpdateInstallButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        UpdateInstallBody(configuration: configuration)
    }
}

private struct UpdateInstallBody: View {
    let configuration: ButtonStyleConfiguration
    @State private var hovering = false

    var body: some View {
        configuration.label
            .font(DS.Font.small)
            .lineLimit(1)
            .foregroundStyle(DS.onAccent)
            .padding(.horizontal, 11)
            .frame(height: 26)
            .background(Capsule().fill(UpdateBadgeStyle.buttonFill)
                .shadow(color: UpdateBadgeStyle.buttonFill.opacity(0.5), radius: 4, x: 0, y: 3))
            .brightness(hovering ? 0.04 : 0)
            .scaleEffect(configuration.isPressed ? 0.97 : 1)
            .contentShape(Capsule())
            .onHover { hovering = $0 }
            .fixedSize()
    }
}
