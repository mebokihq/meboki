import AppKit
import MebokiCore
import SwiftUI

/// Onboarding window content: one page per step, and a footer with the step dots, Back and the main button.
struct OnboardingRootView: View {
    @ObservedObject var model: OnboardingModel
    @ObservedObject var settings: AppSettings
    @ObservedObject var store: ModelStore

    var body: some View {
        VStack(spacing: 0) {
            page
                .id(model.step)
                .transition(DS.Motion.reduceMotion ? .opacity : .asymmetric(
                    insertion: .opacity.combined(with: .offset(x: 24)), removal: .opacity))
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            DSSeparator()
            footer
        }
        .frame(width: OnboardingWindowController.size.width, height: OnboardingWindowController.size.height)
        .background(DS.window)
        .overlay(alignment: .bottom) {
            if let t = model.message {
                ToastView(kind: t.kind, title: t.title)
                    .environment(\.dsGlassBlending, .withinWindow)
                    .padding(.bottom, 76)
                    .transition(.dsPopIn)
                    .id(t.id)
            }
        }
        .environment(\.licenceGate, LicenceGate(locked: !settings.entitlement.isFull,
                                                open: { model.actions.openLicence() }))
        .ignoresSafeArea()
    }

    @ViewBuilder private var page: some View {
        switch model.step {
        case .welcome: WelcomePage()
        case .access: AccessPage(model: model)
        case .model: ModelPage(model: model, store: store)
        case .tryIt: TryPage(model: model, settings: settings)
        case .popup: PopupStylePage(settings: settings)
        case .done: DonePage(model: model, settings: settings)
        }
    }

    // MARK: Footer

    private var footer: some View {
        HStack(spacing: 10) {
            ProgressDots(dots: OnboardingStep.allCases.map { s in
                s == model.step ? .current : s.rawValue < model.step.rawValue ? .applied : .pending
            })
            .accessibilityElement()
            .accessibilityLabel("Step \(model.step.rawValue + 1) of \(OnboardingStep.allCases.count)")
            Spacer()
            if model.step != .welcome {
                Button("Back") { model.back() }.buttonStyle(.dsGhost)
            }
            mainButton
        }
        .padding(.horizontal, 28)
        .frame(height: 64)
    }

    @ViewBuilder private var mainButton: some View {
        switch model.step {
        case .welcome:
            Button("Get Started") { model.next() }
                .buttonStyle(.dsPrimary)
                .keyboardShortcut(.defaultAction)
        case .access:
            next(ready: model.trusted)
        case .model:
            next(ready: modelChosen)
        case .tryIt:
            // No Return shortcut here: Return belongs to the sample text field.
            Button("Continue") { model.next() }.buttonStyle(.dsPrimary)
        case .popup:
            Button("Continue") { model.next() }
                .buttonStyle(.dsPrimary)
                .keyboardShortcut(.defaultAction)
        case .done:
            Button("Finish") { model.actions.finish() }
                .buttonStyle(.dsPrimary)
                .keyboardShortcut(.defaultAction)
        }
    }

    /// "Continue" once the step is done; until then a quieter "Skip for now".
    @ViewBuilder private func next(ready: Bool) -> some View {
        if ready {
            Button("Continue") { model.next() }
                .buttonStyle(.dsPrimary)
                .keyboardShortcut(.defaultAction)
        } else {
            Button("Skip for now") { model.next() }.buttonStyle(.dsSecondary)
        }
    }

    /// A model is in use, downloading or being checked, or checks go to the cloud.
    private var modelChosen: Bool {
        if model.cloudModelName != nil { return true }
        guard let m = Catalog.byID(model.selectedModelID) else { return false }
        _ = store.installedVersion
        if store.isInstalled(m) { return true }
        switch store.state(m) {
        case .downloading, .verifying: return true
        case .paused, .failed, nil: return false
        }
    }
}

// MARK: - Shared pieces

/// Page title block: a 44 pt colored icon square, a 22 pt bold title and a secondary subtitle.
struct PageHeader: View {
    let symbol: String
    let color: UInt32
    let title: String
    let subtitle: String

    var body: some View {
        HStack(alignment: .top, spacing: 16) {
            let square = RoundedRectangle(cornerRadius: 11, style: .continuous)
            square.fill(Color(nsColor: .hex(color)))
                .overlay(InnerTopHighlight(shape: square, color: .white.opacity(0.3)))
                .overlay(Image(systemName: symbol).font(.system(size: 21, weight: .semibold)).foregroundStyle(DS.onAccent))
                .frame(width: 44, height: 44)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 5) {
                Text(title)
                    .font(.system(size: 22, weight: .bold))
                    .foregroundStyle(DS.text)
                    .accessibilityAddTraits(.isHeader)
                Text(subtitle)
                    .font(.system(size: 13.5))
                    .foregroundStyle(DS.textSecondary)
                    .lineSpacing(2)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.bottom, 22)
    }
}

