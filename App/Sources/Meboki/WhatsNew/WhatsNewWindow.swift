import AppKit
import MebokiCore
import SwiftUI

/// The "What's new" window (design_code.md §8.12): opens once after an update, lists what changed since the
/// version the user ran before (several versions when one was skipped, newest first). Onboarding chrome, shown
/// without activating Meboki, so the keyboard stays in the app the user is typing in.
struct WhatsNewView: View {
    let from: String?
    let releases: [WhatsNewRelease]
    /// The folder that holds `whatsnew.json` and its images.
    let folder: URL?
    /// The changelog (About › Changelog): every release, titled "Changelog".
    var changelog = false
    /// The window height; nil while measuring (no scroll view, content at its natural height).
    var height: CGFloat? = nil
    let onContinue: () -> Void

    private var current: String { releases.first?.version ?? "" }

    var body: some View {
        VStack(spacing: 0) {
            header
            Rectangle().fill(DS.separator).frame(height: 0.5)
            if height == nil {
                content
            } else {
                ScrollView { content }
            }
            Rectangle().fill(DS.separator).frame(height: 0.5)
            footer
        }
        .frame(width: WhatsNewWindowController.width, height: height)
        .background(DS.window)
        .ignoresSafeArea()
    }

    private var content: some View {
        VStack(alignment: .leading, spacing: 22) {
            ForEach(releases, id: \.version) { section($0) }
        }
        .padding(EdgeInsets(top: 18, leading: 28, bottom: 22, trailing: 28))
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var header: some View {
        HStack(spacing: 16) {
            Image(nsImage: WhatsNewContent.appIcon)
                .resizable()
                .frame(width: 60, height: 60)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 3) {
                Text(changelog ? "Meboki changelog" : "What's new in Meboki \(current)")
                    .font(.system(size: 22, weight: .bold))
                    .foregroundStyle(DS.text)
                    .accessibilityAddTraits(.isHeader)
                Text(changelog ? WhatsNew.changelogSubtitle(releases) : WhatsNew.subtitle(from: from, releases: releases))
                    .font(.system(size: 13))
                    .foregroundStyle(DS.textSecondary)
                    .monospacedDigit()
            }
            Spacer(minLength: 0)
        }
        .padding(EdgeInsets(top: 38, leading: 26, bottom: 16, trailing: 28))
    }

    @ViewBuilder
    private func section(_ r: WhatsNewRelease) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            if releases.count > 1 || changelog {
                HStack(spacing: 6) {
                    Text("VERSION \(r.version)").font(DS.Font.chip).tracking(0.6).foregroundStyle(DS.textSecondary)
                    Text("· \(r.displayDate)").font(DS.Font.small).foregroundStyle(DS.textTertiary)
                }
                .monospacedDigit()
                .accessibilityElement(children: .combine)
                .accessibilityAddTraits(.isHeader)
            }
            ForEach(Array(r.highlights.enumerated()), id: \.offset) { _, h in highlight(h) }
            if !r.items.isEmpty {
                VStack(spacing: 0) {
                    ForEach(Array(r.items.enumerated()), id: \.offset) { i, item in
                        if i > 0 { Rectangle().fill(DS.separator).frame(height: 0.5).padding(.leading, 14) }
                        HStack(alignment: .firstTextBaseline, spacing: 10) {
                            KindTag(kind: item.kind).frame(width: 78, alignment: .leading)
                            Text(item.text).font(DS.Font.body).foregroundStyle(DS.text)
                                .lineSpacing(2)
                                .fixedSize(horizontal: false, vertical: true)
                            Spacer(minLength: 0)
                        }
                        .padding(.horizontal, 14)
                        .padding(.vertical, 9)
                        .accessibilityElement(children: .combine)
                    }
                }
                .background(RoundedRectangle(cornerRadius: DS.Radius.group, style: .continuous).fill(DS.group))
            }
        }
    }

    private func highlight(_ h: WhatsNewHighlight) -> some View {
        HStack(alignment: .top, spacing: 12) {
            let square = RoundedRectangle(cornerRadius: 9, style: .continuous)
            square.fill(KindTag.color(h.kind))
                .overlay(InnerTopHighlight(shape: square, color: .white.opacity(0.3)))
                .overlay(Image(systemName: h.symbol ?? KindTag.symbol(h.kind))
                    .font(.system(size: 16, weight: .semibold)).foregroundStyle(DS.onAccent))
                .frame(width: 36, height: 36)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 4) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(h.title).font(.system(size: 14, weight: .semibold)).foregroundStyle(DS.text)
                        .fixedSize(horizontal: false, vertical: true)
                    if h.kind != .new { KindTag(kind: h.kind) }
                }
                Text(h.body).font(DS.Font.body).foregroundStyle(DS.textSecondary)
                    .lineSpacing(2.5)
                    .fixedSize(horizontal: false, vertical: true)
                if let name = h.image, let image = loadImage(name) {
                    Image(nsImage: image)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .frame(maxHeight: 220)
                        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(DS.separator, lineWidth: 0.5))
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.top, 6)
                        .accessibilityLabel(h.title)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .accessibilityElement(children: .combine)
    }

    private func loadImage(_ name: String) -> NSImage? {
        guard let folder, !name.contains("..") else { return nil }
        return NSImage(contentsOf: folder.appendingPathComponent(name))
    }

    private var footer: some View {
        HStack(spacing: 12) {
            Text(changelog ? "Every release, newest first. Also in Settings › About."
                           : "Right-click the Meboki icon › What’s New… shows this again.")
                .font(DS.Font.caption)
                .foregroundStyle(DS.textSecondary)
                .lineLimit(1)
                .minimumScaleFactor(0.85)
            Spacer(minLength: 0)
            Button { onContinue() } label: { DSLabel(changelog ? "Done" : "Continue", kbd: "⏎") }
                .buttonStyle(.dsPrimary)
                .keyboardShortcut(.defaultAction)
        }
        .padding(.horizontal, 24)
        .frame(height: 60)
    }
}

