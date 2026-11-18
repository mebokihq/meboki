import MebokiCore
import SwiftUI

/// Settings › Writing (design_code.md §8.2). English variant picks the session's prompt; Check for, Casual
/// mode and Protect are post-filters in Core (`CheckOptions`, `EditFilter`, stage 9, eval in PLAN.md §2).
/// Each check reads them, so a change applies to the next check. Explain each fix is UI-only. Skip text that
/// isn't English keeps such text from the model (`LanguageGate`, eval in PLAN.md §2).
struct WritingPane: View {
    @ObservedObject var settings: AppSettings

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            FreeModeBanner()
            SettingsGroupHeader("Language", first: true)
            SettingsGroup {
                SettingsRow("English variant", subtitle: "Keeps “colour” or “color” the way you write it") {
                    DSSegmented(selection: $settings.englishVariant,
                                options: EnglishVariant.allCases.map { ($0, $0.rawValue) })
                }
                SettingsDivider()
                SettingsRow("Check for") {
                    DSSegmented(selection: $settings.checkLevel, options: CheckLevel.allCases.map { ($0, $0.title) })
                        .licenceLocked(.checkFor, caption: false)
                }
                SettingsDivider()
                SettingsRow("Skip text that isn't English", subtitle: "Other languages aren't sent to the model") {
                    SettingsSwitch(isOn: $settings.skipNonEnglish, label: "Skip text that isn't English")
                }
            }

            SettingsGroupHeader("Style")
            SettingsGroup {
                SettingsRow("Casual mode in chat apps", subtitle: "Leaves lowercase starts and missing periods alone") {
                    SettingsSwitch(isOn: $settings.casualMode, label: "Casual mode in chat apps")
                        .licenceLocked(.casualMode)
                }
                SettingsDivider()
                SettingsRow("Protect names, code and links", subtitle: "Never rewrites @mentions, `code` or URLs") {
                    SettingsSwitch(isOn: $settings.protectTokens, label: "Protect names, code and links")
                }
                SettingsDivider()
                SettingsRow("Explain each fix", subtitle: "Shows a one-line reason in the popup") {
                    SettingsSwitch(isOn: $settings.explainFixes, label: "Explain each fix")
                }
            }
        }
    }
}
