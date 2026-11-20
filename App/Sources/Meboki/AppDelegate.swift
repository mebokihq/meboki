import AppKit
import Carbon
import Combine
import MebokiCore
import ServiceManagement

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    /// Left-click: the popover (design_code.md §7). Right-click: the debug menu below (§6).
    private var statusItem: StatusItem!
    private lazy var popover = PopoverPanel(settings: settings)
    /// The app checks run in: the frontmost app, or the last one before Meboki came forward.
    private var targetApp: NSRunningApplication?
    private let statusLine = NSMenuItem(title: "Starting…", action: nil, keyEquivalent: "")
    private let permissionItem = NSMenuItem(title: "Grant Accessibility Permission…", action: #selector(grantPermission), keyEquivalent: "")
    private let checkItem = NSMenuItem(title: "Proofread Focused Field", action: #selector(proofreadFromMenu), keyEquivalent: "")
    /// Frees the local model's memory now (the next check loads it again); shown while it's loaded.
    private let unloadItem = NSMenuItem(title: "Unload Model", action: #selector(unloadModel), keyEquivalent: "")

    private let server = ServerManager()
    private let store = ModelStore()
    private let settings = AppSettings.shared
    /// Licence state: trial, key, revoked list (`Licence/`). The check flow reads it through `settings`' effective values.
    private let licence = LicenceManager.shared
    /// Updates (official builds only; `isEnabled` is false in a build from source).
    private let updates = UpdateController.shared
    private lazy var popup = PopupController(settings: settings)
    /// The Settings window (design_code.md §8).
    private lazy var settingsWindow: SettingsWindowController = {
        let model = SettingsModel(pane: SettingsPane(rawValue: settings.lastSettingsPane) ?? .general,
                                  selectedModelID: selectedModel.id)
        model.appleModel = appleModel
        settingsWindowMade = true
        model.actions = SettingsActions(
            useModel: { [weak self] m in self?.selectModel(m) },
            download: { [weak self] m in self?.confirmLicense(m) { self?.store.download(m) } },
            pause: { [weak self] m in self?.store.pause(m) },
            delete: { [weak self] m in self?.confirmDelete(m) },
            showModelsFolder: { [weak self] in self?.showModels() },
            showLogs: { NSWorkspace.shared.open(Log.url.deletingLastPathComponent()) },
            setLaunchAtLogin: { [weak self] on in self?.setLaunchAtLogin(on) },
            applyShortcut: { [weak self] s in self?.applyShortcut(s) },
            recordingChanged: { [weak self] on in self?.shortcutRecording(on) },
            saveKey: { [weak self] key, p in self?.saveKey(key, for: p) },
            removeKey: { [weak self] p in self?.removeKey(p) },
            testCloud: { [weak self] p in self?.testCloud(p) },
            useCloud: { [weak self] in self?.useCloud() },
            useApple: { [weak self] in self?.useApple() },
            openAppleSettings: { AppleIntelligence.openSettings() },
            showWelcome: { [weak self] in self?.showOnboarding() },
            showUpdate: { [weak self] in self?.updates.showUpdate() })
        let c = SettingsWindowController(model: model, settings: settings, store: store)
        // Closing Settings gives the keyboard back to the app the user was in.
        c.onClose = { [weak self] in
            guard let app = self?.targetApp, !app.isTerminated else { return }
            app.activate()
        }
        return c
    }()
    /// `settingsWindow` exists (it is lazy): availability changes reach its model only then.
    private var settingsWindowMade = false
    /// The onboarding window (first launch, or right-click menu › Welcome Guide…).
    private var onboarding: OnboardingWindowController?
    /// Polls the Accessibility permission while it's off (`watchTrust`).
    private var trustTimer: Timer?
    private let toasts = ToastPanel()
    private var noticeWindow: TrialEndedWindowController?
    private var lastDayRetryPending = false
    /// The island HUD (popup style `island`, design_code.md §5.6): checking, review, done and messages.
    private let island = IslandPanel()
    private let overlay = UnderlineOverlay()
    /// Field and input watcher of the current review session.
    private var watcher: FieldWatcher?
    /// Debounced underline refresh after a scroll, move or write.
    private var relayout: DispatchWorkItem?
    /// Debounced check that the field still holds the reviewed text.
    private var valueCheck: DispatchWorkItem?
    /// Debounced check of what a scroll brought on screen (automatic review).
    private var scrollCheck: DispatchWorkItem?
    private var hotKey: HotKey?
    /// Launched by the system at login (no Settings window then, even with the icon hidden).
    private var launchedAtLogin = false
    private var checkTask: Task<Void, Never>?
    /// Sentence cache shared by checks (Milestone B, `CheckPipeline`): kept while the model stays the same.
    private var pipeline: CheckPipeline?
    private var pipelineKey = ""
    /// Live-review requests to the scheduler, chained so they reach it in typing order.
    private var liveChain: Task<Void, Never>?
    /// Follows the focused field for the automatic check (Milestone B step 3): no hotkey needed.
    private let focusTracker = FocusTracker()
    /// The focused text area the automatic check watches, until focus moves.
    private struct AutoTarget {
        let element: AXUIElement
        let pid: pid_t
        /// The app gives real text bounds there (measured on the first text with letters). Without them the
        /// automatic check stays off in this field: it shows underlines only, never a card below the field.
        var bounds: Bool?
        /// The text last handed to the scheduler: a caret move that leaves it the same needs no new pass.
        var requested: String?
        /// The field's text looked like code last time (`CodeDetector`): logged once, not checked.
        var code = false
        /// This field already counted for learned Manual (`CodeAppLearner`): one verdict per field.
        var judged = false
    }
    /// Fields that counted for learned Manual this session, per app (compared with `CFEqual`, the last 50), so
    /// refocusing a field doesn't count again.
    private var learnSeen: [String: [AXUIElement]] = [:]
    private var autoTarget: AutoTarget?
    /// Checks the focused field after a typing pause while no review is up; a live review takes over once
    /// the check found fixes.
    private var autoScheduler: CheckScheduler?
    /// The pipeline `autoScheduler` runs on.
    private var autoPipeline: CheckPipeline?
    /// Requests to `autoScheduler`, chained so they reach it in typing order.
    private var autoChain: Task<Void, Never>?
    /// When the text of the pending automatic check was handed over (for the card's check time).
    private var autoRequested = Date()
    /// Esc dismissed the underlines in this field: no automatic check there until focus moves.
    private var autoMuted: AXUIElement?
    /// Fixes the user ignored (⇥). Automatic and live checks leave them out, so they don't come back.
    private var ignoredFixes = IgnoredFixes()
    /// The user switched Spaces while the running check was waiting for the model.
    private var spaceChangedDuringCheck = false
    /// Incremented per check and on cancel; stale async results compare against it and drop themselves.
    private var checkID = 0
    private var isChecking = false
    /// ⌃⌥G while the model was loading (at launch, or again after an idle unload): the check runs once it's
    /// ready, if the same app is still in front (within `pendingCheckLimit`).
    private var pendingCheck: (pid: pid_t, at: Date)?
    private static let pendingCheckLimit: TimeInterval = 60
    private var settingsObservers: Set<AnyCancellable> = []
    private let sigterm = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .main)

    /// A finished check the user is reviewing (design_code.md §5.1). Fixes can be applied or ignored in any
    /// order; `list` tracks their state and keeps the ranges of later fixes in step with the field.
    private struct Session {
        enum Mode {
            /// Underlines in the field; the card opens on a click (design_code.md §5.3, §5.4).
            case underlines
            /// The app gives no text bounds: the card opens below the field on the first fix and steps
            /// through the fixes (the stage 3 flow).
            case fallback
        }
        let snapshot: FieldSnapshot
        /// Where the checked text starts in the field (UTF-16).
        let scopeLocation: Int
        /// Island style (§5.6): the island shows the current fix by itself and takes the keys; underlines
        /// (when the app gives bounds) mark the fixes and a click on one makes it current.
        let island: Bool
        var mode: Mode = .fallback
        /// The whole field value as Meboki expects it: the snapshot, plus every fix written so far, as
        /// the app reported it after the last write. Anything else means the user edited the field.
        var fieldText: String
        /// When the last fix was written. Apps that update their value late (Chromium) get a moment to settle.
        var lastWrite: Date?
        /// The rect of the last underlined one-line fix, compared on each tick to notice silent layout changes.
        var probe: (fix: Int, rect: CGRect)?
        /// The fixes, with ranges relative to `list.text` (the checked text with the fixes applied so far).
        var list: FixList
        /// Model name and check time for the card's lock line.
        let modelName: String
        /// The provider when a cloud model checked the text (the card shows a cloud instead of the lock).
        let cloudProvider: CloudProvider?
        let checkDuration: TimeInterval
        /// `checkID` of the check that started the session; live results of older sessions drop themselves.
        let checkID: Int
        /// Typing may update this review (Milestone B): the whole field was checked, with the local model,
        /// and "Underline mistakes as I type" is on. `startLive` decides once the mode is known.
        let liveEligible: Bool
        /// The check's pipeline: its sentence cache makes the re-checks cheap.
        let pipeline: CheckPipeline
        /// Started by the automatic check (FocusTracker), not the hotkey: underlines only (never the card below
        /// the field), the island doesn't take the keys until a click, and with nothing pending the review
        /// stays up quietly until focus leaves the field.
        var auto = false
        /// Typing updates the review instead of ending it: the fixes follow the text and the edited sentences
        /// are checked again after a pause (card or bubble style, with underlines).
        var live = false
        var scheduler: CheckScheduler?
        /// Saved before any paste fallback; restored once when the session ends.
        let clipboard = ClipboardGuard()
        var usedPaste = false
        var logged = false

        /// Edits the user makes in the field end the session: with underlines, or in island style (which
        /// shows fixes even without underlines).
        var watchesEdits: Bool { mode == .underlines || island }
    }
    private var session: Session?

    private var selectedModel: ModelInfo {
        get { Catalog.byID(UserDefaults.standard.string(forKey: "modelID")) ?? Catalog.recommended }
        set { UserDefaults.standard.set(newValue.id, forKey: "modelID") }
    }

    /// Providers with an API key in the Keychain: read once at launch, then kept in step by save and remove,
    /// so status updates don't query the Keychain.
    private var cloudKeys: Set<CloudProvider> = []
    /// Checks go to the cloud model with the user's key (Settings › Models › Cloud › Use); `llama-server` is stopped.
    private var usingCloud: Bool { settings.modelSource == .cloud }
    /// Checks go to Apple's built-in model (macOS 26+); `llama-server` is stopped. On this Mac, like local.
    private var usingApple: Bool { settings.modelSource == .apple }
    /// Checks go to the downloaded model through `llama-server`.
    private var usingLocal: Bool { settings.modelSource == .local }
    /// Apple's built-in model on this Mac, refreshed by `watchAppleModel` and before each check.
    private var appleModel = AppleIntelligence.current()
    private var appleTimer: Timer?
    /// The model checks use, for status lines and the island ("Gemma 4 E4B", "Claude Haiku 5.5").
    private var activeModelName: String {
        switch settings.modelSource {
        case .cloud: settings.cloudModel.name
        case .apple: AppleModel.displayName
        case .local: selectedModel.name
        }
    }

    /// What a check runs on (PLAN.md §3 "Apple Intelligence"): one factory for the hotkey check, Try it, the
    /// automatic check and the server coming up, instead of a client built in each.
    private struct CheckBackend {
        let corrector: any Corrector
        /// Pipeline cache key: a different model starts with an empty sentence cache.
        let key: String
        /// Requests in flight at once; nil keeps the pipeline's one (cloud: rate limits).
        let lanes: Int?
        /// The provider when the text leaves the Mac (the card shows a cloud instead of the lock).
        let cloudProvider: CloudProvider?
    }

    /// The source's backend, from what this Mac has now. Never switches source by itself.
    private var backendChoice: ModelBackend {
        ModelBackend.choose(source: settings.modelSource, apple: appleModel, localInstalled: store.isInstalled(selectedModel),
                            cloudKey: cloudKeys.contains(settings.cloudModel.provider))
    }

    /// The backend checks use now, or nil when it can't answer yet: the local model is loading, unloaded or not
    /// downloaded, the cloud key is missing, or Apple's model is unavailable (`showModelNotReady` says which).
    private func checkBackend() -> CheckBackend? {
        switch backendChoice {
        case .cloud:
            let m = settings.cloudModel
            guard let key = APIKeyStore.key(for: m.provider) else { return nil }
            return CheckBackend(corrector: ResponsesClient(model: m, apiKey: key), key: "cloud:\(m.provider.rawValue):\(m.id)",
                                lanes: nil, cloudProvider: m.provider)
        case .apple:
            guard let c = AppleIntelligence.corrector() else { return nil }
            return CheckBackend(corrector: c, key: AppleModel.cacheKey, lanes: AppleModel.requestLanes, cloudProvider: nil)
        case .local:
            guard case .ready(let base) = server.state else { return nil }
            return CheckBackend(corrector: LLMClient(baseURL: base), key: "local:\(selectedModel.id)",
                                lanes: ServerManager.slots, cloudProvider: nil)
        case .unusable:
            return nil
        }
    }

    /// Asks the system again (Apple Intelligence turned on or off, the model finished preparing).
    private func refreshAppleModel() {
        let now = AppleIntelligence.current()
        guard now != appleModel else { return }
        Log.write("apple model: \(appleModel.rawValue) → \(now.rawValue)")
        appleModel = now
        if settingsWindowMade { settingsWindow.model.appleModel = now }
        refreshStatus()
        if usingApple, now.isAvailable { resumeAutoCheck() }
    }

    /// macOS 26+: follows the availability every 5 s, so turning Apple Intelligence on in System Settings shows at
    /// once in the menu, Settings and onboarding. Nothing to follow on older macOS.
    private func watchAppleModel() {
        guard AppleIntelligence.canRun, appleTimer == nil else { return }
        appleTimer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.refreshAppleModel() }
        }
    }

    // MARK: Lifecycle

    func applicationWillFinishLaunching(_ notification: Notification) {
        // A login item is opened with `keyAELaunchedAsLogInItem` in the open-application event.
        let event = NSAppleEventManager.shared().currentAppleEvent
        launchedAtLogin = event?.eventID == kAEOpenApplication
            && event?.paramDescriptor(forKeyword: keyAEPropData)?.enumCodeValue == keyAELaunchedAsLogInItem
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        buildMenu()
        startLicence()
        server.onChange = { [weak self] state in
            self?.refreshStatus()
            switch state {
            case .ready(let base): self?.serverReady(base)
            case .starting: break
            case .stopped, .unloaded, .failed: self?.pendingCheck = nil
            }
        }
        server.isBusy = { [weak self] in self?.checkTask != nil }
        server.idleLimit = settings.idleUnload.interval
        settings.$idleUnload.dropFirst().receive(on: DispatchQueue.main)
            .sink { [weak self] v in self?.server.idleLimit = v.interval }
            .store(in: &settingsObservers)
        store.onFinish = { [weak self] m, result in self?.downloadFinished(m, result) }
        store.objectWillChange.receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.refreshStatus() }
            .store(in: &settingsObservers)
        popup.onApplyAll = { [weak self] in self?.applyAll() }
        popup.onApplyOne = { [weak self] in self?.applyCurrent() }
        popup.onIgnore = { [weak self] in self?.ignoreCurrent() }
        popup.onPrevious = { [weak self] in self?.moveCurrent(forward: false) }
        popup.onNext = { [weak self] in self?.moveCurrent(forward: true) }
        popup.onClose = { [weak self] in self?.closeCard() }
        island.keys.onApplyAll = { [weak self] in self?.applyAll() }
        island.keys.onApplyOne = { [weak self] in self?.applyCurrent() }
        island.keys.onIgnore = { [weak self] in self?.ignoreCurrent() }
        island.keys.onPrevious = { [weak self] in self?.moveCurrent(forward: false) }
        island.keys.onNext = { [weak self] in self?.moveCurrent(forward: true) }
        island.keys.onClose = { [weak self] in self?.endReview() }
        // The island stays key through a review; keys it doesn't use (typing, ⌘Z) go on to the target app,
        // whose edit then ends the review as with underlines.
        island.keys.forward = { [weak self] event in
            guard let pid = self?.session?.snapshot.pid else { return }
            event.cgEvent?.postToPid(pid)
        }
        island.setActions(applyAll: { [weak self] in self?.applyAll() },
                          applyOne: { [weak self] in self?.applyCurrent() },
                          skip: { [weak self] in self?.ignoreCurrent() })
        // Another app coming to the front ends the review (the fixes refer to a field the user left) and
        // closes the popover; the paused icon follows the new frontmost app.
        targetApp = NSWorkspace.shared.frontmostApplication.flatMap { $0.processIdentifier == getpid() ? nil : $0 }
        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main
        ) { [weak self] note in
            let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
            MainActor.assumeIsolated {
                guard let self, let app, app.processIdentifier != getpid() else { return }
                self.targetApp = app
                self.popover.hide()
                self.refreshStatus()
                guard let s = self.session, app.processIdentifier != s.snapshot.pid else { return }
                self.cancel()
            }
        }
        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.activeSpaceDidChangeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.spaceChanged() }
        }
        NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.screensChanged() }
        }

        // ⌃⌥G (or the shortcut set in Settings): proofread the focused field (or the selection, if any).
        if !registerHotKey() {
            let shortcut = settings.hotkey.display
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
                self.toast(.warning, "\(shortcut) is taken by another app.",
                           detail: "Choose another shortcut in Settings › Shortcuts", symbol: "exclamationmark.triangle",
                           near: nil, duration: 8)
            }
        }

        // `kill`/`pkill` (e.g. Scripts/make-app.sh --install) should quit cleanly and stop llama-server too.
        signal(SIGTERM, SIG_IGN)
        sigterm.setEventHandler { NSApp.terminate(nil) }
        sigterm.resume()

        // First launch: the onboarding window explains Accessibility and asks for it, and lets the user pick
        // the model to download, so neither the system prompt nor a multi-GB download starts by itself.
        let firstRun = !settings.onboardingDone
        if !firstRun, !AX.isTrusted(prompt: false) { _ = AX.isTrusted(prompt: true) }
        watchTrust()
        cloudKeys = Set(CloudProvider.allCases.filter(APIKeyStore.hasKey))
        // A fresh install on a Mac where Apple's model answers starts with it: checks work with no download
        // (PLAN.md §3; `Catalog.appleIsDefault`). Anyone who already chose, or used the app before, keeps their model.
        if let source = ModelBackend.freshInstallSource(
            storedSource: settings.storedModelSource, storedModelID: UserDefaults.standard.string(forKey: "modelID"),
            onboardingDone: settings.onboardingDone,
            // Never from a DEBUG-forced state on a macOS that can't run the model.
            apple: AppleIntelligence.canRun ? appleModel : .osTooOld, appleIsDefault: Catalog.appleIsDefault) {
            settings.modelSource = source
            Log.write("model: fresh install, \(source.rawValue) by default")
        }
        watchAppleModel()
        // Cloud mode and Apple's model need no local model: llama-server stays stopped (no RAM, no download). A model
        // that isn't downloaded waits for the user (onboarding, or Settings › Models): launch never starts a download.
        if usingLocal, store.isInstalled(selectedModel) { ensureModelAndStart() }

        // Checking as you type (Milestone B step 3): the focused text area is checked after a typing pause.
        focusTracker.onFocus = { [weak self] el, pid in self?.autoFocusChanged(el, pid: pid) }
        focusTracker.onEdit = { [weak self] _, _, caretOnly in self?.requestAutoCheck(caretOnly: caretOnly) }
        focusTracker.shouldFollow = { [weak self] app in self?.settings.autoCheckAllowed(app.bundleIdentifier) ?? false }
        settings.$underlineAsYouType.dropFirst().receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.updateAutoCheck() }
            .store(in: &settingsObservers)
        settings.$modelSource.dropFirst().receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.updateAutoCheck()
                self?.refreshStatus()
            }
            .store(in: &settingsObservers)
        updateAutoCheck()
        startUpdates()
        // Reopened by the updater: as quiet as a launch at login.
        let afterUpdate = UpdateController.consumeRelaunch()
        if firstRun {
            showOnboarding()
        } else if !settings.showInMenuBar, !launchedAtLogin, !afterUpdate {
            // With the icon hidden there is no other way in: a launch by hand opens Settings.
            showSettings()
        }
        // A `meboki://` URL that launched the app waited for everything above.
        launchFinished = true
        let urls = pendingURLs
        pendingURLs = []
        for url in urls { handleActivationURL(url) }
    }

    /// False until `applicationDidFinishLaunching` is through; a URL that opens the app before is kept till then.
    private var launchFinished = false
    private var pendingURLs: [URL] = []

    func applicationWillTerminate(_ notification: Notification) {
        server.stop()
    }

    /// Opening the app again (Finder, Launchpad, `open`) shows Settings, the way back when the menu-bar
    /// icon is hidden (§8.1).
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !settings.onboardingDone || onboarding?.isVisible == true { showOnboarding() } else { showSettings() }
        return false
    }

    // MARK: Menu

    private func buildMenu() {
        let menu = NSMenu()
        menu.delegate = self
        statusLine.isEnabled = false
        menu.addItem(statusLine)
        menu.addItem(.separator())

        menu.addItem(checkItem)
        menu.addItem(permissionItem)
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Settings…", action: #selector(showSettingsFromMenu), keyEquivalent: ","))
        menu.addItem(NSMenuItem(title: "Welcome Guide…", action: #selector(showOnboardingFromMenu), keyEquivalent: ""))
        if updates.isEnabled {
            menu.addItem(NSMenuItem(title: UpdateText.checkNow, action: #selector(checkForUpdatesFromMenu), keyEquivalent: ""))
        }
        menu.addItem(.separator())
        menu.addItem(unloadItem)
        menu.addItem(NSMenuItem(title: "Show Models Folder", action: #selector(showModels), keyEquivalent: ""))
        menu.addItem(NSMenuItem(title: "Show Meboki Log", action: #selector(showAppLog), keyEquivalent: ""))
        menu.addItem(NSMenuItem(title: "Show Server Log", action: #selector(showLog), keyEquivalent: ""))
        #if DEBUG
        menu.addItem(NSMenuItem(title: "Component Gallery (Debug)", action: #selector(showGallery), keyEquivalent: ""))
        menu.addItem(buildLicenceDebugMenu())
        #endif
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Quit Meboki", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
        for item in menu.items where item.action != nil && item.target == nil && item.action != #selector(NSApplication.terminate(_:)) {
            item.target = self
        }
        statusItem = StatusItem(menu: menu)
        statusItem.isVisible = settings.showInMenuBar
        statusItem.onLeftClick = { [weak self] in self?.togglePopover() }
        statusItem.onMenuWillOpen = { [weak self] in self?.popover.hide(animated: false) }
        popover.onHide = { [weak self] in self?.statusItem.isOpen = false }
        // `@Published` sends before the new value is stored: act on the next pass.
        settings.$appModes.dropFirst().receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.appModesChanged() }
            .store(in: &settingsObservers)
        settings.$showInMenuBar.dropFirst().receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                guard let self else { return }
                self.popover.hide(animated: false)
                self.statusItem.isVisible = self.settings.showInMenuBar
            }
            .store(in: &settingsObservers)
        settings.$hotkey.receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.updateShortcutItems() }
            .store(in: &settingsObservers)
        // The cloud provider or model changed in Settings › Models: status lines and the popover follow.
        settings.$cloudProvider.dropFirst().receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.refreshStatus() }
            .store(in: &settingsObservers)
        settings.$cloudModelIDs.dropFirst().receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.refreshStatus() }
            .store(in: &settingsObservers)
        popover.setActions(PopoverActions(
            check: { [weak self] in self?.proofreadFromMenu() },
            openSettings: { [weak self] in self?.showSettings() },
            openGeneral: { [weak self] in self?.showSettings(pane: .general) },
            openModels: { [weak self] in self?.showSettings(pane: .models) },
            openLicence: { [weak self] in self?.showLicence() },
            showUpdate: { [weak self] in self?.showUpdate() },
            quit: { NSApp.terminate(nil) }))
        refreshStatus()
    }

    // MARK: Updates (PLAN.md §6 "Updates")

    /// Starts the updater of an official build. A version found by the daily check shows as a dot on the
    /// menu-bar icon and a row in the popover; nothing opens by itself while another app is in use.
    private func startUpdates() {
        guard updates.isEnabled else { return }
        updates.isBusy = { [weak self] in self?.inUse ?? true }
        updates.$needsAttention.receive(on: DispatchQueue.main)
            .sink { [weak self] on in self?.statusItem.hasUpdate = on }
            .store(in: &settingsObservers)
        updates.start()
    }

    /// Something of Meboki's is in use: no automatic install (it quits and reopens the app).
    private var inUse: Bool {
        isChecking || checkTask != nil || session != nil || popup.isVisible || island.isVisible || toasts.isVisible
            || popover.isVisible || noticeWindow?.isVisible == true || onboarding?.isVisible == true
            || settingsWindow.isVisible || !settings.onboardingDone
            || store.downloads.values.contains { state in
                switch state {
                case .downloading, .verifying: true
                case .paused, .failed: false
                }
            }
    }

    /// Sparkle's update window, in front. A review ends first, as for Settings.
    private func showUpdate() {
        popover.hide(animated: false)
        if session != nil || checkTask != nil { cancel() }
        toasts.hide(animated: false)
        island.hide(animated: false)
        updates.showUpdate()
    }

    @objc private func checkForUpdatesFromMenu() {
        // After the menu has closed.
        DispatchQueue.main.async { self.showUpdate() }
    }

    /// The check item's key equivalent and the popover keycap follow the shortcut set in Settings.
    private func updateShortcutItems() {
        let s = settings.hotkey
        if let k = s.menuKeyEquivalent {
            checkItem.keyEquivalent = k.key
            checkItem.keyEquivalentModifierMask = k.modifiers
        } else {
            checkItem.keyEquivalent = ""
        }
        refreshStatus()
    }

    // MARK: Licence

    /// Starts the licence manager: the app follows its entitlement from here on.
    private func startLicence() {
        settings.entitlement = licence.entitlement
        licence.transitions.receive(on: DispatchQueue.main)
            .sink { [weak self] t in self?.licenceStateChanged(from: t.from, to: t.to) }
            .store(in: &settingsObservers)
        Log.write("licence: \(LicenceManager.describe(licence.entitlement))")
        licence.start()
        // A check counting today changes the trial clock without changing the entitlement.
        licence.$trial.dropFirst().receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.showDueLicenceNotices() }
            .store(in: &settingsObservers)
        // At launch: once everything else is up (and after onboarding, which calls this again when it closes).
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in self?.showDueLicenceNotices() }
    }

    /// The entitlement changed (activation, removal, trial end, a new day, the revoked list). The running app
    /// switches behaviour at once: the effective settings follow, the automatic check starts or stops, and a
    /// review that no longer qualifies ends. The popup style applies to the next check.
    private func licenceStateChanged(from old: Entitlement, to new: Entitlement) {
        settings.entitlement = new
        updateAutoCheck()
        appModesChanged()
        if new.isFull { noticeWindow?.close() }  // a key was activated while the notice was open
        // A review in the other popup style (island or card) than the one now in effect ends, so the two UIs
        // never mix; the next check uses the new style.
        if let s = session, s.island != (settings.effectivePopupStyle == .island) {
            Log.write("review: popup style changed with the licence; review ended")
            cancel()
        }
        showDueLicenceNotices()
    }

    // MARK: Licence notices (PLAN.md §6 "Where the user meets the paywall")

    /// The one-time window notice ("Your trial has ended" / "no longer valid") and the last-day toast, whichever
    /// is due. Safe to call again and again: `LicenceNotices` (Core) decides from the current state and the flags,
    /// and each notice sets its flag when it is shown. Called at launch, on every entitlement change, when the
    /// trial clock changes and when onboarding closes.
    private func showDueLicenceNotices() {
        guard noticeWindow?.isVisible != true else { return }
        let busy = !settings.onboardingDone || onboarding?.isVisible == true
        if let notice = LicenceNotices.windowNotice(entitlement: licence.entitlement, kid: licence.storedKid,
                                                    flags: settings.noticeFlags, onboardingBusy: busy) {
            settings.noticeFlags = settings.noticeFlags.marking(notice)
            showLicenceNotice(notice)
            return
        }
        showLastDayToastWhenIdle()
    }

    private func showLicenceNotice(_ notice: LicenceNotice) {
        let variant: LicenceNoticeVariant
        switch notice {
        case .trialEnded: variant = .trialEnded
        case .revoked: variant = .revoked
        case .expired: variant = .expired
        }
        Log.write("licence: notice shown (\(variant))")
        let w = TrialEndedWindowController(
            variant: variant, hotkey: settings.hotkey.display,
            actions: LicenceNoticeActions(
                buy: { NSWorkspace.shared.open(LicenceManager.buyURL) },
                enterKey: { [weak self] in self?.showLicence() },
                continueFree: {}))
        // Not inside `windowWillClose`: that would drop the last reference to the window while it closes.
        w.onClose = { [weak self] in DispatchQueue.main.async { self?.noticeWindow = nil } }
        noticeWindow = w
        w.show()
    }

    /// The last trial day, after its first check: one toast, once. It waits while a check runs or a popup,
    /// message or the menu-bar popover is on screen, and tries again every 2 s (up to 10 minutes).
    private func showLastDayToastWhenIdle(attempt: Int = 0) {
        let busy = !settings.onboardingDone || onboarding?.isVisible == true
        guard LicenceNotices.lastDayToastDue(entitlement: licence.entitlement,
                                             isLastTrialDay: licence.isLastTrialDay && licence.trialTodayCounted,
                                             flags: settings.noticeFlags, onboardingBusy: busy) else { return }
        let idle = !isChecking && checkTask == nil && !popup.isVisible && !island.isVisible && !toasts.isVisible
            && !popover.isVisible && noticeWindow == nil
        guard idle else {
            guard attempt < 300, !lastDayRetryPending else { return }
            lastDayRetryPending = true
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in
                guard let self else { return }
                self.lastDayRetryPending = false
                self.showLastDayToastWhenIdle(attempt: attempt + 1)
            }
            return
        }
        settings.lastDayNoticeShown = true
        Log.write("licence: last-day toast shown")
        toast(.info, "Last day of the full trial",
              detail: "From tomorrow Meboki checks only on \(settings.hotkey.display)",
              symbol: "clock", actionTitle: "Details", action: { [weak self] in self?.showLicence() },
              near: nil, duration: 10)
    }

    /// `meboki://activate?key=…`, from the purchase page, or launched by it. The URL is untrusted input: only the
    /// `activate` host with one `key` parameter of a sane length is read. The result shows in Settings › Licence.
    func handleActivationURL(_ url: URL) {
        guard url.scheme?.lowercased() == "meboki", url.host?.lowercased() == "activate",
              let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems,
              let key = items.first(where: { $0.name == "key" })?.value, !key.isEmpty,
              key.count <= Self.maxActivationKeyLength else {
            Log.write("licence: ignored a meboki:// URL that isn't a valid activation link")
            return
        }
        let model = settingsWindow.model
        // A different working licence is never replaced by a link: Settings › Licence opens with the new key in
        // the field, and the user presses Activate. The same key again is a quiet success.
        if let current = licence.licence, case .success(let new) = LicenceKey.verify(key), new.kid != current.kid,
           !new.isExpired(now: Date()) {
            Log.write("licence: activation link for another key; asked first")
            model.licenceKeyDraft = key
            model.licenceError = nil
            model.licenceNote = LicenceText.replaceNote
            showLicence()
            return
        }
        // First launch: onboarding is on screen, so no Settings window over it; its Done card shows the licence.
        let quiet = !settings.onboardingDone || onboarding?.isVisible == true
        model.licenceNote = nil
        switch licence.activate(key) {
        case .success(let info):
            model.licenceKeyDraft = ""
            model.licenceError = nil
            if quiet { Log.write("licence: activated by link during onboarding"); return }
            showLicence()
            model.showToast(.success, "Licensed to \(info.email)")
        case .failure(let error):
            Log.write("licence: activation by URL failed (\(error))")
            model.licenceKeyDraft = key
            model.licenceError = error.message
            if !quiet { showLicence() }
        }
    }

    /// Opens Settings on the Licence pane (the popover rows, the notices and `meboki://activate` call this).
    func showLicence() { showSettings(pane: .licence) }

    private static let maxActivationKeyLength = 2_000

    func application(_ application: NSApplication, open urls: [URL]) {
        for url in urls where url.scheme?.lowercased() == "meboki" {
            if launchFinished { handleActivationURL(url) } else { pendingURLs.append(url) }
        }
    }

    #if DEBUG
    private let licenceStatusItem = NSMenuItem(title: "", action: nil, keyEquivalent: "")

    private func buildLicenceDebugMenu() -> NSMenuItem {
        let sub = NSMenu(title: "Licence (debug)")
        licenceStatusItem.isEnabled = false
        sub.addItem(licenceStatusItem)
        sub.addItem(.separator())
        for (title, action) in [("Add a Trial Day", #selector(debugAddTrialDay)), ("End Trial Now", #selector(debugEndTrial)),
                                ("Reset Trial and Notice Flags", #selector(debugResetTrial)),
                                ("Remove Licence", #selector(debugRemoveLicence)),
                                ("Fetch Revoked List Now", #selector(debugFetchRevoked))] {
            let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
            item.target = self
            sub.addItem(item)
        }
        let item = NSMenuItem(title: "Licence (debug)", action: nil, keyEquivalent: "")
        item.submenu = sub
        refreshLicenceStatusItem()
        return item
    }

    private func refreshLicenceStatusItem() {
        licenceStatusItem.title = LicenceManager.describe(licence.entitlement) + " · \(licence.trialDaysUsed) day(s) used"
    }

    @objc private func debugAddTrialDay() { licence.debugAddTrialDay(); refreshLicenceStatusItem() }
    @objc private func debugEndTrial() { licence.debugEndTrial(); refreshLicenceStatusItem() }
    @objc private func debugResetTrial() { licence.debugResetTrial(); refreshLicenceStatusItem() }
    @objc private func debugRemoveLicence() { licence.removeLicence(); refreshLicenceStatusItem() }
    @objc private func debugFetchRevoked() { licence.fetchRevokedIfDue(force: true) }
    #endif

    // MARK: Settings window (§8)

    /// Opens Settings on `pane` (or the last one). A review in progress ends first: its underlines and
    /// popups float above other windows and would cover Settings.
    private func showSettings(pane: SettingsPane? = nil) {
        popover.hide(animated: false)
        if session != nil || checkTask != nil { cancel() }
        toasts.hide(animated: false)
        island.hide(animated: false)
        settingsWindow.model.selectedModelID = selectedModel.id
        settingsWindow.model.savedKeys = cloudKeys
        settingsWindow.model.launchAtLogin = SMAppService.mainApp.status == .enabled
        settingsWindow.show(pane: pane)
    }

    @objc private func showSettingsFromMenu() {
        // After the menu has closed.
        DispatchQueue.main.async { self.showSettings() }
    }

    /// Launch at login through `SMAppService` (§8.1). Returns an error message, or nil.
    private func setLaunchAtLogin(_ on: Bool) -> String? {
        let service = SMAppService.mainApp
        defer {
            settingsWindow.model.launchAtLogin = service.status == .enabled
            onboarding?.model.launchAtLogin = service.status == .enabled
        }
        do {
            if on { try service.register() } else { try service.unregister() }
        } catch {
            Log.write("launch at login: \(on ? "register" : "unregister") failed: \(error.localizedDescription)")
            if service.status == .requiresApproval {
                SMAppService.openSystemSettingsLoginItems()
                return "Allow Meboki in System Settings › Login Items"
            }
            return "Couldn't change Launch at login: \(error.localizedDescription)"
        }
        if service.status == .requiresApproval {
            SMAppService.openSystemSettingsLoginItems()
            return "Allow Meboki in System Settings › Login Items"
        }
        return nil
    }

    // MARK: Onboarding (PLAN §7 Phase 1)

    /// Shows the onboarding window: on the first launch, from the right-click menu (Welcome Guide…) or from
    /// Settings › About. A review in progress ends first, as for Settings.
    private func showOnboarding() {
        popover.hide(animated: false)
        if session != nil || checkTask != nil { cancel() }
        toasts.hide(animated: false)
        island.hide(animated: false)
        let c = onboarding ?? makeOnboarding()
        onboarding = c
        if !c.isVisible {
            c.model.step = .welcome
            c.model.pickedModelID = usingApple ? AppleIntelligence.id : selectedModel.id
            c.model.tryState = .idle
        }
        c.model.launchAtLogin = SMAppService.mainApp.status == .enabled
        refreshOnboarding()
        c.show()
        Log.write("onboarding: shown")
    }

    @objc private func showOnboardingFromMenu() {
        DispatchQueue.main.async { self.showOnboarding() }
    }

    private func makeOnboarding() -> OnboardingWindowController {
        let model = OnboardingModel(selectedModelID: selectedModel.id)
        model.actions = OnboardingActions(
            openAccessibility: { [weak self, weak model] in
                model?.askedForAccess = true
                self?.grantPermission()
            },
            revealApp: { NSWorkspace.shared.activateFileViewerSelecting([Bundle.main.bundleURL]) },
            useModel: { [weak self] m in self?.selectModel(m) },
            useApple: { [weak self] in self?.useApple() },
            openAppleSettings: { AppleIntelligence.openSettings() },
            pause: { [weak self] m in self?.store.pause(m) },
            openSettings: { [weak self] pane in self?.showSettings(pane: pane) },
            openLicence: { [weak self] in self?.showLicence() },
            tryCheck: { [weak self] text in
                guard let self else { return [] }
                return try await self.tryCheck(text)
            },
            openPractice: { [weak self] in self?.openPractice() },
            setLaunchAtLogin: { [weak self] on in self?.setLaunchAtLogin(on) },
            finish: { [weak self] in
                self?.settings.onboardingDone = true
                self?.onboarding?.close()
            })
        let c = OnboardingWindowController(model: model, settings: settings, store: store)
        c.onClose = { [weak self] byUser in
            guard let self else { return }
            // Quitting with the window open doesn't count: the next launch shows it again.
            guard byUser else {
                Log.write("onboarding: app quit at step \(self.onboarding?.model.step ?? .welcome)")
                return
            }
            // Closed early counts too: the next launch doesn't show it again (the menu has Welcome Guide…).
            if !self.settings.onboardingDone {
                self.settings.onboardingDone = true
                Log.write("onboarding: closed at step \(self.onboarding?.model.step ?? .welcome)")
            } else {
                Log.write("onboarding: done")
            }
            if let app = self.targetApp, !app.isTerminated, app.bundleIdentifier != "com.apple.systempreferences" {
                app.activate()
            }
            DispatchQueue.main.async { self.showDueLicenceNotices() }
        }
        return c
    }

    /// Keeps the onboarding pages in step with the permission, the model and the server.
    private func refreshOnboarding() {
        guard let o = onboarding else { return }
        let m = o.model
        let trusted = AX.isTrusted(prompt: false)
        if m.trusted != trusted { m.trusted = trusted }
        if m.selectedModelID != selectedModel.id { m.selectedModelID = selectedModel.id }
        let cloud: String? = usingCloud ? settings.cloudModel.name : nil
        if m.cloudModelName != cloud { m.cloudModelName = cloud }
        if m.usingApple != usingApple { m.usingApple = usingApple }
        if m.appleModel != appleModel { m.appleModel = appleModel }
        let engine: OnboardingEngine
        if usingApple {
            engine = appleModel.isAvailable && AppleIntelligence.canRun
                ? .ready(model: AppleModel.displayName, cloud: false)
                : .unavailable(AppleModel.unavailableMessage(appleModel == .available ? .osTooOld : appleModel))
        } else if usingCloud {
            let c = settings.cloudModel
            engine = cloudKeys.contains(c.provider) ? .ready(model: c.name, cloud: true)
                : .failed("no \(c.provider.name) API key")
        } else {
            let name = selectedModel.shortName
            switch server.state {
            case .ready: engine = .ready(model: name, cloud: false)
            case .starting: engine = .loading(name)
            // Unloaded when idle: a check loads it again.
            case .unloaded: engine = .ready(model: name, cloud: false)
            case .failed(let msg): engine = .failed(msg)
            case .stopped:
                switch store.state(selectedModel) {
                case .downloading(let w, let t): engine = .downloading(name, fraction: t > 0 ? Double(w) / Double(t) : 0)
                case .verifying: engine = .downloading(name, fraction: 1)
                case .paused: engine = .needsModel("paused")
                case .failed(let msg): engine = .needsModel(msg)
                case nil: engine = store.isInstalled(selectedModel) ? .loading(name) : .needsModel(nil)
                }
            }
        }
        if m.engine != engine { m.engine = engine }
    }

    /// Onboarding › Try it: checks a sample text with the current model and settings, outside any field.
    private func tryCheck(_ text: String) async throws -> [Edit] {
        if usingLocal {
            if server.state == .unloaded { _ = server.reload(reason: "onboarding") }
            // Loading again after an idle unload: wait for it (a few seconds at most).
            for _ in 0..<150 where server.state == .starting { try await Task.sleep(for: .milliseconds(100)) }
        }
        refreshAppleModel()
        guard let backend = checkBackend() else {
            switch settings.modelSource {
            case .cloud: throw TryError.notReady("No \(settings.cloudModel.provider.name) API key")
            case .apple: throw TryError.notReady(AppleModel.unavailableMessage(appleModel == .available ? .osTooOld : appleModel))
            case .local: throw TryError.notReady("The model isn't ready yet")
            }
        }
        if usingLocal { server.noteUse() }
        let engine = ProofreadEngine(client: backend.corrector, options: settings.checkOptions(for: nil))
        let result = try await engine.check(text)
        Log.write("onboarding: sample checked, \(result.edits.count) fix(es)")
        return result.edits
    }

    private enum TryError: LocalizedError {
        case notReady(String)
        var errorDescription: String? {
            switch self { case .notReady(let m): m }
        }
    }

    /// Onboarding › Try it › Open in TextEdit: a practice note with a few mistakes, in Application Support
    /// (written once; opening it again keeps the user's edits).
    private func openPractice() {
        let url = ModelStore.directory.deletingLastPathComponent().appendingPathComponent("Meboki Practice.txt")
        if !FileManager.default.fileExists(atPath: url.path) {
            let hotkey = settings.hotkey.display
            let text = """
                Click anywhere in this note and press \(hotkey). Mistakes get underlined; click one to see the fix.

                I has wrote this note to see how Meboki work. Their are a few mistake in it, and it should find them quick.

                Press Return in the popup to apply all fixes, or Shift-Return to apply just one. Your text never leave this Mac.

                """
            do {
                try text.write(to: url, atomically: true, encoding: .utf8)
            } catch {
                Log.write("onboarding: practice note not written: \(error.localizedDescription)")
                onboarding?.model.showMessage(.error, "Couldn't create the practice note")
                return
            }
        }
        guard let textEdit = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.TextEdit") else {
            NSWorkspace.shared.open(url)
            return
        }
        NSWorkspace.shared.open([url], withApplicationAt: textEdit, configuration: NSWorkspace.OpenConfiguration())
    }

    // MARK: Shortcut (§8.1, §8.5)

    /// Registers `settings.hotkey`. False when the system refused it.
    @discardableResult
    private func registerHotKey() -> Bool {
        hotKey = nil
        hotKey = HotKey(settings.hotkey) { [weak self] in self?.proofread() }
        if hotKey == nil {
            Log.write("hotkey: \(settings.hotkey.display) not registered (OSStatus \(HotKey.lastError))")
        }
        return hotKey != nil
    }

    /// The recorder in Settings is listening: the current hotkey is off, so pressing it records it again.
    private func shortcutRecording(_ on: Bool) {
        if on {
            hotKey = nil
        } else if hotKey == nil {
            registerHotKey()
        }
    }

    /// A shortcut recorded in Settings. Registers it in place of the current one; on failure the current
    /// one stays. Returns an error message, or nil.
    private func applyShortcut(_ s: Shortcut) -> String? {
        if s == settings.hotkey { return nil }
        if s.isSystemShortcut { return "\(s.display) is a macOS shortcut. Choose another one." }
        hotKey = nil
        if let new = HotKey(s, handler: { [weak self] in self?.proofread() }) {
            hotKey = new
            settings.hotkey = s
            Log.write("hotkey: set to \(s.display)")
            return nil
        }
        Log.write("hotkey: \(s.display) refused (OSStatus \(HotKey.lastError))")
        registerHotKey()
        return "That shortcut is taken by another app"
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        refreshStatus()
        #if DEBUG
        refreshLicenceStatusItem()
        #endif
    }

    // MARK: Popover (§7)

    private func togglePopover() {
        if popover.isVisible {
            popover.hide()
            return
        }
        guard let item = statusItem.screenFrame else { return }
        refreshStatus()
        popover.show(under: item, screen: statusItem.screen)
        statusItem.isOpen = true
    }

    /// An app's mode changed (Settings › Apps, or popover › Pause in {App}, §7.3): a review in an Off app ends.
    private func appModesChanged() {
        // A pending automatic check in an app that was just paused must not reach the model; the tracker
        // drops (or picks up) the frontmost app by the new rules.
        stopAutoCheck()
        focusTracker.retarget()
        if let s = session {
            let id = NSRunningApplication(processIdentifier: s.snapshot.pid)?.bundleIdentifier
            // Off ends any review; Manual ends an automatic one (it only follows apps that allow it).
            if settings.effectiveAppMode(id) == .off || (s.auto && !settings.autoCheckAllowed(id)) { cancel() }
        }
        refreshStatus()
    }

    /// Another Space came forward. The panels join every Space (`canJoinAllSpaces`, so they also show over
    /// full-screen apps), so a review would follow the user onto a Space where its field isn't: it ends, as
    /// when another app comes forward. A running check keeps going, but its result is dropped.
    private func spaceChanged() {
        popover.hide(animated: false)
        if checkTask != nil { spaceChangedDuringCheck = true }
        guard let s = session else { return }
        Log.write("review: the Space changed; underlines cleared")
        if s.list.appliedCount > 0, !s.auto { finish(placeCaret: false) } else { cancel() }
    }

    /// A display was added, removed, moved or changed resolution. Underlines (and a card on a word) are
    /// measured again; the island moves to its screen's new menu bar, or to another screen if its own is gone.
    private func screensChanged() {
        popover.hide(animated: false)
        island.screensChanged(field: session?.snapshot.frame)
        if session?.mode == .underlines { scheduleRelayout(after: 0.3) }
    }

    private func refreshStatus() {
        permissionItem.isHidden = AX.isTrusted(prompt: false)
        if case .ready = server.state, usingLocal { unloadItem.isHidden = false } else { unloadItem.isHidden = true }
        let text: String
        if usingApple {
            // No silent switch when the model is gone: the status says why (Settings › Models has the way back).
            statusLine.title = appleModel.isAvailable
                ? "Ready · \(AppleModel.displayName) (built into macOS) · \(settings.hotkey.display)"
                : "\(AppleIntelligence.shortStatus(appleModel)) · choose another model in Settings › Models"
            refreshPopover()
            refreshOnboarding()
            return
        }
        if usingCloud {
            let m = settings.cloudModel
            statusLine.title = cloudKeys.contains(m.provider)
                ? "Ready · \(m.name) via \(m.provider.name) (cloud) · \(settings.hotkey.display)"
                : "No \(m.provider.name) API key · add one in Settings › Models"
            refreshPopover()
            refreshOnboarding()
            return
        }
        switch server.state {
        case .ready: text = "Ready · \(selectedModel.name) · \(settings.hotkey.display)"
        case .starting: text = "Loading \(selectedModel.name)…"
        case .unloaded: text = "Idle · \(selectedModel.name) unloaded, loads on the next check · \(settings.hotkey.display)"
        case .failed(let msg): text = "Error: \(msg)"
        case .stopped: text = downloadStatus ?? (store.isInstalled(selectedModel) ? "Model not running"
                                                  : "No model downloaded · Settings › Models")
        }
        statusLine.title = text
        refreshPopover()
        refreshOnboarding()
    }

    /// The selected model's download, as a status line ("Downloading Gemma 4 E4B… 46%"). Nil when none.
    private var downloadStatus: String? {
        let m = selectedModel
        switch store.state(m) {
        case .downloading(let w, let t):
            return "Downloading \(m.shortName)… " + String(format: "%.0f%%", t > 0 ? Double(w) / Double(t) * 100 : 0)
        case .paused: return "Download paused · \(m.shortName) · resume it in Settings › Models"
        case .verifying: return "Checking \(m.shortName)…"
        case .failed(let msg): return "Download failed: \(msg)"
        case nil: return nil
        }
    }

    private var downloadFailed: Bool {
        if case .failed = store.state(selectedModel) { return true }
        return false
    }

    @objc private func proofreadFromMenu() {
        // Let the menu or popover close and the keyboard return to the previous app first.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { self.proofread() }
    }

    /// The popover's live state (§7.1, §7.3, §7.4) and the status item's paused dot (§6).
    private func refreshPopover() {
        let m = selectedModel
        let app = targetApp.flatMap { $0.isTerminated ? nil : $0 }
        let paused = settings.isPaused(app?.bundleIdentifier)
        let appName = app?.localizedName ?? "this app"
        let p = popover.model
        if usingApple {
            if p.cloudProvider != nil { p.cloudProvider = nil }
            refreshApplePopover(paused: paused, appName: appName)
        } else if usingCloud {
            if p.builtIn { p.builtIn = false }
            refreshCloudPopover(paused: paused, appName: appName)
        } else {
            if p.cloudProvider != nil { p.cloudProvider = nil; p.modelID = "" }
            if p.builtIn { p.builtIn = false; p.modelID = "" }
            refreshLocalPopover(m, paused: paused, appName: appName)
        }
        if p.ramGB != Catalog.ramGB { p.ramGB = Catalog.ramGB }
        if p.appBundleID != app?.bundleIdentifier { p.appBundleID = app?.bundleIdentifier }
        if p.appName != app?.localizedName { p.appName = app?.localizedName }
        if p.hotkey != settings.hotkey.display { p.hotkey = settings.hotkey.display }
        if !AX.isTrusted(prompt: false) {
            let s = PopoverStatus(kind: .error, text: "Needs Accessibility access · right-click the icon")
            if p.status != s { p.status = s }
        }
        // The icon's paused dot is for the frontmost app only (not Meboki's own windows).
        let front = NSWorkspace.shared.frontmostApplication
        statusItem?.isPaused = front?.processIdentifier != getpid() && settings.isPaused(front?.bundleIdentifier)
    }

    /// The popover's status and model row in cloud mode: the provider and model, no memory meter.
    private func refreshCloudPopover(paused: Bool, appName: String) {
        let m = settings.cloudModel
        let label = "\(m.name) · \(m.provider.name)"
        let status: PopoverStatus
        if !cloudKeys.contains(m.provider) {
            status = PopoverStatus(kind: .error, text: "No \(m.provider.name) API key")
        } else if paused {
            status = PopoverStatus(kind: .paused, text: "Paused in \(appName) · \(label)")
        } else if isChecking {
            status = PopoverStatus(kind: .busy, text: "Checking · \(label)")
        } else {
            status = PopoverStatus(kind: .ready, text: "Ready · \(label)")
        }
        let p = popover.model
        if p.status != status { p.status = status }
        let id = "cloud:" + m.provider.rawValue + ":" + m.id
        if p.modelID != id || p.cloudProvider != m.provider.name {
            p.modelID = id
            p.modelName = m.name
            p.cloudProvider = m.provider.name
            p.cloudDetail = m.errorsFixed == nil
                ? "Cloud · \(m.provider.name) · your key"
                : "Cloud · \(m.provider.name) · " + String(format: "%.1f s per sentence", m.latencySeconds ?? 0)
        }
    }

    /// The popover's status and model row with Apple's built-in model: no memory meter (it lives in a system
    /// process), "Built into macOS" under the name.
    private func refreshApplePopover(paused: Bool, appName: String) {
        let name = AppleModel.displayName
        let status: PopoverStatus
        if !appleModel.isAvailable {
            status = PopoverStatus(kind: .error, text: AppleIntelligence.shortStatus(appleModel))
        } else if paused {
            status = PopoverStatus(kind: .paused, text: "Paused in \(appName) · \(name)")
        } else if isChecking {
            status = PopoverStatus(kind: .busy, text: "Checking · \(name)")
        } else {
            status = PopoverStatus(kind: .ready, text: "Ready · \(name)")
        }
        let p = popover.model
        if p.status != status { p.status = status }
        if p.unloaded { p.unloaded = false }
        if p.modelID != AppleIntelligence.id || !p.builtIn {
            p.modelID = AppleIntelligence.id
            p.modelName = name
            p.builtIn = true
        }
    }

    private func refreshLocalPopover(_ m: ModelInfo, paused: Bool, appName: String) {
        let status: PopoverStatus
        switch server.state {
        case .ready:
            if paused {
                status = PopoverStatus(kind: .paused, text: "Paused in \(appName) · \(m.shortName)")
            } else if isChecking {
                status = PopoverStatus(kind: .busy, text: "Checking · \(m.shortName)")
            } else {
                status = PopoverStatus(kind: .ready, text: "Ready · \(m.shortName)")
            }
        case .starting: status = PopoverStatus(kind: .busy, text: "Loading \(m.shortName)…")
        case .unloaded:
            status = paused
                ? PopoverStatus(kind: .paused, text: "Paused in \(appName) · \(m.shortName) unloaded")
                : PopoverStatus(kind: .idle, text: "Idle · \(m.shortName) unloaded")
        case .failed(let msg): status = PopoverStatus(kind: .error, text: "Error: \(msg)")
        case .stopped:
            if let d = downloadStatus {
                status = PopoverStatus(kind: downloadFailed ? .error : .busy, text: d)
            } else {
                status = PopoverStatus(kind: .idle, text: store.isInstalled(m) ? "Model not running" : "No model downloaded")
            }
        }
        let p = popover.model
        if p.status != status { p.status = status }
        let unloaded = server.state == .unloaded
        if p.unloaded != unloaded { p.unloaded = unloaded }
        if p.modelID != m.id {
            p.modelID = m.id
            p.modelName = m.shortName
            p.peakMemoryGB = m.peakMemoryGB
            p.paragraphSeconds = m.paragraphSeconds
        }
    }

    @objc private func grantPermission() {
        _ = AX.isTrusted(prompt: true)
        AX.openAccessibilitySettings()
        watchTrust()
    }

    /// Polls the Accessibility permission while it's off: System Settings tells no one when it changes. Access
    /// allowed at any time then takes effect at once (the automatic check follows the front app; the menu,
    /// popover and onboarding update). Stops once allowed; a check that finds it off again starts it again.
    private func watchTrust() {
        guard trustTimer == nil, !AX.isTrusted(prompt: false) else { return }
        trustTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.checkTrust() }
        }
    }

    private func checkTrust() {
        guard AX.isTrusted(prompt: false) else { return }
        trustTimer?.invalidate()
        trustTimer = nil
        Log.write("accessibility: access allowed")
        focusTracker.retarget()
        refreshStatus()
        if let o = onboarding, o.isVisible, o.model.step == .access { o.bringForward() }
    }

    /// Settings › Models › Use (or a click on a downloaded model's row): switch and restart `llama-server`.
    private func selectModel(_ m: ModelInfo) {
        // A model that isn't downloaded yet downloads below: ask for its license first (Llama 3.1).
        if !store.isInstalled(m), !licenseAccepted(m) {
            confirmLicense(m) { [weak self] in self?.selectModel(m) }
            return
        }
        settingsWindow.model.selectedModelID = m.id
        if !usingLocal {
            // Back from the cloud or Apple's model: llama-server was stopped, so the switch below starts it.
            if session != nil || checkTask != nil { cancel() }
            settings.modelSource = .local
            Log.write("model: local \(m.id)")
        }
        if m == selectedModel {
            // Same model: only act as "retry" when it isn't already running or loading.
            switch server.state {
            case .ready, .starting: return
            case .stopped, .unloaded, .failed: ensureModelAndStart()
            }
            return
        }
        selectedModel = m
        server.stop()
        ensureModelAndStart()
    }

    // MARK: Apple's built-in model (PLAN.md §3 "Apple Intelligence")

    /// Settings › Models › Use Apple Intelligence, or its onboarding card: checks go to Apple's model at once (no
    /// download); llama-server stops and frees its memory. Only while the model can answer.
    private func useApple() {
        refreshAppleModel()
        guard appleModel.isAvailable else {
            settingsWindow.model.showToast(.info, AppleModel.unavailableMessage(appleModel))
            return
        }
        if session != nil || checkTask != nil { cancel() }
        settings.modelSource = .apple
        server.stop()
        Log.write("model: apple")
        AppleIntelligence.prewarm(system: Prompt.system(for: settings.englishVariant))
        refreshStatus()
        settingsWindow.model.showToast(.success, "Checks now use \(AppleModel.displayName), on this Mac")
    }

    // MARK: Cloud (BYOK)

    /// Settings › Models › Cloud › Use: checks go to the cloud model; llama-server stops and frees its memory.
    private func useCloud() {
        let m = settings.cloudModel
        guard cloudKeys.contains(m.provider) else { return }
        if session != nil || checkTask != nil { cancel() }
        settings.modelSource = .cloud
        server.stop()
        Log.write("model: cloud \(m.provider.rawValue) \(m.id)")
        refreshStatus()
        settingsWindow.model.showToast(.success, "Checks now use \(m.name) via \(m.provider.name)")
    }

    private func saveKey(_ key: String, for provider: CloudProvider) -> String? {
        if let error = APIKeyStore.save(key, for: provider) { return error }
        cloudKeys.insert(provider)
        settingsWindow.model.savedKeys = cloudKeys
        settingsWindow.model.cloudTest[provider] = nil
        Log.write("cloud: \(provider.rawValue) key saved")
        refreshStatus()
        settingsWindow.model.showToast(.success, "\(provider.name) key saved in your Keychain")
        return nil
    }

    /// Removes the key. When cloud mode was using it, checks go back to the local model.
    private func removeKey(_ provider: CloudProvider) {
        APIKeyStore.remove(provider)
        cloudKeys.remove(provider)
        settingsWindow.model.savedKeys = cloudKeys
        settingsWindow.model.cloudTest[provider] = nil
        Log.write("cloud: \(provider.rawValue) key removed")
        if usingCloud, settings.cloudProvider == provider {
            // Back on this Mac: Apple's model when the local one isn't downloaded (no download starts by itself).
            if appleModel.isAvailable, AppleIntelligence.canRun, !store.isInstalled(selectedModel) {
                useApple()
            } else {
                selectModel(selectedModel)
            }
            settingsWindow.model.showToast(.info, "Key removed. Checks are back on this Mac")
        } else {
            settingsWindow.model.showToast(.info, "\(provider.name) key removed")
        }
        refreshStatus()
    }

    /// Settings › Models › Cloud › Test: one sample sentence through the selected model, with the session prompt.
    private func testCloud(_ provider: CloudProvider) {
        let model = settingsWindow.model
        guard let key = APIKeyStore.key(for: provider) else {
            model.cloudTest[provider] = .failed("No key saved")
            return
        }
        let m = settings.cloudModel(for: provider)
        let system = Prompt.system(for: settings.englishVariant)
        let sample = "She have two cat."
        model.cloudTest[provider] = .running
        Task { @MainActor in
            let started = Date()
            do {
                let reply = try await ResponsesClient(model: m, apiKey: key).correct(sample, system: system)
                let seconds = String(format: "%.1f s", Date().timeIntervalSince(started))
                let text = reply.text.trimmingCharacters(in: .whitespacesAndNewlines)
                if reply.truncated {
                    model.cloudTest[provider] = .failed("The reply was cut off (\(seconds)). "
                        + "The model may be thinking first; pick another model")
                } else {
                    model.cloudTest[provider] = .passed("Works · \(seconds) · “\(sample)” → “\(text.prefix(60))”")
                }
                Log.write("cloud: test \(provider.rawValue) \(m.id) ok in \(seconds)")
            } catch {
                model.cloudTest[provider] = .failed(error.localizedDescription)
                Log.write("cloud: test \(provider.rawValue) \(m.id) failed: \(error.localizedDescription)")
            }
        }
    }

    @objc private func showModels() { NSWorkspace.shared.open(ModelStore.directory) }
    @objc private func showLog() { NSWorkspace.shared.open(ServerManager.logURL) }
    #if DEBUG
    @objc private func showGallery() { DesignGallery.show(activate: true) }
    #endif
    @objc private func unloadModel() {
        server.unloadNow()
    }

    @objc private func showAppLog() {
        if !FileManager.default.fileExists(atPath: Log.url.path) { Log.write("log created") }
        NSWorkspace.shared.open(Log.url)
    }

    // MARK: Model

    /// Starts the selected model, downloading it first when it isn't installed (a paused download resumes).
    private func ensureModelAndStart() {
        let m = selectedModel
        if store.isInstalled(m) {
            server.start(model: store.localURL(m))
        } else if licenseAccepted(m) {
            store.download(m)
        } else {
            Log.write("download: \(m.file) not started: license not accepted")
        }
        refreshStatus()
    }

    private func licenseAccepted(_ m: ModelInfo) -> Bool {
        !m.license.requiresAcceptance || settings.acceptedLicenses.contains(m.license.id)
    }

    /// Runs `then` once the model's license is accepted (PLAN.md §3 Notes): at once for a license that needs
    /// no acceptance or was accepted before; otherwise after the user accepts it in an alert (a sheet on the
    /// key window, Settings › Models). Cancel does nothing; Read License opens the license page.
    private func confirmLicense(_ m: ModelInfo, then: @escaping () -> Void) {
        guard !licenseAccepted(m) else { return then() }
        let alert = NSAlert()
        alert.messageText = "Accept the \(m.license.name)?"
        alert.informativeText = "\(m.shortName) comes under the \(m.license.name) and \(m.license.owner)'s "
            + "Acceptable Use Policy. By downloading it you accept them. The model runs only on this Mac; "
            + "Meboki sends nothing to \(m.license.owner)."
        alert.addButton(withTitle: "Accept and Download")
        alert.addButton(withTitle: "Cancel")
        alert.addButton(withTitle: "Read License…")
        let done: (NSApplication.ModalResponse) -> Void = { [weak self] r in
            guard let self else { return }
            switch r {
            case .alertFirstButtonReturn:
                self.settings.acceptedLicenses.insert(m.license.id)
                Log.write("license: accepted \(m.license.id)")
                then()
            case .alertThirdButtonReturn:
                NSWorkspace.shared.open(m.license.url)
            default:
                break
            }
        }
        if let window = NSApp.keyWindow, window.isVisible, window.attachedSheet == nil {
            alert.beginSheetModal(for: window, completionHandler: done)
        } else {
            NSApp.activate(ignoringOtherApps: true)
            done(alert.runModal())
        }
    }

    /// Settings › Models › Delete…: asks in a sheet, then deletes the file (or the paused download). The
    /// selected local model can't be deleted (the pane disables the button); switch to another one first.
    private func confirmDelete(_ m: ModelInfo) {
        guard m != selectedModel else { return }
        let installed = store.isInstalled(m)
        let freed: Int64
        switch store.state(m) {
        case .paused(let w, _): freed = installed ? m.bytes : w
        default: freed = installed ? m.bytes : 0
        }
        let size = String(format: "%.2f GB", Double(freed) / 1e9)
        let alert = NSAlert()
        alert.messageText = installed ? "Delete \(m.shortName)?" : "Discard the \(m.shortName) download?"
        alert.informativeText = (freed > 0 ? "Frees \(size). " : "") + "You can download it again at any time."
        alert.addButton(withTitle: installed ? "Delete" : "Discard")
        alert.addButton(withTitle: "Cancel")
        alert.buttons.first?.hasDestructiveAction = true
        let done: (NSApplication.ModalResponse) -> Void = { [weak self] r in
            guard let self, r == .alertFirstButtonReturn else { return }
            do {
                try self.store.delete(m)
                self.settingsWindow.model.showToast(.success, installed ? "Deleted \(m.shortName) · \(size) freed"
                                                                       : "Download discarded")
            } catch {
                self.settingsWindow.model.showToast(.error, "Couldn't delete \(m.shortName): \(error.localizedDescription)")
                Log.write("model: delete \(m.file) failed: \(error.localizedDescription)")
            }
            self.refreshStatus()
        }
        if let window = NSApp.keyWindow, window.isVisible, window.attachedSheet == nil {
            alert.beginSheetModal(for: window, completionHandler: done)
        } else {
            done(alert.runModal())
        }
    }

    /// A download ended. The selected model starts once it is installed; other models just become usable.
    private func downloadFinished(_ m: ModelInfo, _ result: Result<URL, Error>) {
        guard case .success = result, m == selectedModel, usingLocal else {
            refreshStatus()
            return
        }
        switch server.state {
        case .ready, .starting, .unloaded: break
        case .stopped, .failed: ensureModelAndStart()
        }
    }

    // MARK: Proofread

    private func proofread() {
        toasts.hide(animated: false)
        island.hide(animated: false)
        popover.hide(animated: false)
        cancel()  // stops a running check; ⌃⌥G again also clears the underlines of the last one
        stopAutoCheck()  // the hotkey check replaces a pending automatic one
        // Off in this app (Settings › Apps, §5.8, or popover › Pause in {App}): nothing is read.
        if let front = NSWorkspace.shared.frontmostApplication, front.processIdentifier != getpid(),
           settings.effectiveAppMode(front.bundleIdentifier) == .off {
            let name = front.localizedName ?? "this app"
            if settings.isOffByDefault(front.bundleIdentifier),
               let category = AppRules.category(of: front.bundleIdentifier) {
                // A password manager or remote desktop on the built-in list.
                toast(.info, "Meboki is off in \(name).",
                      detail: "\(category.pluralTitle) are skipped · turn it on in Settings › Apps", near: nil)
            } else {
                toast(.info, "Meboki is paused in \(name).",
                      detail: "Turn it back on in the menu-bar popover or Settings › Apps", near: nil)
            }
            return
        }
        guard AX.isTrusted(prompt: false) else {
            showAccessibilityToast(near: nil)
            return
        }
        if usingApple { refreshAppleModel() }
        guard let backend = checkBackend() else {
            // Loading (at launch, or again after an idle unload): the check runs once the model is ready.
            if usingLocal, server.state == .starting || server.reload(reason: "check") {
                if let front = NSWorkspace.shared.frontmostApplication, front.processIdentifier != getpid() {
                    pendingCheck = (front.processIdentifier, Date())
                }
                toast(.info, "Loading \(selectedModel.name)…", detail: "The check starts when it's ready",
                      symbol: "hourglass", near: nil, duration: 20)
            } else {
                showModelNotReady()
            }
            return
        }
        if usingLocal { server.noteUse() }
        let corrector = backend.corrector
        let cloudProvider = backend.cloudProvider
        guard let front = NSWorkspace.shared.frontmostApplication, front.processIdentifier != getpid() else { return }
        AX.prepare(app: front)
        if let id = front.bundleIdentifier { settings.noteChecked(bundleID: id, name: front.localizedName ?? id) }

        let snap: FieldSnapshot
        do {
            snap = try AX.snapshot(pid: front.processIdentifier)
        } catch {
            showSnapshotError(error, appName: front.localizedName)
            return
        }
        let ns = snap.text as NSString
        let scope: NSRange
        if let sel = snap.selection, sel.length > 0, NSMaxRange(sel) <= ns.length {
            scope = sel
        } else {
            scope = NSRange(location: 0, length: ns.length)
        }
        let scopeText = ns.substring(with: scope)
        guard scopeText.rangeOfCharacter(from: .letters) != nil else {
            toast(.info, "Nothing to check in this field.", near: snap.frame)
            return
        }

        let id = checkID
        spaceChangedDuringCheck = false
        licence.recordCheck()  // a real check: counts a trial day
        setChecking(true, status: "Checking…")
        let modelName = activeModelName
        let useIsland = settings.effectivePopupStyle == .island
        if useIsland { island.showChecking(model: modelName, field: snap.frame) }

        // Settings › Writing and Settings › Apps (stage 9). Only the English variant reaches the model: it picks
        // the session's system prompt, the same string for every request until the user switches US/UK, so the
        // server keeps its prompt cache. Level, casual and protection filter the edits.
        let options = settings.checkOptions(for: front.bundleIdentifier)
        Log.write("check: \(options.variant.rawValue), \(options.level.rawValue)"
            + (options.casual ? ", casual" : "") + (options.protectTokens ? ", protect" : "")
            + (options.englishOnly ? ", English only" : "")
            + (cloudProvider.map { ", cloud \($0.rawValue) \(settings.cloudModel.id)" } ?? "")
            + (usingApple ? ", \(AppleModel.displayName)" : ""))
        // With an empty cache the pipeline sends exactly what `ProofreadEngine` would (whole paragraphs); its
        // cache makes a second check, and the re-checks of a live review, send only the sentences that changed.
        let pipe = checkPipeline(for: backend)
        let liveEligible = settings.effectiveUnderlineAsYouType && cloudProvider == nil
            && scope.location == 0 && scope.length == ns.length
        let started = Date()
        checkTask = Task { @MainActor in
            defer { if self.checkID == id { self.setChecking(false) } }
            do {
                await pipe.setClient(corrector, sameModel: true)
                await pipe.setOptions(options)
                let result = try await pipe.check(scopeText, scope: .init(maxLength: .max)) { partial in
                    let done = partial.covered.count, total = partial.totalChunks
                    guard total > 1, done < total else { return }
                    Task { @MainActor in
                        // Drop progress from older checks, or arriving after the result.
                        guard self.checkID == id, self.checkTask != nil else { return }
                        self.setChecking(true, status: "Checking paragraph \(done + 1) of \(total)…")
                    }
                }
                guard self.checkID == id, !Task.isCancelled else { return }
                self.checkTask = nil
                self.setChecking(false)  // the review may end (and bump checkID) before the defer runs
                // The user moved on while the model worked (another app, or another Space): the field isn't in
                // front, and underlines or a card would float over something else (§12 edge cases).
                if self.spaceChangedDuringCheck
                    || NSWorkspace.shared.frontmostApplication?.processIdentifier != snap.pid {
                    Log.write("check: the field isn't in front any more; result dropped")
                    self.toast(.info, "The field you checked isn't in front any more.",
                               detail: "Check it again with \(self.settings.hotkey.display)", near: nil)
                    return
                }
                let list = FixList(text: scopeText, edits: self.ignoredFixes.filter(result.edits, in: scopeText))
                if result.foreignChunks > 0 {
                    Log.write("check: \(result.foreignChunks) paragraph(s) not in English, not sent")
                }
                if list.isEmpty, result.foreignChunks > 0, result.foreignChunks == result.totalChunks {
                    // Nothing in the text is English (`LanguageGate`): say so instead of "No mistakes found".
                    self.toast(.info, "This text isn't in English.", detail: "Meboki checks English only",
                               near: snap.frame)
                    return
                }
                if list.isEmpty {
                    var notes: [String] = []
                    if result.rejectedChunks > 0 {
                        notes.append("\(Self.paragraphs(result.rejectedChunks)) skipped: the model's answer looked unreliable")
                    }
                    if result.skippedChunks > 0 {
                        notes.append("\(Self.paragraphs(result.skippedChunks, adjective: "very long ")) skipped")
                    }
                    if result.foreignChunks > 0 {
                        notes.append("\(Self.paragraphs(result.foreignChunks)) not in English skipped")
                    }
                    self.toast(.success, "No mistakes found.", detail: notes.isEmpty ? nil : notes.joined(separator: " · "),
                               near: snap.frame)
                    return
                }
                self.session = Session(snapshot: snap, scopeLocation: scope.location, island: useIsland,
                                       fieldText: snap.text, list: list, modelName: modelName,
                                       cloudProvider: cloudProvider,
                                       checkDuration: Date().timeIntervalSince(started),
                                       checkID: id, liveEligible: liveEligible, pipeline: pipe)
                self.startReview()
            } catch {
                // Cancelled checks (CancellationError, or URLError.cancelled from URLSession) stay silent.
                guard self.checkID == id, !Task.isCancelled, (error as? URLError)?.code != .cancelled else { return }
                self.checkTask = nil
                self.toast(.error, "Check failed: \(error.localizedDescription)",
                           detail: "Details: menu › Show Meboki Log", near: snap.frame)
            }
        }
    }

    /// The shared pipeline for the backend's model; a different model starts with an empty cache.
    private func checkPipeline(for b: CheckBackend) -> CheckPipeline {
        if let p = pipeline, pipelineKey == b.key { return p }
        let p = CheckPipeline(client: b.corrector)
        // The local server takes several requests at once; Apple's model one until measured (`AppleModel.requestLanes`);
        // cloud models one at a time (rate limits).
        if let lanes = b.lanes, lanes > 1 { Task { await p.setMaxConcurrentRequests(lanes) } }
        pipeline = p
        pipelineKey = b.key
        return p
    }

    /// "1 paragraph", "3 very long paragraphs".
    private static func paragraphs(_ n: Int, adjective: String = "") -> String {
        "\(n) \(adjective)paragraph\(n == 1 ? "" : "s")"
    }

    /// Stops a running check and ends the review without a toast. Applied fixes stay in the field.
    private func cancel() {
        checkTask?.cancel()
        checkTask = nil
        checkID += 1
        setChecking(false)
        popup.hide()
        island.hide()
        endSession(placeCaret: false)
    }

    // MARK: Review

    /// Underlines the fixes in the field, or, when the app gives no text bounds, opens the card below the
    /// field on the first fix (§5.3 fallback).
    private func startReview() {
        guard var s = session else { return }
        let layout = underlineLayout(s)
        let app = NSRunningApplication(processIdentifier: s.snapshot.pid)?.bundleIdentifier ?? "pid \(s.snapshot.pid)"
        if s.auto {
            // Underlines only. Fixes scrolled out of view still count: a scroll brings their underlines.
            guard let layout else {
                Log.write("auto: no text bounds in \(app); automatic check off in this field")
                session = nil
                if let t = autoTarget, CFEqual(t.element, s.snapshot.element) { autoTarget?.bounds = false }
                return
            }
            s.mode = .underlines
            s.probe = layout.probe
            session = s
            overlay.show(layout.marks, clip: layout.clip)
            watch(s, observeField: true)
            Log.write("review: auto, \(layout.marks.count) of \(s.list.fixes.count) fix(es) underlined in \(app)")
            startLive()
            return
        }
        if s.island {
            // The island shows the first fix by itself and takes the keys; underlines only when there are bounds.
            if let layout, !layout.marks.isEmpty {
                s.mode = .underlines
                s.probe = layout.probe
                overlay.show(layout.marks, clip: layout.clip)
                Log.write("review: island, \(layout.marks.count) of \(s.list.fixes.count) fix(es) underlined in \(app)")
                session = s
                startLive()
                s = session ?? s
            } else {
                s.mode = .fallback
                Log.write("review: island, no text bounds" + (layout == nil ? "" : " on screen") + " in \(app)")
            }
            session = s
            watch(s, observeField: true)
            showIsland(makeKey: true)
            return
        }
        if let layout, !layout.marks.isEmpty {
            s.mode = .underlines
            s.probe = layout.probe
            session = s
            overlay.show(layout.marks, clip: layout.clip)
            watch(s, observeField: true)
            Log.write("review: \(layout.marks.count) of \(s.list.fixes.count) fix(es) underlined in \(app)")
            startLive()
        } else {
            s.mode = .fallback
            session = s
            watch(s, observeField: false)
            Log.write("review: no text bounds" + (layout == nil ? "" : " on screen") + " in \(app), card below the field")
            showCard()
        }
    }

    private struct UnderlineLayout {
        var marks: [UnderlineMark]
        var clip: CGRect
        /// AX gave bounds for at least one pending fix (on screen or not).
        var anyBounds: Bool
        var probe: (fix: Int, rect: CGRect)?
    }

    /// Asks Accessibility where each pending fix is. Nil when the field's visible frame is unknown or no
    /// pending fix has bounds.
    private func underlineLayout(_ s: Session) -> UnderlineLayout? {
        let el = s.snapshot.element
        guard let clip = (AX.visibleFrame(el) ?? s.snapshot.frame).map(Self.onOneDisplay) else { return nil }
        var layout = UnderlineLayout(marks: [], clip: clip, anyBounds: false)
        for i in s.list.pendingIndices {
            guard let r = fieldRange(markOf: i, in: s),
                  let rects = AX.lineRects(el, range: r, in: s.fieldText) else { continue }
            layout.anyBounds = true
            let visible = rects.filter { clip.contains(CGPoint(x: $0.midX, y: $0.midY)) }
            guard !visible.isEmpty else { continue }
            layout.marks.append(UnderlineMark(fix: i, rects: visible, category: s.list.fixes[i].category))
            // A one-line fix's rect is exactly what `AX.bounds` returns for it, so it can be re-measured cheaply.
            if rects.count == 1 { layout.probe = (i, rects[0]) }
        }
        // Some web and Electron fields answer every range with the same rect (the field's, or the caret's).
        // Underlines there would sit on the wrong words, so treat that as no bounds.
        if layout.marks.count > 1, Set(layout.marks.map { NSStringFromRect($0.rects[0]) }).count == 1 {
            Log.write("review: the app gives the same text bounds for every fix; treating as no bounds")
            return nil
        }
        return layout.anyBounds ? layout : nil
    }

    /// The field range (UTF-16) to underline or flash for fix `index`. Nil when there's nothing to mark.
    private func fieldRange(markOf index: Int, in s: Session) -> NSRange? {
        guard let r = s.list.markRange(at: index), r.length > 0 else { return nil }
        return NSRange(location: s.scopeLocation + r.location, length: r.length)
    }

    /// Recomputes the underlines (after a write, a scroll or a move). When AX can't place any pending fix any
    /// more, the session ends. An open card follows its word, or closes when the word left the screen.
    private func refreshUnderlines() {
        relayout?.cancel()
        relayout = nil
        guard var s = session, s.mode == .underlines else { return }
        guard s.list.pendingCount > 0 else {
            // A live review with nothing pending stays up and waits for the next check.
            if s.live {
                closeCard()
                overlay.hide()
            }
            return
        }
        guard let layout = underlineLayout(s) else {
            // An automatic review waits (a scroll or the next edit brings the underlines back) rather than
            // ending and starting a new check with no user action.
            if s.auto {
                closeCard()
                overlay.hide()
                return
            }
            Log.write("review: the app stopped giving text bounds; underlines cleared")
            cancel()
            return
        }
        s.probe = layout.probe
        session = s
        overlay.show(layout.marks, clip: layout.clip)
        guard popup.isVisible else { return }
        if let c = s.list.current, let word = layout.marks.first(where: { $0.fix == c })?.rects.first {
            showCard(word: word)
        } else {
            closeCard()
        }
    }

    /// Redraws the underlines once a scroll, move or write has settled. `suspend` hides them until then
    /// (they'd sit on the wrong words while the text moves).
    private func scheduleRelayout(after delay: TimeInterval = 0.15, suspend: Bool = true) {
        guard session?.mode == .underlines else { return }
        if suspend { overlay.suspend() }
        relayout?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.refreshUnderlines() }
        relayout = work
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }

    /// Starts watching the field and the user's input for this session.
    private func watch(_ s: Session, observeField: Bool) {
        watcher?.stop()
        let w = FieldWatcher(pid: s.snapshot.pid, element: s.snapshot.element, observeField: observeField)
        w.onClick = { [weak self] p in self?.handleClick(at: p) }
        w.onKey = { [weak self] code in self?.handleKey(code) }
        w.onMouseMoved = { [weak self] p in
            guard let self, self.session?.mode == .underlines else { return }
            self.overlay.hovered = self.overlay.hit(p)?.fix
        }
        w.onValueChanged = { [weak self] in self?.scheduleValueCheck(after: 0.05) }
        w.onFieldGone = { [weak self] in
            Log.write("review: the field went away; underlines cleared")
            self?.cancel()
        }
        w.onFocusChanged = { [weak self] in
            guard let self, let s = self.session, !AX.isFocused(s.snapshot.element, pid: s.snapshot.pid) else { return }
            Log.write("review: focus left the field; underlines cleared")
            self.cancel()
        }
        w.onLayoutChanged = { [weak self] in self?.layoutChanged() }
        w.onTick = { [weak self] in self?.checkLayoutDrift() }
        watcher = w
    }

    /// A scroll, move or resize: redraw the underlines once it settles. An automatic review also asks for a
    /// check, so paragraphs scrolled into view get checked (the scheduler waits for a pause, and paragraphs
    /// already checked come from the cache).
    private func layoutChanged() {
        scheduleRelayout()
        guard let s = session, s.auto, s.live else { return }
        // Once the scroll settles: per scroll event it would read the field and stop the running pass each time.
        scrollCheck?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.scrollCheck = nil
            if let s = self.session, s.auto, s.live { self.requestLiveCheck(s) }
        }
        scrollCheck = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4, execute: work)
    }

    /// A click in another app. With underlines: a click on one opens the card on that fix (or moves it
    /// there), any other click closes the card and keeps the underlines. In the fallback, a click outside the
    /// card closes it and ends the review, as in stage 3. The click still reaches the app and moves its caret.
    private func handleClick(at p: CGPoint) {
        if syncLive() { return }
        guard let s = session else { return }
        if s.island {
            // A click on an underline makes that fix the current one. Any other click only takes the keys
            // from the island (the app gets them back); the island stays.
            guard s.mode == .underlines, let hit = overlay.hit(p), var t = session, t.list.select(hit.fix) else { return }
            session = t
            showIsland(makeKey: true)
        } else if s.mode == .underlines, let hit = overlay.hit(p) {
            openCard(on: hit.fix, word: hit.rect)
        } else if s.mode == .fallback || popup.isVisible {
            closeCard()
        }
    }

    /// A key press in the target app (the card is not key). Esc clears the underlines (observed, not
    /// swallowed). Any other key may be typing, so the field is checked for edits.
    private func handleKey(_ code: UInt16) {
        guard let s = session, s.watchesEdits, !popup.isVisible else { return }
        if code == 53 {
            dismissReview()
        } else {
            scheduleValueCheck(after: 0.15)
        }
    }

    private func scheduleValueCheck(after delay: TimeInterval) {
        guard session?.watchesEdits == true else { return }
        valueCheck?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.checkFieldUnchanged() }
        valueCheck = work
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }

    /// Typing (or any edit Meboki didn't make) ends the session: the fix ranges would be wrong.
    private func checkFieldUnchanged() {
        valueCheck = nil
        guard var s = session, s.watchesEdits else { return }
        if s.live {
            syncLive()
            return
        }
        guard let now = AX.text(s.snapshot.element) else { return }
        guard now != s.fieldText else { return }
        // An app that settles its value late after our write (Chromium): take the settled value. A later
        // write still checks the original text is in place before it writes anything.
        if let t = s.lastWrite, Date().timeIntervalSince(t) < 0.5 {
            s.fieldText = now
            session = s
            scheduleRelayout(after: 0.05, suspend: false)
            return
        }
        Log.write("review: the field was edited; underlines cleared")
        if s.list.appliedCount > 0, !s.auto { finish(placeCaret: false) } else { cancel() }
    }

    // MARK: Live review (Milestone B)

    /// A review with underlines over the whole field (any popup style): from now on typing updates the review.
    private func startLive() {
        guard var s = session, s.liveEligible, s.mode == .underlines else { return }
        let id = s.checkID
        s.live = true
        s.scheduler = CheckScheduler(pipeline: s.pipeline) { [weak self] update in
            Task { @MainActor in self?.liveResult(update, checkID: id) }
        }
        session = s
        Log.write("review: live (typing re-checks after a pause)")
    }

    /// Live review: carries the fixes over to what the field holds now (`FixList.textEdited`) and asks for a
    /// re-check. Returns true when the field had changed: fix indices, underlines and the card changed, so a
    /// caller holding a fix index must stop.
    @discardableResult
    private func syncLive() -> Bool {
        guard var s = session, s.live else { return false }
        // Secure input came on (a password field): read nothing more.
        if IsSecureEventInputEnabled() {
            Log.write("review: secure input is on; underlines cleared")
            cancel()
            return true
        }
        guard let now = AX.text(s.snapshot.element), now != s.list.text else { return false }
        // Our own write may not have settled yet (Chromium reports the old value for a moment): look again then.
        if let t = s.lastWrite, Date().timeIntervalSince(t) < 0.5 {
            scheduleValueCheck(after: 0.52 - Date().timeIntervalSince(t))
            return false
        }
        guard let change = TextChange.between(s.list.text, now), s.list.textEdited(change) else { return false }
        s.fieldText = now
        session = s
        Log.write("review: field edited at \(change.range.location) (\(change.delta >= 0 ? "+" : "")\(change.delta)), "
            + "\(s.list.pendingCount) pending")
        // The indices moved: no card on a fix that moved, no clicks on the old marks (a suspended overlay
        // doesn't hit-test) until the redraw.
        popup.hide()
        overlay.current = nil
        scheduleRelayout(after: 0.05)
        showLiveIsland()
        requestLiveCheck(s)
        return true
    }

    /// Island style in a live review: the island follows the current fix, and hides while nothing is pending.
    private func showLiveIsland() {
        guard let s = session, s.live, s.island else { return }
        // An automatic review shows the island only once the user clicked an underline.
        if s.auto, !island.isVisible { return }
        if s.list.pendingCount > 0 { showIsland() } else { island.hide() }
    }

    /// Hands the current text to the scheduler, which checks it after a typing pause.
    private func requestLiveCheck(_ s: Session) {
        guard let scheduler = s.scheduler, liveCheckAllowed(s) else { return }
        let text = s.list.text
        // An automatic review whose field now holds code: no re-check (the fixes already shown stay).
        if s.auto, CodeDetector.looksLikeCode(text) { return }
        if usingLocal {
            guard case .ready = server.state else {
                // Unloaded while idle: load it again; `serverReady` re-points the pipeline and asks again.
                server.reload(reason: "live check")
                return
            }
            server.noteUse()
        } else if !appleModel.isAvailable {
            // Apple's model went away during the review: the fixes shown stay, nothing more is checked.
            return
        }
        let el = s.snapshot.element
        let caret = AX.selection(el)?.location
        // A hotkey review covers the whole field; an automatic one, what's on screen around the caret.
        let scope: CheckPipeline.Scope = s.auto
            ? .init(cursor: caret, visible: AX.visibleCharacterRange(el))
            : .init(cursor: caret, maxLength: .max)
        let previous = liveChain
        liveChain = Task {
            await previous?.value
            await scheduler.textChanged(text, scope: scope)
        }
    }

    /// The gates of ⌃⌥G, checked again before every live re-check: the text goes to the model again.
    private func liveCheckAllowed(_ s: Session) -> Bool {
        guard !usingCloud, settings.effectiveUnderlineAsYouType, !AX.isSecureField(s.snapshot.element) else { return false }
        let bundle = NSRunningApplication(processIdentifier: s.snapshot.pid)?.bundleIdentifier
        if s.auto { return settings.autoCheckAllowed(bundle) }
        return settings.effectiveAppMode(bundle) != .off
    }

    /// A live re-check came back. Applied only when the field still holds the text it checked; the fixes
    /// inside the paragraphs it covered are replaced (`FixList.reconcile`), the others stay.
    private func liveResult(_ update: CheckScheduler.Update, checkID id: Int) {
        guard session?.live == true, session?.checkID == id else { return }
        if let error = update.error {
            Log.write("live check failed: \(error)")
            return
        }
        guard let result = update.result else { return }
        syncLive()  // typing the watcher hasn't reported yet
        guard var s = session, s.live, s.list.text == update.text else { return }
        let open = popup.isVisible ? s.list.currentFix?.edit : nil
        s.list.reconcile(edits: ignoredFixes.filter(result.edits, in: update.text), covered: result.covered)
        session = s
        if update.done {
            Log.write("live check: \(s.list.pendingCount) pending, \(result.requests) request(s)"
                + (result.foreignChunks > 0 ? ", \(result.foreignChunks) paragraph(s) not in English" : ""))
        }
        // The card stays on its fix while the check still has it.
        if let open, s.list.currentFix?.edit != open { closeCard() }
        refreshUnderlines()
        showLiveIsland()
    }

    /// Some apps move text without telling (Chromium reflow, a scroll without a scroll bar). Every tick, the
    /// last underlined fix is measured again; if it moved, the underlines are redrawn.
    private func checkLayoutDrift() {
        guard let s = session, s.mode == .underlines, relayout == nil else { return }
        let clip = AX.visibleFrame(s.snapshot.element).map(Self.onOneDisplay)
        var moved = clip != nil && overlay.isVisible && !overlay.marks.isEmpty
            && clip.map { !Self.near($0, overlay.clip) } == true
        if !moved, let probe = s.probe, let r = fieldRange(markOf: probe.fix, in: s) {
            moved = AX.bounds(s.snapshot.element, r, text: s.fieldText).map { !Self.near($0, probe.rect) } ?? true
        }
        if moved { refreshUnderlines() }
    }

    /// With "Displays have separate Spaces" (the macOS default) a window shows on one display only, so a field
    /// that spans two displays is underlined on the one that holds most of it; hit-testing then matches what
    /// is drawn. Without separate Spaces the overlay can span displays.
    private static func onOneDisplay(_ clip: CGRect) -> CGRect {
        guard NSScreen.screensHaveSeparateSpaces, NSScreen.screens.count > 1 else { return clip }
        func area(_ r: CGRect) -> CGFloat { r.isNull ? 0 : r.width * r.height }
        guard let best = NSScreen.screens.max(by: { area($0.frame.intersection(clip)) < area($1.frame.intersection(clip)) }),
              area(best.frame.intersection(clip)) > 0 else { return clip }
        return clip.intersection(best.frame)
    }

    private static func near(_ a: CGRect, _ b: CGRect) -> Bool {
        abs(a.minX - b.minX) < 0.5 && abs(a.minY - b.minY) < 0.5
            && abs(a.width - b.width) < 0.5 && abs(a.height - b.height) < 0.5
    }

    /// A click on an underline: make that fix current and open the popup (card or bubble) at the clicked word.
    private func openCard(on index: Int, word: CGRect) {
        guard var s = session, s.list.select(index) else { return }
        session = s
        showCard(word: word)
    }

    /// Shows the popup on the current fix, or finishes the session when no fix is pending. With underlines it
    /// sits under `word` (or the current fix's first underlined line); in the fallback, below the field.
    private func showCard(word: CGRect? = nil) {
        guard let s = session else { return }
        guard let i = s.list.current, let pos = s.list.currentPosition, let swap = s.list.swap(at: i) else {
            reviewDone()
            return
        }
        if s.island {
            showIsland()
            return
        }
        let fix = s.list.fixes[i]
        let dots: [ProgressDots.Dot] = s.list.fixes.indices.map { j in
            if j == i { return .current }
            switch s.list.fixes[j].status {
            case .pending: return .pending
            case .applied: return .applied
            case .skipped: return .skipped
            }
        }
        let place = s.cloudProvider?.name ?? "On this Mac"
        let footer = "\(place) · \(s.modelName) · " + String(format: "%.1f s", s.checkDuration)
        let state = CardState(category: fix.category, swap: swap, reason: fix.reason, dots: dots,
                              position: pos.n, pending: pos.total, footer: footer, cloud: s.cloudProvider != nil)
        var anchor: CGRect?
        if s.mode == .underlines {
            anchor = word ?? overlay.marks.first(where: { $0.fix == i })?.rects.first
            overlay.current = i
        }
        popup.show(state, field: s.snapshot.frame, word: anchor)
    }

    /// ⇧⏎ / Apply: write the current fix. With underlines the card closes, the word flashes and the other
    /// underlines stay; in the fallback the card moves on to the next fix.
    private func applyCurrent() {
        if syncLive() { return }
        guard var s = session, let i = s.list.current else { return }
        if s.mode == .underlines, !s.island {
            popup.hide()
            overlay.current = nil
        }
        // No underlines while the fix goes in: the text moves under them.
        if s.mode == .underlines { hideUnderlinesNow(suspend: true) }
        // A paste fallback hides the island; it takes the keys back when it had them.
        let islandHadKeys = s.island && island.isKey
        KeyGuard.shared.begin()
        let ok = write(i, in: &s)
        KeyGuard.shared.end()
        guard ok else { return }
        session = s
        guard s.mode == .underlines else {
            if s.island, !s.list.isDone { showIsland(makeKey: islandHadKeys) } else { showCard() }
            return
        }
        if s.list.isDone {
            reviewDone()
            return
        }
        // Apps that lay out late (Chromium) report the old positions for a moment: the underlines come back, and
        // the applied word flashes, once the field has settled.
        let applied = s.list.fixes[i].edit
        relayout?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.refreshUnderlines()
            guard let s = self.session, s.list.fixes.indices.contains(i), s.list.fixes[i].status == .applied,
                  s.list.fixes[i].edit == applied, let r = self.fieldRange(markOf: i, in: s),
                  let rects = AX.lineRects(s.snapshot.element, range: r, in: s.fieldText) else { return }
            self.overlay.flash(rects)
        }
        relayout = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3, execute: work)
        // The island moves on to the next fix (§5.6 ⇧⏎).
        if s.island { showIsland(makeKey: islandHadKeys) }
    }

    /// ⏎ / Apply all: write every pending fix from the last to the first, so earlier ranges stay valid.
    /// Neighbouring fixes in one paragraph and one run of formatting go in as one write (`applyAllGroups`,
    /// Optimization A): each write is verified like a single fix, and a long field needs far fewer select +
    /// paste rounds. The review keys are held while it runs (`KeyGuard`); Esc stops it after the current write.
    /// No live re-check until the last write.
    private func applyAll() {
        if syncLive() { return }
        guard var s = session else { return }
        // Before anything slow (grouping asks the app about formatting): a second ⏎ must not reach the app.
        KeyGuard.shared.begin()
        hideUnderlinesNow(suspend: false)
        let el = s.snapshot.element, offset = s.scopeLocation
        let now = AX.text(el) ?? s.fieldText
        let groups = s.list.applyAllGroups { span in
            AX.isOneTextRun(el, NSRange(location: offset + span.location, length: span.length), text: now)
        }
        let total = groups.reduce(0) { $0 + $1.indices.count }
        let started = Date()
        var written = 0, stopped = false
        func report(_ outcome: String) {
            let held = KeyGuard.shared.end(tail: true)
            Log.write("apply all: \(written) of \(groups.count) write(s) for \(total) fix(es), "
                + String(format: "%.1f s", Date().timeIntervalSince(started)) + ", \(outcome)"
                + (held > 0 ? ", \(held) key press(es) held" : ""))
        }
        for g in groups {
            if KeyGuard.shared.stopRequested { stopped = true; break }
            guard writeGroup(g, in: &s) else { report("stopped by a failed write"); return }
            written += 1
            session = s
        }
        report(stopped ? "stopped by Esc" : "done")
        if s.live { requestLiveCheck(s) }
        if stopped, !s.list.isDone {
            // The rest come back once the field has settled.
            if s.auto { scheduleRelayout(after: 0.3) } else { finish(placeCaret: false) }
            return
        }
        reviewDone()
    }

    /// Takes the underlines off the screen before a write blocks the main thread: `suspend` keeps them for the
    /// redraw after it (a single fix), otherwise they're dropped (Apply all). The flush puts the change on screen
    /// now; without it the window would only update after the write.
    private func hideUnderlinesNow(suspend: Bool) {
        relayout?.cancel()
        relayout = nil
        if suspend { overlay.suspend() } else { overlay.hide() }
        CATransaction.flush()
    }

    /// ⇥ / Ignore: keep the text as it is. With underlines the card closes and the fix's underline goes; in
    /// the fallback the card moves on to the next fix.
    private func ignoreCurrent() {
        if syncLive() { return }
        guard var s = session, let i = s.list.current else { return }
        ignoredFixes.add(s.list.fixes[i].edit, in: s.list.text)
        s.list.skip(at: i)
        session = s
        guard s.mode == .underlines else {
            showCard()
            return
        }
        if s.island {
            if s.list.isDone {
                reviewDone()
            } else {
                refreshUnderlines()
                showIsland()
            }
            return
        }
        popup.hide()
        overlay.current = nil
        if s.list.isDone { reviewDone() } else { refreshUnderlines() }
    }

    /// ← → ↑ ↓: previous or next pending fix (no wrap). The card slides to that word.
    private func moveCurrent(forward: Bool) {
        guard var s = session else { return }
        let moved = forward ? s.list.selectNext() : s.list.selectPrevious()
        guard moved else { return }
        session = s
        showCard()
    }

    /// Esc on the card, or a click outside it. With underlines, only the card closes. In the fallback there
    /// are no underlines to come back to, so this ends the review (with the done toast if fixes were applied).
    private func closeCard() {
        guard let s = session else { popup.hide(); return }
        if s.mode == .underlines {
            popup.hide()
            overlay.current = nil
            return
        }
        if s.list.appliedCount > 0 { finish() } else { cancel() }
    }

    /// Esc on the island: end the session and clear the underlines (§5.6). After some fixes were applied, the
    /// island shows the done line first.
    private func endReview() {
        guard session != nil else { island.hide(); return }
        dismissReview()
    }

    /// The user dismissed the underlines (Esc). The automatic check stays off in this field until focus moves,
    /// or the same underlines would come back at the next pause. A hotkey review that applied fixes ends with
    /// the done line; an automatic one ends quietly.
    private func dismissReview() {
        guard let s = session else { return }
        autoMuted = s.snapshot.element
        Log.write("review: dismissed; no automatic check in this field until focus moves")
        if s.list.appliedCount > 0, !s.auto { finish(placeCaret: false) } else { cancel() }
    }

    /// No fix is pending. A hotkey review ends with the done line; an automatic one stays up quietly (no
    /// underlines, no popup) and waits for the next check, until focus leaves the field.
    private func reviewDone() {
        guard let s = session else { return }
        guard s.auto else {
            finish()
            return
        }
        popup.hide()
        overlay.current = nil
        if s.island { island.hide() }
        refreshUnderlines()
    }

    /// Shows the island on the current fix (§5.6) and marks that fix in the underlines. `makeKey` gives it the
    /// review keys (at the start of a review, and after a click on an underline).
    private func showIsland(makeKey: Bool = false) {
        guard let s = session else { return }
        guard let i = s.list.current, let pos = s.list.currentPosition, let swap = s.list.swap(at: i) else {
            reviewDone()
            return
        }
        let fix = s.list.fixes[i]
        let upcoming: [IslandFix] = s.list.pendingIndices.filter { $0 != i }.prefix(3).compactMap { j in
            s.list.swap(at: j).map { IslandFix(category: s.list.fixes[j].category, swap: $0) }
        }
        let reason = settings.explainFixes ? "\(fix.category.title) · \(fix.reason)" : fix.category.title
        if s.mode == .underlines { overlay.current = i }
        island.showReview(IslandReview(fix: IslandFix(category: fix.category, swap: swap), reason: reason,
                                       upcoming: upcoming, position: pos.n, pending: pos.total),
                          field: s.snapshot.frame, makeKey: makeKey)
    }

    /// No pending fix left, or the user ended the review after applying some: done toast, end the session.
    /// `placeCaret` puts the caret after the checked text (§5.7); not when the user is already typing or
    /// dismissed the underlines with Esc.
    private func finish(placeCaret: Bool = true) {
        guard let s = session else { return }
        popup.hide()
        let a = s.list.appliedCount, k = s.list.skippedCount
        var title = a == 1 ? "1 fix applied" : "\(a) fixes applied"
        if k > 0 { title += " · \(k) kept" }
        let frame = s.snapshot.frame
        endSession(placeCaret: placeCaret)
        if s.island {
            island.showDone(title: title, detail: a > 0 ? "⌘Z undoes" : nil, field: frame)
        } else {
            toast(a > 0 ? .success : .info, title, detail: a > 0 ? "⌘Z undoes in the app" : nil, near: frame, duration: 2.8)
        }
    }

    /// Writes fix `index` into the field and marks it applied. On failure ends the session with a message.
    private func write(_ index: Int, in s: inout Session) -> Bool {
        let e = s.list.fixes[index].edit
        guard writeEdit(e, in: &s) else { return false }
        s.list.applyOne(at: index)
        afterWrite(e, in: &s, recheck: true)
        return true
    }

    /// Writes one Apply all group (one fix, or several in one paragraph) and marks its fixes applied. The live
    /// re-check waits for the end of the apply.
    private func writeGroup(_ g: FixList.ApplyGroup, in s: inout Session) -> Bool {
        let e = Edit(range: g.range, original: g.original, replacement: g.replacement)
        guard writeEdit(e, in: &s) else { return false }
        s.list.applyGroup(g)
        afterWrite(e, in: &s, recheck: false)
        return true
    }

    /// After a write: the field value Meboki now expects.
    private func afterWrite(_ e: Edit, in s: inout Session, recheck: Bool) {
        s.lastWrite = Date()
        if s.live {
            // The list is the truth; anything else in the field is diffed against it once the write settled.
            s.fieldText = s.list.text
            if recheck { requestLiveCheck(s) }
            return
        }
        // What the app now reports, so later edit checks compare against the real value.
        let range = NSRange(location: s.scopeLocation + e.range.location, length: e.range.length)
        s.fieldText = AX.text(s.snapshot.element)
            ?? (s.fieldText as NSString).replacingCharacters(in: range, with: e.replacement)
    }

    /// Writes `e` (range relative to `s.list.text`) into the field. On failure ends the session with a message,
    /// or in a live review follows the field (the user typed meanwhile).
    private func writeEdit(_ e: Edit, in s: inout Session) -> Bool {
        if !s.logged {
            let app = NSRunningApplication(processIdentifier: s.snapshot.pid)?.bundleIdentifier ?? "pid \(s.snapshot.pid)"
            Log.write("session: \(s.list.fixes.count) fix(es) in \(app)")
            s.logged = true
        }
        let range = NSRange(location: s.scopeLocation + e.range.location, length: e.range.length)
        var usedPaste = false
        let ok = AX.replace(in: s.snapshot.element, pid: s.snapshot.pid, range: range,
                            original: e.original, replacement: e.replacement, pasteOnly: s.usedPaste) {
            // The keystroke fallback must reach the field, not a Meboki panel. A panel that was up gets a
            // moment to go; later writes of an apply find nothing up and don't wait.
            usedPaste = true
            let shown = popup.isVisible || island.isVisible || overlay.isVisible || toasts.isVisible
            popup.hide()
            island.hide(animated: false)
            overlay.hide()
            toasts.hide(animated: false)
            if shown { Thread.sleep(forTimeInterval: 0.15) }
        }
        s.usedPaste = s.usedPaste || usedPaste
        guard ok else {
            // Live review: the user typed meanwhile, so the original wasn't there. Follow the field instead.
            if s.live {
                session = s
                if syncLive() {
                    Log.write("review: the field changed under the fix; fixes carried over")
                    return false
                }
            }
            let a = s.list.appliedCount
            let title = a == 0
                ? "This app didn't accept the change, so nothing was replaced."
                : "Applied \(a) of \(a + s.list.pendingCount) fixes, then this app didn't accept the next one."
            let frame = s.snapshot.frame
            session = s
            popup.hide()
            endSession(placeCaret: false)
            toast(.error, title, detail: "Details: menu › Show Meboki Log", near: frame)
            return false
        }
        return true
    }

    /// Restores the clipboard if a paste was used, and optionally puts the caret after the checked text.
    private func endSession(placeCaret: Bool) {
        watcher?.stop()
        watcher = nil
        relayout?.cancel()
        relayout = nil
        valueCheck?.cancel()
        valueCheck = nil
        scrollCheck?.cancel()
        scrollCheck = nil
        overlay.hide()
        guard let s = session else { return }
        session = nil
        checkID += 1  // late live results of this session drop themselves
        if let scheduler = s.scheduler { Task { await scheduler.cancel() } }
        if s.usedPaste { s.clipboard.restore() }
        if placeCaret, s.list.appliedCount > 0, let now = AX.text(s.snapshot.element) {
            let end = s.scopeLocation + (s.list.text as NSString).length
            if end <= (now as NSString).length {
                _ = AX.select(s.snapshot.element, NSRange(location: end, length: 0), in: now)
            }
        }
        // An automatic review that ended while its field still has focus (a failed write, secure input): the
        // automatic check takes over again. Asynchronous, so a hotkey check that ended it has started first. A
        // finished hotkey review doesn't start a pass by itself; the next edit does.
        if s.auto { DispatchQueue.main.async { [weak self] in self?.resumeAutoCheck() } }
    }

    // MARK: Automatic check (Milestone B step 3: FocusTracker)

    /// The tracker runs while "Underline mistakes as I type" is on and checks use the local model. Cloud
    /// models stay hotkey-only: Use consented to sends on ⌃⌥G, not one per typing pause.
    private func updateAutoCheck() {
        if settings.effectiveUnderlineAsYouType, !usingCloud {
            focusTracker.start()
        } else {
            focusTracker.stop()
            autoTarget = nil
            stopAutoCheck()
            if session?.auto == true { cancel() }
        }
    }

    /// Focus moved. A multi-line text area the user can type in becomes the target, and its text is checked
    /// after a pause (a field that already holds text gets underlined without typing).
    private func autoFocusChanged(_ el: AXUIElement?, pid: pid_t) {
        stopAutoCheck()
        autoTarget = nil
        // Focus moved to another element: the mute ends. Nil focus (an Electron window while our panel is key, a
        // re-attach) keeps it, since focus usually comes back to the same field.
        if let muted = autoMuted, let el, !CFEqual(el, muted) { autoMuted = nil }
        // Secure fields are never read; only editable text areas qualify (not URL bars, search boxes or
        // terminal output). The gates that can change while the field has focus are checked per request.
        guard let el, !AX.isSecureField(el), AX.isEditableTextArea(el) else { return }
        autoTarget = AutoTarget(element: el, pid: pid)
        let app = NSRunningApplication(processIdentifier: pid)?.bundleIdentifier ?? "pid \(pid)"
        Log.write("auto: focus on a text area in \(app)" + (autoMuted != nil ? " (dismissed here)" : ""))
        requestAutoCheck()
    }

    /// The gates of ⌃⌥G, checked before every automatic check, plus the automatic check's own: the field's app
    /// is in front, the app isn't a terminal or code editor, the user didn't dismiss the underlines here.
    private func autoCheckAllowed(_ t: AutoTarget) -> Bool {
        guard settings.effectiveUnderlineAsYouType, !usingCloud, AX.isTrusted(prompt: false),
              session == nil, checkTask == nil,
              NSWorkspace.shared.frontmostApplication?.processIdentifier == t.pid,
              settings.autoCheckAllowed(NSRunningApplication(processIdentifier: t.pid)?.bundleIdentifier),
              autoMuted.map({ !CFEqual($0, t.element) }) ?? true,
              !IsSecureEventInputEnabled() else { return false }
        return true
    }

    /// The target's text changed (or it just got focus): hand it to the scheduler, which checks it after a
    /// typing pause. A review in progress handles its own edits (`syncLive`). `caretOnly`: only the caret moved
    /// (an editable web area), so nothing happens unless the text changed too.
    private func requestAutoCheck(caretOnly: Bool = false) {
        guard var t = autoTarget, t.bounds != false, autoCheckAllowed(t) else { return }
        guard let text = AX.text(t.element), text.rangeOfCharacter(from: .letters) != nil else {
            stopAutoCheck()
            return
        }
        if caretOnly, text == t.requested { return }
        let verdict = CodeDetector.verdict(text)
        if !t.judged, CodeAppLearner.isEvidence(verdict) {
            t.judged = true
            autoTarget = t
            if learnFromField(t, verdict: verdict) { return }
        }
        // A field that holds code (a script, JSON, a terminal session) in an app that isn't on the skip list:
        // no automatic check while it looks like code. ⌃⌥G still checks it.
        if verdict.isCode {
            if !t.code {
                let app = NSRunningApplication(processIdentifier: t.pid)?.bundleIdentifier ?? "pid \(t.pid)"
                Log.write("auto: the field in \(app) looks like code; no automatic check (⌃⌥G still works)")
                autoTarget?.code = true
            }
            stopAutoCheck()
            return
        }
        if t.code {
            t.code = false
            autoTarget = t
        }
        if t.bounds == nil {
            let bounds = AX.hasTextBounds(t.element, text: text, visible: AX.visibleCharacterRange(t.element))
            t.bounds = bounds
            autoTarget = t
            let app = NSRunningApplication(processIdentifier: t.pid)?.bundleIdentifier ?? "pid \(t.pid)"
            if !bounds { Log.write("auto: no text bounds in \(app); automatic check off in this field (⌃⌥G still works)") }
        }
        guard t.bounds == true else { return }
        guard let backend = checkBackend() else {
            // Unloaded while idle: load it again; `serverReady` asks for this check once it's up. Apple's model
            // unavailable: nothing to do until it comes back (`refreshAppleModel`).
            if usingLocal { server.reload(reason: "automatic check") }
            return
        }
        if usingLocal { server.noteUse() }
        let bundle = NSRunningApplication(processIdentifier: t.pid)?.bundleIdentifier
        let client = backend.corrector
        let pipe = checkPipeline(for: backend)
        let scheduler = autoScheduler(for: pipe)
        let options = settings.checkOptions(for: bundle)
        // What's on screen around the caret; a scroll or the next edit brings the rest.
        let scope = CheckPipeline.Scope(cursor: AX.selection(t.element)?.location,
                                        visible: AX.visibleCharacterRange(t.element))
        autoTarget?.requested = text
        autoRequested = Date()
        let previous = autoChain
        autoChain = Task {
            await previous?.value
            await pipe.setClient(client, sameModel: true)
            await pipe.setOptions(options)
            await scheduler.textChanged(text, scope: scope)
        }
    }

    /// Learned Manual: counts this field's verdict for its app (once per field). When the app has just been
    /// learned as a code editor, it goes Manual: the automatic check stops following it, and a message says so
    /// once, with a way to change it. Returns true then.
    private func learnFromField(_ t: AutoTarget, verdict: CodeDetector.Verdict) -> Bool {
        guard let app = NSRunningApplication(processIdentifier: t.pid), let id = app.bundleIdentifier else { return false }
        var seen = learnSeen[id, default: []]
        guard !seen.contains(where: { CFEqual($0, t.element) }) else { return false }
        seen.append(t.element)
        learnSeen[id] = Array(seen.suffix(50))
        guard settings.noteField(bundleID: id, verdict: verdict) else { return false }
        let name = app.localizedName ?? id
        Log.write("auto: \(id) looks like a code editor (\(CodeAppLearner.threshold) code fields, no prose); "
            + "Manual by default now")
        settings.noteChecked(bundleID: id, name: name)
        // Not inline: this runs inside the focus tracker's AXObserver callback, and retargeting tears that
        // observer down.
        stopAutoCheck()
        DispatchQueue.main.async { [weak self] in self?.appModesChanged() }
        toast(.info, "\(name) looks like a code editor.",
              detail: "Meboki won't check as you type there; \(settings.hotkey.display) still works",
              actionTitle: "Change", action: { [weak self] in self?.showSettings(pane: .apps) },
              near: nil, duration: 8)
        return true
    }

    /// The scheduler for the current pipeline (one per model, like the pipeline).
    private func autoScheduler(for pipe: CheckPipeline) -> CheckScheduler {
        if let s = autoScheduler, autoPipeline === pipe { return s }
        stopAutoCheck()
        autoPipeline = pipe
        let s = CheckScheduler(pipeline: pipe) { [weak self] update in
            Task { @MainActor in self?.autoResult(update) }
        }
        autoScheduler = s
        return s
    }

    /// Drops the pending automatic check (focus moved, the hotkey, the setting went off).
    private func stopAutoCheck() {
        guard let scheduler = autoScheduler else { return }
        let previous = autoChain
        autoChain = Task {
            await previous?.value
            await scheduler.cancel()
        }
    }

    /// The model is up (at launch, after a switch, or loaded again after an idle unload). The pipeline's client
    /// points at the new port; a ⌃⌥G that waited for it runs; the focused field gets its automatic check, and a
    /// live review re-checks what was typed while the model was loading.
    private func serverReady(_ base: URL) {
        guard usingLocal else { return }
        if let p = pipeline, let b = checkBackend(), pipelineKey == b.key {
            let client = b.corrector
            Task { await p.setClient(client, sameModel: true) }
        }
        if let pending = pendingCheck {
            pendingCheck = nil
            if Date().timeIntervalSince(pending.at) < Self.pendingCheckLimit,
               NSWorkspace.shared.frontmostApplication?.processIdentifier == pending.pid {
                proofread()
                return
            }
            toasts.hide()
            if settings.effectivePopupStyle == .island { island.hide() }
        }
        if let s = session, s.live { requestLiveCheck(s) }
        resumeAutoCheck()
    }

    /// A review ended: if its field still has focus, the automatic check watches it again.
    private func resumeAutoCheck() {
        guard let t = autoTarget, session == nil, checkTask == nil, focusTracker.isFocused(t.element) else { return }
        requestAutoCheck()
    }

    /// An automatic check finished. With fixes (minus ignored ones), and the field still focused and holding the
    /// checked text, it becomes a live review with underlines.
    private func autoResult(_ update: CheckScheduler.Update) {
        guard update.done else { return }
        if let error = update.error {
            Log.write("auto check failed: \(error)")
            return
        }
        // Counts a trial day only when the pass really asked the model (not a focus, nor a cache hit).
        if let r = update.result, r.requests > 0 { licence.recordCheck() }
        // The model changed since this check started: drop it. The text check below drops one for text that's gone.
        guard let result = update.result, let t = autoTarget, autoCheckAllowed(t), let pipe = autoPipeline,
              pipe === pipeline else { return }
        let edits = ignoredFixes.filter(result.edits, in: update.text)
        if result.requests > 0 || !edits.isEmpty {
            Log.write("auto check: \(edits.count) fix(es), \(result.requests) request(s)"
                + (result.foreignChunks > 0 ? ", \(result.foreignChunks) paragraph(s) not in English" : ""))
        }
        guard !edits.isEmpty else { return }
        // Read the field again with the hotkey's checks (secure input, secure field, focus): it must still be
        // this field, holding exactly the checked text.
        guard let snap = try? AX.snapshot(pid: t.pid), CFEqual(snap.element, t.element), snap.text == update.text else {
            return
        }
        if let app = NSRunningApplication(processIdentifier: t.pid), let id = app.bundleIdentifier {
            settings.noteChecked(bundleID: id, name: app.localizedName ?? id)
        }
        session = Session(snapshot: snap, scopeLocation: 0, island: settings.effectivePopupStyle == .island,
                          fieldText: snap.text, list: FixList(text: snap.text, edits: edits),
                          modelName: activeModelName, cloudProvider: nil,
                          checkDuration: max(0, Date().timeIntervalSince(autoRequested) - 0.6),
                          checkID: checkID, liveEligible: true, pipeline: pipe, auto: true)
        startReview()
    }

    // MARK: Toasts (§5.7, §5.8)

    private func toast(_ kind: MessageKind, _ title: String, detail: String? = nil, symbol: String? = nil,
                       actionTitle: String? = nil, action: (() -> Void)? = nil,
                       near frame: CGRect?, duration: TimeInterval = 4) {
        // Island style shows messages in the island (§5.8).
        if settings.effectivePopupStyle == .island {
            toasts.hide(animated: false)
            island.showMessage(kind: kind, title: title, detail: detail, symbol: symbol, actionTitle: actionTitle,
                               action: action, field: frame, duration: duration)
            return
        }
        toasts.show(ToastContent(kind: kind, title: title, detail: detail, symbol: symbol,
                                 actionTitle: actionTitle, action: action, duration: duration),
                    field: frame)
    }

    private func showAccessibilityToast(near frame: CGRect?) {
        watchTrust()
        // Longer than 4 s: the user needs time to reach the button.
        toast(.warning, "Meboki needs Accessibility access to read this field.",
              actionTitle: "Open System Settings", action: { [weak self] in self?.grantPermission() },
              near: frame, duration: 8)
    }

    private func showModelNotReady() {
        if usingCloud {
            let m = settings.cloudModel
            toast(.info, "Add your \(m.provider.name) API key first.", detail: "Settings › Models › Cloud",
                  actionTitle: "Open Models", action: { [weak self] in self?.showSettings(pane: .models) },
                  near: nil, duration: 6)
            return
        }
        if usingApple {
            // Selected but gone (Apple Intelligence off, or a forced state on an older macOS): no silent switch.
            let a = appleModel
            let detail: String
            switch a {
            case .notEnabled: detail = "Turn it on in System Settings, or choose another model in Settings › Models"
            case .modelNotReady: detail = "macOS is preparing the model. Try again later, or choose another model"
            default: detail = "Choose another model in Settings › Models"
            }
            toast(.info, AppleIntelligence.notReadyTitle(a), detail: detail,
                  actionTitle: a == .notEnabled ? "Open System Settings" : "Open Models",
                  action: { [weak self] in
                      if a == .notEnabled { AppleIntelligence.openSettings() } else { self?.showSettings(pane: .models) }
                  },
                  near: nil, duration: 8)
            return
        }
        let name = selectedModel.name
        switch server.state {
        case .ready:
            return
        case .starting, .unloaded:
            toast(.info, "The model is still loading. Try again in a moment.", detail: "Loading \(name)…", near: nil)
        case .failed(let msg):
            toast(.error, "The model didn't start: \(msg)", detail: "Details: menu › Show Server Log", near: nil)
        case .stopped:
            if let d = downloadStatus {
                toast(.info, "The model isn't ready yet. Try again when it's done.", detail: d, near: nil)
            } else {
                let installed = store.isInstalled(selectedModel)
                toast(.info, installed ? "The model isn't running." : "No model downloaded yet.",
                      detail: installed ? "Choose a model in Settings › Models" : "Download one in Settings › Models",
                      actionTitle: "Open Models", action: { [weak self] in self?.showSettings(pane: .models) },
                      near: nil, duration: 8)
            }
        }
    }

    private func showSnapshotError(_ error: Error, appName: String?) {
        switch error as? AXError2 {
        case .notTrusted:
            showAccessibilityToast(near: nil)
        case .secureField:
            toast(.warning, "Meboki doesn't read password fields.", near: nil)
        case .secureInput:
            toast(.warning, "Meboki doesn't read password fields.", detail: "Secure input is on", near: nil)
        case .noFocusedField:
            toast(.info, "No text field is focused.", detail: "Click into a text field and try again", near: nil)
        case .noText:
            toast(.info, "This field doesn't share its text with macOS.", detail: "Meboki can't check it here",
                  near: nil)
        case .appHidesText:
            // Sublime Text, Zed, canvas apps: they draw their own text, so there's nothing to read.
            toast(.info, "\(appName ?? "This app") doesn't share its text with macOS.",
                  detail: "Meboki can't check it here", near: nil, duration: 6)
        default:
            toast(.error, error.localizedDescription, near: nil)
        }
    }

    // MARK: Status item while checking (§6)

    /// Pulses the status icon (`menuPulse`, with the brand dot) while a check runs.
    private func setChecking(_ on: Bool, status: String? = nil) {
        statusItem.setToolTip(on ? status : nil)
        statusItem.isChecking = on
        if isChecking != on {
            isChecking = on
            refreshPopover()
        }
    }
}
