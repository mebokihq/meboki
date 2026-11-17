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
                SettingsRow("Check text") { HotkeyField(model: model, shortcut: settings.hotkey) }
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
