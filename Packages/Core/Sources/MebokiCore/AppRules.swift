import Foundation

/// Per-app mode (design_code.md §8.4, §9 `appModes`).
/// - `on`: ⌃⌥G and the automatic check.
/// - `casual`: as `on`, with casual mode forced there (`CheckOptions.casual`).
/// - `manual`: ⌃⌥G only; the automatic check (checking as you type) leaves the app alone. The default for
///   terminals and code editors.
/// - `off`: nothing is read there, ⌃⌥G included. The default for password managers and remote desktops.
public enum AppMode: String, CaseIterable, Sendable {
    case on, casual, manual, off

    public var title: String {
        switch self {
        case .on: "On"
        case .casual: "Casual"
        case .manual: "Manual"
        case .off: "Off"
        }
    }

    /// The automatic check may run in an app with this mode.
    public var allowsAutoCheck: Bool { self == .on || self == .casual }
}

/// Why an app is skipped by default. Each category has its own default mode.
public enum AppCategory: String, CaseIterable, Sendable {
    /// Terminals, code editors, IDEs, SQL and API tools: their text areas hold code and output, not prose.
    case code
    /// Password managers: vault notes and one-time-code fields aren't secure fields, so the secure-field gate
    /// doesn't cover them.
    case passwords
    /// Remote desktops and virtual machines: the remote screen is pixels, and what is typed goes elsewhere.
    case remote

    public var title: String {
        switch self {
        case .code: "Terminal or code editor"
        case .passwords: "Password manager"
        case .remote: "Remote desktop or virtual machine"
        }
    }

    public var pluralTitle: String {
        switch self {
        case .code: "Terminals and code editors"
        case .passwords: "Password managers"
        case .remote: "Remote desktops and virtual machines"
        }
    }

    public var defaultMode: AppMode {
        switch self {
        case .code: .manual
        case .passwords, .remote: .off
        }
    }
}

/// The built-in list of apps that are skipped by default (PLAN.md §5 "apps to skip"). Bundle IDs are read from
/// the apps' own `Info.plist` (`CFBundleIdentifier`). Only the user's changes are stored (`appModes`), so an
/// app added here in an update gets its default without touching anything the user chose.
public enum AppRules {
    /// Terminals and code editors. ⌃⌥G still works there (`AppMode.manual`).
    public static let code: Set<String> = [
        // Terminals
        "com.apple.Terminal", "com.googlecode.iterm2", "dev.warp.Warp-Stable", "dev.warp.Warp-Preview",
        "com.mitchellh.ghostty", "net.kovidgoyal.kitty", "io.alacritty", "org.alacritty", "com.github.wez.wezterm",
        "co.zeit.hyper", "org.tabby", "com.termius-dmg.mac", "com.raphaelamorim.rio",
        // Code editors and IDEs (JetBrains by prefix, see `codePrefixes`)
        "com.apple.dt.Xcode", "com.microsoft.VSCode", "com.microsoft.VSCodeInsiders", "com.vscodium",
        "com.todesktop.230313mzl4w4u92",  // Cursor
        "com.exafunction.windsurf", "dev.zed.Zed", "dev.zed.Zed-Preview", "com.sublimetext.4", "com.sublimetext.3",
        "com.panic.Nova", "com.barebones.bbedit", "com.macromates.TextMate", "org.gnu.Emacs", "org.vim.MacVim",
        "com.google.android.studio", "com.apple.ScriptEditor2",
        // Logs, databases, API clients
        "com.apple.Console", "com.tinyapp.TablePlus", "com.sequel-ace.sequel-ace", "com.postmanlabs.mac",
        "com.insomnia.app",
    ]

    /// Bundle ID prefixes in `code`: every JetBrains IDE, including EAP builds and Fleet.
    public static let codePrefixes = ["com.jetbrains."]
    /// Matches a prefix but isn't an editor: the JetBrains Toolbox launcher.
    static let codePrefixExceptions: Set<String> = ["com.jetbrains.toolbox"]

    /// Password managers: off, ⌃⌥G included.
    public static let passwords: Set<String> = [
        "com.1password.1password", "com.agilebits.onepassword7", "com.bitwarden.desktop", "org.keepassxc.keepassxc",
        "com.apple.keychainaccess", "com.apple.Passwords", "org.gpgtools.gpgkeychain",
    ]

    /// Remote desktops and virtual machines: off.
    public static let remote: Set<String> = [
        "com.apple.ScreenSharing", "com.microsoft.rdc.macos", "com.parallels.desktop.console", "com.vmware.fusion",
        "com.utmapp.UTM", "com.teamviewer.TeamViewer", "com.philandro.anydesk",
        "com.google.Chrome.app.cmkncekebbebpfilplodngbpllndjkfo",  // Chrome Remote Desktop
    ]

