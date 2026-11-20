import AppKit
import MebokiCore
import Combine
import SwiftUI

/// Settings panes (design_code.md §8), in sidebar order.
enum SettingsPane: String, CaseIterable, Identifiable {
    case general, appearance, writing, models, apps, shortcuts, privacy, licence, about
    #if DEBUG
    case debug
    #endif

    var id: String { rawValue }

    var title: String {
        switch self {
        case .general: "General"
        case .appearance: "Appearance"
        case .writing: "Writing"
        case .models: "Models"
        case .apps: "Apps"
        case .shortcuts: "Shortcuts"
        case .privacy: "Privacy"
        case .licence: "Licence"
        case .about: "About"
        #if DEBUG
        case .debug: "Debug"
        #endif
        }
    }

    var symbol: String {
        switch self {
        case .general: "gearshape"
        case .appearance: "paintpalette"
        case .writing: "textformat"
        case .models: "cpu"
        case .apps: "macwindow"
        case .shortcuts: "keyboard"
        case .privacy: "lock.shield"
        case .licence: "key.fill"
        case .about: "info.circle"
        #if DEBUG
        case .debug: "ladybug"
        #endif
        }
    }

    /// Sidebar icon square color (§8 table).
    var color: Color {
        let rgb: UInt32
        switch self {
        case .general: rgb = 0x8E8E93
        case .appearance: rgb = 0x5E5CE6
        case .writing: rgb = 0x0A84FF
        case .models: rgb = 0xAF52DE
        case .apps: rgb = 0xFF9F0A
        case .shortcuts: rgb = 0xFF375F
        case .privacy: rgb = 0x30B850
        case .licence: rgb = 0x30B0C7
        case .about: rgb = 0x636366
        #if DEBUG
        case .debug: rgb = 0xFF453A
        #endif
        }
        return Color(nsColor: .hex(rgb))
    }

    /// Row labels on the pane, for the sidebar search.
    var searchTerms: [String] {
        switch self {
        case .general:
            ["Correction popup", "Glass card", "Anchored bubble", "Island HUD", "Return key", "Launch at login",
             "Show in menu bar", "Underline mistakes as I type", "Updates",
             "Check for updates automatically", "Install updates automatically"]
        case .appearance: ["Color tone", "Colors", "Vivid", "Eased", "Muted", "Dusty", "Bright", "Theme", "Preview"]
        case .writing:
            ["English variant", "US", "UK", "Check for", "Spelling", "Grammar", "Casual mode in chat apps",
             "Protect names, code and links", "Explain each fix", "Skip text that isn't English", "Language"]
        case .models: ["Model", "Apple Intelligence", "Built in", "Gemma", "Download", "Show models folder",
                       "Hugging Face", "Cloud", "API key", "BYOK", "OpenRouter", "OpenAI", "Claude", "GPT"]
        case .apps: ["Check text in", "Casual", "Manual", "Off", "Add App", "Skipped by default", "Skip", "Terminal",
                     "Code editor", "IDE", "Password manager", "Remote desktop", "Code", "Password fields"]
        case .shortcuts: ["Global", "Check text", "Apply all fixes", "Apply this fix", "Skip", "Ignore",
                          "Previous / next fix", "Close", "Hotkey", "Keyboard"]
        case .privacy: ["Text sent to the internet", "Cloud", "Model downloads", "Logs", "Short text snippets in logs",
                        "Licence check", "Revoked keys"]
        case .licence: ["Licence", "License", "Trial", "Free mode", "Activate", "Buy a Licence", "Licence key", "Key",
                        "Paste", "Remove Licence", "Lost your key", "Refund", "Unlock", "What a licence adds"]
        case .about: ["Version", "Source code", "Acknowledgements", "Licensed to", "Welcome Guide", "Onboarding", "Accessibility"]
        #if DEBUG
        case .debug: ["Debug", "Trial", "Clock", "Revoke", "Test key"]
        #endif
        }
    }

    func matches(_ query: String) -> Bool {
        let q = query.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { return true }
        return ([title] + searchTerms).contains { $0.localizedCaseInsensitiveContains(q) }
    }
}

