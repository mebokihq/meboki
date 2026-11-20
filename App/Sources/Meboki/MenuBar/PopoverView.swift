import AppKit
import Combine
import MebokiCore
import SwiftUI

/// The popover header's status line (§7.1).
struct PopoverStatus: Equatable {
    enum Kind: Equatable {
        /// `ok` dot: ready.
        case ready
        /// Spinner: loading, downloading or checking.
        case busy
        /// `catPunctuation` dot: paused in the frontmost app.
        case paused
        /// `catSpelling` dot: an error.
        case error
        /// `textTertiary` dot: the model isn't running.
        case idle
    }
    var kind: Kind
    var text: String
}

/// Live state the popover shows; `AppDelegate` keeps it current.
@MainActor
final class PopoverModel: ObservableObject {
    @Published var status = PopoverStatus(kind: .busy, text: "Starting…")
    @Published var modelID = ""
    @Published var modelName = ""
    @Published var peakMemoryGB = 0.0
    @Published var paragraphSeconds = 0.0
    @Published var ramGB = 1
    /// The local model was unloaded to free memory (idle or memory pressure); the next check loads it again.
    @Published var unloaded = false
    /// Cloud mode: the provider's name ("OpenRouter") and the model line under the name. Nil on this Mac.
    @Published var cloudProvider: String?
    @Published var cloudDetail = ""
    /// Apple's built-in model is in use: no memory meter (it lives in a system process), "Built into macOS".
    @Published var builtIn = false
    /// The app checks run in (the frontmost app, or the last one before Meboki). Nil when unknown.
    @Published var appName: String?
    @Published var appBundleID: String?
    /// The global hotkey, as keycap glyphs.
    @Published var hotkey = "⌃⌥G"
    /// "Trial · 4 days left" while the trial runs (nil otherwise). `PopoverPanel` keeps it current.
    @Published var trialText: String?
    /// "0.2.0" when a new version is waiting (nil otherwise). `PopoverPanel` keeps it current.
    @Published var updateVersion: String?
}

struct PopoverActions {
    var check: () -> Void = {}
    /// Settings… and ⌘,: the last pane.
    var openSettings: () -> Void = {}
    /// The gear: Settings › General.
    var openGeneral: () -> Void = {}
    var openModels: () -> Void = {}
    /// Settings › Licence (the trial line, "Unlock", a locked control).
    var openLicence: () -> Void = {}
    /// The "Update available" row: the update window.
    var showUpdate: () -> Void = {}
    var quit: () -> Void = {}
}

/// Root of the popover window: the popover, popping in when `appear.shown` turns true.
struct PopoverRoot: View {
    @ObservedObject var model: PopoverModel
    @ObservedObject var settings: AppSettings
    var actions = PopoverActions()
    @ObservedObject var appear: AppearModel

    var body: some View {
        PopoverView(model: model, settings: settings, actions: actions)
            .modifier(PopInModifier(active: !appear.shown))
    }
}