/// A page's padding: below the title bar, 44 pt at the sides.
private struct PageBody<Content: View>: View {
    @ViewBuilder var content: Content
    var body: some View {
        VStack(alignment: .leading, spacing: 0) { content }
            .padding(EdgeInsets(top: 48, leading: 44, bottom: 16, trailing: 44))
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}

/// A numbered instruction: brand-tinted number circle and text.
private struct NumberedStep: View {
    let number: Int
    let text: String
    var done = false

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            ZStack {
                Circle().fill(done ? DS.ok.opacity(0.16) : DS.brandSoft)
                if done {
                    Image(systemName: "checkmark").font(.system(size: 10, weight: .bold)).foregroundStyle(DS.ok)
                } else {
                    Text("\(number)").font(.system(size: 11.5, weight: .bold)).foregroundStyle(DS.brand)
                }
            }
            .frame(width: 22, height: 22)
            .alignmentGuide(.firstTextBaseline) { $0[VerticalAlignment.center] + 4 }
            Text(text)
                .font(DS.Font.body)
                .foregroundStyle(DS.text)
                .fixedSize(horizontal: false, vertical: true)
        }
        .accessibilityElement(children: .combine)
    }
}

/// A rounded box with the settings group look.
struct Box<Content: View>: View {
    var padding: CGFloat = 14
    @ViewBuilder var content: Content
    var body: some View {
        let shape = RoundedRectangle(cornerRadius: DS.Radius.group, style: .continuous)
        content
            .padding(padding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(shape.fill(DS.group))
            .overlay(shape.strokeBorder(DS.separator, lineWidth: 0.5))
    }
}

private struct StatusLine: View {
    enum Kind { case ok, waiting, warning, plain }
    let kind: Kind
    let text: String