/// "New", "Improved", "Fixed": a capsule with a dot in the kind's color.
struct KindTag: View {
    let kind: WhatsNewKind

    var body: some View {
        HStack(spacing: 5) {
            Circle().fill(Self.color(kind)).frame(width: 6, height: 6)
            Text(kind.label).font(DS.Font.pill)
        }
        .foregroundStyle(Self.color(kind))
        .padding(EdgeInsets(top: 2, leading: 6, bottom: 2, trailing: 8))
        .background(Capsule().fill(Self.color(kind).opacity(0.14)))
        .fixedSize()
    }

    /// Not the brand or a mistake category (design rule 3): indigo, teal, green.
    static func color(_ kind: WhatsNewKind) -> Color {
        switch kind {
        case .new: Color(nsColor: .hex(0x5E5CE6))
        case .improved: Color(nsColor: .hex(0x30B0C7))
        case .fixed: DS.ok
        }
    }

    static func symbol(_ kind: WhatsNewKind) -> String {
        switch kind {
        case .new: "sparkles"
        case .improved: "arrow.up.circle"
        case .fixed: "checkmark"
        }
    }
}

/// Where the content lives: `Contents/Resources/WhatsNew/` in the app; in a DEBUG run from `.build`, the
/// source folder `App/WhatsNew/`.
enum WhatsNewContent {
    static var folder: URL? {
        if let res = Bundle.main.resourceURL?.appendingPathComponent("WhatsNew"),
           FileManager.default.fileExists(atPath: res.appendingPathComponent(WhatsNew.fileName).path) {
            return res
        }
        #if DEBUG
        let src = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("WhatsNew")
        if FileManager.default.fileExists(atPath: src.appendingPathComponent(WhatsNew.fileName).path) { return src }
        #endif
        return nil
    }

    /// Every entry in the file; empty when it is missing or can't be read.
    static func load() -> [WhatsNewRelease] {
        guard let url = folder?.appendingPathComponent(WhatsNew.fileName),
              let data = try? Data(contentsOf: url) else { return [] }
        do { return try WhatsNew.decode(data) } catch {
            Log.write("whats-new: \(WhatsNew.fileName) can't be read: \(error)")
            return []
        }
    }

    /// The app icon; in a DEBUG run from `.build` (no bundle icon) the one in `App/Art/`.
    static var appIcon: NSImage {
        #if DEBUG
        if Bundle.main.bundleURL.pathExtension != "app" {
            let src = URL(fileURLWithPath: #filePath)
                .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
                .deletingLastPathComponent().appendingPathComponent("Art/AppIcon.icns")
            if let image = NSImage(contentsOf: src) { return image }
        }
        #endif
        return NSApp.applicationIconImage
    }

    static var currentVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? ""
    }
}

/// The window. Comes to the front without activating Meboki (like the licence notice); the app becomes a
/// regular app while it is open (Dock icon), which doesn't activate it either.
@MainActor
final class WhatsNewWindowController: NSObject, NSWindowDelegate {
    static let width: CGFloat = 560
    /// The window fits its content between these heights; longer notes scroll.
    static let minHeight: CGFloat = 320
    static let maxHeight: CGFloat = 620

    private var window: NSWindow?
    private let from: String?
    private let releases: [WhatsNewRelease]
    private let folder: URL?
    private let changelog: Bool
    var onClose: (() -> Void)?
    private lazy var mainMenu = AppMenus.windowMenu(appName: "Meboki")

