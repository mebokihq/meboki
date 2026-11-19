#if DEBUG
import AppKit
import MebokiCore
import SwiftUI

/// Settings › Debug (DEBUG builds only): the licence state at a glance and the controls to walk through the trial,
/// free mode, activation and revocation by hand. Every action goes through the real `LicenceManager` paths, so
/// notices, lock marks and the check flow react exactly as they would for a user.
struct DebugPane: View {
    @ObservedObject var model: SettingsModel
    @ObservedObject var settings: AppSettings
    @ObservedObject var licence: LicenceManager
    @State private var pastDays = 3

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            TimelineView(.periodic(from: .now, by: 1)) { _ in status }

            SettingsGroupHeader("Trial")
            SettingsGroup {
                SettingsRow("Past trial days", subtitle: "Days before today that count; today stays uncounted until a check runs") {
                    Stepper("\(pastDays)", value: $pastDays, in: 0...7).fixedSize()
                    button("Set") { licence.debugSetTrial(pastDays: pastDays, today: false) }
                }
                SettingsDivider()
                SettingsRow("Last day", subtitle: "6 past days + today: day 7, full until midnight") {
                    button("Set") { licence.debugSetTrial(pastDays: 6, today: true) }
                }
                SettingsDivider()
                SettingsRow("Last day, before its first check", subtitle: "6 past days; the next check counts today and should show the last-day toast") {
                    button("Set") { licence.debugSetTrial(pastDays: 6, today: false) }
                }
                SettingsDivider()
                SettingsRow("End trial now", subtitle: "7 past days: free mode, the trial-ended window (once)") {
                    button("End") { licence.debugSetTrial(pastDays: 7, today: false) }
                }
                SettingsDivider()
                SettingsRow("Count today", subtitle: "What a real check does") {
                    button("Record Check") { licence.recordCheck() }
                }
                SettingsDivider()
                SettingsRow("Reset", subtitle: "Fresh trial (Keychain and preferences) and the one-time notices") {
                    button("Notices Only") { licence.debugResetNotices(); model.showToast(.info, "Notice flags reset") }
                    button("Trial + Notices") { licence.debugResetTrial(); model.showToast(.info, "Trial reset") }
                }
            }

            SettingsGroupHeader("Clock (licence only)")
            SettingsGroup {
                SettingsRow("Jump to 23:59:50", subtitle: "With Last day set, watch the trial end at midnight") {
                    button("Jump") { licence.debugJumpToBeforeMidnight(secondsBefore: 10) }
                }
                SettingsDivider()
                SettingsRow("Move forward") {
                    button("+1 Hour") { licence.debugSetClockOffset(DebugClock.offset + 3_600) }
                    button("+1 Day") { licence.debugSetClockOffset(DebugClock.offset + 86_400) }
                }
                SettingsDivider()
                SettingsRow("Real time", subtitle: "Also moves the trial's latest-day-seen back to today") {
                    button("Reset Clock") { licence.debugSetClockOffset(0) }
                }
            }

            SettingsGroupHeader("Licence key (signed with the test key from the Keychain)")
            SettingsGroup {
                SettingsRow("Activate a test key", subtitle: "Personal, 1 Mac, debug@example.com") {
                    button("Activate") { withKey { activate(DebugSigner.licence(with: $0, issued: licence.debugNow)) } }
                }
                SettingsDivider()
                SettingsRow("Corporate key ending tomorrow", subtitle: "Expired + 14-day grace ends in 1 day: activate, then +1 Day") {
                    button("Activate") {
                        withKey {
                            let exp = licence.debugNow.addingTimeInterval(-Double(Entitlement.expiryGraceDays - 1) * 86_400)
                            activate(DebugSigner.licence(with: $0, issued: licence.debugNow.addingTimeInterval(-300 * 86_400),
                                                         corporateExpiry: exp))
                        }
                    }
                }
                SettingsDivider()
                SettingsRow("Copy a test key", subtitle: "Then paste it in Settings › Licence") {
                    button("Copy") {
                        withKey { key in
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(DebugSigner.licence(with: key, issued: licence.debugNow), forType: .string)
                            model.showToast(.success, "Test key copied")
                        }
                    }
                }
                SettingsDivider()
                SettingsRow("Open an activation link", subtitle: "meboki://activate?key=… with a new test key, as from the email") {
                    button("Open") {
                        withKey { key in
                            var c = URLComponents(string: "meboki://activate")!
                            c.queryItems = [URLQueryItem(name: "key", value: DebugSigner.licence(with: key, issued: licence.debugNow))]
                            if let url = c.url { NSWorkspace.shared.open(url) }
                        }
                    }
                }
                SettingsDivider()
                SettingsRow("Remove licence") {
                    button("Remove") { licence.removeLicence() }
                }
            }

