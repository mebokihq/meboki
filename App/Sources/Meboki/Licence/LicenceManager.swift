import AppKit
import Combine
import MebokiCore

/// Why a key was not activated. `message` is the line the UI shows.
enum ActivationError: Error, Equatable {
    case invalid(LicenceError)
    case revoked
    case expired
    case saveFailed(String)

    var message: String {
        switch self {
        case .invalid(let e): e.message
        case .revoked: LicenceText.revoked
        case .expired: LicenceText.expired
        case .saveFailed(let why): "Couldn't save the key: \(why)"
        }
    }
}

/// The app's licence state (PLAN.md §6 "App-side licensing"): the stored key, the revoked list and the trial
/// clock, joined into one `Entitlement` that the check flow reads (through `AppSettings`' effective values).
/// Everything is checked on this Mac; the only network call is the daily revoked-list download.
@MainActor
final class LicenceManager: ObservableObject {
    static let shared = LicenceManager()

    struct Transition {
        let from: Entitlement
        let to: Entitlement
    }

    @Published private(set) var entitlement: Entitlement
    /// The trial clock (it changes when a check counts a day, which `entitlement` alone doesn't show).
    @Published private(set) var trial: TrialClock
    /// Fires after `entitlement` changed (activation, removal, trial end, day change, revoked list), old and new.
    let transitions = PassthroughSubject<Transition, Never>()

    private let licenceStore: LicenceStore
    private let trialStore: TrialStore
    private let defaults: UserDefaults
    private let calendar: Calendar
    private let now: () -> Date
    private let fetchEnabled: Bool
    private var key: Result<LicenceInfo, LicenceError>?
    private var revoked: RevokedList?
    private var observers: [NSObjectProtocol] = []
    private var fetching = false

    private static let lastFetchKey = "revokedLastFetch"
    private static let fetchInterval: TimeInterval = 24 * 3600

    // MARK: URLs for the UI

    /// `https://meboki.com`; in DEBUG builds `MEBOKI_LICENCE_BASE_URL` overrides it (testing only).
    static let baseURL: URL = {
        #if DEBUG
        if let s = ProcessInfo.processInfo.environment["MEBOKI_LICENCE_BASE_URL"], let u = URL(string: s) { return u }
        #endif
        return URL(string: "https://meboki.com")!
    }()
    static var buyURL: URL { baseURL.appendingPathComponent("api/checkout") }
    static var lostKeyURL: URL { baseURL.appendingPathComponent("licence") }
    static var revokedURL: URL { baseURL.appendingPathComponent("api/revoked") }
    static let supportEmail = LicenceText.supportEmail

    // MARK: Conveniences

    var isFull: Bool { entitlement.isFull }
    var licence: LicenceInfo? {
        if case .licensed(let info) = entitlement { return info }
        return nil
    }
    /// Days left in the trial (7 on a fresh install), whatever the state; 0 once it is used up.
    var trialDaysLeft: Int { trial.daysLeft(now: now(), calendar: calendar) }
    var isLastTrialDay: Bool {
        if case .trial = entitlement { return trial.isLastDay(now: now(), calendar: calendar) }
        return false
    }
    var trialDaysUsed: Int { trial.days.count }
    /// Today already counts as a trial day (a check ran today).
    var trialTodayCounted: Bool { trial.days.contains(trial.today(now: now(), calendar: calendar)) }
    /// The ID of the stored key when it verifies (also when it is revoked or expired), for the per-key notice.
    var storedKid: String? {
        if case .success(let info)? = key { return info.kid }
        return nil
    }

    // MARK: Init

    /// `fetchEnabled: false` and a private `defaults`/stores keep demos and tests off the network and the real state.
    init(licenceStore: LicenceStore = .standard, trialStore: TrialStore = TrialStore(),
         defaults: UserDefaults = .standard, calendar: Calendar = .current, now: @escaping () -> Date = { Date() },
         fetchEnabled: Bool = true, observeSystem: Bool = true) {
        self.licenceStore = licenceStore
        self.trialStore = trialStore
        self.defaults = defaults
        self.calendar = calendar
        self.now = now
        self.fetchEnabled = fetchEnabled
        let state = Self.load(licenceStore: licenceStore, trialStore: trialStore)
        key = state.key
        revoked = state.revoked
        trial = state.trial
        entitlement = Entitlement.resolve(licence: state.key, revoked: state.revoked, trial: state.trial,
                                          now: now(), calendar: calendar)
        if observeSystem { startObserving() }
    }

    private struct State: Sendable {
        var key: Result<LicenceInfo, LicenceError>?
        var revoked: RevokedList?
        var trial: TrialClock
    }

    nonisolated private static func load(licenceStore: LicenceStore, trialStore: TrialStore) -> State {
        State(key: licenceStore.loadKey().map { LicenceKey.verify($0) }, revoked: licenceStore.loadRevoked(),
              trial: trialStore.read())
    }

    /// Read-only: the entitlement this Mac has now, without writing anything (`--licence-status`).
    nonisolated static func peek(now: Date = Date(), calendar: Calendar = .current) -> Entitlement {
        let s = load(licenceStore: .standard, trialStore: TrialStore(interactive: false))
        return Entitlement.resolve(licence: s.key, revoked: s.revoked, trial: s.trial, now: now, calendar: calendar)
    }

    /// Call once at launch, after the observers of `transitions` exist: remembers today, re-checks the key and
    /// the revoked list, and fetches the list when one is due.
    func start() {
        refresh()
        fetchRevokedIfDue()
    }

