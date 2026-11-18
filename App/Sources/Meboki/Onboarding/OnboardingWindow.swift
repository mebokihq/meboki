import AppKit
import Combine
import MebokiCore
import SwiftUI

/// Onboarding pages (PLAN.md §7 Phase 1 "Onboarding window"), in order.
enum OnboardingStep: Int, CaseIterable {
    case welcome, access, model, tryIt, popup, done
}

/// Where checks stand, for the model and "Try it" pages (set by `AppDelegate.refreshStatus`).
enum OnboardingEngine: Equatable {
    /// The local model answers, or a cloud model with a saved key is in use.
    case ready(model: String, cloud: Bool)
    case loading(String)
    case downloading(String, fraction: Double)
    /// Downloading paused, failed, or never started: the model page has the buttons.
    case needsModel(String?)
    case failed(String)

    var isReady: Bool {
        if case .ready = self { return true }
        return false
    }
}

/// The result of the sample check on the "Try it" page.
enum OnboardingTryState: Equatable {
    case idle
    case checking
    case done(text: String, edits: [Edit], seconds: Double)
    case failed(String)
}

/// What the onboarding pages call back into (`AppDelegate`).
struct OnboardingActions {
    /// Adds Meboki to System Settings › Privacy & Security › Accessibility (the system prompt) and opens it.
    var openAccessibility: () -> Void = {}
    /// Shows Meboki.app in Finder, for the "+" button of the Accessibility list.
    var revealApp: () -> Void = {}
    /// Makes `m` the model checks use, downloading it first when it isn't installed.
    var useModel: (ModelInfo) -> Void = { _ in }
    var pause: (ModelInfo) -> Void = { _ in }
    var openSettings: (SettingsPane) -> Void = { _ in }
    /// Settings › Licence (the Done page's key link and locked controls).
    var openLicence: () -> Void = {}
    /// Checks a sample text with the current model (no field, no Accessibility). Edits are relative to the text.
    var tryCheck: (String) async throws -> [Edit] = { _ in [] }
    /// Opens a practice note in TextEdit, to try the shortcut in a real app.
    var openPractice: () -> Void = {}
    /// Returns an error message when the system refused.
    var setLaunchAtLogin: (Bool) -> String? = { _ in nil }
    /// The last page's Finish: onboarding is done.
    var finish: () -> Void = {}
}

/// Window state; settings live in `AppSettings`, models in `ModelStore`.
@MainActor
final class OnboardingModel: ObservableObject {
    @Published var step: OnboardingStep = .welcome
    @Published var trusted = false
    /// The user pressed Open System Settings at least once (the page then says what to do there).
    @Published var askedForAccess = false
    /// The model the model page has picked (`Catalog` ID).
    @Published var pickedModelID: String
    /// The model checks use now (`AppDelegate.selectedModel`).
    @Published var selectedModelID: String
    /// Checks use a cloud model (Settings › Models › Cloud).
    @Published var cloudModelName: String?
    @Published var engine: OnboardingEngine = .needsModel(nil)
    @Published var tryState: OnboardingTryState = .idle
    @Published var launchAtLogin = false
    @Published var message: SettingsToast?
    var actions = OnboardingActions()

    private var messageHide: DispatchWorkItem?

    init(selectedModelID: String) {
        self.selectedModelID = selectedModelID
        pickedModelID = selectedModelID
    }

    func go(_ step: OnboardingStep) {
        withAnimation(DS.Motion.reduceMotion ? nil : .snappy(duration: 0.28)) { self.step = step }
    }

    func next() {
        if let n = OnboardingStep(rawValue: step.rawValue + 1) { go(n) } else { actions.finish() }
    }

    func back() {
        if let p = OnboardingStep(rawValue: step.rawValue - 1) { go(p) }
    }

    func showMessage(_ kind: MessageKind, _ title: String) {
        withAnimation(DS.Motion.popIn) { message = SettingsToast(kind: kind, title: title) }
        messageHide?.cancel()
        let work = DispatchWorkItem { [weak self] in
            withAnimation(DS.Motion.fade) { self?.message = nil }
        }
        messageHide = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 3, execute: work)
    }
}

/// The onboarding window: 680 × 560, full-size content, transparent title bar, close button only. Like
/// Settings, the app is a regular app (Dock icon, can take focus) while it's open.
@MainActor
final class OnboardingWindowController: NSObject, NSWindowDelegate {
    static let size = NSSize(width: 680, height: 600)