/// The menu-bar popover (design_code.md §7, compact): width 320, padding 10, gap 8, glass, radius 20.
struct PopoverView: View {
    @ObservedObject var model: PopoverModel
    @ObservedObject var settings: AppSettings
    var actions = PopoverActions()

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            header
            updateRow
            checkButton
            freeModeRow
            tiles
            modelRow
            menuRows
            trialRow
            PrivacyLine(text: model.cloudProvider.map { "Cloud: text you check goes to \($0)" } ?? "Your text stays on this Mac",
                        symbol: model.cloudProvider == nil ? "lock" : "cloud")
                .frame(maxWidth: .infinity)
        }
        .padding(10)
        .frame(width: 320)
        .background(GlassBackground(shape: RoundedRectangle(cornerRadius: 20, style: .continuous)))
        .dsShadow(DS.windowShadow)
    }

    // MARK: Header

    private var header: some View {
        HStack(spacing: 10) {
            AppIconView(size: 28)
            VStack(alignment: .leading, spacing: 1) {
                Text("Meboki").font(DS.Font.bodySemibold).foregroundStyle(DS.text)
                HStack(spacing: 6) {
                    statusMark
                    Text(model.status.text).lineLimit(1).truncationMode(.tail)
                }
                .font(.system(size: 11.5))
                .foregroundStyle(DS.textSecondary)
                .accessibilityElement(children: .combine)
            }
            Spacer(minLength: 0)
            Button(action: actions.openGeneral) {
                Image(systemName: "gearshape")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(DS.text)
                    .frame(width: 26, height: 26)
                    .background(Circle().fill(DS.control))
                    .contentShape(Circle())
            }
            .buttonStyle(PressScaleStyle())
            .accessibilityLabel("Settings")
        }
        .padding(EdgeInsets(top: 2, leading: 4, bottom: 2, trailing: 2))
    }

    @ViewBuilder private var statusMark: some View {
        switch model.status.kind {
        case .busy:
            DSSpinner().scaleEffect(0.75).frame(width: 13, height: 13)
        case .ready: StatusDot(color: DS.ok)
        case .paused: StatusDot(color: DS.catPunctuation)
        case .error: StatusDot(color: DS.catSpelling)
        case .idle: StatusDot(color: DS.textTertiary)
        }
    }

    // MARK: Check button

    private var checkButton: some View {
        Button(action: actions.check) {
            HStack(spacing: 8) {
                Image(systemName: "sparkle").font(.system(size: 14, weight: .semibold)).frame(width: 16, height: 16)
                Text("Check focused field").font(.system(size: 13.5, weight: .semibold))
                Spacer(minLength: 0)
                Text(model.hotkey)
                    .font(.system(size: 11.5, weight: .medium))
                    .padding(.vertical, 3)
                    .padding(.horizontal, 6)
                    .background(RoundedRectangle(cornerRadius: DS.Radius.kbd, style: .continuous).fill(DS.kbdOnAccent))
                    .accessibilityHidden(true)
            }
            .foregroundStyle(DS.onAccent)
            .padding(.horizontal, 12)
            .frame(maxWidth: .infinity, minHeight: 38, maxHeight: 38)
            .background {
                let shape = RoundedRectangle(cornerRadius: 12, style: .continuous)
                shape.fill(DS.brandGradient)
                    .overlay(InnerTopHighlight(shape: shape, color: DS.primaryHighlight))
                    .dsShadow(DS.checkButtonShadow)
            }
            .contentShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        }
        .buttonStyle(PressScaleStyle(hoverBrightness: true))
        .dsKeyLabel("Check focused field", kbd: model.hotkey)
    }

    // MARK: Update

    /// A new version is waiting: one quiet row that opens the update window.
    @ViewBuilder private var updateRow: some View {
        if let version = model.updateVersion {
            Button(action: actions.showUpdate) {
                HStack(spacing: 8) {
                    Image(systemName: "arrow.down.circle.fill").font(.system(size: 13)).foregroundStyle(DS.ok)
                    Text(UpdateText.available(version)).font(.system(size: 12.5, weight: .semibold)).foregroundStyle(DS.text)
                    Spacer(minLength: 0)
                    Text("Install…").font(DS.Font.caption).foregroundStyle(DS.textSecondary)
                }
                .padding(EdgeInsets(top: 7, leading: 10, bottom: 7, trailing: 10))
                .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(DS.ok.opacity(0.14)))
                .contentShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            }
            .buttonStyle(PressScaleStyle())
            .accessibilityLabel(UpdateText.available(version))
            .accessibilityHint("Opens the update window")
        }
    }

    // MARK: Licence (PLAN.md §6 "Where the user meets the paywall")

    private var locked: Bool { !settings.entitlement.isFull }

    /// Free mode: what it means, and a way out.
    @ViewBuilder private var freeModeRow: some View {
        if locked {
            HStack(spacing: 8) {
                Image(systemName: "lock.fill").font(.system(size: 10, weight: .semibold)).foregroundStyle(DS.textSecondary)
                Text("Free mode · checks only on \(model.hotkey)")
                    .font(DS.Font.caption)
                    .foregroundStyle(DS.textSecondary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.9)
                Spacer(minLength: 0)
                Button("Unlock", action: actions.openLicence).buttonStyle(.ds(.primary, small: true))
            }
            .padding(.leading, 6)
            .accessibilityElement(children: .contain)
        }
    }

    /// The trial: a quiet line that opens Settings › Licence.
    @ViewBuilder private var trialRow: some View {
        if let text = model.trialText, settings.entitlement.isFull {
            Button(action: actions.openLicence) {
                HStack(spacing: 5) {
                    Image(systemName: "clock").font(.system(size: 10))
                    Text(text)
                }
                .font(DS.Font.caption)
                .foregroundStyle(DS.textSecondary)
                .frame(maxWidth: .infinity)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(text)
            .accessibilityHint("Opens Settings, Licence")
        }
    }

    // MARK: Tiles

    private var tiles: some View {
        VStack(spacing: 6) {
            HStack(spacing: 6) {
                // Milestone B (§8.1): a review started with the hotkey follows typing.
                // Free mode: locked, a click goes to Settings › Licence (the stored value is kept).
                ToggleTile(symbol: locked ? "lock.fill" : "underline", title: "Underline as I type",
                           state: locked ? "Needs a licence" : settings.underlineAsYouType ? "On" : "Off",
                           isOn: !locked && settings.underlineAsYouType, dimmed: locked) {
                    if locked { actions.openLicence() } else { settings.underlineAsYouType.toggle() }
                }
                pauseTile
            }
            VStack(spacing: 0) {
                WideRow(title: "English") {
                    DSSegmented(selection: $settings.englishVariant,
                                options: EnglishVariant.allCases.map { ($0, $0.rawValue) })
                }
                DSSeparator().padding(.horizontal, 12)
                WideRow(title: "Check", locked: locked) {
                    DSSegmented(selection: $settings.checkLevel,
                                options: CheckLevel.allCases.map { ($0, $0.title) })
                        .opacity(locked ? 0.5 : 1)
                        .allowsHitTesting(!locked)
                }
                .contentShape(Rectangle())
                .onTapGesture { if locked { actions.openLicence() } }
            }
            .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(DS.control))
        }
    }

    @ViewBuilder private var pauseTile: some View {
        if let id = model.appBundleID {
            let paused = settings.isPaused(id)
            ToggleTile(symbol: "pause", title: "Pause in \(model.appName ?? "this app")",
                       state: paused ? "Paused" : settings.effectiveAppMode(id) == .manual ? "Manual" : "Checking",
                       isOn: paused) {
                settings.setPaused(!paused, bundleID: id, name: model.appName)
            }
        } else {
            ToggleTile(symbol: "pause", title: "Pause in this app", state: "No app in front", isOn: false) {}
                .disabled(true)
        }
    }

    // MARK: Model row

    private var modelRow: some View {
        Button(action: actions.openModels) {
            HStack(spacing: 10) {
                ModelGlyph(modelID: model.modelID, initial: String(model.modelName.prefix(1)), size: 26)
                VStack(alignment: .leading, spacing: 0) {
                    Text(model.modelName).font(DS.Font.bodySemibold).foregroundStyle(DS.text)
                    if model.builtIn {
                        Text("Built into macOS · no download")
                            .font(DS.Font.footnote)
                            .foregroundStyle(DS.textSecondary)
                            .lineLimit(1)
                            .padding(.top, 2)
                    } else if model.cloudProvider != nil {
                        Text(model.cloudDetail)
                            .font(DS.Font.footnote)
                            .foregroundStyle(DS.textSecondary)
                            .lineLimit(1)
                            .padding(.top, 2)
                    } else {
                        DSMeter(value: model.unloaded ? 0 : model.peakMemoryGB / Double(max(1, model.ramGB)), height: 4)
                            .padding(.top, 4)
                        Text(model.unloaded
                             ? "Unloaded to free memory · loads on the next check"
                             : "\(Self.gb(model.peakMemoryGB)) GB of \(model.ramGB) GB · "
                                + String(format: "%.1f s", model.paragraphSeconds) + " per paragraph")
                            .font(DS.Font.footnote)
                            .foregroundStyle(DS.textSecondary)
                            .lineLimit(1)
                            .padding(.top, 2)
                    }
                }
            }
            .padding(EdgeInsets(top: 7, leading: 10, bottom: 7, trailing: 10))
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(DS.control))
            .contentShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        }
        .buttonStyle(PressScaleStyle(hoverBrightness: true))
        .accessibilityElement(children: .combine)
        .accessibilityHint("Opens the models")
    }

    /// "4.75", "3.6".
    private static func gb(_ v: Double) -> String { String(format: "%g", (v * 100).rounded() / 100) }

    // MARK: Menu rows

    private var menuRows: some View {
        VStack(spacing: 0) {
            MenuRow(title: "Models…", action: actions.openModels)
            MenuRow(title: "Settings…", shortcut: "⌘,", action: actions.openSettings)
            MenuRow(title: "Quit Meboki", shortcut: "⌘Q", action: actions.quit)
        }
        .padding(.top, 4)
        .overlay(alignment: .top) { DSSeparator() }
    }
}