    var body: some View {
        HStack(spacing: 7) {
            switch kind {
            case .ok: Image(systemName: "checkmark.circle.fill").foregroundStyle(DS.ok)
            case .waiting: DSSpinner()
            case .warning: Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(DS.catPunctuation)
            case .plain: EmptyView()
            }
            Text(text)
                .font(kind == .ok ? DS.Font.bodySemibold : DS.Font.body)
                .foregroundStyle(kind == .ok ? DS.text : DS.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .font(.system(size: 14))
        .accessibilityElement(children: .combine)
    }
}

// MARK: - 1. Welcome

private struct WelcomePage: View {
    var body: some View {
        VStack(spacing: 0) {
            AppIconView(size: 84)
                .padding(.top, 52)
            Text("Welcome to Meboki")
                .font(.system(size: 26, weight: .bold))
                .foregroundStyle(DS.text)
                .padding(.top, 18)
                .accessibilityAddTraits(.isHeader)
            Text("Spelling and grammar fixes in the apps you already use.\nYour text stays on this Mac.")
                .font(.system(size: 14))
                .foregroundStyle(DS.textSecondary)
                .multilineTextAlignment(.center)
                .lineSpacing(3)
                .padding(.top, 8)
            VStack(alignment: .leading, spacing: 16) {
                feature("text.badge.checkmark", 0x0A84FF, "Underlines in any app",
                        "Mail, Notes, Slack, browsers and more. Click an underline to see the fix.")
                feature("keyboard", 0xFF375F, "One shortcut",
                        "Press \(AppSettings.shared.hotkey.display) to check the field you're typing in, or just the selected text.")
                feature("lock.shield", 0x30B850, "Private by design",
                        "An open model checks your text on this Mac. No account, no tracking.")
            }
            .frame(maxWidth: 440, alignment: .leading)
            .padding(.top, 34)
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity)
        .padding(.horizontal, 44)
    }

    private func feature(_ symbol: String, _ color: UInt32, _ title: String, _ text: String) -> some View {
        HStack(alignment: .top, spacing: 13) {
            let square = RoundedRectangle(cornerRadius: 8, style: .continuous)
            square.fill(Color(nsColor: .hex(color)))
                .overlay(InnerTopHighlight(shape: square, color: .white.opacity(0.3)))
                .overlay(Image(systemName: symbol).font(.system(size: 15, weight: .semibold)).foregroundStyle(DS.onAccent))
                .frame(width: 32, height: 32)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(DS.Font.bodySemibold).foregroundStyle(DS.text)
                Text(text).font(DS.Font.body).foregroundStyle(DS.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .accessibilityElement(children: .combine)
    }
}

// MARK: - 2. Accessibility

private struct AccessPage: View {
    @ObservedObject var model: OnboardingModel

    var body: some View {
        PageBody {
            PageHeader(symbol: "accessibility", color: 0x0A84FF, title: "Allow Accessibility access",
                       subtitle: "Meboki reads the text field you're typing in and writes the fixes you accept back into it. macOS asks you to allow this once.")
            HStack(alignment: .top, spacing: 24) {
                VStack(alignment: .leading, spacing: 13) {
                    NumberedStep(number: 1, text: "Click Open System Settings.", done: model.askedForAccess || model.trusted)
                    NumberedStep(number: 2, text: "Turn on Meboki in the Accessibility list. macOS may ask for your password.",
                                 done: model.trusted)
                    NumberedStep(number: 3, text: "Come back here. This page updates by itself.", done: model.trusted)
                    Group {
                        if model.trusted {
                            StatusLine(kind: .ok, text: "Access allowed")
                        } else {
                            VStack(alignment: .leading, spacing: 10) {
                                Button { model.actions.openAccessibility() } label: {
                                    DSLabel("Open System Settings", systemImage: "gearshape")
                                }
                                .buttonStyle(.dsPrimary)
                                .fixedSize()
                                if model.askedForAccess { StatusLine(kind: .waiting, text: "Waiting for access…") }
                            }
                        }
                    }
                    .padding(.top, 6)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                SettingsMock(trusted: model.trusted)
                    .frame(width: 236)
            }
            Spacer(minLength: 12)
            if model.askedForAccess && !model.trusted {
                Box(padding: 12) {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Not working?").font(DS.Font.bodySemibold).foregroundStyle(DS.text)
                        Text("Meboki isn't in the list: click +, then choose Meboki. The switch is on but this page doesn't change: select Meboki, remove it with −, and add it again.")
                            .font(DS.Font.caption)
                            .foregroundStyle(DS.textSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                        Button("Show Meboki in Finder") { model.actions.revealApp() }
                            .buttonStyle(.dsLinkStrong)
                            .padding(.leading, -6)
                    }
                }
                .padding(.bottom, 10)
            }
            SettingsFootnote(symbol: "lock.shield",
                             text: "Meboki never reads password fields, or anything while secure input is on.")
                .padding(.top, -12)
        }
    }
}

/// A small drawing of System Settings › Privacy & Security › Accessibility with Meboki's switch.
private struct SettingsMock: View {
    let trusted: Bool
    @State private var pulse = false

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 12, style: .continuous)
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 5) {
                ForEach([0xFF5F57, 0xFEBC2E, 0x28C840] as [UInt32], id: \.self) { c in
                    Circle().fill(Color(nsColor: .hex(c))).frame(width: 8, height: 8)
                }
            }
            .padding(.bottom, 10)
            HStack(spacing: 4) {
                Image(systemName: "chevron.left").font(.system(size: 10, weight: .semibold))
                Text("Accessibility").font(.system(size: 12, weight: .bold))
            }
            .foregroundStyle(DS.text)
            .padding(.bottom, 8)
            VStack(spacing: 0) {
                row(icon: AnyView(Image(systemName: "app.dashed").font(.system(size: 15)).foregroundStyle(DS.textTertiary)),
                    name: "Other app", on: true, highlight: false)
                DSSeparator()
                row(icon: AnyView(AppIconView(size: 18)), name: "Meboki", on: trusted, highlight: !trusted)
            }
            .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(DS.group))
            HStack(spacing: 10) {
                Text("+").font(.system(size: 13, weight: .medium))
                Text("−").font(.system(size: 13, weight: .medium))
            }
            .foregroundStyle(DS.textSecondary)
            .padding(.top, 6)
            .padding(.leading, 4)
        }
        .padding(12)
        .background(shape.fill(DS.field))
        .overlay(shape.strokeBorder(DS.separator, lineWidth: 0.5))
        .shadow(color: .black.opacity(0.08), radius: 8, x: 0, y: 4)
        .accessibilityElement()
        .accessibilityLabel(trusted ? "Meboki is turned on in the Accessibility list"
                            : "Turn on the switch next to Meboki in the Accessibility list")
        .onAppear {
            guard !DS.Motion.reduceMotion else { return }
            withAnimation(DS.Motion.menuPulse.speed(0.5)) { pulse = true }
        }
    }

    private func row(icon: AnyView, name: String, on: Bool, highlight: Bool) -> some View {
        HStack(spacing: 8) {
            icon.frame(width: 18, height: 18)
            Text(name).font(.system(size: 12, weight: highlight ? .semibold : .regular)).foregroundStyle(DS.text)
            Spacer(minLength: 0)
            Toggle(isOn: .constant(on)) { EmptyView() }
                .toggleStyle(.dsSwitch)
                .scaleEffect(0.8)
                .allowsHitTesting(false)
                .overlay {
                    if highlight {
                        Capsule().strokeBorder(DS.brand, lineWidth: 2)
                            .frame(width: 38, height: 24)
                            .opacity(pulse ? 1 : 0.25)
                    }
                }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
    }
}

// MARK: - 3. Model

private struct ModelPage: View {
    @ObservedObject var model: OnboardingModel
    @ObservedObject var store: ModelStore