/// What the Settings panes call back into (`AppDelegate`).
struct SettingsActions {
    var useModel: (ModelInfo) -> Void = { _ in }
    var download: (ModelInfo) -> Void = { _ in }
    var pause: (ModelInfo) -> Void = { _ in }
    /// Asks, then deletes a downloaded model (or discards a paused download).
    var delete: (ModelInfo) -> Void = { _ in }
    var showModelsFolder: () -> Void = {}
    var showLogs: () -> Void = {}
    /// Turns launch at login on or off; returns an error message when the system refused.
    var setLaunchAtLogin: (Bool) -> String? = { _ in nil }
    /// Tries a recorded shortcut; returns an error message when it can't be used.
    var applyShortcut: (Shortcut) -> String? = { _ in nil }
    /// Recording a shortcut started (true) or ended (false): the current hotkey is off while recording.
    var recordingChanged: (Bool) -> Void = { _ in }
    /// Saves a pasted API key in the Keychain; returns an error message, or nil.
    var saveKey: (String, CloudProvider) -> String? = { _, _ in nil }
    var removeKey: (CloudProvider) -> Void = { _ in }
    /// Sends one sample sentence to the provider's selected model and reports the result in `cloudTest`.
    var testCloud: (CloudProvider) -> Void = { _ in }
    /// Switches checks to the selected provider's cloud model.
    var useCloud: () -> Void = {}
    /// Switches checks to Apple's built-in model (only while it is available).
    var useApple: () -> Void = {}
    /// System Settings › Apple Intelligence & Siri.
    var openAppleSettings: () -> Void = {}
    /// Opens the onboarding window (About › Welcome Guide).
    var showWelcome: () -> Void = {}
    /// Opens the update window (Check Now, or the version already found).
    var showUpdate: () -> Void = {}
}

/// The result of Settings › Models › Test.
enum CloudTestState: Equatable {
    case running
    case passed(String)
    case failed(String)
}

/// A toast at the bottom of the Settings window.
struct SettingsToast: Equatable {
    var kind: MessageKind
    var title: String
    var id = UUID()
}

/// Window state shared by the panes; settings themselves live in `AppSettings`.
@MainActor
final class SettingsModel: ObservableObject {
    @Published var pane: SettingsPane
    @Published var search = ""
    @Published var recording = false
    @Published var toast: SettingsToast?
    @Published var selectedModelID: String
    @Published var launchAtLogin = false
    /// Providers with a key in the Keychain (`APIKeyStore`); the keys themselves never reach the UI.
    @Published var savedKeys: Set<CloudProvider> = []
    @Published var cloudTest: [CloudProvider: CloudTestState] = [:]
    /// Apple's built-in model on this Mac (Settings › Models' built-in row).
    @Published var appleModel: AppleModelAvailability = .osTooOld
    var actions = SettingsActions()
    /// The licence state the Licence pane, the lock marks and About show.
    let licence: LicenceManager
    /// The key field of Settings › Licence, and the last activation error (kept here so a `meboki://` link can fill them).
    @Published var licenceKeyDraft = ""
    @Published var licenceError: String?
    /// A neutral line under the key field (a link brought a second key while one is active).
    @Published var licenceNote: String?

    private var toastHide: DispatchWorkItem?

    init(pane: SettingsPane, selectedModelID: String, licence: LicenceManager? = nil) {
        self.licence = licence ?? .shared
        self.pane = pane
        self.selectedModelID = selectedModelID
    }

    func showToast(_ kind: MessageKind, _ title: String) {
        withAnimation(DS.Motion.popIn) { toast = SettingsToast(kind: kind, title: title) }
        toastHide?.cancel()
        let work = DispatchWorkItem { [weak self] in
            withAnimation(DS.Motion.fade) { self?.toast = nil }
        }
        toastHide = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.4, execute: work)
    }
}

// MARK: - Views

/// The Settings window content: the floating glass sidebar and the content pane (§8).
struct SettingsRootView: View {
    @ObservedObject var model: SettingsModel
    @ObservedObject var settings: AppSettings
    @ObservedObject var store: ModelStore

