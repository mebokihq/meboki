import AppKit
import Combine
import MebokiCore
import Sparkle

/// Updates of an official build, through Sparkle (PLAN.md §6 "Updates").
///
/// - **Only official builds update.** The feed address and the public key come from Info.plist (`SUFeedURL`,
///   `SUPublicEDKey`), which the release build adds. A build from source has neither: `isEnabled` is false,
///   Sparkle is never started and the update rows stay hidden.
/// - **One request a day**, a plain GET of the public version list. No system profile is sent.
/// - **Never in the way.** Meboki has no Dock icon and the keyboard is usually in another app, so a version
///   found by the daily check doesn't open a window: `available` turns on a dot on the menu-bar icon and a row
///   in the popover, and Sparkle's window opens when the user asks (`showUpdate`).
/// - **Automatic install** (off by default) installs and reopens the app only at a quiet moment
///   (`UpdateTiming`): nothing of Meboki's in use and no key or mouse input for two minutes.
@MainActor
final class UpdateController: NSObject, ObservableObject {
    static let shared = UpdateController()

    /// False in builds without a feed (from source): there is nothing to show or check.
    let isEnabled: Bool
    /// The version a scheduled check found and the user hasn't acted on yet ("0.2.0").
    @Published private(set) var available: String?
    /// The found version hasn't been looked at yet: the menu-bar icon carries a dot.
    @Published private(set) var needsAttention = false
    @Published private(set) var canCheck = false
    @Published private(set) var lastCheck: Date?
    /// Settings › General. Sparkle keeps both in the app's defaults.
    @Published var automaticChecks = true {
        didSet { if automaticChecks != oldValue, updater?.automaticallyChecksForUpdates != automaticChecks { updater?.automaticallyChecksForUpdates = automaticChecks } }
    }
    @Published var automaticInstall = false {
        didSet { if automaticInstall != oldValue, updater?.automaticallyDownloadsUpdates != automaticInstall { updater?.automaticallyDownloadsUpdates = automaticInstall } }
    }

    /// True while the app is in use (a check, a review, a popup, one of its windows, a download): no automatic
    /// install then. Set by the app delegate.
    var isBusy: () -> Bool = { false }

    private var controller: SPUStandardUpdaterController?
    private var updater: SPUUpdater? { controller?.updater }
    private var observations: [NSKeyValueObservation] = []
    /// Installs the downloaded update and reopens the app (from Sparkle, with automatic install on).
    private var installNow: (() -> Void)?
    private var installTimer: Timer?

    private static let relaunchedKey = "relaunchedByUpdate"
    private static let foundVersionKey = "updateFoundVersion"
    private static let foundDateKey = "updateFoundDate"

    /// The newest version found and when it was first found (kept in defaults, so the popup badge counts days
    /// across launches and stays after "Later" until that version is installed).
    private var foundVersion: String?
    private var foundDate: Date?
    /// The running version the badge compares with (a demo run outside a bundle pretends one).
    private var runningVersion = UpdateController.currentVersion

    private override init() {
        #if DEBUG
        // Screenshots: `MEBOKI_DEMO_UPDATE=0.2.0` shows the update rows with that version found; nothing is started.
        if let demo = ProcessInfo.processInfo.environment["MEBOKI_DEMO_UPDATE"], !demo.isEmpty {
            isEnabled = true
            super.init()
            available = demo
            // `MEBOKI_DEMO_UPDATE_DAYS=9` pretends the version was found that many days ago (the popup banner).
            let days = Int(ProcessInfo.processInfo.environment["MEBOKI_DEMO_UPDATE_DAYS"] ?? "") ?? 0
            foundVersion = demo
            foundDate = Calendar.current.date(byAdding: .day, value: -days, to: Date())
            if !UpdateNudge.isNewer(demo, than: runningVersion) { runningVersion = "1.0.0" }
            needsAttention = true
            canCheck = true
            lastCheck = Date()
            return
        }
        #endif
        let info = Bundle.main.infoDictionary
        isEnabled = UpdateFeed(feed: info?["SUFeedURL"] as? String, publicKey: info?["SUPublicEDKey"] as? String) != nil
        let d = UserDefaults.standard
        foundVersion = d.string(forKey: Self.foundVersionKey)
        foundDate = d.object(forKey: Self.foundDateKey) as? Date
        super.init()
    }

