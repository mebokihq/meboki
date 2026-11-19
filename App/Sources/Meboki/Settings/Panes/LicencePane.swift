import AppKit
import MebokiCore
import SwiftUI

/// Settings › Licence (PLAN.md §6 "App-side licensing" › "Settings › Licence", design_code.md §8): the status card
/// (trial meter, free mode, licensed), then by state: buy and the key field, or the key and Remove Licence…
/// Everything is checked on this Mac; "Buy a Licence" only opens the browser.
struct LicencePane: View {
    @ObservedObject var model: SettingsModel
    @ObservedObject var settings: AppSettings
    @ObservedObject var licence: LicenceManager
    @State private var confirmRemove = false

    private var hotkey: String { settings.hotkey.display }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            statusCard.padding(.bottom, 6)
            if let info = licence.licence {
                licensedGroups(info)
                if !model.licenceKeyDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    replaceGroup
                }
            } else {
                getGroups
                addsGroup
            }
            SettingsFootnote(symbol: "lock", text: "The key is checked on this Mac. No account, nothing is sent.")
            HStack(spacing: 6) {
                Image(systemName: "arrow.uturn.backward").font(.system(size: 13))
                Text("Refunds within 14 days:")
                Button(LicenceManager.supportEmail) { Self.openMail() }.buttonStyle(.dsLink).padding(.leading, -6)
                Spacer(minLength: 0)
            }
            .font(.system(size: 12))
            .foregroundStyle(DS.textSecondary)
            .padding(EdgeInsets(top: 8, leading: 4, bottom: 0, trailing: 0))
        }
        .alert("Remove the licence from this Mac?", isPresented: $confirmRemove) {
            Button("Remove", role: .destructive) {
                licence.removeLicence()
                model.showToast(.info, "Licence removed from this Mac")
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Meboki goes back to free mode here. Keep your key to use it again.")
        }
    }

    // MARK: Status card

    @ViewBuilder private var statusCard: some View {
        switch licence.entitlement {
        case .licensed(let info): licensedCard(info)
        case .trial: trialCard
        case .free(let reason): freeCard(reason)
        }
    }

    /// Padding 18, radius 16, a tinted gradient and a 52 pt badge (like the Privacy hero).
    private func card<Extra: View>(symbol: String, badge: [Color], tint: Color, title: String, line: String,
                                   @ViewBuilder extra: () -> Extra) -> some View {
        HStack(spacing: 16) {
            Circle()
                .fill(LinearGradient(colors: badge, startPoint: .topLeading, endPoint: .bottomTrailing))
                .overlay(Image(systemName: symbol).font(.system(size: 22, weight: .semibold)).foregroundStyle(DS.onAccent))
                .frame(width: 52, height: 52)
                .shadow(color: tint.opacity(0.5), radius: 8, x: 0, y: 8)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(.system(size: 16, weight: .semibold)).foregroundStyle(DS.text)
                extra()
                Text(line)
                    .font(DS.Font.link)
                    .foregroundStyle(DS.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .padding(18)
        .background(RoundedRectangle(cornerRadius: DS.Radius.tile, style: .continuous)
            .fill(LinearGradient(colors: [tint.opacity(0.16), tint.opacity(0.07)],
                                 startPoint: .topLeading, endPoint: .bottomTrailing)))
        .accessibilityElement(children: .combine)
    }

    private var trialCard: some View {
        let used = licence.trialDaysUsed
        let line: String
        if licence.isLastTrialDay {
            line = "Last day · everything stays on until midnight"
        } else if used == 0 {
            line = "\(licence.trialDaysLeft) days left · starts with your first check"
        } else {
            let n = licence.trialDaysLeft
            line = "\(n) \(n == 1 ? "day" : "days") left · only days you check text count"
        }
        return card(symbol: "sparkles", badge: [DS.brand2, DS.brand], tint: DS.brand, title: "Full trial", line: line) {
            TrialMeter(used: used)
        }
    }

    private func freeCard(_ reason: FreeReason) -> some View {
        let line = reason == .trialEnded
            ? "Meboki checks only when you press \(hotkey). Your settings are saved and come back with a licence."
            : "\(reason.message)\nMeboki checks only when you press \(hotkey)."
        let bad = reason != .trialEnded
        return card(symbol: bad ? "exclamationmark.triangle.fill" : "lock.fill",
                    badge: bad ? [Color(nsColor: .hex(0xFF8A80)), DS.catSpelling]
                               : [Color(nsColor: .hex(0xA3A3AB)), Color(nsColor: .hex(0x636366))],
                    tint: bad ? DS.catSpelling : DS.textSecondary,
                    title: "Free mode", line: line) {
            EmptyView()
        }
    }

    private func licensedCard(_ info: LicenceInfo) -> some View {
        let date = Self.format(info.issued)
        var line = "\(info.seats) \(info.seats == 1 ? "Mac" : "Macs") · since \(date)"
        if let exp = info.expires { line += " · valid until \(Self.format(exp))" }
        if info.sandbox { line += " · test purchase, works only in development builds" }
        return card(symbol: "checkmark.seal.fill", badge: [Color(nsColor: .hex(0x5EE08A)), DS.ok], tint: DS.ok,
                    title: "Licensed to \(info.email)", line: line) { EmptyView() }
    }

    private static func format(_ date: Date) -> String {
        date.formatted(.dateTime.month(.abbreviated).day().year())
    }

    // MARK: Not licensed

    @ViewBuilder private var getGroups: some View {
        SettingsGroupHeader("Get a licence")
        SettingsGroup {
            SettingsRow("Unlock everything", subtitle: "One payment. No subscription. Stays with you forever. The key arrives by email.") {
                Button("Buy a Licence") { NSWorkspace.shared.open(LicenceManager.buyURL) }
                    .buttonStyle(.dsPrimary)
            }
        }
        SettingsGroupHeader("Have a key?")
        SettingsGroup { keyEntry }
        HStack {
            Spacer(minLength: 0)
            Button("Lost your key?") { NSWorkspace.shared.open(LicenceManager.lostKeyURL) }.buttonStyle(.dsLink)
        }
        .padding(.top, 4)
    }

    /// Key field, result line, Paste and Activate.
    private var keyEntry: some View {
        VStack(alignment: .leading, spacing: 10) {
            keyField
            HStack(spacing: 8) {
                resultLine
                Spacer(minLength: 0)
                Button("Paste") { paste() }.buttonStyle(.ds(.secondary, small: true))
                Button("Activate") { activate() }
                    .buttonStyle(.ds(.primary, small: true))
                    .disabled(model.licenceKeyDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(14)
    }

    /// Shown while licensed only when a key waits in the field (a `meboki://` link brought another one, or a
    /// failed replacement): Activate replaces the licence, Clear drops the draft.
    @ViewBuilder private var replaceGroup: some View {
        SettingsGroupHeader("Replace the licence")
        SettingsGroup { keyEntry }
        HStack {
            Spacer(minLength: 0)
            Button("Cancel") { model.licenceKeyDraft = ""; model.licenceError = nil; model.licenceNote = nil }
                .buttonStyle(.dsLink)
        }
        .padding(.top, 4)
    }

    /// Several lines are fine: mail clients wrap the key (the pasted text is cleaned before it is checked).
    private var keyField: some View {
        TextField("MEBOKI-…", text: $model.licenceKeyDraft, axis: .vertical)
            .textFieldStyle(.plain)
            .font(.system(size: 12, design: .monospaced))
            .foregroundStyle(DS.text)
            .lineLimit(3...3)
            .autocorrectionDisabled()
            .onSubmit { activate() }
            .padding(.vertical, 8)
            .padding(.horizontal, 10)
            .frame(maxWidth: .infinity, alignment: .topLeading)
            .background(KeyFieldBackground(recording: false))
            .onChange(of: model.licenceKeyDraft) { _, _ in model.licenceError = nil }
            .accessibilityLabel("Licence key")
    }

    @ViewBuilder private var resultLine: some View {
        if let error = model.licenceError {
            HStack(alignment: .firstTextBaseline, spacing: 5) {
                Image(systemName: "exclamationmark.circle.fill").font(.system(size: 11))
                Text(error).fixedSize(horizontal: false, vertical: true)
            }
            .font(DS.Font.caption)
            .foregroundStyle(DS.catSpelling)
            .accessibilityElement(children: .combine)
        } else if let note = model.licenceNote {
            Text(note)
                .font(DS.Font.caption)
                .foregroundStyle(DS.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func paste() {
        guard let text = NSPasteboard.general.string(forType: .string), !text.isEmpty else {
            NSSound.beep()
            return
        }
        model.licenceKeyDraft = text
    }

    private func activate() {
        let text = model.licenceKeyDraft
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        switch licence.activate(text) {
        case .success(let info):
            model.licenceKeyDraft = ""
            model.licenceError = nil
            model.licenceNote = nil
            model.showToast(.success, "Licensed to \(info.email)")
        case .failure(let error):
            model.licenceNote = nil
            model.licenceError = error.message
        }
    }

    // MARK: What a licence adds

    private var addsGroup: some View {
        VStack(alignment: .leading, spacing: 0) {
            SettingsGroupHeader("What a licence adds")
            SettingsGroup {
                addsRow("text.cursor", "Underlines as you type", "Checks the field you type in when you pause")
                SettingsDivider()
                addsRow("bubble.left", "Bubble and island popups", "Free mode uses the glass card")
                SettingsDivider()
                addsRow("slider.horizontal.3", "Check for and casual mode", "Tune what Meboki flags, and relax in chat apps")
                SettingsDivider()
                addsRow("macwindow", "Per-app On and Casual", "Choose automatic checking app by app")
            }
            SettingsFootnote(symbol: "checkmark.circle",
                             text: "Always free: checking with \(hotkey), every model and your own API key, applying fixes, all privacy settings.")
        }
    }

    private func addsRow(_ symbol: String, _ title: String, _ subtitle: String) -> some View {
        SettingsRow(leading: {
            HStack(spacing: 12) {
                Circle().fill(DS.brandSoft)
                    .overlay(Image(systemName: symbol).font(.system(size: 12, weight: .semibold)).foregroundStyle(DS.brand))
                    .frame(width: 28, height: 28)
                    .accessibilityHidden(true)
                SettingsLabel(title: title, subtitle: subtitle)
            }
        }, control: { EmptyView() })
    }

    // MARK: Licensed

    @ViewBuilder private func licensedGroups(_ info: LicenceInfo) -> some View {
        SettingsGroupHeader("Your licence")
        SettingsGroup {
            SettingsRow(leading: {
                SettingsLabel(title: "Licence key", subtitle: Self.truncated(info.key), monospacedSubtitle: true)
            }, control: {
                Button("Copy Key") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(info.key, forType: .string)
                    model.showToast(.success, "Key copied")
                }
                .buttonStyle(.ds(.secondary, small: true))
            })
            SettingsDivider()
            SettingsRow("Move to another Mac", subtitle: "Remove the licence from this Mac, then use the key there.") {
                Button("Remove Licence…") { confirmRemove = true }.buttonStyle(.ds(.secondary, small: true))
            }
        }
    }

    /// First and last characters of the key, joined by an ellipsis.
    private static func truncated(_ key: String) -> String {
        key.count > 28 ? "\(key.prefix(16))…\(key.suffix(8))" : key
    }

    private static func openMail() {
        if let url = URL(string: "mailto:\(LicenceManager.supportEmail)") { NSWorkspace.shared.open(url) }
    }
}

/// Seven segments, one per trial day; the days used are filled with the brand gradient.
private struct TrialMeter: View {
    let used: Int

    var body: some View {
        HStack(spacing: 4) {
            ForEach(0..<TrialClock.length, id: \.self) { i in
                Capsule()
                    .fill(i < used ? AnyShapeStyle(DS.brandGradientHorizontal) : AnyShapeStyle(DS.control2))
                    .frame(height: 8)
            }
        }
        .frame(maxWidth: 260)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(used) of \(TrialClock.length) trial days used")
    }
}