    private var picked: ModelInfo { Catalog.byID(model.pickedModelID) ?? Catalog.recommended }
    /// The two defaults, plus the model in use when it's another one (Welcome Guide reopened later).
    private var models: [ModelInfo] {
        var list = Catalog.onboarding
        if let m = Catalog.byID(model.selectedModelID), !list.contains(m) { list.append(m) }
        return list
    }

    var body: some View {
        PageBody {
            PageHeader(symbol: "cpu", color: 0xAF52DE, title: "Download the writing model",
                       subtitle: "Meboki checks your text with an open model that runs on this Mac. It downloads once; after that, checks work offline.")
            VStack(spacing: 10) {
                ForEach(models, id: \.id) { m in
                    ModelCard(info: m, picked: m.id == model.pickedModelID,
                              inUse: model.cloudModelName == nil && m.id == model.selectedModelID,
                              installed: installed(m)) {
                        model.pickedModelID = m.id
                    }
                }
            }
            HStack(spacing: 6) {
                Image(systemName: "memorychip")
                Text("This Mac has \(Catalog.ramGB) GB of memory. "
                     + "\(Catalog.recommended.shortName) suits it best.")
            }
            .font(DS.Font.caption)
            .foregroundStyle(DS.textSecondary)
            .padding(.top, 10)
            .padding(.leading, 4)
            actionRow.padding(.top, 18)
            Spacer(minLength: 0)
            SettingsFootnote(symbol: "cloud",
                             text: "Prefer a cloud model with your own OpenRouter or OpenAI key? Your text then leaves this Mac.") {
                Button("Set up in Settings") { model.actions.openSettings(.models) }.buttonStyle(.dsLink)
            }
        }
    }

    private func installed(_ m: ModelInfo) -> Bool {
        _ = store.installedVersion
        return store.isInstalled(m)
    }

    /// The button and status for the picked model.
    @ViewBuilder private var actionRow: some View {
        let m = picked
        HStack(spacing: 12) {
            switch store.state(m) {
            case .downloading(let w, let t):
                downloadProgress(m, written: w, total: t, paused: false)
                Button("Pause") { model.actions.pause(m) }.buttonStyle(.dsSecondary)
            case .paused(let w, let t):
                downloadProgress(m, written: w, total: t, paused: true)
                Button("Resume") { model.actions.useModel(m) }.buttonStyle(.dsPrimary)
            case .verifying:
                StatusLine(kind: .waiting, text: "Checking the file (SHA-256)…")
            case .failed(let message):
                StatusLine(kind: .warning, text: message)
                Spacer(minLength: 0)
                Button("Try Again") { model.actions.useModel(m) }.buttonStyle(.dsPrimary)
            case nil:
                if installed(m) {
                    if model.cloudModelName == nil, m.id == model.selectedModelID {
                        StatusLine(kind: .ok, text: readyText(m))
                    } else {
                        if let cloud = model.cloudModelName {
                            StatusLine(kind: .plain, text: "Checks use \(cloud) (cloud) now.")
                        }
                        Button("Use \(m.shortName)") { model.actions.useModel(m) }.buttonStyle(.dsPrimary)
                    }
                } else {
                    Button { model.actions.useModel(m) } label: {
                        DSLabel("Download " + String(format: "%.1f GB", Double(m.bytes) / 1e9),
                                systemImage: "arrow.down.to.line")
                    }
                    .buttonStyle(.dsPrimary)
                    .disabled(!enoughSpace(m))
                    diskLine(m)
                }
            }
        }
        .frame(minHeight: 34)
    }

    private func readyText(_ m: ModelInfo) -> String {
        switch model.engine {
        case .loading: "\(m.shortName) is downloaded · loading…"
        case .failed(let msg): "\(m.shortName) is downloaded, but it didn't start: \(msg)"
        default: "\(m.shortName) is ready"
        }
    }

    private func downloadProgress(_ m: ModelInfo, written: Int64, total: Int64, paused: Bool) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            DSMeter(value: total > 0 ? Double(written) / Double(total) : 0, height: 6)
            Text((paused ? "Paused · " : "Downloading \(m.shortName) · ") + Self.progressText(written: written, total: total)
                 + (paused ? "" : " · you can continue meanwhile"))
                .font(DS.Font.footnote)
                .monospacedDigit()
                .foregroundStyle(DS.textSecondary)
        }
        .frame(maxWidth: .infinity)
    }

    private func enoughSpace(_ m: ModelInfo) -> Bool {
        guard let free = ModelStore.freeSpace else { return true }
        return free >= m.bytes + ModelStore.spaceMargin
    }