    /// Every bundle ID on the list (prefix matches aren't enumerable; Settings finds those among known apps).
    public static var listed: Set<String> { code.union(passwords).union(remote) }

    public static func category(of bundleID: String?) -> AppCategory? {
        guard let id = bundleID else { return nil }
        if passwords.contains(id) { return .passwords }
        if remote.contains(id) { return .remote }
        if code.contains(id) { return .code }
        if !codePrefixExceptions.contains(id), codePrefixes.contains(where: { id.hasPrefix($0) }) { return .code }
        return nil
    }

    /// The mode an app has until the user changes it: the built-in list's, else Manual for an app learned to be
    /// a code editor (`CodeAppLearner`), else On.
    public static func defaultMode(_ bundleID: String?, learned: Set<String> = []) -> AppMode {
        guard let id = bundleID else { return .on }
        if let c = category(of: id) { return c.defaultMode }
        return learned.contains(id) ? .manual : .on
    }

    /// The app's mode. The user's choice (`stored`) always wins, over the list and over anything learned; only
    /// Reset removes it.
    public static func mode(_ bundleID: String?, stored: [String: AppMode], learned: Set<String> = []) -> AppMode {
        guard let id = bundleID else { return .on }
        return stored[id] ?? defaultMode(id, learned: learned)
    }

    /// Chat apps where "Casual mode in chat apps" applies (PLAN.md §2 step 7).
    public static let chatApps: Set<String> = [
        "com.tinyspeck.slackmacgap",            // Slack
        "com.hnc.Discord",                      // Discord
        "ru.keepcoder.Telegram", "org.telegram.desktop", "com.telegram.desktop",  // Telegram
        "com.apple.MobileSMS",                  // Messages
        "net.whatsapp.WhatsApp", "desktop.WhatsApp",  // WhatsApp
        "org.whispersystems.signal-desktop",    // Signal
        "com.microsoft.teams2", "com.microsoft.teams",  // Teams
        "com.facebook.archon",                  // Messenger
        "jp.naver.line.mac",                    // LINE
        "com.viber.osx",                        // Viber
        "im.riot.app",                          // Element
        "com.skype.skype",                      // Skype
        "us.zoom.xos",                          // Zoom chat
        "com.mattermost.desktop",               // Mattermost
        "chat.rocket",                          // Rocket.Chat
        "com.google.Chat",                      // Google Chat (app)
    ]
}

/// Learned Manual: an app that isn't on the built-in list, whose text fields keep holding code, is treated as a
/// code editor (Manual: ⌃⌥G only) without anyone adding it to `AppRules`.
///
/// Evidence comes from the automatic check, one verdict per field (the app counts each field once):
/// a field that looks like code (`CodeDetector`) adds a code field; a field with at least `minProseCharacters`
/// that doesn't adds a prose field. An app is learned once it has `threshold` code fields and no prose field at
/// all (precision first: an app where the user writes prose is never learned). Only apps the user never set a
/// mode for are counted, and the user's choice always wins over a learned default (`AppRules.mode`).
public struct CodeAppLearner: Codable, Equatable, Sendable {
    public static let threshold = 3
    public static let minProseCharacters = 80
    /// Counts stop here (they only need to pass the threshold).
    static let cap = 99

    public private(set) var codeFields: [String: Int] = [:]
    public private(set) var proseFields: [String: Int] = [:]

    public init() {}

    public var learned: Set<String> {
        Set(codeFields.keys.filter(isLearned))
    }

    public func isLearned(_ bundleID: String) -> Bool {
        (codeFields[bundleID] ?? 0) >= Self.threshold && (proseFields[bundleID] ?? 0) == 0
    }

    /// The verdict says something about the app: code, or enough text to be prose. A field that is code with
    /// real sentences left outside its blocks (`residualProse`) is mixed, so it says nothing either way.
    public static func isEvidence(_ verdict: CodeDetector.Verdict, residualProse: Bool = false) -> Bool {
        if verdict.isCode { return !residualProse }
        return verdict.totalChars >= minProseCharacters
    }

    /// Records one field's verdict. Returns true when this makes the app learned.
    @discardableResult
    public mutating func note(_ bundleID: String, verdict: CodeDetector.Verdict, residualProse: Bool = false) -> Bool {
        guard Self.isEvidence(verdict, residualProse: residualProse) else { return false }
        let was = isLearned(bundleID)
        if verdict.isCode {
            codeFields[bundleID] = min(Self.cap, (codeFields[bundleID] ?? 0) + 1)
        } else {
            proseFields[bundleID] = min(Self.cap, (proseFields[bundleID] ?? 0) + 1)
        }
        return !was && isLearned(bundleID)
    }

    /// Drops what was learned about an app.
    public mutating func forget(_ bundleID: String) {
        codeFields[bundleID] = nil
        proseFields[bundleID] = nil
    }
}
