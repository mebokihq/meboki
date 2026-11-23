import AppKit
import MebokiCore
import SwiftUI

/// Settings › About (design_code.md §8.7): the app icon, a short line, a version chip and a licence chip,
/// four action cards (Welcome Guide, What's new, Source code, Acknowledgements), a "Report an issue" box that
/// opens an email to support, and a link row.
struct AboutPane: View {
    @ObservedObject var model: SettingsModel
    @ObservedObject var licence: LicenceManager
    @ObservedObject private var updates = UpdateController.shared
    @State private var showLicenses = false

    private var version: String { UpdateController.currentVersion }

    /// The public source repository (GPL-3.0).
    static let repository = URL(string: "https://github.com/mebokihq/meboki")!
    private static func repo(_ path: String) -> URL { repository.appendingPathComponent(path) }

    var body: some View {
        VStack(spacing: 0) {
            icon
            Text("Meboki").font(DS.Font.aboutTitle).foregroundStyle(DS.text).padding(.top, 6)
            Text("Friendly grammar help that never leaves your Mac.")
                .font(DS.Font.aboutTagline).foregroundStyle(DS.textSecondary).padding(.top, 4)
            HStack(spacing: 8) {
                versionChip
                licenceChip
            }
            .padding(.top, 12)
            actions.padding(.top, 20)
            reportBox.padding(.top, 12)
            linkRow.padding(.top, 14)
            Text("Open source · Local models · No account · No tracking")
                .font(DS.Font.small.weight(.regular)).foregroundStyle(DS.textTertiary)
                .padding(.top, 18)
        }
        .font(DS.Font.body)
        .frame(maxWidth: .infinity)
        .padding(.top, 26)
        .padding(.bottom, 16)
    }

    // MARK: Header

    /// The real app icon (App/Art/AppIcon.svg): its squircle fills 80% of the canvas, so 112 pt shows a ~90 pt
    /// squircle with the icon's own shadow. A thin white border on the squircle keeps the charcoal icon apart
    /// from a dark background.
    private var icon: some View {
        let side: CGFloat = 112
        return Image(nsImage: WhatsNewContent.appIcon)
            .resizable()
            .interpolation(.high)
            .frame(width: side, height: side)
            .overlay {
                // The SVG's rect: x/y 100, size 824, rx 185 on a 1024 canvas.
                RoundedRectangle(cornerRadius: side * 185 / 1024, style: .circular)
                    .strokeBorder(Color.white.opacity(0.55), lineWidth: 1.5)
                    .padding(side * 100 / 1024)
            }
            .padding(.vertical, -6)
            .accessibilityHidden(true)
    }

    /// "Version x · up to date" after a check that found nothing, "Version x · Install y…" with one waiting;
    /// a click opens the update window. A build without the updater shows only the version.
    @ViewBuilder private var versionChip: some View {
        if updates.isEnabled {
            Button { model.actions.showUpdate() } label: {
                if let newer = updates.available {
                    chipLabel(symbol: "arrow.down.circle.fill", tint: DS.ok, "Version \(version) · Install \(newer)…")
                } else if updates.lastCheck != nil {
                    chipLabel(symbol: "checkmark", tint: DS.ok, "Version \(version) · up to date")
                } else {
                    chipLabel(symbol: nil, tint: nil, "Version \(version)")
                }
            }
            .buttonStyle(.plain)
            .disabled(!updates.canCheck && updates.available == nil)
            .help(UpdateText.lastChecked(updates.lastCheck) ?? UpdateText.checkNow)
        } else {
            chipLabel(symbol: nil, tint: nil, "Version \(version)")
        }
    }

    private var licenceChip: some View {
        Button { model.pane = .licence } label: {
            chipLabel(symbol: licenceSymbol, tint: nil, licenceLine, chevron: true)
        }
        .buttonStyle(.plain)
        .help("Open Settings › Licence")
    }