    @ViewBuilder private func diskLine(_ m: ModelInfo) -> some View {
        if let free = ModelStore.freeSpace {
            let ok = free >= m.bytes + ModelStore.spaceMargin
            Text(ok ? String(format: "%.0f GB free on this Mac", Double(free) / 1e9)
                    : String(format: "Not enough space: %.1f GB free, needs %.1f GB", Double(free) / 1e9,
                             Double(m.bytes + ModelStore.spaceMargin) / 1e9))
                .font(DS.Font.caption)
                .foregroundStyle(ok ? DS.textSecondary : DS.catSpelling)
        }
    }

    /// "53% · 1.51 of 2.84 GB".
    static func progressText(written: Int64, total: Int64) -> String {
        let pct = total > 0 ? Int((Double(written) / Double(total) * 100).rounded(.down)) : 0
        return "\(pct)% · " + String(format: "%.2f of %.2f GB", Double(written) / 1e9, Double(total) / 1e9)
    }
}

private struct ModelCard: View {
    let info: ModelInfo
    let picked: Bool
    let inUse: Bool
    let installed: Bool
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: DS.Radius.group, style: .continuous)
        Button(action: action) {
            HStack(spacing: 14) {
                RadioDot(isOn: picked)
                ModelGlyph(modelID: info.id, initial: String(info.shortName.prefix(1)), size: 34)
                    .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text(info.shortName).font(DS.Font.bodySemibold).foregroundStyle(DS.text)
                        if info == Catalog.recommended { Pill("Recommended for this Mac", kind: .brand) }
                        if inUse && installed { Pill("In use", kind: .success) } else if installed { Pill("Downloaded") }
                    }
                    Text(detail)
                        .font(DS.Font.caption)
                        .foregroundStyle(DS.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
                Text(String(format: "%.1f GB", Double(info.bytes) / 1e9))
                    .font(DS.Font.small)
                    .monospacedDigit()
                    .foregroundStyle(DS.textSecondary)
            }
            .padding(.vertical, 11)
            .padding(.horizontal, 14)
            .background(shape.fill(hovering && !picked ? DS.hover : DS.group))
            .overlay(shape.strokeBorder(picked ? DS.brand : DS.separator, lineWidth: picked ? 2 : 0.5))
            .contentShape(shape)
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .accessibilityLabel(info.shortName + (info == Catalog.recommended ? ", recommended" : ""))
        .accessibilityValue(detail)
        .accessibilityAddTraits(picked ? [.isButton, .isSelected] : .isButton)
    }

    private var detail: String {
        return "\(info.tagline) · fixed \(info.errorsFixed) of 45 test mistakes · "
            + String(format: "%.1f s per paragraph · uses %g GB of memory", info.paragraphSeconds,
                     (info.peakMemoryGB * 10).rounded() / 10)
            + " · for Macs with \(info.recommendedMinRAMGB) GB+"
    }
}

// MARK: - 4. Try it

private struct TryPage: View {
    @ObservedObject var model: OnboardingModel
    @ObservedObject var settings: AppSettings
    @State private var sample = OnboardingModel.sample
    @State private var task: Task<Void, Never>?

    var body: some View {
        PageBody {
            PageHeader(symbol: "text.badge.checkmark", color: 0xFF375F, title: "Try it",
                       subtitle: "Check the sample below, or type a sentence of your own.")
            editor
            HStack(spacing: 12) {
                Button { check() } label: { DSLabel("Check", systemImage: "checkmark") }
                    .buttonStyle(.dsPrimary)
                    .disabled(!model.engine.isReady || model.tryState == .checking
                              || sample.rangeOfCharacter(from: .letters) == nil)
                engineLine
            }
            .padding(.top, 10)
            result.padding(.top, 12)
            Spacer(minLength: 10)
            Box(padding: 0) {
                VStack(spacing: 0) {
                    SettingsRow("Now in any app", subtitle: "Click into a text field and press the shortcut") {
                        KeyField(glyphs: settings.hotkey.glyphs)
                    }
                    SettingsDivider()
                    SettingsRow("Practice note", subtitle: "A note with a few mistakes, in TextEdit") {
                        Button("Open in TextEdit") { model.actions.openPractice() }.buttonStyle(.ds(.secondary, small: true))
                    }
                }
            }
        }
        .onDisappear { task?.cancel() }
    }

    private var editor: some View {
        let shape = RoundedRectangle(cornerRadius: 12, style: .continuous)
        return TextField("Type a sentence", text: $sample, axis: .vertical)
            .textFieldStyle(.plain)
            .font(.system(size: 15))
            .lineLimit(2...4)
            .lineSpacing(3)
            .foregroundStyle(DS.text)
            .padding(12)
            .background(shape.fill(DS.field))
            .overlay(shape.strokeBorder(DS.separator, lineWidth: 0.5))
            .onSubmit { if model.engine.isReady { check() } }
            .onChange(of: sample) { _, _ in if case .done = model.tryState { model.tryState = .idle } }
            .accessibilityLabel("Sample text")
    }

