import AppKit
import MebokiCore
import SwiftUI
import UniformTypeIdentifiers

/// Settings › Apps (design_code.md §8.4): every app the user has checked in (or added), with
/// On | Casual | Manual | Off, then the installed apps on the built-in skip list (`AppRules`) with their defaults.
/// Off blocks checks there; Casual turns on casual mode there (`AppSettings.isCasual`); Manual leaves the app to ⌃⌥G.
struct AppsPane: View {
    @ObservedObject var settings: AppSettings
    /// Installed apps on the skip list (bundle ID → name), found when the pane opens.
    @State private var installedSkipped: [String: String] = [:]
    @Environment(\.licenceGate) private var gate
    /// The row whose locked segment was clicked (shows the "Needs a licence" popover).
    @State private var lockedPopover: String?

    private struct App: Identifiable {
        let id: String
        let name: String
    }

    /// Apps the user checked in or set a mode for, minus those on the skip list (they have their own group).
    private var apps: [App] {
        var all = settings.checkedApps
        for id in settings.appModes.keys where all[id] == nil { all[id] = Self.displayName(id) }
        return all.filter { settings.skipReason($0.key) == nil }.map { App(id: $0.key, name: $0.value) }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    /// The skip list's installed apps, listed apps the user checked in or set a mode for, and apps learned to
    /// be code editors (`CodeAppLearner`).
    private var skipped: [App] {
        var all = installedSkipped
        for id in Set(settings.checkedApps.keys).union(settings.appModes.keys).union(settings.codeLearning.learned)
        where settings.skipReason(id) != nil && all[id] == nil {
            all[id] = settings.checkedApps[id] ?? Self.displayName(id)
        }
        return all.map { App(id: $0.key, name: $0.value) }.sorted {
            let a = rank($0.id), b = rank($1.id)
            return a != b ? a < b : $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
        }
    }

    /// Group order: terminals and code editors, learned code editors, password managers, remote desktops.
    private func rank(_ id: String) -> Int {
        switch AppRules.category(of: id) {
        case .code: 0
        case nil: 1
        case .passwords: 2
        case .remote: 3
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            FreeModeBanner()
            SettingsGroupHeader("Check text in", first: true)
            SettingsGroup {
                let list = apps
                if list.isEmpty {
                    SettingsRow("No apps yet", subtitle: "Apps you check text in appear here") { EmptyView() }
                    SettingsDivider()
                }
                ForEach(list) { app in
                    appRow(app, subtitle: nil)
                    SettingsDivider()
                }
                SettingsRow("Add an app", subtitle: "Choose its mode before you check text in it") {
                    Button("Add App…") { addApp() }.buttonStyle(.ds(.secondary, small: true))
                }
            }
            SettingsFootnote(symbol: "keyboard",
                             text: "Manual: only \(settings.hotkey.display) checks text there, nothing as you type.")

            let skippedList = skipped
            if !skippedList.isEmpty {
                SettingsGroupHeader("Skipped by default")
                SettingsGroup {
                    ForEach(Array(skippedList.enumerated()), id: \.element.id) { i, app in
                        if i > 0 { SettingsDivider() }
                        appRow(app, subtitle: settings.skipReason(app.id))
                    }
                }
            }
            SettingsFootnote(symbol: "chevron.left.forwardslash.chevron.right",
                             text: "A field that looks like code (a script, JSON, a terminal session) isn't checked "
                                 + "as you type in any app.")
            SettingsFootnote(symbol: "lock", text: "Password fields and secure input are never read, in any app.")
        }
        .task { installedSkipped = await Self.findInstalledSkippedApps() }
    }

    private func appRow(_ app: App, subtitle: String?) -> some View {
        let mode = settings.appMode(app.id)
        let defaultMode = settings.defaultMode(app.id)
        // The user's own choice, kept for good; Reset removes it (even when it equals the default now).
        let chosen = settings.appModes[app.id] != nil
        return SettingsRow(leading: {
            HStack(spacing: 10) {
                AppIcon(bundleID: app.id, name: app.name)
                VStack(alignment: .leading, spacing: 1) {
                    Text(app.name).font(DS.Font.bodyMedium).foregroundStyle(DS.text).lineLimit(1)
                    if gate.locked, mode != settings.effectiveAppMode(app.id) {
                        Text("Acts as Manual for now")
                            .font(DS.Font.caption).foregroundStyle(DS.textSecondary).lineLimit(1)
                    }
                    if let subtitle {
                        HStack(spacing: 2) {
                            Text(mode == defaultMode ? subtitle : "\(subtitle) · default \(defaultMode.title)")
                                .font(DS.Font.caption).foregroundStyle(DS.textSecondary).lineLimit(1)
                            if chosen {
                                Button("Reset") { settings.resetAppMode(app.id) }
                                    .buttonStyle(.dsLink)
                                    .accessibilityLabel("Reset \(app.name) to \(defaultMode.title)")
                            }
                        }
                    }
                }
            }
        }, control: {
            // Only a real change is stored: tapping the selected segment doesn't turn the default into a choice.
            DSSegmented(selection: Binding(get: { settings.appMode(app.id) },
                                           set: { if $0 != settings.appMode(app.id) {
                                               settings.setAppMode($0, bundleID: app.id) } }),
                        options: AppMode.allCases.map { ($0, $0.title) },
                        locked: gate.locked ? [.on, .casual] : [],
                        onLockedTap: { lockedPopover = app.id })
                .popover(isPresented: Binding(get: { lockedPopover == app.id },
                                              set: { if !$0 && lockedPopover == app.id { lockedPopover = nil } }),
                         arrowEdge: .bottom) {
                    NeedsLicencePopover(open: gate.open) { lockedPopover = nil }
                }
        })
        .accessibilityLabel(subtitle.map { "\(app.name), \($0)" } ?? app.name)
    }

    /// Add App…: pick an app in Applications; it's listed with its default mode, ready to change.
    private func addApp() {
        let panel = NSOpenPanel()
        panel.title = "Add an App"
        panel.prompt = "Add"
        panel.allowedContentTypes = [.application]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        guard panel.runModal() == .OK, let url = panel.url else { return }
        guard let id = Bundle(url: url)?.bundleIdentifier, id != Bundle.main.bundleIdentifier else {
            NSSound.beep()  // not an app with a bundle ID, or Meboki itself
            return
        }
        settings.noteChecked(bundleID: id, name: Self.name(of: url))
        if AppRules.category(of: id) != nil, installedSkipped[id] == nil { installedSkipped[id] = Self.name(of: url) }
    }

    /// An app set to Off before it was ever checked (paused before 2026-11-16) has no stored name.
    /// Cached: the pane re-renders on every settings change, and Launch Services lookups aren't free.
    private static var names: [String: String] = [:]
    private static func displayName(_ bundleID: String) -> String {
        if let n = names[bundleID] { return n }
        let n = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID).map(name(of:)) ?? bundleID
        names[bundleID] = n
        return n
    }