    private func chipLabel(symbol: String?, tint: Color?, _ title: String, chevron: Bool = false) -> some View {
        HStack(spacing: 6) {
            if let symbol {
                Image(systemName: symbol).font(.system(size: 10.5, weight: .bold)).foregroundStyle(tint ?? DS.textSecondary)
            }
            Text(title)
            if chevron {
                Image(systemName: "chevron.right").font(.system(size: 9, weight: .bold))
            }
        }
        .font(DS.Font.small.weight(.regular))
        .foregroundStyle(DS.textSecondary)
        .padding(.horizontal, 10)
        .padding(.vertical, 4)
        .background(Capsule().fill(DS.control))
        .contentShape(Capsule())
    }

    private var licenceLine: String {
        switch licence.entitlement {
        case .licensed(let info): "Licensed to \(info.email)"
        case .trial: licence.isLastTrialDay ? "Trial · last day" : "Trial · \(licence.trialDaysLeft) days left"
        case .free: "Free mode"
        }
    }

    private var licenceSymbol: String {
        switch licence.entitlement {
        case .licensed: "checkmark.seal"
        case .trial: "clock"
        case .free: "lock.open"
        }
    }

    // MARK: Actions

    private var actions: some View {
        Grid(horizontalSpacing: 8, verticalSpacing: 8) {
            GridRow {
                AboutActionCard(symbol: "book", title: "Welcome Guide", detail: "Take the short tour again") {
                    model.actions.showWelcome()
                }
                AboutActionCard(symbol: "sparkles", title: "What’s new", detail: "Every release, newest first") {
                    model.actions.showChangelog()
                }
            }
            GridRow {
                AboutActionCard(symbol: "chevron.left.forwardslash.chevron.right", title: "Source code",
                                detail: "Read it, build it, improve it") {
                    NSWorkspace.shared.open(Self.repository)
                }
                .help(Self.repository.absoluteString)
                AboutActionCard(symbol: "heart", title: "Acknowledgements", detail: "Open source we build on") {
                    showLicenses.toggle()
                }
                .popover(isPresented: $showLicenses, arrowEdge: .bottom) { licenses }
            }
        }
        .frame(maxWidth: 448)
    }

    // MARK: Report an issue