    @ViewBuilder private var engineLine: some View {
        switch model.engine {
        case .ready(let name, let cloud):
            if model.tryState == .checking {
                StatusLine(kind: .waiting, text: "Checking with \(name)…")
            } else {
                PrivacyLine(text: cloud ? "Sent to \(name) (cloud)" : "On this Mac · \(name)",
                            symbol: cloud ? "cloud" : "lock")
            }
        case .loading(let name):
            StatusLine(kind: .waiting, text: "Loading \(name)…")
        case .downloading(let name, let f):
            StatusLine(kind: .waiting, text: "Downloading \(name) · \(Int(f * 100))%. Check works when it's done.")
        case .needsModel:
            HStack(spacing: 8) {
                StatusLine(kind: .warning, text: "No model yet.")
                Button("Choose one") { model.go(.model) }.buttonStyle(.dsLinkStrong)
            }
        case .failed(let msg):
            StatusLine(kind: .warning, text: "The model didn't start: \(msg)")
        }
    }

    @ViewBuilder private var result: some View {
        switch model.tryState {
        case .idle, .checking:
            EmptyView()
        case .failed(let msg):
            StatusLine(kind: .warning, text: "Check failed: \(msg)")
        case .done(let text, let edits, let seconds):
            if edits.isEmpty {
                StatusLine(kind: .ok, text: "No mistakes found · " + String(format: "%.1f s", seconds))
            } else {
                Box(padding: 12) {
                    VStack(alignment: .leading, spacing: 9) {
                        Text(Self.underlined(text, edits))
                            .font(.system(size: 15))
                            .lineSpacing(3)
                            .fixedSize(horizontal: false, vertical: true)
                        FlowChips(edits: edits, text: text)
                        Text("\(edits.count) fix\(edits.count == 1 ? "" : "es") in " + String(format: "%.1f s", seconds)
                             + ". In other apps these show as underlines; click one to apply it.")
                            .font(DS.Font.caption)
                            .foregroundStyle(DS.textSecondary)
                    }
                }
            }
        }
    }

    private func check() {
        let text = sample
        task?.cancel()
        model.tryState = .checking
        let started = Date()
        task = Task { @MainActor in
            do {
                let edits = try await model.actions.tryCheck(text)
                guard !Task.isCancelled else { return }
                model.tryState = .done(text: text, edits: edits, seconds: Date().timeIntervalSince(started))
            } catch {
                guard !Task.isCancelled else { return }
                model.tryState = .failed(error.localizedDescription)
            }
        }
    }

    /// The text with each fix underlined in its category color.
    static func underlined(_ text: String, _ edits: [Edit]) -> AttributedString {
        var a = AttributedString(text)
        a.foregroundColor = DS.text
        for e in edits where e.range.length > 0 {
            guard let r = Range(e.range, in: text), let ar = Range(r, in: a) else { continue }
            let color = FixClassifier.classify(e, in: text).color
            a[ar].underlineStyle = Text.LineStyle(pattern: .solid, color: color)
            a[ar].backgroundColor = color.opacity(0.12)
        }
        return a
    }
}

/// The fixes of the sample as "category · old → new" chips, wrapped.
private struct FlowChips: View {
    let edits: [Edit]
    let text: String

    var body: some View {
        WrapLayout(spacing: 6) {
            ForEach(edits.indices, id: \.self) { i in
                let e = edits[i]
                let cat = FixClassifier.classify(e, in: text)
                HStack(spacing: 5) {
                    Circle().fill(cat.color).frame(width: 7, height: 7)
                    swap(e)
                }
                .font(DS.Font.small)
                .padding(EdgeInsets(top: 3, leading: 7, bottom: 3, trailing: 9))
                .background(Capsule().fill(cat.color.opacity(0.12)))
                .accessibilityElement(children: .combine)
                .accessibilityLabel("\(cat.title): \(e.original) to \(e.replacement)")
            }
        }
    }

    @ViewBuilder private func swap(_ e: Edit) -> some View {
        let old = e.original.trimmingCharacters(in: .whitespaces)
        let new = e.replacement.trimmingCharacters(in: .whitespaces)
        if old.isEmpty {
            Text("+ " + new).foregroundStyle(DS.text)
        } else if new.isEmpty {
            Text(old).strikethrough().foregroundStyle(DS.textSecondary)
        } else {
            (Text(old).foregroundColor(DS.textSecondary) + Text(" → ").foregroundColor(DS.textTertiary)
                + Text(new).foregroundColor(DS.text).fontWeight(.semibold))
        }
    }
}