    /// Starts the updater (official builds only). Call once, when the app has launched.
    func start() {
        guard isEnabled, controller == nil, Bundle.main.infoDictionary?["SUFeedURL"] != nil else { return }  // not in the demo
        let c = SPUStandardUpdaterController(startingUpdater: false, updaterDelegate: self, userDriverDelegate: self)
        controller = c
        let u = c.updater
        do {
            try u.start()
        } catch {
            Log.write("updates: not started (\(error.localizedDescription))")
            return
        }
        automaticChecks = u.automaticallyChecksForUpdates
        automaticInstall = u.automaticallyDownloadsUpdates
        canCheck = u.canCheckForUpdates
        lastCheck = u.lastUpdateCheckDate
        observations = [
            u.observe(\.canCheckForUpdates) { [weak self] u, _ in
                let v = u.canCheckForUpdates
                DispatchQueue.main.async {
                    self?.canCheck = v
                    if v, self?.showWhenReady == true { self?.showUpdate() }
                }
            },
            u.observe(\.lastUpdateCheckDate) { [weak self] u, _ in
                let v = u.lastUpdateCheckDate
                DispatchQueue.main.async { self?.lastCheck = v }
            },
            u.observe(\.automaticallyChecksForUpdates) { [weak self] u, _ in
                let v = u.automaticallyChecksForUpdates
                DispatchQueue.main.async { if self?.automaticChecks != v { self?.automaticChecks = v } }
            },
            u.observe(\.automaticallyDownloadsUpdates) { [weak self] u, _ in
                let v = u.automaticallyDownloadsUpdates
                DispatchQueue.main.async { if self?.automaticInstall != v { self?.automaticInstall = v } }
            },
        ]
        Log.write("updates: on, automatic checks \(automaticChecks ? "on" : "off"), automatic install \(automaticInstall ? "on" : "off")")
    }

    /// "Check for Updates…" and the popover's "Update available" row: Sparkle's window, in front. With a
    /// version already found it opens on that version.
    func showUpdate() {
        guard let updater else { return }
        guard updater.canCheckForUpdates else {
            // Sparkle is fetching the feed or downloading in the background: open the window as soon as it
            // can, instead of dropping the click (the popup that was clicked has already closed).
            showWhenReady = true
            Log.write("updates: window waits for the background check to finish")
            return
        }
        showWhenReady = false
        updater.checkForUpdates()
    }

    /// A request to show the update window came while Sparkle couldn't take it (`canCheckForUpdates` false).
    private var showWhenReady = false

    /// The green badge on the correction popups (design_code.md §8.10 "Popup badge"): a pill, then a banner
    /// from day 7. Nil without an updater or without a version newer than this one.
    func popupBadge(now: Date = Date()) -> UpdateNudge.Badge? {
        guard isEnabled, let version = available ?? foundVersion, let found = foundDate else { return nil }
        return UpdateNudge.badge(version: version, current: runningVersion, found: found, now: now)
    }

    private func clearFound() {
        guard foundVersion != nil else { return }
        Log.write("updates: \(foundVersion ?? "") no longer offered; popup badge off")
        foundVersion = nil
        foundDate = nil
        let d = UserDefaults.standard
        d.removeObject(forKey: Self.foundVersionKey)
        d.removeObject(forKey: Self.foundDateKey)
    }

    /// Remembers the day `version` was first found; a different version starts the count again.
    private func noteFound(_ version: String) {
        guard foundVersion != version else { return }
        foundVersion = version
        foundDate = Date()
        let d = UserDefaults.standard
        d.set(version, forKey: Self.foundVersionKey)
        d.set(foundDate, forKey: Self.foundDateKey)
    }

    /// "0.1.0", as in Info.plist ("dev" when run outside a bundle).
    static var currentVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "dev"
    }

    /// True once after the updater reopened the app: that launch shouldn't open any window by itself.
    static func consumeRelaunch() -> Bool {
        let d = UserDefaults.standard
        guard d.bool(forKey: relaunchedKey) else { return false }
        d.removeObject(forKey: relaunchedKey)
        return true
    }

    // MARK: Automatic install

    /// Tries now, then every 30 s, until the app is idle and the user is away.
    private func installWhenQuiet() {
        installTimer?.invalidate()
        guard installNow != nil else { return }
        if tryInstall() { return }
        installTimer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { _ = self?.tryInstall() }
        }
    }

    private func tryInstall() -> Bool {
        guard let install = installNow else { return true }
        // Any key, mouse or scroll event, from any source.
        let anyInput = CGEventType(rawValue: ~0)!
        let quiet = CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: anyInput)
        guard UpdateTiming.canInstallNow(busy: isBusy(), secondsSinceInput: quiet) else { return false }
        installTimer?.invalidate()
        installTimer = nil
        installNow = nil
        Log.write("updates: installing now (idle)")
        install()
        return true
    }
}

