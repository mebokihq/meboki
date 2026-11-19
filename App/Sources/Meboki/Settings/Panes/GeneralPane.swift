import MebokiCore
import SwiftUI

/// Settings › General (design_code.md §8.1): popup style picker, Return key, App group, the shortcut.
struct GeneralPane: View {
    @ObservedObject var model: SettingsModel
    @ObservedObject var settings: AppSettings
    @ObservedObject private var updates = UpdateController.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            FreeModeBanner()
            SettingsGroupHeader("Correction popup", first: true)
            SettingsGroup {
                PopupStylePicker(selection: $settings.popupStyle)
                // A looping demo of the picked style, as in the HTML reference.
                PopupPreview(style: settings.effectivePopupStyle, reasons: settings.explainFixes)
                    .padding(EdgeInsets(top: 0, leading: 14, bottom: 14, trailing: 14))
                SettingsDivider()
                SettingsRow("Return key", subtitle: "⏎ applies all fixes. ⇧⏎ applies only the current one.") {
                    KeyField(glyphs: ["⏎"])
                }
            }

            SettingsGroupHeader("App")
            SettingsGroup {
                SettingsRow("Launch at login") {
                    SettingsSwitch(isOn: Binding(
                        get: { model.launchAtLogin },
                        set: { on in
                            if let error = model.actions.setLaunchAtLogin(on) { model.showToast(.error, error) }
                        }), label: "Launch at login")
                }
                SettingsDivider()
                SettingsRow("Show in menu bar") {
                    SettingsSwitch(isOn: $settings.showInMenuBar, label: "Show in menu bar")
                        .help("When it's off, open Meboki again from Finder or Launchpad to get back to Settings.")
                }
                SettingsDivider()
                // Milestone B step 2: a review started with the hotkey follows typing. Checking any field on its
                // own (FocusTracker) is the next step.
                SettingsRow("Underline mistakes as I type",
                            subtitle: "Checks the text area you type in when you pause, no shortcut needed, and keeps the underlines up to date. Local model only") {
                    SettingsSwitch(isOn: $settings.underlineAsYouType, label: "Underline mistakes as I type")
                        .licenceLocked(.automaticCheck)
                }
            }

            SettingsGroupHeader("Shortcut")
            SettingsGroup {
                SettingsRow("Check text", subtitle: "Proofreads the focused field, or the selection if there is one") {
                    HotkeyField(model: model, shortcut: settings.hotkey)
                }
            }

            // Official builds only: a build from source has no updater.
            if updates.isEnabled {
                SettingsGroupHeader("Updates")
                SettingsGroup {
                    SettingsRow(UpdateText.automaticChecks, subtitle: UpdateText.automaticChecksDetail) {
                        SettingsSwitch(isOn: $updates.automaticChecks, label: UpdateText.automaticChecks)
                    }
                    SettingsDivider()
                    SettingsRow(UpdateText.automaticInstall, subtitle: UpdateText.automaticInstallDetail) {
                        SettingsSwitch(isOn: $updates.automaticInstall, label: UpdateText.automaticInstall)
                            .disabled(!updates.automaticChecks)
                            .opacity(updates.automaticChecks ? 1 : 0.5)
                    }
                    SettingsDivider()
                    SettingsRow(updates.available.map(UpdateText.available) ?? "Version \(UpdateController.currentVersion)",
                                subtitle: UpdateText.lastChecked(updates.lastCheck)) {
                        Button(updates.available == nil ? "Check Now" : "Install…") { model.actions.showUpdate() }
                            .buttonStyle(.ds(updates.available == nil ? .secondary : .primary, small: true))
                            .disabled(!updates.canCheck)
                    }
                }
            }
        }
    }
}

/// The hotkey field (§8.1): one keycap per key; a click records a new shortcut ("Type a new shortcut…" in
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

// MARK: - Popup style picker

