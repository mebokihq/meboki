import SwiftUI

/// Settings › Shortcuts (design_code.md §8.5): the global hotkey, and the popup keys (read-only).
struct ShortcutsPane: View {
    @ObservedObject var model: SettingsModel
    @ObservedObject var settings: AppSettings

    private static let popupKeys: [(String, [String])] = [
        ("Apply all fixes", ["⏎"]),
        ("Apply this fix", ["⇧⏎"]),
        ("Skip / Ignore", ["⇥"]),
        ("Previous / next fix", ["← →"]),
        ("Close", ["Esc"]),
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            SettingsGroupHeader("Global", first: true)
            SettingsGroup {
                SettingsRow("Check text", subtitle: "Proofreads the focused field, or the selection if there is one") {
                    HotkeyField(model: model, shortcut: settings.hotkey)
                }
            }

            SettingsGroupHeader("In the popup")
            SettingsGroup {
                ForEach(Self.popupKeys.indices, id: \.self) { i in
                    if i > 0 { SettingsDivider() }
                    SettingsRow(Self.popupKeys[i].0) { KeyField(glyphs: Self.popupKeys[i].1) }
                }
            }
        }
    }
}

/// The hotkey field (§8.5): one keycap per key; a click records a new shortcut ("Type a new shortcut…" in
/// brand semibold with a 2 pt brand ring). `SettingsWindowController` takes the key presses.
struct HotkeyField: View {
    @ObservedObject var model: SettingsModel
    let shortcut: Shortcut

    var body: some View {
        Button { model.recording.toggle() } label: {
            Group {
                if model.recording {
                    Text("Type a new shortcut…")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(DS.brand)
                        .padding(.horizontal, 10)
                        // Same height as the keycaps, so the row doesn't jump.
                        .frame(height: 31)
                } else {
                    HStack(spacing: 3) {
                        ForEach(shortcut.glyphs.indices, id: \.self) { i in
                            Text(shortcut.glyphs[i])
                                .font(.system(size: 12.5, weight: .medium))
                                .foregroundStyle(DS.text)
                                .fixedSize()
                                .padding(.vertical, 4)
                                .padding(.horizontal, 7)
                                .background(RoundedRectangle(cornerRadius: DS.Radius.kbd, style: .continuous)
                                    .fill(DS.control))
                        }
                    }
                    .padding(4)
                }
            }
            .background(KeyFieldBackground(recording: model.recording))
            .contentShape(RoundedRectangle(cornerRadius: DS.Radius.field, style: .continuous))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(model.recording ? "Type a new shortcut" : "Shortcut \(Kbd.spoken(shortcut.display))")
        .accessibilityHint("Click to record a new shortcut. Escape cancels.")
    }
}