// MARK: - Pieces

/// 7 pt dot with a 3 pt halo of the same color at 22%.
private struct StatusDot: View {
    let color: Color
    var body: some View {
        Circle().fill(color)
            .frame(width: 7, height: 7)
            .background(Circle().fill(color.opacity(0.22)).frame(width: 13, height: 13))
            .frame(width: 13, height: 13)
            .accessibilityHidden(true)
    }
}

/// A compact toggle tile: a round icon on the left, the title over the state. Radius 12, padding 8 10.
private struct ToggleTile: View {
    let symbol: String
    let title: String
    let state: String
    let isOn: Bool
    var dimmed = false
    let action: () -> Void
    @Environment(\.isEnabled) private var isEnabled

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Image(systemName: symbol)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(isOn ? DS.onAccent : DS.text)
                    .frame(width: 24, height: 24)
                    .background {
                        if isOn { Circle().fill(DS.brandGradient) } else { Circle().fill(DS.control2) }
                    }
                VStack(alignment: .leading, spacing: 0) {
                    Text(title).font(.system(size: 12, weight: .semibold)).foregroundStyle(DS.text)
                        .lineLimit(1).truncationMode(.middle)
                    Text(state).font(DS.Font.footnote).foregroundStyle(DS.textSecondary).lineLimit(1)
                }
                Spacer(minLength: 0)
            }
            .padding(EdgeInsets(top: 8, leading: 8, bottom: 8, trailing: 8))
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(DS.control))
            .contentShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            .opacity(isEnabled && !dimmed ? 1 : 0.55)
        }
        .buttonStyle(PressScaleStyle(hoverBrightness: true))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(title)
        .accessibilityValue(state)
        .accessibilityAddTraits(isOn ? [.isButton, .isSelected] : .isButton)
    }
}