    private var reportBox: some View {
        HStack(spacing: 12) {
            Circle().fill(DS.iconCoral)
                .frame(width: 34, height: 34)
                .overlay(Image(systemName: "envelope").font(.system(size: 15, weight: .semibold)).foregroundStyle(.white))
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 1) {
                Text("Spotted a wrong fix or a bug?").font(DS.Font.bodySemibold).foregroundStyle(DS.text)
                Text("Tell us. A person reads every email.").font(DS.Font.caption).foregroundStyle(DS.textSecondary)
            }
            Spacer(minLength: 8)
            Button { NSWorkspace.shared.open(Self.reportMail(version: version)) } label: {
                HStack(spacing: 6) {
                    Image(systemName: "envelope").font(.system(size: 11.5, weight: .semibold))
                    Text("Report an issue").font(DS.Font.bodySemibold)
                }
                .foregroundStyle(DS.onInk)
                .padding(.horizontal, 12)
                .frame(height: 30)
                .background(RoundedRectangle(cornerRadius: DS.Radius.row, style: .continuous).fill(DS.ink))
                .contentShape(RoundedRectangle(cornerRadius: DS.Radius.row, style: .continuous))
            }
            .buttonStyle(.plain)
            .help("Write to \(LicenceText.supportEmail)")
        }
        .padding(.leading, 14)
        .padding(.trailing, 12)
        .padding(.vertical, 12)
        .background(RoundedRectangle(cornerRadius: DS.Radius.suggestion, style: .continuous).fill(DS.helpFill))
        .overlay(RoundedRectangle(cornerRadius: DS.Radius.suggestion, style: .continuous).strokeBorder(DS.helpBorder))
        .frame(maxWidth: 448)
    }

    /// A new email to support with the subject filled in and the app and macOS versions under the message.
    /// Nothing else goes in: the user writes the rest and sees everything before it's sent.
    static func reportMail(version: String) -> URL {
        let os = ProcessInfo.processInfo.operatingSystemVersion
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "?"
        var c = URLComponents()
        c.scheme = "mailto"
        c.path = LicenceText.supportEmail
        c.queryItems = [
            URLQueryItem(name: "subject", value: "Meboki \(version): issue report"),
            URLQueryItem(name: "body", value: "\n\n\n—\nMeboki \(version) (\(build))\n"
                + "macOS \(os.majorVersion).\(os.minorVersion).\(os.patchVersion)\n"),
        ]
        return c.url ?? URL(string: "mailto:\(LicenceText.supportEmail)")!
    }

    // MARK: Links

    private var linkRow: some View {
        HStack(spacing: 6) {
            link("Licence (GPL-3.0)", Self.repo("blob/master/LICENSE"))
            Text("·").foregroundStyle(DS.textTertiary)
            link("Releases", Self.repo("releases"))
            Text("·").foregroundStyle(DS.textTertiary)
            link(LicenceText.supportEmail, URL(string: "mailto:\(LicenceText.supportEmail)")!)
        }
        .font(DS.Font.link)
    }

    private func link(_ title: String, _ url: URL) -> some View {
        Button(title) { NSWorkspace.shared.open(url) }
            .buttonStyle(.dsLink)
            .help(url.absoluteString)
    }

    private var licenses: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Third-party parts").font(DS.Font.bodySemibold)
            license("llama.cpp (llama-server)", "MIT License · github.com/ggml-org/llama.cpp")
            license("Sparkle (updates)", "MIT License · github.com/sparkle-project/Sparkle")
            license("Gemma 4 and Qwen3.5 model files", "Apache-2.0 · Google, Alibaba Cloud (Qwen)")
            license("Apple Intelligence (optional)", "Apple's on-device model, part of macOS 26. Not included in Meboki")
            license("Llama 3.1 8B model file (optional)",
                    "Built with Llama. Llama 3.1 is licensed under the Llama 3.1 Community License, "
                        + "Copyright © Meta Platforms, Inc. All Rights Reserved.")
            Text("Meboki is open source under GPL-3.0.").font(DS.Font.caption).foregroundStyle(DS.textSecondary)
        }
        .padding(16)
        .frame(width: 320, alignment: .leading)
    }

    private func license(_ name: String, _ detail: String) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(name).font(DS.Font.bodyMedium)
            Text(detail).font(DS.Font.caption).foregroundStyle(DS.textSecondary).fixedSize(horizontal: false, vertical: true)
        }
    }
}

/// One About action: a card with a symbol tile, a title and a one-line detail; lightens on hover.
private struct AboutActionCard: View {
    let symbol: String
    let title: String
    let detail: String
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                RoundedRectangle(cornerRadius: DS.Radius.row, style: .continuous)
                    .fill(DS.control)
                    .frame(width: 30, height: 30)
                    .overlay(Image(systemName: symbol).font(.system(size: 13, weight: .medium)).foregroundStyle(DS.text))
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 1) {
                    Text(title).font(DS.Font.bodySemibold).foregroundStyle(DS.text)
                    Text(detail).font(DS.Font.caption).foregroundStyle(DS.textSecondary).lineLimit(1)
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 12)
            .frame(maxWidth: .infinity, minHeight: 52, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: DS.Radius.suggestion, style: .continuous).fill(DS.field))
            .overlay(RoundedRectangle(cornerRadius: DS.Radius.suggestion, style: .continuous).fill(hovering ? DS.hover : .clear))
            .overlay(RoundedRectangle(cornerRadius: DS.Radius.suggestion, style: .continuous).strokeBorder(DS.separator))
            .contentShape(RoundedRectangle(cornerRadius: DS.Radius.suggestion, style: .continuous))
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }
}