/// Three cards in a 3-column grid, gap 12, padding 14 (§8.1).
/// In free mode only the glass card can be picked: it carries the ring, the stored choice (bubble or island)
/// keeps a dashed ring and "Your choice", and a click on a locked card opens the "Needs a licence" popover.
struct PopupStylePicker: View {
    @Binding var selection: PopupStyle
    @Environment(\.licenceGate) private var gate
    @State private var lockedPopover: PopupStyle?

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            ForEach(PopupStyle.allCases, id: \.self) { style in
                let locked = gate.locked && style != .card
                PickerCard(style: style,
                           selected: gate.locked ? style == .card : style == selection,
                           locked: locked,
                           stored: locked && style == selection) {
                    if locked { lockedPopover = style } else { selection = style }
                }
                .popover(isPresented: Binding(get: { lockedPopover == style },
                                              set: { if !$0 && lockedPopover == style { lockedPopover = nil } }),
                         arrowEdge: .bottom) {
                    NeedsLicencePopover(open: gate.open) { lockedPopover = nil }
                }
            }
        }
        .padding(14)
    }
}

private struct PickerCard: View {
    let style: PopupStyle
    let selected: Bool
    var locked = false
    /// Locked, but the user's stored choice (free mode): dashed ring and "Your choice".
    var stored = false
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 6) {
                PickerArt(style: style)
                    .frame(height: 96)
                    .opacity(locked ? 0.5 : 1)
                    .brightness(hovering ? 0.02 : 0)
                    .overlay {
                        let shape = RoundedRectangle(cornerRadius: DS.Radius.suggestion, style: .continuous)
                        if selected {
                            shape.inset(by: -1.25).strokeBorder(DS.brand, lineWidth: 2.5)
                        } else if stored {
                            shape.inset(by: -1.25).strokeBorder(DS.brand.opacity(0.55),
                                                                style: StrokeStyle(lineWidth: 2, dash: [5, 4]))
                        } else {
                            shape.strokeBorder(DS.separator, lineWidth: 0.5)
                        }
                    }
                HStack(spacing: 6) {
                    if selected {
                        Circle().fill(DS.brandGradient)
                            .overlay(Image(systemName: "checkmark").font(.system(size: 8, weight: .heavy))
                                .foregroundStyle(DS.onAccent))
                            .frame(width: 16, height: 16)
                    }
                    Text(name).font(DS.Font.bodySemibold).foregroundStyle(DS.text)
                    if locked { Spacer(minLength: 0); LockBadge(caption: false) }
                }
                if stored {
                    Text("Your choice. It comes back with a licence.")
                        .font(DS.Font.caption).foregroundStyle(DS.brand)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Text(detail)
                    .font(DS.Font.caption)
                    .foregroundStyle(DS.textSecondary)
                    .lineSpacing(1.5)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(name)
        .accessibilityHint(detail)
        .accessibilityAddTraits(selected ? [.isButton, .isSelected] : .isButton)
    }

    private var name: String {
        switch style {
        case .card: "Glass card"
        case .bubble: "Anchored bubble"
        case .island: "Island HUD"
        }
    }

    private var detail: String {
        switch style {
        case .card: "Opens when you click an underline"
        case .bubble: "Small card pointing at the word you click"
        case .island: "Appears under the menu bar after each check"
        }
    }
}