            SettingsGroupHeader("Revoked list")
            SettingsGroup {
                SettingsRow("Revoke the stored key", subtitle: "Installs a signed list with its ID, as if downloaded: the no-longer-valid window (once per key)") {
                    button("Revoke") {
                        guard let kid = licence.storedKid else { model.showToast(.warning, "No key stored"); return }
                        withKey { key in
                            let kids = Array(licence.debugRevoked?.kids ?? []) + [kid]
                            let body = DebugSigner.revokedList(kids: kids, issued: licence.debugNow, with: key)
                            let ok = licence.debugInstallRevoked(body)
                            model.showToast(ok ? .success : .error, ok ? "Revoked \(kid)" : "List didn't verify")
                        }
                    }
                }
                SettingsDivider()
                SettingsRow("Clear the stored list") {
                    button("Clear") { licence.debugClearRevoked() }
                }
                SettingsDivider()
                SettingsRow("Download from meboki.com now", subtitle: "Only with a key stored; a newer list replaces a local one") {
                    button("Fetch") { licence.fetchRevokedIfDue(force: true) }
                }
            }

            SettingsGroupHeader("Onboarding")
            SettingsGroup {
                SettingsRow("Reset onboarding", subtitle: "Marks it not done (\(settings.onboardingDone ? "done now" : "not done now")): it opens at the next launch, and licence notices wait until it closes") {
                    button("Reset") { settings.onboardingDone = false; model.showToast(.info, "Onboarding opens at the next launch") }
                    button("Reset + Open") { settings.onboardingDone = false; model.actions.showWelcome() }
                }
            }
        }
    }

    // MARK: Status

    private var status: some View {
        let n = licence.debugNow
        let df = DateFormatter()
        df.dateFormat = "yyyy-MM-dd HH:mm:ss"
        var lines: [(String, String)] = [
            ("State", LicenceManager.describe(licence.entitlement)),
            ("Licence clock", df.string(from: n) + (DebugClock.offset == 0 ? " (real)" : " (fake, \(Self.offset(DebugClock.offset)))")),
            ("Trial days", licence.trial.days.isEmpty ? "none" : licence.trial.days.joined(separator: ", ")),
            ("Days used / left", "\(licence.trialDaysUsed) / \(licence.trialDaysLeft)" + (licence.trialTodayCounted ? ", today counted" : "")
                + (licence.isLastTrialDay ? ", LAST DAY" : "")),
            ("Latest day seen", licence.trial.lastSeen ?? "none"),
        ]
        switch licence.debugKey {
        case .success(let info)?:
            var line = "\(info.kid) · \(info.type.rawValue) · \(info.email)" + (info.sandbox ? " · test key" : " · production key")
            if let exp = info.expires { line += " · exp \(df.string(from: exp))" }
            lines.append(("Stored key", line))
        case .failure(let e)?: lines.append(("Stored key", "doesn't verify (\(e))"))
        case nil: lines.append(("Stored key", "none"))
        }
        if let list = licence.debugRevoked {
            let mine = licence.storedKid.map { list.contains($0) } == true ? ", contains stored key" : ""
            lines.append(("Revoked list", "\(list.kids.count) id(s), issued \(df.string(from: list.issued))\(mine)"))
        } else {
            lines.append(("Revoked list", "none"))
        }
        lines.append(("Notices shown", "trial ended \(settings.trialEndNoticeShown ? "yes" : "no") · last day \(settings.lastDayNoticeShown ? "yes" : "no") · key \(settings.revokedNoticeShownKid ?? "none")"))
        return SettingsGroup {
            VStack(alignment: .leading, spacing: 4) {
                ForEach(lines, id: \.0) { k, v in
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text(k).foregroundStyle(DS.textSecondary).frame(width: 120, alignment: .leading)
                        Text(v).foregroundStyle(DS.text).textSelection(.enabled)
                    }
                    .font(.system(size: 12, design: .monospaced))
                }
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private static func offset(_ s: TimeInterval) -> String {
        let t = Int(s.rounded())
        let sign = t < 0 ? "-" : "+"
        let a = abs(t)
        return "\(sign)\(a / 86_400)d \((a % 86_400) / 3_600)h \((a % 3_600) / 60)m \(a % 60)s"
    }

    // MARK: Helpers

    private func button(_ title: String, _ action: @escaping () -> Void) -> some View {
        Button(title, action: action).buttonStyle(.ds(.secondary, small: true))
    }

    private func withKey(_ body: @escaping @MainActor (DebugSigner.Key) -> Void) {
        DebugSigner.withKey { result in
            switch result {
            case .success(let key): body(key)
            case .failure(let e): model.showToast(.error, e.description)
            }
        }
    }

    private func activate(_ key: String) {
        switch licence.activate(key) {
        case .success(let info): model.showToast(.success, "Activated \(info.kid)")
        case .failure(let e): model.showToast(.error, e.message)
        }
    }
}

#endif
