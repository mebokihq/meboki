import Foundation
import MebokiCore

/// Correction popup style (design_code.md §5.4–5.6, Settings › General › Correction popup).
enum PopupStyle: String, CaseIterable {
    case card, bubble, island

    var title: String {
        switch self {
        case .card: "Glass Card"
        case .bubble: "Anchored Bubble"
        case .island: "Island HUD"
        }
    }
}

// `EnglishVariant` (§9 `englishVariant`) and `CheckLevel` (§9 `checkLevel`) live in MebokiCore
// (`CheckOptions`): the variant picks the session's prompt, the level filters the edits.

extension CheckLevel {
    var title: String {
        switch self {
        case .spelling: "Spelling"
        case .grammar: "Grammar"
        case .full: "Full"
        }
    }
}

/// Settings › Models › Unload when idle: minutes without a check before the local model is unloaded to free
/// its memory (the next check loads it again). `never` keeps it loaded; memory pressure still unloads it.
enum IdleUnload: Int, CaseIterable {
    case five = 5, fifteen = 15, hour = 60, never = 0

    var title: String {
        switch self {
        case .five: "5 min"
        case .fifteen: "15 min"
        case .hour: "1 hour"
        case .never: "Never"
        }
    }

    /// Seconds, or nil for never.
    var interval: TimeInterval? { self == .never ? nil : TimeInterval(rawValue * 60) }
}

// `ModelSource` (local model `modelID`, Apple's built-in model, or cloud with the user's own key) lives in
// MebokiCore with the backend rule that uses it (`ModelBackend`).