    init(from: String?, releases: [WhatsNewRelease], folder: URL?, changelog: Bool = false) {
        self.from = from
        self.releases = releases
        self.folder = folder
        self.changelog = changelog
        super.init()
    }

    func matches(releases: [WhatsNewRelease], changelog: Bool) -> Bool {
        self.releases == releases && self.changelog == changelog
    }

    var isVisible: Bool { window?.isVisible == true }
    var windowNumber: Int { window?.windowNumber ?? -1 }
    #if DEBUG
    var debugWindow: NSWindow? { window }
    #endif

    /// `activate`: opened from the menu (the user asked for it), so it may take the keyboard.
    func show(activate: Bool = false) {
        let w = window ?? makeWindow()
        window = w
        if !w.isVisible { w.center() }
        if NSApp.activationPolicy() != .regular { NSApp.setActivationPolicy(.regular) }
        if activate {
            NSApp.activate(ignoringOtherApps: true)
            w.makeKeyAndOrderFront(nil)
        } else {
            w.orderFrontRegardless()
        }
    }

    func close() { window?.close() }

    private func makeWindow() -> NSWindow {
        let measure = NSHostingView(rootView: WhatsNewView(from: from, releases: releases, folder: folder, changelog: changelog) {})
        let height = min(Self.maxHeight, max(Self.minHeight, ceil(measure.fittingSize.height)))
        let size = NSSize(width: Self.width, height: height)
        let view = WhatsNewView(from: from, releases: releases, folder: folder, changelog: changelog, height: height) { [weak self] in self?.close() }
        let host = FirstClickHostingView(rootView: view)
        host.sizingOptions = []
        let w = NSWindow(contentRect: NSRect(origin: .zero, size: size),
                         styleMask: [.titled, .closable, .fullSizeContentView],
                         backing: .buffered, defer: false)
        w.title = changelog ? "Meboki Changelog" : "What's New in Meboki"
        w.titleVisibility = .hidden
        w.titlebarAppearsTransparent = true
        w.isReleasedWhenClosed = false
        w.isMovableByWindowBackground = true
        w.collectionBehavior = [.fullScreenAuxiliary, .moveToActiveSpace]
        w.backgroundColor = NSColor(DS.window)
        w.standardWindowButton(.miniaturizeButton)?.isHidden = true
        w.standardWindowButton(.zoomButton)?.isHidden = true
        w.delegate = self
        w.contentView = host
        w.setContentSize(size)
        return w
    }

    func windowDidBecomeKey(_ notification: Notification) { NSApp.mainMenu = mainMenu }

    func windowDidResignKey(_ notification: Notification) {
        if NSApp.mainMenu === mainMenu { NSApp.mainMenu = nil }
    }

    func windowWillClose(_ notification: Notification) {
        if NSApp.mainMenu === mainMenu { NSApp.mainMenu = nil }
        AppMenus.windowClosed(window)
        onClose?()
    }
}

#if DEBUG
/// DEBUG `--whats-new-demo [--from <version>|--from-none] [--current <version>] [--changelog] [--dark]`: the window with the
/// shipped content, as after an update from `--from` (default: the second entry) to `--current` (default: the
/// newest entry). `MEBOKI_DEMO_SNAPSHOT=<png>` draws it into a file.
@MainActor
enum WhatsNewDemo {
    private static var controller: WhatsNewWindowController?

    static func show(_ args: [String]) {
        NSApp.appearance = NSAppearance(named: args.contains("--dark") ? .darkAqua : .aqua)
        func value(_ flag: String) -> String? {
            args.firstIndex(of: flag).flatMap { args.indices.contains($0 + 1) ? args[$0 + 1] : nil }
        }
        let all = WhatsNewContent.load()
        let current = value("--current") ?? all.first?.version ?? "1.0.0"
        let from = args.contains("--from-none") ? nil : (value("--from") ?? (all.count > 1 ? all[1].version : nil))
        let changelog = args.contains("--changelog")
        let releases = changelog ? WhatsNew.history(all, upTo: current) : WhatsNew.releases(all, from: from, to: current)
        guard !releases.isEmpty else {
            print("whats-new demo: no entries between \(from ?? "nil") and \(current)")
            exit(1)
        }
        let c = WhatsNewWindowController(from: from, releases: releases, folder: WhatsNewContent.folder,
                                         changelog: changelog)
        controller = c
        c.show()
        DemoSnapshot.scheduleIfRequested(c.debugWindow)
        print("whats-new window \(c.windowNumber)")
        fflush(stdout)
    }
}
#endif