    nonisolated private static func name(of url: URL) -> String {
        FileManager.default.displayName(atPath: url.path).replacingOccurrences(of: ".app", with: "")
    }

    /// The skip list's apps on this Mac: the listed bundle IDs through Launch Services, and apps in the
    /// Applications folders whose ID matches a listed prefix (JetBrains IDEs).
    nonisolated private static func findInstalledSkippedApps() async -> [String: String] {
        await Task.detached(priority: .utility) {
            var found: [String: String] = [:]
            for id in AppRules.listed {
                if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: id) { found[id] = name(of: url) }
            }
            let fm = FileManager.default
            let dirs = ["/Applications", fm.homeDirectoryForCurrentUser.appendingPathComponent("Applications").path]
            // Apps, and apps one folder down (`/Applications/JetBrains/…`, `~/Applications/JetBrains Toolbox/…`).
            var bundles: [URL] = []
            for dir in dirs {
                for item in (try? fm.contentsOfDirectory(atPath: dir)) ?? [] {
                    let url = URL(fileURLWithPath: dir).appendingPathComponent(item)
                    if item.hasSuffix(".app") {
                        bundles.append(url)
                    } else if (try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true {
                        for sub in (try? fm.contentsOfDirectory(atPath: url.path)) ?? [] where sub.hasSuffix(".app") {
                            bundles.append(url.appendingPathComponent(sub))
                        }
                    }
                }
            }
            for url in bundles {
                guard let id = Bundle(url: url)?.bundleIdentifier, found[id] == nil,
                      AppRules.category(of: id) != nil else { continue }
                found[id] = name(of: url)
            }
            return found
        }.value
    }
}