/// A row in the settings group: label on the left, a control on the right. Padding 5 6 5 12.
private struct WideRow<Control: View>: View {
    let title: String
    var locked = false
    @ViewBuilder let control: Control

    var body: some View {
        HStack(spacing: 8) {
            Text(title).font(.system(size: 12.5, weight: .semibold)).foregroundStyle(DS.text)
            if locked { LockBadge(caption: false) }
            Spacer(minLength: 0)
            control
        }
        .padding(EdgeInsets(top: 5, leading: 12, bottom: 5, trailing: 6))
        .accessibilityElement(children: .contain)
        .accessibilityLabel(locked ? "\(title), needs a licence" : title)
    }
}

/// A menu row: padding 4 × 8, radius 6, 13 pt. On hover a `brand` fill with white text, like an NSMenu
/// highlight. The shortcut is right-aligned at 55% opacity.
private struct MenuRow: View {
    let title: String
    var shortcut: String?
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack {
                Text(title).font(DS.Font.body)
                Spacer(minLength: 0)
                if let shortcut {
                    Text(shortcut).font(.system(size: 12)).opacity(hovering ? 1 : 0.55)
                }
            }
            .foregroundStyle(hovering ? DS.onAccent : DS.text)
            .padding(.vertical, 4)
            .padding(.horizontal, 8)
            .background(RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(hovering ? DS.brand : Color.clear))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .dsKeyLabel(title, kbd: shortcut)
    }
}

/// Pressed: scale .97. Optional hover: brightness .96 (−0.04).
private struct PressScaleStyle: ButtonStyle {
    var hoverBrightness = false
    func makeBody(configuration: Configuration) -> some View {
        PressScaleBody(configuration: configuration, hoverBrightness: hoverBrightness)
    }
}

private struct PressScaleBody: View {
    let configuration: ButtonStyleConfiguration
    let hoverBrightness: Bool
    @State private var hovering = false

    var body: some View {
        configuration.label
            .brightness(hoverBrightness && hovering ? -0.04 : 0)
            .scaleEffect(configuration.isPressed ? 0.97 : 1)
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
            .onHover { hovering = $0 }
    }
}

// MARK: - Panel

/// The popover window (§7): a borderless non-activating panel with no arrow, 6 pt below the menu bar,
/// centered on the status item and clamped to the screen with 8 pt margins. It becomes key without
/// activating Meboki (so Esc, ⌘, and ⌘Q reach it while the frontmost app stays frontmost), and closes
/// on Esc, a click outside, another app coming forward, or `hide()`.
@MainActor
final class PopoverPanel {
    let model = PopoverModel()
    /// Called whenever the popover closes, however it closed.
    var onHide: (() -> Void)?

    private let settings: AppSettings
    private let appear = AppearModel()
    private let hosted: HostedPanel<PopoverRoot>
    private var panel: NSPanel { hosted.panel }
    private var actions = PopoverActions()
    private var keyMonitor: Any?
    private var mouseMonitor: Any?
    private var generation = 0
    private var licenceSub: AnyCancellable?
    private var updateSub: AnyCancellable?