    /// The widest a pane's rows get (§8: the content area is 560 at the default 800 width).
    static let maxPaneWidth: CGFloat = 708

    var body: some View {
        HStack(spacing: 0) {
            SettingsSidebar(model: model)
                .frame(width: 224)
            // `minWidth: 0`: a pane wider than the content area must never widen the HStack, or the whole
            // layout is re-centered at a fractional x and the sidebar icons shift inside their squares.
            content
                .frame(minWidth: 0, maxWidth: .infinity, minHeight: 0, maxHeight: .infinity, alignment: .topLeading)
                .clipped()
        }
        // A new color tone redraws the whole window, so every brand and category color picks it up at once.
        .id(settings.colorTone)
        .padding(8)
        .frame(minWidth: SettingsWindowController.minSize.width, maxWidth: .infinity,
               minHeight: SettingsWindowController.minSize.height, maxHeight: .infinity)
        .background(DS.window)
        .overlay(alignment: .bottom) {
            if let t = model.toast {
                ToastView(kind: t.kind, title: t.title)
                    .environment(\.dsGlassBlending, .withinWindow)
                    .padding(.bottom, 24)
                    .transition(.dsPopIn)
                    .id(t.id)
            }
        }
        .ignoresSafeArea()
        .environment(\.licenceGate, LicenceGate(locked: !settings.entitlement.isFull, open: { model.pane = .licence }))
        .onChange(of: model.pane) { _, p in
            settings.lastSettingsPane = p.rawValue
            model.recording = false
        }
    }

    @ViewBuilder private var content: some View {
        if model.pane == .about {
            ScrollView { AboutPane(model: model, licence: model.licence) }
        } else {
            VStack(alignment: .leading, spacing: 0) {
                // The title stays put: the window's (taller) title bar covers it, so nothing clickable
                // scrolls under there.
                Text(model.pane.title)
                    .font(DS.Font.paneTitle)
                    .foregroundStyle(DS.text)
                    .padding(EdgeInsets(top: 20, leading: 26, bottom: 16, trailing: 26))
                    .accessibilityAddTraits(.isHeader)
                ScrollView {
                    // Rows stop growing at `maxPaneWidth` in a wide window; the scroll view (and its
                    // scroller) still spans the whole content area.
                    pane
                        .frame(maxWidth: Self.maxPaneWidth, alignment: .leading)
                        .padding(EdgeInsets(top: 0, leading: 26, bottom: 24, trailing: 26))
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
    }

    @ViewBuilder private var pane: some View {
        switch model.pane {
        case .general: GeneralPane(model: model, settings: settings)
        case .appearance: AppearancePane(settings: settings)
        case .writing: WritingPane(settings: settings)
        case .models: ModelsPane(model: model, settings: settings, store: store)
        case .apps: AppsPane(settings: settings)
        case .shortcuts: ShortcutsPane(model: model, settings: settings)
        case .privacy: PrivacyPane(model: model, settings: settings)
        case .licence: LicencePane(model: model, settings: settings, licence: model.licence)
        case .about: AboutPane(model: model, licence: model.licence)
        #if DEBUG
        case .debug: DebugPane(model: model, settings: settings, licence: model.licence)
        #endif
        }
    }
}

/// Sidebar (§8): traffic lights space, search field, pane items. Radius 14, sidebar glass, padding 12 × 10.
private struct SettingsSidebar: View {
    @ObservedObject var model: SettingsModel

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            // The window's traffic lights sit here (moved by `SettingsWindowController`).
            Color.clear.frame(height: 12).padding(EdgeInsets(top: 4, leading: 6, bottom: 14, trailing: 6))
            searchField.padding(.bottom, 8)
            ForEach(visiblePanes) { p in
                SidebarItem(pane: p, selected: p == model.pane) { model.pane = p }
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, 12)
        .padding(.horizontal, 10)
        .frame(maxHeight: .infinity, alignment: .top)
        .background(GlassBackground(shape: RoundedRectangle(cornerRadius: DS.Radius.group, style: .continuous),
                                    tint: DS.sidebar))
        .onChange(of: model.search) { _, q in
            // Keep a matching pane selected while searching.
            if !model.pane.matches(q), let first = SettingsPane.allCases.first(where: { $0.matches(q) }) {
                model.pane = first
            }
        }
    }

    private var visiblePanes: [SettingsPane] { SettingsPane.allCases.filter { $0.matches(model.search) } }

    private var searchField: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass").font(.system(size: 13)).foregroundStyle(DS.textSecondary)
            TextField("Search", text: $model.search)
                .textFieldStyle(.plain)
                .font(DS.Font.body)
                .foregroundStyle(DS.text)
            if !model.search.isEmpty {
                Button { model.search = "" } label: {
                    Image(systemName: "xmark.circle.fill").foregroundStyle(DS.textTertiary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Clear search")
            }
        }
        .padding(.horizontal, 8)
        .frame(height: 28)
        .background(RoundedRectangle(cornerRadius: DS.Radius.field, style: .continuous).fill(DS.control))
    }
}

/// Sidebar item: padding 5 × 8, radius 8, 13 pt, gap 9, a 22 pt colored icon square (radius 6). Selected:
/// `brandSoft` fill and semibold text.
private struct SidebarItem: View {
    let pane: SettingsPane
    let selected: Bool
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 9) {
                let square = RoundedRectangle(cornerRadius: DS.Radius.iconSquare, style: .continuous)
                square.fill(pane.color)
                    .overlay(InnerTopHighlight(shape: square, color: .white.opacity(0.3)))
                    .overlay(Image(systemName: pane.symbol)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(DS.onAccent))
                    .frame(width: 22, height: 22)
                Text(pane.title)
                    .font(selected ? DS.Font.bodySemibold : DS.Font.body)
                    .foregroundStyle(DS.text)
                Spacer(minLength: 0)
            }
            .padding(.vertical, 5)
            .padding(.horizontal, 8)
            .background(RoundedRectangle(cornerRadius: DS.Radius.row, style: .continuous)
                .fill(selected ? DS.brandSoft : hovering ? DS.hover : Color.clear))
            .contentShape(RoundedRectangle(cornerRadius: DS.Radius.row, style: .continuous))
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .accessibilityLabel(pane.title)
        .accessibilityAddTraits(selected ? [.isButton, .isSelected] : .isButton)
    }
}

