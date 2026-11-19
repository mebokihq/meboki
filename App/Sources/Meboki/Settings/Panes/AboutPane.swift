import MebokiCore
import SwiftUI

/// Settings › About (design_code.md §8.7). The source isn't published yet, so "Source code" is disabled;
/// "Acknowledgements" lists the third-party parts; the line under the version shows the licence state.
struct AboutPane: View {
    @ObservedObject var model: SettingsModel
    @ObservedObject var licence: LicenceManager
    @ObservedObject private var updates = UpdateController.shared
    @State private var showLicenses = false

    private var version: String { UpdateController.currentVersion }

    var body: some View {
        VStack(spacing: 8) {
            AppIconView(size: 96)
                .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
            Text("Meboki").font(DS.Font.aboutTitle).foregroundStyle(DS.text).padding(.top, 8)
            Text("Version \(version) · Milestone A").foregroundStyle(DS.textSecondary)
            Button { model.pane = .licence } label: {
                Text(licenceLine).foregroundStyle(DS.textSecondary)
            }
            .buttonStyle(.plain)
            .help("Open Settings › Licence")
            Text("Open source. Local models. No account.").foregroundStyle(DS.textSecondary)
            HStack(spacing: 8) {
                Button("Source code") {}
                    .buttonStyle(.dsSecondary)
                    .disabled(true)
                    .help("The source isn't published yet.")
                Button("Acknowledgements") { showLicenses.toggle() }
                    .buttonStyle(.dsSecondary)
                    .popover(isPresented: $showLicenses, arrowEdge: .bottom) { licenses }
                Button("Welcome Guide") { model.actions.showWelcome() }
                    .buttonStyle(.dsSecondary)
            }
            .padding(.top, 14)
            // Official builds only.
            if updates.isEnabled {
                HStack(spacing: 10) {
                    Button(updates.available.map { "Install \($0)…" } ?? UpdateText.checkNow) { model.actions.showUpdate() }
                        .buttonStyle(.dsSecondary)
                        .disabled(!updates.canCheck)
                    if let checked = UpdateText.lastChecked(updates.lastCheck) {
                        Text(checked).font(DS.Font.caption).foregroundStyle(DS.textSecondary)
                    }
                }
                .padding(.top, 4)
            }
        }
        .font(DS.Font.body)
        .frame(maxWidth: .infinity)
        .padding(.top, 40)
    }

    private var licenceLine: String {
        switch licence.entitlement {
        case .licensed(let info): "Licensed to \(info.email)"
        case .trial: licence.isLastTrialDay ? "Trial · last day" : "Trial · \(licence.trialDaysLeft) days left"
        case .free: "Free mode"
        }
    }

    private var licenses: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Third-party parts").font(DS.Font.bodySemibold)
            license("llama.cpp (llama-server)", "MIT License · github.com/ggml-org/llama.cpp")
            license("Sparkle (updates)", "MIT License · github.com/sparkle-project/Sparkle")
            license("Gemma 4 and Qwen3.5 model files", "Apache-2.0 · Google, Alibaba Cloud (Qwen)")
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