    init(settings: AppSettings, licence: LicenceManager? = nil) {
        let licence = licence ?? LicenceManager.shared
        self.settings = settings
        hosted = HostedPanel(PopoverRoot(model: model, settings: settings, appear: appear), canBecomeKey: true)
        panel.level = .statusBar
        panel.setAccessibilityLabel("Meboki")
        licenceSub = licence.$trial.combineLatest(licence.$entitlement)
            .receive(on: DispatchQueue.main)
            .sink { [weak self, weak licence] _, _ in
                guard let self, let licence else { return }
                self.model.trialText = Self.trialText(licence)
            }
        updateSub = UpdateController.shared.$available.receive(on: DispatchQueue.main)
            .sink { [weak self] v in self?.model.updateVersion = v }
    }

    var isVisible: Bool { panel.isVisible }
    var windowNumber: Int { panel.windowNumber }
    #if DEBUG
    var debugWindow: NSWindow? { panel }
    #endif

    /// "Trial · 4 days left", "Trial · last day", "Trial · 7 days" (nothing checked yet); nil outside the trial.
    static func trialText(_ licence: LicenceManager) -> String? {
        guard case .trial(let left) = licence.entitlement else { return nil }
        if licence.isLastTrialDay { return "Trial · last day" }
        if licence.trialDaysUsed == 0 { return "Trial · \(left) days" }
        return "Trial · \(left) \(left == 1 ? "day" : "days") left"
    }

    /// Each action closes the popover first.
    func setActions(_ a: PopoverActions) {
        actions = PopoverActions(
            check: { [weak self] in self?.hide(animated: false); a.check() },
            openSettings: { [weak self] in self?.hide(animated: false); a.openSettings() },
            openGeneral: { [weak self] in self?.hide(animated: false); a.openGeneral() },
            openModels: { [weak self] in self?.hide(animated: false); a.openModels() },
            openLicence: { [weak self] in self?.hide(animated: false); a.openLicence() },
            showUpdate: { [weak self] in self?.hide(animated: false); a.showUpdate() },
            quit: { a.quit() })
    }

    /// Shows the popover under `item` (the status item's screen frame) on `screen`.
    func show(under item: CGRect, screen: NSScreen?) {
        generation += 1
        let gen = generation
        appear.shown = false
        let size = hosted.setRoot(PopoverRoot(model: model, settings: settings, actions: actions, appear: appear))
        let frame = screen?.frame ?? NSScreen.main?.frame ?? CGRect(x: 0, y: 0, width: 1440, height: 900)
        var x = item.midX - size.width / 2
        x = max(frame.minX + 8, min(x, frame.maxX - 8 - size.width))
        let top = item.minY - 6
        hosted.place(shapeOrigin: CGPoint(x: x, y: top - size.height))
        panel.alphaValue = 1
        panel.orderFrontRegardless()
        panel.makeKey()
        installMonitors()
        DispatchQueue.main.async { [weak self] in
            guard let self, self.generation == gen, self.panel.isVisible else { return }
            withAnimation(DS.Motion.popIn) { self.appear.shown = true }
        }
    }

    /// Fades out over 0.15 s (instant with Reduce Motion, or when `animated` is false). Ordering the key panel
    /// out gives the keyboard back to the frontmost app.
    func hide(animated: Bool = true) {
        generation += 1
        let gen = generation
        removeMonitors()
        guard panel.isVisible else { return }
        onHide?()
        if !animated || DS.Motion.reduceMotion {
            panel.orderOut(nil)
            appear.shown = false
            return
        }
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.15
            panel.animator().alphaValue = 0
        }, completionHandler: { [weak self] in
            MainActor.assumeIsolated {
                guard let self, self.generation == gen else { return }
                self.panel.orderOut(nil)
                self.panel.alphaValue = 1
                self.appear.shown = false
            }
        })
    }

    private func installMonitors() {
        removeMonitors()
        // Keys aimed at the popover: Esc closes it, ⌘, opens Settings, ⌘Q quits.
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            let handled = MainActor.assumeIsolated { () -> Bool in
                guard let self, event.windowNumber == self.panel.windowNumber else { return false }
                let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
                if event.keyCode == 53 {
                    self.hide()
                    return true
                }
                if flags == .command, let key = event.charactersIgnoringModifiers {
                    if key == "," { self.actions.openSettings(); return true }
                    if key == "q" { self.actions.quit(); return true }
                }
                return false
            }
            return handled ? nil : event
        }
        // A click anywhere outside Meboki closes it. Clicks on the status item are local events: the
        // item toggles the popover itself.
        mouseMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown]) { [weak self] _ in
            MainActor.assumeIsolated { self?.hide() }
        }
    }

    private func removeMonitors() {
        if let m = keyMonitor { NSEvent.removeMonitor(m) }
        if let m = mouseMonitor { NSEvent.removeMonitor(m) }
        keyMonitor = nil
        mouseMonitor = nil
    }
}