// MARK: - Window

/// The Settings window (§8): 800 × 580 by default, resizable down to 800 × 500, the size remembered
/// (`AppSettings.settingsWindowSize`; it always opens centered), full-size content, transparent title bar,
/// the traffic lights moved into the floating sidebar. Opening it activates Meboki (as Settings windows do); closing it gives the
/// keyboard back to the app the user was in. While it is key, a small main menu gives it ⌘, ⌘W ⌘Q and the
/// Edit keys; the menu is removed again so the popups' keys stay untouched.
@MainActor
final class SettingsWindowController: NSObject, NSWindowDelegate {
    let model: SettingsModel
    /// The window closed (give the keyboard back to the previous app).
    var onClose: (() -> Void)?

    private let settings: AppSettings
    private let store: ModelStore
    private var window: NSWindow?
    private var keyMonitor: Any?
    private var observers: Set<AnyCancellable> = []
    private lazy var mainMenu = Self.makeMainMenu(target: self)

    init(model: SettingsModel, settings: AppSettings, store: ModelStore) {
        self.model = model
        self.settings = settings
        self.store = store
        super.init()
        model.$recording.dropFirst().removeDuplicates().receive(on: DispatchQueue.main)
            .sink { [weak self] on in self?.recordingChanged(on) }
            .store(in: &observers)
    }

    var isVisible: Bool { window?.isVisible == true }
    #if DEBUG
    /// The window, for the DEBUG `--settings-demo` mode.
    var debugWindow: NSWindow? { window }
    #endif
    var windowNumber: Int { window?.windowNumber ?? -1 }