/// The picker's mini art (HTML `.art`): a soft wallpaper, a mini window with three lines (the middle one
/// underlined in `catGrammar`), and the style's popup drawn with shapes.
private struct PickerArt: View {
    let style: PopupStyle
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width
            ZStack(alignment: .topLeading) {
                MiniWallpaper()
                miniWindow(width: w - 24)
                    .offset(x: 12, y: 18)
                popup(width: w)
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: DS.Radius.suggestion, style: .continuous))
    }

    private func miniWindow(width: CGFloat) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            line(width * 0.86 - 20)
            line((width - 20) * 0.7)
                .overlay(alignment: .bottomLeading) {
                    RoundedRectangle(cornerRadius: 1).fill(DS.catGrammar)
                        .frame(width: (width - 20) * 0.7 * 0.28, height: 2)
                        .offset(x: (width - 20) * 0.7 * 0.3, y: 3)
                }
            line((width - 20) * 0.54)
            Spacer(minLength: 0)
        }
        .padding(.vertical, 12)
        .padding(.horizontal, 10)
        .frame(width: width, height: 96 - 18 + 6, alignment: .topLeading)
        .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(DS.window)
            .shadow(color: .black.opacity(0.18), radius: 5, x: 0, y: 4))
    }

    private func line(_ width: CGFloat) -> some View {
        RoundedRectangle(cornerRadius: 3).fill(DS.control2).frame(width: max(0, width), height: 5)
    }

    @ViewBuilder private func popup(width w: CGFloat) -> some View {
        let glass = RoundedRectangle(cornerRadius: 8, style: .continuous)
        switch style {
        case .card:
            glass.fill(DS.glassStrong)
                .overlay(glass.stroke(DS.edge, lineWidth: 0.5))
                .overlay(alignment: .bottomTrailing) {
                    RoundedRectangle(cornerRadius: 4).fill(DS.brandGradient)
                        .frame(width: w * 0.58 * 0.34, height: 8)
                        .padding(6)
                }
                .frame(width: w * 0.58, height: 34)
                .shadow(color: .black.opacity(0.22), radius: 6, x: 0, y: 5)
                .offset(x: w * 0.34, y: 44)
        case .bubble:
            ZStack(alignment: .topLeading) {
                Rectangle().fill(DS.glassStrong)
                    .frame(width: 8, height: 8)
                    .rotationEffect(.degrees(45))
                    .offset(x: 16, y: -4)
                glass.fill(DS.glassStrong)
                    .overlay(glass.stroke(DS.edge, lineWidth: 0.5))
                    .overlay(alignment: .top) {
                        RoundedRectangle(cornerRadius: 3).fill(DS.catGrammar).frame(height: 9)
                            .padding(.horizontal, 6).padding(.top, 7)
                    }
                    .frame(width: w * 0.44, height: 30)
            }
            .shadow(color: .black.opacity(0.22), radius: 6, x: 0, y: 5)
            .offset(x: w * 0.28, y: 48)
        case .island:
            Capsule().fill(DS.hud)
                .overlay(alignment: .trailing) {
                    Capsule().fill(DS.brandGradient).frame(width: w * 0.62 * 0.24, height: 6).padding(.trailing, 4)
                }
                .frame(width: w * 0.62, height: 14)
                .shadow(color: .black.opacity(0.35), radius: 4, x: 0, y: 3)
                .offset(x: w * 0.19, y: 5)
        }
    }
}

/// The mock wallpaper in miniature: peach top-left, pink top-right, cyan bottom-right, lilac bottom-left.
private struct MiniWallpaper: View {
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        let dark = scheme == .dark
        let base: [UInt32] = dark ? [0x1A1222, 0x120F1C, 0x0B1A20] : [0xFFE6D6, 0xFFD3E2, 0xD3F1F6]
        let blobs: [(UInt32, UnitPoint)] = dark
            ? [(0x8A3A1E, .topLeading), (0x7A2E5C, .topTrailing), (0x0F6170, .bottomTrailing), (0x3B2A8C, .bottomLeading)]
            : [(0xFFB287, .topLeading), (0xFF77A9, .topTrailing), (0x5ED0E6, .bottomTrailing), (0xB79CFF, .bottomLeading)]
        ZStack {
            LinearGradient(colors: base.map { Color(nsColor: .hex($0)) }, startPoint: .topLeading, endPoint: .bottomTrailing)
            ForEach(blobs.indices, id: \.self) { i in
                RadialGradient(colors: [Color(nsColor: .hex(blobs[i].0)).opacity(0.85), .clear],
                               center: blobs[i].1, startRadius: 0, endRadius: 90)
            }
        }
    }
}
