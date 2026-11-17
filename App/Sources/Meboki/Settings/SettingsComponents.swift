import AppKit
import SwiftUI

// Building blocks of the Settings panes (design_code.md §8 "Content pane").

/// Group header: 12 pt semibold `textSecondary`, margin 18 0 6 12 (no top margin on the first one).
struct SettingsGroupHeader: View {
    let title: String
    var first = false

    init(_ title: String, first: Bool = false) {
        self.title = title
        self.first = first
    }

    var body: some View {
        Text(title)
            .font(.system(size: 12, weight: .semibold))
            .foregroundStyle(DS.textSecondary)
            .padding(EdgeInsets(top: first ? 0 : 18, leading: 12, bottom: 6, trailing: 0))
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityAddTraits(.isHeader)
    }
}

/// Group: `group` fill, radius 14, 0.5 pt inner `separator` ring (1 pt `separatorHigh` with Increase
/// Contrast). Put `SettingsDivider()` between rows.
struct SettingsGroup<Content: View>: View {
    @ViewBuilder let content: Content
    @Environment(\.colorSchemeContrast) private var contrast

    var body: some View {
        VStack(spacing: 0) { content }
            .background {
                let shape = RoundedRectangle(cornerRadius: DS.Radius.group, style: .continuous)
                let high = contrast.isIncreased
                shape.fill(DS.group)
                    .overlay(shape.strokeBorder(high ? DS.separatorHigh : DS.separator, lineWidth: high ? 1 : 0.5))
            }
    }
}

/// 0.5 pt `separator` line between rows (1 pt `separatorHigh` with Increase Contrast).
struct SettingsDivider: View {
    var body: some View { DSSeparator() }
}

/// Row: padding 10 × 14, min height 46, gap 14. Label 13 pt medium with an optional 11.5 pt subtitle; the
/// control on the right.
struct SettingsRow<Leading: View, Control: View>: View {
    @ViewBuilder let leading: Leading
    @ViewBuilder let control: Control

    var body: some View {
        HStack(spacing: 14) {
            leading.frame(maxWidth: .infinity, alignment: .leading)
            control
        }
        .padding(.vertical, 10)
        .padding(.horizontal, 14)
        .frame(minHeight: 46)
        .accessibilityElement(children: .contain)
    }
}

extension SettingsRow where Leading == SettingsLabel {
    init(_ title: String, subtitle: String? = nil, @ViewBuilder control: () -> Control) {
        leading = SettingsLabel(title: title, subtitle: subtitle)
        self.control = control()
    }
}

/// The row label: 13 pt medium, optional 11.5 pt `textSecondary` subtitle.
struct SettingsLabel: View {
    let title: String
    var subtitle: String?
    var monospacedSubtitle = false

    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(title).font(DS.Font.bodyMedium).foregroundStyle(DS.text)
            if let subtitle {
                Text(subtitle)
                    .font(monospacedSubtitle ? .system(size: 11.5, design: .monospaced) : DS.Font.caption)
                    .foregroundStyle(DS.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

/// The DS switch with no label (§4 Switch).
struct SettingsSwitch: View {
    @Binding var isOn: Bool
    var label: String

    var body: some View {
        // The DS switch style draws its label, so the label stays empty and goes to accessibility only.
        Toggle(isOn: $isOn) { EmptyView() }
            .toggleStyle(.dsSwitch)
            .accessibilityLabel(label)
    }
}

/// Keycap field (`.hk`): `field` fill, radius 9, 0.5 pt `separator` ring, padding 4, gap 3, one 12.5 pt
/// keycap per key (padding 4 × 7).
struct KeyField: View {
    let glyphs: [String]

    var body: some View {
        HStack(spacing: 3) {
            ForEach(glyphs.indices, id: \.self) { i in
                Text(glyphs[i])
                    .font(.system(size: 12.5, weight: .medium))
                    .foregroundStyle(DS.text)
                    .fixedSize()
                    .padding(.vertical, 4)
                    .padding(.horizontal, 7)
                    .background(RoundedRectangle(cornerRadius: DS.Radius.kbd, style: .continuous).fill(DS.control))
            }
        }
        .padding(4)
        .background(KeyFieldBackground(recording: false))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Kbd.spoken(glyphs.joined()))
    }
}

struct KeyFieldBackground: View {
    let recording: Bool
    @Environment(\.colorSchemeContrast) private var contrast
    var body: some View {
        let shape = RoundedRectangle(cornerRadius: DS.Radius.field, style: .continuous)
        let high = contrast.isIncreased
        shape.fill(DS.field)
            .shadow(color: .black.opacity(0.06), radius: 1, x: 0, y: 1)
            .overlay(shape.strokeBorder(recording ? DS.brand : high ? DS.separatorHigh : DS.separator,
                                        lineWidth: recording ? 2 : high ? 1 : 0.5))
    }
}

/// Footer note under a group: 12 pt `textSecondary` with a leading symbol, margin 12 4 0.
struct SettingsFootnote<Trailing: View>: View {
    let symbol: String
    let text: String
    @ViewBuilder var trailing: Trailing

    var body: some View {
        HStack(alignment: .center, spacing: 6) {
            Image(systemName: symbol).font(.system(size: 13))
            Text(text).fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
            trailing
        }
        .font(.system(size: 12))
        .foregroundStyle(DS.textSecondary)
        .padding(EdgeInsets(top: 12, leading: 4, bottom: 0, trailing: 0))
    }
}

extension SettingsFootnote where Trailing == EmptyView {
    init(symbol: String, text: String) {
        self.symbol = symbol
        self.text = text
        trailing = EmptyView()
    }
}

/// Error pill ("Failed"): `catSpelling` on a 14% fill, like the other pills (§4).
struct ErrorPill: View {
    let title: String
    var body: some View {
        Text(title)
            .font(DS.Font.pill)
            .foregroundStyle(DS.catSpelling)
            .padding(.vertical, 3)
            .padding(.horizontal, 9)
            .background(Capsule().fill(DS.catSpelling.opacity(0.14)))
    }
}

/// An app's icon from its bundle ID (26 pt, radius 7 stand-in with the initial when the app is gone).
struct AppIcon: View {
    let bundleID: String
    let name: String
    var size: CGFloat = 26

    var body: some View {
        if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) {
            Image(nsImage: NSWorkspace.shared.icon(forFile: url.path))
                .resizable()
                .frame(width: size, height: size)
                .accessibilityHidden(true)
        } else {
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .fill(DS.control2)
                .overlay(Text(String(name.prefix(1))).font(.system(size: 12, weight: .bold)).foregroundStyle(DS.onAccent))
                .frame(width: size, height: size)
                .accessibilityHidden(true)
        }
    }
}