extension UpdateController: SPUUpdaterDelegate {
    nonisolated func updater(_ updater: SPUUpdater, willInstallUpdateOnQuit item: SUAppcastItem,
                             immediateInstallationBlock immediateInstallHandler: @escaping () -> Void) -> Bool {
        let version = item.displayVersionString
        DispatchQueue.main.async {
            Log.write("updates: \(version) downloaded; installs when the app is idle or quits")
            self.installNow = immediateInstallHandler
            self.installWhenQuiet()
        }
        return true
    }

    nonisolated func updaterWillRelaunchApplication(_ updater: SPUUpdater) {
        UserDefaults.standard.set(true, forKey: "relaunchedByUpdate")
    }

    nonisolated func updater(_ updater: SPUUpdater, didFindValidUpdate item: SUAppcastItem) {
        let version = item.displayVersionString
        DispatchQueue.main.async {
            Log.write("updates: found \(version)")
            self.noteFound(version)
        }
    }

    /// The feed no longer offers a newer version (it was pulled, or it's installed): the popup badge goes.
    /// Only when the feed's newest item is not newer than this build; a scheduled check that hides a version
    /// the user skipped says the same thing, so then the badge stays (it shows until the version is installed).
    nonisolated func updaterDidNotFindUpdate(_ updater: SPUUpdater, error: Error) {
        let info = (error as NSError).userInfo
        let reason = (info[SPUNoUpdateFoundReasonKey] as? NSNumber).flatMap { SPUNoUpdateFoundReason(rawValue: $0.int32Value) }
        let userInitiated = (info[SPUNoUpdateFoundUserInitiatedKey] as? NSNumber)?.boolValue ?? false
        guard reason == .onLatestVersion || reason == .onNewerThanLatestVersion else { return }
        DispatchQueue.main.async {
            let d = UserDefaults.standard
            let skipped = d.string(forKey: "SUSkippedVersion") != nil || d.string(forKey: "SUSkippedMajorVersion") != nil
            guard userInitiated || !skipped else { return }
            self.clearFound()
        }
    }

    nonisolated func updater(_ updater: SPUUpdater, didFinishUpdateCycleFor updateCheck: SPUUpdateCheck, error: Error?) {
        let message = error.map { ($0 as NSError).code == 1001 ? "up to date" : $0.localizedDescription } ?? "done"
        DispatchQueue.main.async { Log.write("updates: check finished (\(message))") }
    }
}

extension UpdateController: SPUStandardUserDriverDelegate {
    nonisolated var supportsGentleScheduledUpdateReminders: Bool { true }

    /// A version found by the daily check opens Sparkle's window only when Meboki is the app in use (its
    /// Settings window is in front). Otherwise the keyboard belongs to another app: the dot and the popover
    /// row say it instead.
    nonisolated func standardUserDriverShouldHandleShowingScheduledUpdate(_ update: SUAppcastItem,
                                                                          andInImmediateFocus immediateFocus: Bool) -> Bool {
        immediateFocus && MainActor.assumeIsolated { NSApp.isActive }
    }

    nonisolated func standardUserDriverWillHandleShowingUpdate(_ handleShowingUpdate: Bool, forUpdate update: SUAppcastItem,
                                                               state: SPUUserUpdateState) {
        let version = update.displayVersionString
        DispatchQueue.main.async {
            if self.available != version || self.needsAttention == handleShowingUpdate {
                Log.write("updates: \(version) \(handleShowingUpdate ? "shown in the update window" : "waits behind the menu-bar icon")")
            }
            self.available = version
            self.noteFound(version)
            self.needsAttention = !handleShowingUpdate
        }
    }

    nonisolated func standardUserDriverDidReceiveUserAttention(forUpdate update: SUAppcastItem) {
        DispatchQueue.main.async { self.needsAttention = false }
    }

    nonisolated func standardUserDriverWillFinishUpdateSession() {
        DispatchQueue.main.async {
            self.available = nil
            self.needsAttention = false
        }
    }
}
