import SwiftUI

/// Settings › Privacy (design_code.md §8.6): the hero card and what leaves the Mac (nothing but downloads, or
/// the checked text in cloud mode, PLAN.md §4 "Privacy & Cost Controls").
struct PrivacyPane: View {
    @ObservedObject var model: SettingsModel
    @ObservedObject var settings: AppSettings

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            hero.padding(.bottom, 6)
            SettingsGroup {
                if cloud {
                    SettingsRow("Text sent to the internet", subtitle: "Only the text you check, only while cloud is in use") {
                        Pill("To \(settings.cloudProvider.name)", kind: .brand)
                    }
                } else {
                    SettingsRow("Text sent to the internet") { Pill("Never", kind: .success) }
                }
                SettingsDivider()
                SettingsRow("Model downloads", subtitle: "Pinned Hugging Face files, checked with SHA-256") {
                    Pill("huggingface.co")
                }
                SettingsDivider()
                SettingsRow(leading: {
                    SettingsLabel(title: "Logs", subtitle: "~/Library/Logs/Meboki/", monospacedSubtitle: true)
                }, control: {
                    Button("Show in Finder", action: model.actions.showLogs).buttonStyle(.ds(.secondary, small: true))
                })
                SettingsDivider()
                SettingsRow("Short text snippets in logs", subtitle: "Helps debug a bad fix. Off keeps logs text-free") {
                    SettingsSwitch(isOn: $settings.logSnippets, label: "Short text snippets in logs")
                }
            }
        }
    }

    private var cloud: Bool { settings.modelSource == .cloud }

    /// Padding 18, radius 16, `ok` 16% → `catGrammar` 12% at 135°, a 52 pt green badge with a white lock.
    private var hero: some View {
        HStack(spacing: 16) {
            Circle()
                .fill(LinearGradient(colors: [Color(nsColor: .hex(0x5EE08A)), DS.ok],
                                     startPoint: .topLeading, endPoint: .bottomTrailing))
                .overlay(Image(systemName: cloud ? "cloud" : "lock").font(.system(size: 22, weight: .semibold)).foregroundStyle(DS.onAccent))
                .frame(width: 52, height: 52)
                .shadow(color: DS.ok.opacity(0.5), radius: 8, x: 0, y: 8)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(cloud ? "Cloud mode: checks go to \(settings.cloudProvider.name)" : "Your text never leaves this Mac")
                    .font(.system(size: 16, weight: .semibold)).foregroundStyle(DS.text)
                Text(cloud ? "With your own key. Pick a local model in Settings › Models to keep text on this Mac."
                           : "The model runs locally. No account, no analytics, no cloud.")
                    .font(DS.Font.link)
                    .foregroundStyle(DS.textSecondary)
            }
            Spacer(minLength: 0)
        }
        .padding(18)
        .background(RoundedRectangle(cornerRadius: DS.Radius.tile, style: .continuous)
            .fill(LinearGradient(colors: [DS.ok.opacity(0.16), DS.catGrammar.opacity(0.12)],
                                 startPoint: .topLeading, endPoint: .bottomTrailing)))
        .accessibilityElement(children: .combine)
    }
}