    let model: OnboardingModel
    /// The window closed. True when the user closed it (Finish, the close button, ⌘W); false when the app quit
    /// with it open, which must not count as onboarding done.
    var onClose: ((_ byUser: Bool) -> Void)?
    private var closingByUser = false

    private let settings: AppSettings
    private let store: ModelStore
    private var window: NSWindow?
    private lazy var mainMenu = AppMenus.windowMenu(appName: "Meboki")

    init(model: OnboardingModel, settings: AppSettings, store: ModelStore) {
        self.model = model
        self.settings = settings
        self.store = store
        super.init()
    }

    var isVisible: Bool { window?.isVisible == true }
    var windowNumber: Int { window?.windowNumber ?? -1 }
    #if DEBUG
    var debugWindow: NSWindow? { window }
    #endif

    func show(activate: Bool = true) {
        let w = window ?? makeWindow()
        window = w
        if !w.isVisible { w.center() }
        if activate {
            if NSApp.activationPolicy() != .regular { NSApp.setActivationPolicy(.regular) }
            NSApp.activate(ignoringOtherApps: true)
            w.makeKeyAndOrderFront(nil)
        } else {
            w.orderFrontRegardless()
        }
    }

    /// Access was just allowed while the user is in System Settings: bring the window back, so the next step
    /// is right there. macOS may refuse to activate a background app; the window still comes to the front.
    func bringForward() {
        guard let w = window, w.isVisible else { return }
        NSApp.activate(ignoringOtherApps: true)
        w.orderFrontRegardless()
        w.makeKey()
    }

    func close() { window?.performClose(nil) }

    private func makeWindow() -> NSWindow {
        let w = NSWindow(contentRect: NSRect(origin: .zero, size: Self.size),
                         styleMask: [.titled, .closable, .fullSizeContentView],
                         backing: .buffered, defer: false)
        w.title = "Welcome to Meboki"
        w.titleVisibility = .hidden
        w.titlebarAppearsTransparent = true
        w.isReleasedWhenClosed = false
        w.isMovableByWindowBackground = true
        w.collectionBehavior = [.fullScreenAuxiliary, .moveToActiveSpace]
        w.backgroundColor = NSColor(DS.window)
        w.standardWindowButton(.miniaturizeButton)?.isHidden = true
        w.standardWindowButton(.zoomButton)?.isHidden = true
        w.delegate = self
        let host = NSHostingView(rootView: OnboardingRootView(model: model, settings: settings, store: store))
        host.sizingOptions = []
        w.contentView = host
        w.setFrame(NSRect(origin: w.frame.origin, size: Self.size), display: false)
        return w
    }

    func windowDidBecomeKey(_ notification: Notification) { NSApp.mainMenu = mainMenu }

    func windowDidResignKey(_ notification: Notification) {
        if NSApp.mainMenu === mainMenu { NSApp.mainMenu = nil }
    }

    /// Asked for the close button, ⌘W and `performClose` (Finish), not when the app quits.
    func windowShouldClose(_ sender: NSWindow) -> Bool {
        closingByUser = true
        return true
    }

    func windowWillClose(_ notification: Notification) {
        if NSApp.mainMenu === mainMenu { NSApp.mainMenu = nil }
        AppMenus.windowClosed(window)
        let byUser = closingByUser
        closingByUser = false
        onClose?(byUser)
    }
}

/// Shared bits of the app's own windows (Settings, onboarding).
@MainActor
enum AppMenus {
    /// A small main menu for a window of this accessory app: Quit, the Edit keys and ⌘W.
    static func windowMenu(appName: String) -> NSMenu {
        let main = NSMenu()
        let appItem = NSMenuItem()
        let app = NSMenu(title: appName)
        app.addItem(NSMenuItem(title: "Quit \(appName)", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
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
        windowItem.submenu = window
        main.addItem(windowItem)
        return main
    }

    /// One of the app's titled windows is closing: the app goes back to a menu-bar-only accessory app (no Dock
    /// icon) unless another of its titled windows is still open.
    static func windowClosed(_ closing: NSWindow?) {
        let others = NSApp.windows.contains { w in
            w !== closing && w.isVisible && !(w is NSPanel) && w.styleMask.contains(.titled)
        }
        if !others, NSApp.activationPolicy() != .accessory { NSApp.setActivationPolicy(.accessory) }
    }
}