    /// Shows the window on `pane` (or the last one) and activates the app.
    func show(pane: SettingsPane? = nil, activate: Bool = true) {
        if let pane { model.pane = pane }
        let w = window ?? makeWindow()
        window = w
        if !w.isVisible { w.center() }
        if activate {
            // An accessory app can't take the focus from the active app on macOS 14+ (cooperative
            // activation refuses it). While Settings is open the app is a regular app, with a Dock icon,
            // as other menu-bar apps do; closing Settings makes it an accessory again.
            if NSApp.activationPolicy() != .regular { NSApp.setActivationPolicy(.regular) }
            NSApp.activate(ignoringOtherApps: true)
        }
        w.makeKeyAndOrderFront(nil)
        layoutTrafficLights()
    }

    func close() { window?.performClose(nil) }

    static let defaultSize = NSSize(width: 800, height: 580)
    static let minSize = NSSize(width: 800, height: 500)

    /// The size to open at: the remembered one, at least `minSize`, and no bigger than the screen's visible
    /// area (a size saved on a larger display).
    private func openingSize(on screen: NSScreen?) -> NSSize {
        var s = settings.settingsWindowSize ?? Self.defaultSize
        s.width = max(s.width, Self.minSize.width)
        s.height = max(s.height, Self.minSize.height)
        if let visible = (screen ?? NSScreen.main)?.visibleFrame.size {
            s.width = min(s.width, max(visible.width, Self.minSize.width))
            s.height = min(s.height, max(visible.height, Self.minSize.height))
        }
        return s
    }

    private func saveSize() {
        guard let w = window else { return }
        settings.settingsWindowSize = w.frame.size
    }

    private func makeWindow() -> NSWindow {
        let w = NSWindow(contentRect: NSRect(origin: .zero, size: Self.defaultSize),
                         styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                         backing: .buffered, defer: false)
        w.title = "Meboki Settings"
        w.titleVisibility = .hidden
        w.titlebarAppearsTransparent = true
        w.isReleasedWhenClosed = false
        // Opens on the Space the user is on, also over a full-screen app (auxiliary: it never goes full screen
        // itself, and macOS doesn't switch away from the full-screen app to show it).
        w.collectionBehavior = [.fullScreenAuxiliary, .moveToActiveSpace]
        w.backgroundColor = NSColor(DS.window)
        w.delegate = self
        let host = NSHostingView(rootView: SettingsRootView(model: model, settings: settings, store: store))
        // The window keeps the size set below; the hosting view must not resize it to content + title bar.
        // With `[]` it also resets the window's min size to zero on its first update (and `.minSize` would add
        // the title bar to it), so `windowWillResize` holds the minimum instead.
        host.sizingOptions = []
        w.contentView = host
        // With a full-size content view the frame is the whole window (800 × 580 by default, §8), not
        // content + title bar; so the content min size is the frame min size too.
        w.contentMinSize = Self.minSize
        w.minSize = Self.minSize
        w.setFrame(NSRect(origin: w.frame.origin, size: openingSize(on: w.screen)), display: false)
        return w
    }

    /// Puts the traffic lights inside the sidebar: centers at (30, 30) from the window's top-left, 20 pt apart
    /// (the HTML's `.lights` inside the 8 pt inset and the sidebar's 12 × 10 padding). The title-bar container
    /// grows to 60 pt so the buttons stay inside it (and clickable); AppKit lays it out again on some window
    /// events, so this runs again after them.
    private func layoutTrafficLights() {
        guard let w = window, let close = w.standardWindowButton(.closeButton),
              let container = close.superview?.superview else { return }
        let height: CGFloat = 60
        var f = container.frame
        f.size.height = height
        f.origin.y = w.frame.height - height
        container.frame = f
        let buttons: [NSWindow.ButtonType] = [.closeButton, .miniaturizeButton, .zoomButton]
        for (i, type) in buttons.enumerated() {
            guard let b = w.standardWindowButton(type) else { continue }
            var r = b.frame
            r.origin.x = 30 - r.width / 2 + CGFloat(i) * 20
            r.origin.y = (height - r.height) / 2
            b.setFrameOrigin(r.origin)
        }
    }

    // MARK: NSWindowDelegate

    func windowDidBecomeKey(_ notification: Notification) {
        layoutTrafficLights()
        NSApp.mainMenu = mainMenu
    }