    private func startObserving() {
        let nc = NotificationCenter.default
        observers.append(nc.addObserver(forName: .NSCalendarDayChanged, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh(); self?.fetchRevokedIfDue() }
        })
        observers.append(NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh(); self?.fetchRevokedIfDue() }
        })
    }

    // MARK: State

    /// Reads everything again (stores, clock, day) and publishes a change.
    func refresh() {
        var s = Self.load(licenceStore: licenceStore, trialStore: trialStore)
        let before = s.trial
        s.trial.observe(now: now(), calendar: calendar)
        if s.trial != before { trialStore.write(s.trial) }
        key = s.key
        revoked = s.revoked
        trial = s.trial
        publish()
    }

    private func publish() {
        let new = Entitlement.resolve(licence: key, revoked: revoked, trial: trial, now: now(), calendar: calendar)
        guard new != entitlement else { return }
        let old = entitlement
        entitlement = new
        Log.write("licence: \(Self.describe(old)) -> \(Self.describe(new))")
        transitions.send(Transition(from: old, to: new))
    }

    /// One log-safe line (the `kid` at most; never the key or the email).
    nonisolated static func describe(_ e: Entitlement) -> String {
        switch e {
        case .licensed(let i): "licensed (\(i.type.rawValue), kid \(i.kid))"
        case .trial(let d): "trial (\(d) day(s) left)"
        case .free(let r): "free (\(r))"
        }
    }

    // MARK: Actions

    /// Checks `text` offline and stores the key. The features unlock at once.
    func activate(_ text: String) -> Result<LicenceInfo, ActivationError> {
        switch LicenceKey.verify(text) {
        case .failure(let e):
            return .failure(.invalid(e))
        case .success(let info):
            if revoked?.contains(info.kid) == true { return .failure(.revoked) }
            if info.isExpired(now: now()) { return .failure(.expired) }
            if let why = licenceStore.saveKey(info.key) { return .failure(.saveFailed(why)) }
            key = .success(info)
            publish()
            Log.write("licence: activated (kid \(info.kid))")
            fetchRevokedIfDue()
            return .success(info)
        }
    }

    /// Deletes the stored key (and the revoked list kept for it). Back to the trial, or free mode.
    func removeLicence() {
        licenceStore.removeKey()
        licenceStore.removeRevoked()
        key = nil
        revoked = nil
        Log.write("licence: removed")
        publish()
    }

    /// A real check ran (hotkey or automatic; not the onboarding sample): counts today as a trial day.
    func recordCheck() {
        if case .licensed = entitlement { return }
        var t = trial
        t.recordCheck(now: now(), calendar: calendar)
        guard t != trial else { return }
        trialStore.write(t)
        trial = t
        publish()
    }

    // MARK: Revoked list (PLAN.md §6 "Revoked list")

    /// Only with a licence installed: at launch, then at most once every 24 hours. Nothing is sent but a plain GET.
    func fetchRevokedIfDue(force: Bool = false) {
        guard fetchEnabled, !fetching, key != nil else { return }
        let last = defaults.object(forKey: Self.lastFetchKey) as? Date
        if !force, let last, now().timeIntervalSince(last) < Self.fetchInterval, last <= now() { return }
        defaults.set(now(), forKey: Self.lastFetchKey)
        fetching = true
        let url = Self.revokedURL
        Task { @MainActor in
            defer { self.fetching = false }
            let config = URLSessionConfiguration.ephemeral
            config.urlCache = nil
            config.httpCookieStorage = nil
            config.httpShouldSetCookies = false
            config.requestCachePolicy = .reloadIgnoringLocalAndRemoteCacheData
            config.timeoutIntervalForRequest = 15
            let session = URLSession(configuration: config)
            defer { session.finishTasksAndInvalidate() }
            do {
                let (data, response) = try await session.data(from: url)
                guard (response as? HTTPURLResponse)?.statusCode == 200, data.count < 1_000_000,
                      let list = RevokedList.parse(data) else {
                    Log.write("licence: revoked list not updated (bad response)")
                    return
                }
                guard let newest = RevokedList.newer(current: self.revoked, candidate: list), newest.raw == list.raw
                else {
                    Log.write("licence: revoked list is current")
                    return
                }
                self.licenceStore.saveRevoked(list.raw)
                self.revoked = list
                Log.write("licence: revoked list updated (\(list.kids.count) id(s))")
                self.publish()
            } catch {
                Log.write("licence: revoked list not updated (\(error.localizedDescription))")
            }
        }
    }

    // MARK: Debug

    #if DEBUG
    /// Adds one past day to the trial.
    func debugAddTrialDay() {
        var days = trial.days
        var n = 1
        while days.count < TrialClock.length {
            let d = TrialClock.dayString(now().addingTimeInterval(-Double(n) * 86_400), calendar: calendar)
            n += 1
            if !days.contains(d) { days.append(d); break }
        }
        applyDebugTrial(TrialClock(days: days, lastSeen: trial.lastSeen))
    }

    /// Fills the trial with seven past days, so it is over today.
    func debugEndTrial() {
        let days = (1...TrialClock.length).map {
            TrialClock.dayString(now().addingTimeInterval(-Double($0) * 86_400), calendar: calendar)
        }
        applyDebugTrial(TrialClock(days: days, lastSeen: trial.lastSeen))
    }

    /// Forgets the trial, and the one-shot notice flags.
    func debugResetTrial() {
        trialStore.erase()
        trial = TrialClock()
        AppSettings.shared.resetLicenceNotices()
        refresh()
    }

    /// Screenshot demos only: shows `entitlement` and `trial` as given, without touching any store.
    func debugForce(_ entitlement: Entitlement, trial: TrialClock) {
        self.trial = trial
        self.entitlement = entitlement
    }

    private func applyDebugTrial(_ t: TrialClock) {
        trialStore.write(t)
        trial = trialStore.read()
        publish()
    }
    #endif
}