/// User settings stored in `UserDefaults` (design_code.md §9), shared by the check flow, the menu-bar popover
/// and the Settings window. The local model keeps its own key (`modelID`, in `AppDelegate`); cloud keys live
/// in the Keychain (`APIKeyStore`), never here.
@MainActor
final class AppSettings: ObservableObject {
    static let shared = AppSettings()

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        popupStyle = PopupStyle(rawValue: defaults.string(forKey: Key.popupStyle) ?? "") ?? .card
        explainFixes = defaults.object(forKey: Key.explainFixes) as? Bool ?? true
        englishVariant = EnglishVariant(rawValue: defaults.string(forKey: Key.englishVariant) ?? "") ?? .us
        checkLevel = CheckLevel(rawValue: defaults.string(forKey: Key.checkLevel) ?? "") ?? .full
        casualMode = defaults.object(forKey: Key.casualMode) as? Bool ?? true
        protectTokens = defaults.object(forKey: Key.protectTokens) as? Bool ?? true
        skipNonEnglish = defaults.object(forKey: Key.skipNonEnglish) as? Bool ?? false
        underlineAsYouType = defaults.object(forKey: Key.underlineAsYouType) as? Bool ?? true
        var modes = (defaults.dictionary(forKey: Key.appModes) as? [String: String] ?? [:])
            .compactMapValues { AppMode(rawValue: $0) }
        // Before 2026-11-16 "Pause in {App}" kept its own list, which Settings › Apps didn't show. A paused
        // app is now Off there; move the old list over once.
        if let paused = defaults.stringArray(forKey: Key.legacyPausedApps) {
            for id in paused { modes[id] = .off }
            defaults.set(modes.mapValues(\.rawValue), forKey: Key.appModes)
            defaults.removeObject(forKey: Key.legacyPausedApps)
        }
        appModes = modes
        checkedApps = defaults.dictionary(forKey: Key.checkedApps) as? [String: String] ?? [:]
        codeLearning = defaults.data(forKey: Key.codeLearning)
            .flatMap { try? JSONDecoder().decode(CodeAppLearner.self, from: $0) } ?? CodeAppLearner()
        hotkey = defaults.data(forKey: Key.hotkey).flatMap { try? JSONDecoder().decode(Shortcut.self, from: $0) }
            ?? .default
        logSnippets = defaults.object(forKey: Key.logSnippets) as? Bool ?? true
        showInMenuBar = defaults.object(forKey: Key.showInMenuBar) as? Bool ?? true
        lastSettingsPane = defaults.string(forKey: Key.lastSettingsPane) ?? "general"
        let tone = ColorTone(rawValue: defaults.string(forKey: Key.colorTone) ?? "") ?? .muted
        colorTone = tone
        DS.tone = tone
        modelSource = ModelSource(rawValue: defaults.string(forKey: Key.modelSource) ?? "") ?? .local
        cloudProvider = CloudProvider(rawValue: defaults.string(forKey: Key.cloudProvider) ?? "") ?? .openRouter
        cloudModelIDs = defaults.dictionary(forKey: Key.cloudModelIDs) as? [String: String] ?? [:]
        idleUnload = (defaults.object(forKey: Key.idleUnload) as? Int).flatMap(IdleUnload.init(rawValue:)) ?? .fifteen
        onboardingDone = defaults.bool(forKey: Key.onboardingDone)
        acceptedLicenses = Set(defaults.stringArray(forKey: Key.acceptedLicenses) ?? [])
        trialEndNoticeShown = defaults.bool(forKey: Key.trialEndNoticeShown)
        lastDayNoticeShown = defaults.bool(forKey: Key.lastDayNoticeShown)
        revokedNoticeShownKid = defaults.string(forKey: Key.revokedNoticeShownKid)
    }

    enum Key {
        static let popupStyle = "popupStyle"
        static let explainFixes = "explainFixes"
        static let englishVariant = "englishVariant"
        static let checkLevel = "checkLevel"
        static let casualMode = "casualMode"
        static let protectTokens = "protectTokens"
        static let skipNonEnglish = "skipNonEnglish"
        static let underlineAsYouType = "underlineAsYouType"
        static let legacyPausedApps = "pausedApps"
        static let appModes = "appModes"
        static let checkedApps = "checkedApps"
        static let codeLearning = "codeLearning"
        static let hotkey = "hotkey"
        /// Read by `Log.snippet` (any thread) straight from `UserDefaults.standard`.
        static let logSnippets = "logSnippets"
        static let showInMenuBar = "showInMenuBar"
        static let lastSettingsPane = "lastSettingsPane"
        static let colorTone = "colorTone"
        static let modelSource = "modelSource"
        static let cloudProvider = "cloudProvider"
        static let cloudModelIDs = "cloudModelIDs"
        static let idleUnload = "idleUnloadMinutes"
        static let onboardingDone = "onboardingDone"
        static let acceptedLicenses = "acceptedModelLicenses"
        static let trialEndNoticeShown = "trialEndNoticeShown"
        static let lastDayNoticeShown = "lastDayNoticeShown"
        static let revokedNoticeShownKid = "revokedNoticeShownKid"
    }

    /// Default `.card`.
    @Published var popupStyle: PopupStyle {
        didSet { defaults.set(popupStyle.rawValue, forKey: Key.popupStyle) }
    }

    /// Show the reason line on the card, bubble and island. Default on.
    @Published var explainFixes: Bool {
        didSet { defaults.set(explainFixes, forKey: Key.explainFixes) }
    }

    /// Default US. Picks the system prompt (`Prompt.system(for:)`), fixed until the user switches.
    @Published var englishVariant: EnglishVariant {
        didSet { defaults.set(englishVariant.rawValue, forKey: Key.englishVariant) }
    }

    /// Default full. Filters the edits by category (`EditFilter.allows`).
    @Published var checkLevel: CheckLevel {
        didSet { defaults.set(checkLevel.rawValue, forKey: Key.checkLevel) }
    }

    /// Casual mode in chat apps (`AppRules.chatApps`). Default on.
    @Published var casualMode: Bool {
        didSet { defaults.set(casualMode, forKey: Key.casualMode) }
    }

    /// Protect names, code and links (`ProtectedTokens`). Default on.
    @Published var protectTokens: Bool {
        didSet { defaults.set(protectTokens, forKey: Key.protectTokens) }
    }

    /// Skip text that isn't English (`LanguageGate`): it's never sent to the model. Default off.
    @Published var skipNonEnglish: Bool {
        didSet { defaults.set(skipNonEnglish, forKey: Key.skipNonEnglish) }
    }

    /// Default on. Nothing reads it until Milestone B (checking as you type); the controls show "Coming soon".
    @Published var underlineAsYouType: Bool {
        didSet { defaults.set(underlineAsYouType, forKey: Key.underlineAsYouType) }
    }

    /// Settings › Apps: bundle ID → mode. Missing means `on`. The popover's "Pause in {App}" sets `off` too.
    @Published var appModes: [String: AppMode] {
        didSet { defaults.set(appModes.mapValues(\.rawValue), forKey: Key.appModes) }
    }

    /// Learned Manual (`CodeAppLearner`): apps whose fields kept holding code. Bundle IDs and counts only.
    @Published var codeLearning: CodeAppLearner {
        didSet { defaults.set(try? JSONEncoder().encode(codeLearning), forKey: Key.codeLearning) }
    }

    /// Apps the user has checked in at least once (bundle ID → name), listed in Settings › Apps.
    @Published var checkedApps: [String: String] {
        didSet { defaults.set(checkedApps, forKey: Key.checkedApps) }
    }

    /// The global check shortcut. Default ⌃⌥G.
    @Published var hotkey: Shortcut {
        didSet { defaults.set(try? JSONEncoder().encode(hotkey), forKey: Key.hotkey) }
    }

    /// Short text snippets in the log (Settings › Privacy). Off logs lengths only. Default on.
    @Published var logSnippets: Bool {
        didSet { defaults.set(logSnippets, forKey: Key.logSnippets) }
    }

    /// The status item is visible. Default on.
    @Published var showInMenuBar: Bool {
        didSet { defaults.set(showInMenuBar, forKey: Key.showInMenuBar) }
    }

    /// The Settings pane shown last (`SettingsPane` raw value).
    @Published var lastSettingsPane: String {
        didSet { defaults.set(lastSettingsPane, forKey: Key.lastSettingsPane) }
    }

    /// Settings › Appearance: how vivid the brand and category colors are (`ColorTone`). Default `.muted`.
    /// Sets `DS.tone`, which every brand and category color reads when it's drawn.
    @Published var colorTone: ColorTone {
        didSet {
            DS.tone = colorTone
            defaults.set(colorTone.rawValue, forKey: Key.colorTone)
        }
    }

    /// Local (default), Apple's built-in model, or cloud. Cloud is opt-in: only the Models pane's "Use" on a saved
    /// key turns it on. Apple is picked by the user, or set once on a fresh install (`ModelBackend.freshInstallSource`).
    @Published var modelSource: ModelSource {
        didSet { defaults.set(modelSource.rawValue, forKey: Key.modelSource) }
    }

    /// A source was ever stored (chosen, or set on a fresh install): a later launch never changes it by itself.
    var storedModelSource: String? { defaults.string(forKey: Key.modelSource) }

    /// The BYOK provider shown in Settings › Models and used in cloud mode. Default OpenRouter.
    @Published var cloudProvider: CloudProvider {
        didSet { defaults.set(cloudProvider.rawValue, forKey: Key.cloudProvider) }
    }

    /// Provider raw value → model ID (a catalog ID or one the user typed). Missing means the provider's default.
    @Published var cloudModelIDs: [String: String] {
        didSet { defaults.set(cloudModelIDs, forKey: Key.cloudModelIDs) }
    }

    /// The onboarding window was finished or closed once. Until then a launch shows it, and neither asks for
    /// Accessibility nor downloads a model by itself.
    @Published var onboardingDone: Bool {
        didSet { defaults.set(onboardingDone, forKey: Key.onboardingDone) }
    }

    /// Model licenses the user accepted before a download (`ModelLicense.id`, Llama 3.1 only so far).
    @Published var acceptedLicenses: Set<String> {
        didSet { defaults.set(acceptedLicenses.sorted(), forKey: Key.acceptedLicenses) }
    }

    /// Unload the local model after this much idle time. Default 15 min.
    @Published var idleUnload: IdleUnload {
        didSet { defaults.set(idleUnload.rawValue, forKey: Key.idleUnload) }
    }

    // MARK: Licence (PLAN.md §6 "App-side licensing")

    /// What the licence allows now, set by `AppDelegate` from `LicenceManager`. Defaults to everything on, so a
    /// demo or test instance isn't gated. The stored settings above never change with it.
    @Published var entitlement: Entitlement = .trial(daysLeft: TrialClock.length)

    /// The trial-ended notice was shown (once, ever).
    @Published var trialEndNoticeShown: Bool {
        didSet { defaults.set(trialEndNoticeShown, forKey: Key.trialEndNoticeShown) }
    }

    /// The last-trial-day toast was shown (once, ever).
    @Published var lastDayNoticeShown: Bool {
        didSet { defaults.set(lastDayNoticeShown, forKey: Key.lastDayNoticeShown) }
    }

    /// The `kid` of the licence whose revoked or expired notice was shown (once per key).
    @Published var revokedNoticeShownKid: String? {
        didSet { defaults.set(revokedNoticeShownKid, forKey: Key.revokedNoticeShownKid) }
    }

    /// The three notice flags as one value, for `LicenceNotices` (Core).
    var noticeFlags: LicenceNoticeFlags {
        get { LicenceNoticeFlags(trialEndNoticeShown: trialEndNoticeShown, lastDayNoticeShown: lastDayNoticeShown,
                                 revokedNoticeShownKid: revokedNoticeShownKid) }
        set {
            trialEndNoticeShown = newValue.trialEndNoticeShown
            lastDayNoticeShown = newValue.lastDayNoticeShown
            revokedNoticeShownKid = newValue.revokedNoticeShownKid
        }
    }

    /// Debug reset of the one-shot notices.
    func resetLicenceNotices() {
        trialEndNoticeShown = false
        lastDayNoticeShown = false
        revokedNoticeShownKid = nil
    }

    // Effective values: the stored setting combined with the entitlement (`Entitlement` in Core). The check flow
    // reads these; the Settings controls keep reading and writing the stored values.

    /// Card in free mode, else the stored style.
    var effectivePopupStyle: PopupStyle { entitlement.allows(.popupStyles) ? popupStyle : .card }

    /// Full in free mode, else the stored level.
    var effectiveCheckLevel: CheckLevel { entitlement.effective(checkLevel) }

    /// Off in free mode, else the stored switch.
    var effectiveCasualMode: Bool { entitlement.effectiveCasual(casualMode) }

    /// Off in free mode (no automatic check, no live re-check), else the stored switch.
    var effectiveUnderlineAsYouType: Bool { entitlement.effectiveAutomaticCheck(underlineAsYouType) }

    /// The mode the check flow acts on: On and Casual act as Manual in free mode; Manual and Off stay.
    func effectiveAppMode(_ bundleID: String?) -> AppMode { entitlement.effective(appMode(bundleID)) }

    func cloudModel(for provider: CloudProvider) -> CloudModel {
        CloudCatalog.model(id: cloudModelIDs[provider.rawValue], provider: provider)
    }

    /// The cloud model checks use in cloud mode.
    var cloudModel: CloudModel { cloudModel(for: cloudProvider) }

    /// Paused in the popover = Off in Settings › Apps: one setting, shown in both places.
    func isPaused(_ bundleID: String?) -> Bool {
        appMode(bundleID) == .off
    }

    /// Popover › Pause in {App}: sets the app to Off (and lists it in Settings › Apps). Resume removes the
    /// choice, so the app is back on its default; an app that is Off by default is set to On.
    func setPaused(_ paused: Bool, bundleID: String, name: String? = nil) {
        if let name { noteChecked(bundleID: bundleID, name: name) }
        if paused {
            setAppMode(.off, bundleID: bundleID)
        } else if defaultMode(bundleID) == .off {
            setAppMode(.on, bundleID: bundleID)
        } else {
            resetAppMode(bundleID)
        }
    }

    /// The app's mode: the user's choice, else the built-in list's default, else learned Manual, else On.
    func appMode(_ bundleID: String?) -> AppMode {
        AppRules.mode(bundleID, stored: appModes, learned: codeLearning.learned)
    }

    /// The mode the app has without a choice of the user's.
    func defaultMode(_ bundleID: String?) -> AppMode {
        AppRules.defaultMode(bundleID, learned: codeLearning.learned)
    }

    /// The user's choice, kept for good (even when it equals the default): it wins over the built-in list and
    /// over learning, and only `resetAppMode` removes it.
    func setAppMode(_ mode: AppMode, bundleID: String) {
        if appModes[bundleID] != mode { appModes[bundleID] = mode }
    }

    /// Settings › Apps › Reset: drops the user's choice; the app is back on its default.
    func resetAppMode(_ bundleID: String) {
        if appModes[bundleID] != nil { appModes[bundleID] = nil }
    }

    /// The app is Off because of the built-in list (a password manager, a remote desktop), not by the user.
    func isOffByDefault(_ bundleID: String?) -> Bool {
        guard let bundleID else { return false }
        return appModes[bundleID] == nil && defaultMode(bundleID) == .off
    }

    /// Why an app is skipped by default (Settings › Apps caption), or nil for an app that isn't.
    func skipReason(_ bundleID: String) -> String? {
        if let c = AppRules.category(of: bundleID) { return c.title }
        return codeLearning.isLearned(bundleID) ? "Looks like a code editor" : nil
    }

    /// One field's verdict from the automatic check, for learned Manual. Counted only for apps that aren't on
    /// the built-in list and that the user never set a mode for. Returns true when the app was just learned.
    func noteField(bundleID: String, verdict: CodeDetector.Verdict) -> Bool {
        guard appModes[bundleID] == nil, AppRules.category(of: bundleID) == nil,
              CodeAppLearner.isEvidence(verdict) else { return false }
        var l = codeLearning
        let learned = l.note(bundleID, verdict: verdict)
        if l != codeLearning { codeLearning = l }
        return learned
    }

    /// The automatic check may run in this app: the switch is on and the app is On or Casual (not Manual, not Off or
    /// paused), by the effective values: never in free mode.
    func autoCheckAllowed(_ bundleID: String?) -> Bool {
        guard let bundleID else { return false }
        return effectiveUnderlineAsYouType && effectiveAppMode(bundleID).allowsAutoCheck
    }

    /// Casual mode for an app: set to Casual in Settings › Apps, or a chat app with the switch on.
    func isCasual(_ bundleID: String?) -> Bool {
        guard let bundleID else { return false }
        return effectiveAppMode(bundleID) == .casual
            || (effectiveCasualMode && AppRules.chatApps.contains(bundleID))
    }

    /// What a check in `bundleID` uses (design_code.md §8.2, §8.4).
    func checkOptions(for bundleID: String?) -> CheckOptions {
        CheckOptions(variant: englishVariant, level: effectiveCheckLevel, casual: isCasual(bundleID), protectTokens: protectTokens,
                     englishOnly: skipNonEnglish)
    }

    /// Remembers an app the user checked in, for Settings › Apps.
    func noteChecked(bundleID: String, name: String) {
        if checkedApps[bundleID] != name { checkedApps[bundleID] = name }
    }
}