    func windowDidResignKey(_ notification: Notification) {
        layoutTrafficLights()
        model.recording = false
        if NSApp.mainMenu === mainMenu { NSApp.mainMenu = nil }
    }

    func windowDidResize(_ notification: Notification) { layoutTrafficLights() }

    /// Never smaller than `minSize`, whatever the window's own min size says at the moment.
    func windowWillResize(_ sender: NSWindow, to frameSize: NSSize) -> NSSize {
        NSSize(width: max(frameSize.width, Self.minSize.width), height: max(frameSize.height, Self.minSize.height))
    }

    func windowDidEndLiveResize(_ notification: Notification) {
        layoutTrafficLights()
        saveSize()
    }

    func windowDidChangeScreen(_ notification: Notification) { layoutTrafficLights() }

    func windowWillClose(_ notification: Notification) {
        saveSize()
        model.recording = false
        model.search = ""
        if NSApp.mainMenu === mainMenu { NSApp.mainMenu = nil }
        AppMenus.windowClosed(window)
        onClose?()
    }

    // MARK: Shortcut recording (§8.1 "Shortcut")

    private func recordingChanged(_ on: Bool) {
        model.actions.recordingChanged(on)
        if let m = keyMonitor { NSEvent.removeMonitor(m) }
        keyMonitor = nil
        guard on else { return }
        // Every key goes to the recorder while it records (even ⌘W and ⌘Q): Esc cancels, a key with ⌃ ⌥ or
        // ⌘ becomes the shortcut, anything else asks for a modifier.
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            let handled = MainActor.assumeIsolated { () -> Bool in
                guard let self, self.model.recording else { return false }
                let flags = event.modifierFlags.intersection([.control, .option, .command, .shift])
                if event.keyCode == 53, flags.isEmpty {
                    self.model.recording = false
                    return true
                }
                switch Shortcut.record(event) {
                case .failure(.needsModifier):
                    self.model.showToast(.info, "Use at least one of ⌃ ⌥ ⌘")
                case .failure(.notAKey):
                    NSSound.beep()
                case .success(let shortcut):
                    let error = self.model.actions.applyShortcut(shortcut)
                    self.model.recording = false
                    if let error {
                        self.model.showToast(.error, error)
                    } else {
                        self.model.showToast(.success, "Shortcut set to \(shortcut.display)")
                    }
                }
                return true
            }
            return handled ? nil : event
        }
    }

    // MARK: Main menu (only while Settings is key)

    private static func makeMainMenu(target: SettingsWindowController) -> NSMenu {
        let main = NSMenu()
        let appItem = NSMenuItem()
        let app = NSMenu(title: "Meboki")
        let settingsItem = NSMenuItem(title: "Settings…", action: #selector(showSettingsAction), keyEquivalent: ",")
        settingsItem.target = target
        app.addItem(settingsItem)
        app.addItem(.separator())
        app.addItem(NSMenuItem(title: "Quit Meboki", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
        appItem.submenu = app
        main.addItem(appItem)

        let editItem = NSMenuItem()
        let edit = NSMenu(title: "Edit")
        edit.addItem(NSMenuItem(title: "Undo", action: Selector(("undo:")), keyEquivalent: "z"))
        let redo = NSMenuItem(title: "Redo", action: Selector(("redo:")), keyEquivalent: "z")
        redo.keyEquivalentModifierMask = [.command, .shift]
        edit.addItem(redo)
        edit.addItem(.separator())
        edit.addItem(NSMenuItem(title: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x"))
        edit.addItem(NSMenuItem(title: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c"))
        edit.addItem(NSMenuItem(title: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v"))
        edit.addItem(NSMenuItem(title: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a"))
        editItem.submenu = edit
        main.addItem(editItem)

        let windowItem = NSMenuItem()
        let window = NSMenu(title: "Window")
        window.addItem(NSMenuItem(title: "Close", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w"))
        window.addItem(NSMenuItem(title: "Minimize", action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m"))
        windowItem.submenu = window
        main.addItem(windowItem)
        return main
    }

    @objc private func showSettingsAction() { show() }
}