/// Lays out views left to right, wrapping to a new line when the row is full.
private struct WrapLayout: Layout {
    var spacing: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? .infinity
        var x: CGFloat = 0, y: CGFloat = 0, line: CGFloat = 0, widest: CGFloat = 0
        for s in subviews {
            let size = s.sizeThatFits(.unspecified)
            if x > 0, x + size.width > width {
                y += line + spacing
                x = 0
                line = 0
            }
            x += size.width + spacing
            line = max(line, size.height)
            widest = max(widest, x - spacing)
        }
        return CGSize(width: proposal.width ?? widest, height: y + line)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX, y = bounds.minY, line: CGFloat = 0
        for s in subviews {
            let size = s.sizeThatFits(.unspecified)
            if x > bounds.minX, x + size.width > bounds.maxX {
                y += line + spacing
                x = bounds.minX
                line = 0
            }
            s.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
            x += size.width + spacing
            line = max(line, size.height)
        }
    }
}

// MARK: - 5. Popup style

/// The correction popup: a live preview of the picked style, and the three styles to pick from.
private struct PopupStylePage: View {
    @ObservedObject var settings: AppSettings
    @Environment(\.licenceGate) private var gate
    @State private var lockedPopover: PopupStyle?

    var body: some View {
        PageBody {
            PageHeader(symbol: "rectangle.on.rectangle", color: 0xFF9F0A, title: "Choose how fixes appear",
                       subtitle: "Pick a style to see it in action. You can change it any time in Settings › General.")
            PopupPreview(style: gate.locked ? .card : settings.popupStyle, reasons: settings.explainFixes)
                .dsShadow(DS.windowShadow)
            HStack(spacing: 10) {
                ForEach(PopupStyle.allCases, id: \.self) { s in
                    // Free mode: only the glass card can be picked; the others are locked (the stored choice stays).
                    let locked = gate.locked && s != .card
                    StyleChoice(style: s, selected: gate.locked ? s == .card : s == settings.popupStyle,
                                locked: locked) {
                        if locked { lockedPopover = s } else { settings.popupStyle = s }
                    }
                    .popover(isPresented: Binding(get: { lockedPopover == s },
                                                  set: { if !$0 && lockedPopover == s { lockedPopover = nil } }),
                             arrowEdge: .bottom) {
                        NeedsLicencePopover(open: gate.open) { lockedPopover = nil }
                    }
                }
            }
            .padding(.top, 16)
        }
    }
}

private struct StyleChoice: View {
    let style: PopupStyle
    let selected: Bool
    var locked = false
    let action: () -> Void
    @State private var hovering = false

    private var subtitle: String {
        switch style {
        case .card: "Opens when you click an underline"
        case .bubble: "Small card pointing at the word"
        case .island: "Appears under the menu bar by itself"
        }
    }

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: DS.Radius.suggestion, style: .continuous)
        Button(action: action) {
            HStack(alignment: .top, spacing: 9) {
                if locked {
                    // Free mode: a lock where the radio dot would be.
                    Image(systemName: "lock.fill").font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(DS.textSecondary).frame(width: 16, height: 16).padding(.top, 1)
                } else {
                    RadioDot(isOn: selected).padding(.top, 1)
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text(style.title).font(DS.Font.bodySemibold).foregroundStyle(DS.text)
                    Text(subtitle).font(DS.Font.caption).foregroundStyle(DS.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .opacity(locked ? 0.5 : 1)
                Spacer(minLength: 0)
            }
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(shape.fill(hovering && !selected ? DS.hover : DS.group))
            .overlay(shape.strokeBorder(selected ? DS.brand : DS.separator, lineWidth: selected ? 2 : 0.5))
            .contentShape(shape)
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .accessibilityLabel(locked ? "\(style.title), needs a licence" : style.title)
        .accessibilityHint(subtitle)
        .accessibilityAddTraits(selected ? [.isButton, .isSelected] : .isButton)
    }
}

// MARK: - 6. Done

private struct DonePage: View {
    @ObservedObject var model: OnboardingModel
    @ObservedObject var settings: AppSettings
    @ObservedObject private var updates = UpdateController.shared

    var body: some View {
        PageBody {
            PageHeader(symbol: "checkmark", color: 0x30B850, title: "You're all set",
                       subtitle: "Meboki lives in the menu bar. Click its icon for status and quick switches; right-click it for more.")
            if !missing.isEmpty {
                Box(padding: 0) {
                    VStack(spacing: 0) {
                        ForEach(missing.indices, id: \.self) { i in
                            if i > 0 { SettingsDivider() }
                            missing[i]
                        }
                    }
                }
                .padding(.bottom, 16)
            }
            Box(padding: 0) {
                VStack(spacing: 0) {
                    SettingsRow("Underline mistakes as I type",
                                subtitle: "Checks text areas after you pause typing (local model)") {
                        SettingsSwitch(isOn: $settings.underlineAsYouType, label: "Underline mistakes as I type")
                            .licenceLocked(.automaticCheck)
                    }
                    SettingsDivider()
                    SettingsRow("Launch at login", subtitle: "Start Meboki when you log in") {
                        SettingsSwitch(isOn: launchBinding, label: "Launch at login")
                    }
                    // Official builds only. On from the start, so it is said here, before the first check.
                    if updates.isEnabled {
                        SettingsDivider()
                        SettingsRow(UpdateText.automaticChecks, subtitle: "Once a day. Nothing about you is sent") {
                            SettingsSwitch(isOn: $updates.automaticChecks, label: UpdateText.automaticChecks)
                        }
                    }
                }
            }
            licenceCard.padding(.top, 14)
            Spacer(minLength: 0)
            SettingsFootnote(symbol: "gearshape", text: "Everything else is in Settings: languages, apps, models and shortcuts.") {
                Button("Open Settings") { model.actions.openSettings(.general) }.buttonStyle(.dsLink)
            }
        }
    }

    // MARK: Licence card (PLAN.md §6 "Where the user meets the paywall")

    private var hotkey: String { settings.hotkey.display }

    @ViewBuilder private var licenceCard: some View {
        switch settings.entitlement {
        case .licensed(let info):
            LicenceCard(symbol: "checkmark.seal.fill", tint: DS.ok, title: "Licensed to \(info.email)",
                        text: "Everything is unlocked. Thank you.")
        case .trial(let left):
            LicenceCard(symbol: "sparkles", tint: DS.brand,
                        title: left >= 7 ? "Everything is unlocked for 7 days"
                            : left <= 1 ? "Everything is unlocked · last trial day"
                            : "Everything is unlocked · \(left) trial days left",
                        text: "Only days you check text count. After that Meboki keeps working in free mode: \(hotkey) checks any field, with every model, for as long as you like. No account, no card.") {
                Button("I have a licence key") { model.actions.openLicence() }.buttonStyle(.dsLink).padding(.leading, -6)
            }
        case .free:
            LicenceCard(symbol: "lock.fill", tint: DS.textSecondary, title: "Free mode",
                        text: "\(hotkey) checks any field, with every model. Underlines as you type and the bubble and island popups need a licence.") {
                Button("See Licence") { model.actions.openLicence() }.buttonStyle(.dsLink).padding(.leading, -6)
            }
        }
    }

    /// Rows for what still keeps checks from working.
    private var missing: [AnyView] {
        var rows: [AnyView] = []
        if !model.trusted {
            rows.append(AnyView(SettingsRow("Accessibility access is off", subtitle: "Meboki can't read text fields without it") {
                Button("Allow…") { model.go(.access) }.buttonStyle(.ds(.primary, small: true))
            }))
        }
        switch model.engine {
        case .needsModel, .failed:
            rows.append(AnyView(SettingsRow("No model yet", subtitle: "Checks need a downloaded model or a cloud key") {
                Button("Choose…") { model.go(.model) }.buttonStyle(.ds(.primary, small: true))
            }))
        default:
            break
        }
        return rows
    }

    private var launchBinding: Binding<Bool> {
        Binding(get: { model.launchAtLogin }, set: { on in
            if let error = model.actions.setLaunchAtLogin(on) { model.showMessage(.warning, error) }
        })
    }
}

extension OnboardingModel {
    /// The "Try it" sample: a few common mistakes the default models fix.
    static let sample = "Their going to the libary tomorow, but she dont know were it is."
}

/// The Done page's licence card: a tinted badge, a title, one paragraph and an optional quiet link.
private struct LicenceCard<Extra: View>: View {
    let symbol: String
    let tint: Color
    let title: String
    let text: String
    @ViewBuilder var extra: Extra

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Circle().fill(tint.opacity(0.16))
                .overlay(Image(systemName: symbol).font(.system(size: 14, weight: .semibold)).foregroundStyle(tint))
                .frame(width: 32, height: 32)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(DS.Font.bodySemibold).foregroundStyle(DS.text)
                Text(text)
                    .font(DS.Font.link)
                    .foregroundStyle(DS.textSecondary)
                    .lineSpacing(1.5)
                    .fixedSize(horizontal: false, vertical: true)
                extra
            }
            Spacer(minLength: 0)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: DS.Radius.group, style: .continuous).fill(tint.opacity(0.07)))
        .accessibilityElement(children: .contain)
    }
}

extension LicenceCard where Extra == EmptyView {
    init(symbol: String, tint: Color, title: String, text: String) {
        self.init(symbol: symbol, tint: tint, title: title, text: text) { EmptyView() }
    }
}
