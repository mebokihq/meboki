import MebokiCore
import SwiftUI

/// Settings › Models (design_code.md §8.3): the model picker is a list + detail. The list has one compact row
/// per catalog model (radio = in use, glyph, name, a status line, Accuracy / Speed / Memory mini scales in a
/// fixed column, chevron); a click shows that model in the Details group below: full scales with their
/// numbers, "Recommended for your Mac", a memory warning, download progress, Use / Download / Pause / Resume /
/// Retry, Delete…, and the disk-space check. Switching restarts `llama-server` (in `AppDelegate`). Above the
/// catalog: Apple's built-in model (macOS 26+, PLAN.md §3 "Apple Intelligence"), no download; using it stops
/// `llama-server`. Below: cloud models with the user's own OpenRouter or OpenAI key (BYOK, PLAN.md §4); using one
/// stops `llama-server`.
struct ModelsPane: View {
    @ObservedObject var model: SettingsModel
    @ObservedObject var settings: AppSettings
    @ObservedObject var store: ModelStore
    /// The model shown in Details; starts on the selected one.
    @State private var inspectedID: String?

    private var inspected: ModelInfo {
        Catalog.byID(inspectedID) ?? Catalog.byID(model.selectedModelID) ?? Catalog.recommended
    }

    /// Details shows Apple's model: picked in the list, or (nothing picked yet) it is the one in use.
    private var inspectingApple: Bool {
        inspectedID == AppleIntelligence.id || (inspectedID == nil && settings.modelSource == .apple)
    }

    /// Gemma's "Recommended" pill moves to Apple's model where that is the default (`Catalog.appleRecommended`).
    private func recommended(_ m: ModelInfo) -> Bool {
        m == Catalog.recommended && !Catalog.appleRecommended(model.appleModel)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            SettingsGroupHeader("Model", first: true)
            SettingsGroup {
                AppleListRow(availability: model.appleModel, inUse: settings.modelSource == .apple,
                             recommended: Catalog.appleRecommended(model.appleModel), inspected: inspectingApple,
                             inspect: { inspectedID = AppleIntelligence.id },
                             use: model.actions.useApple)
                ForEach(Catalog.all.indices, id: \.self) { i in
                    SettingsDivider()
                    let info = Catalog.all[i]
                    ModelListRow(info: info, status: ModelStatus(info, model: model, settings: settings, store: store),
                                 recommended: recommended(info),
                                 inspected: !inspectingApple && info == inspected,
                                 inspect: { inspectedID = info.id },
                                 use: { model.actions.useModel(info) })
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: DS.Radius.group, style: .continuous))
            SettingsGroupHeader("Details")
            SettingsGroup {
                if inspectingApple {
                    AppleModelDetail(availability: model.appleModel, inUse: settings.modelSource == .apple,
                                     recommended: Catalog.appleRecommended(model.appleModel), actions: model.actions)
                } else {
                    ModelDetail(info: inspected,
                                status: ModelStatus(inspected, model: model, settings: settings, store: store),
                                recommended: recommended(inspected), actions: model.actions)
                }
            }
            SettingsFootnote(symbol: "lock.shield",
                             text: "Models run on this Mac. Files come from pinned Hugging Face commits and are checked with SHA-256.") {
                Button("Show models folder", action: model.actions.showModelsFolder).buttonStyle(.dsLink)
            }
            SettingsGroupHeader("Memory")
            SettingsGroup {
                SettingsRow("Unload when idle", subtitle: "Frees its memory; the next check loads it again") {
                    DSSegmented(selection: $settings.idleUnload, options: IdleUnload.allCases.map { ($0, $0.title) })
                        .fixedSize()
                }
            }
            CloudSection(model: model, settings: settings)
        }
    }
}

/// What the list row and Details need to know about one model right now.
private struct ModelStatus {
    let installed: Bool
    /// The local model checks use (not while cloud is in use).
    let inUse: Bool
    /// The model `AppDelegate` would run locally; it can't be deleted.
    let selected: Bool
    let download: DownloadState?

    @MainActor init(_ m: ModelInfo, model: SettingsModel, settings: AppSettings, store: ModelStore) {
        _ = store.installedVersion
        installed = store.isInstalled(m)
        selected = model.selectedModelID == m.id
        inUse = selected && installed && settings.modelSource == .local
        download = store.state(m)
    }

    var isPaused: Bool {
        if case .paused = download { return true }
        return false
    }

    var isFailed: Bool {
        if case .failed = download { return true }
        return false
    }

    /// The row's status: "In use", "Downloaded", "Downloading 53%", "Paused at 53%", "Checking the file…",
    /// "Download failed", or the download size.
    func text(_ m: ModelInfo) -> String {
        if inUse { return "In use" }
        switch download {
        case .downloading: return "Downloading \(percent)%"
        case .paused: return "Paused at \(percent)%"
        case .verifying: return "Checking the file…"
        case .failed: return "Download failed"
        case nil: return installed ? "Downloaded" : ModelFormat.gb(m.bytes) + " download"
        }
    }

    var textColor: Color { inUse ? DS.ok : isFailed ? DS.catSpelling : DS.textSecondary }

    private var percent: Int { Int(((download?.fraction ?? 0) * 100).rounded(.down)) }
}

private enum ModelFormat {
    /// "4.6 GB" (1 decimal).
    static func gb(_ bytes: Int64) -> String { String(format: "%.1f GB", Double(bytes) / 1e9) }
    /// "4.59 GB".
    static func gb2(_ bytes: Int64) -> String { String(format: "%.2f GB", Double(bytes) / 1e9) }

    /// "53% · 1.51 of 2.84 GB".
    static func progress(written: Int64, total: Int64) -> String {
        let pct = total > 0 ? Int((Double(written) / Double(total) * 100).rounded(.down)) : 0
        return "\(pct)% · " + String(format: "%.2f of %.2f GB", Double(written) / 1e9, Double(total) / 1e9)
    }

    /// Peak memory over 45% of RAM slows the Mac (PLAN.md §3).
    static func heavy(_ m: ModelInfo) -> Bool { m.peakMemoryGB > Double(Catalog.ramGB) * 0.45 }
}

// MARK: - List row

/// Radio · glyph · name (+ "Recommended") over the status line · mini scales · chevron. The scales sit in a
/// fixed-width column and the trailing slot is always the chevron, so every row's scales line up; "In use"
/// is the green status line, not a trailing pill. The radio is its own button: on a downloaded model it
/// switches to it (and shows it in Details); the rest of the row only shows the model in Details.
private struct ModelListRow: View {
    let info: ModelInfo
    let status: ModelStatus
    let recommended: Bool
    let inspected: Bool
    let inspect: () -> Void
    let use: () -> Void
    @State private var hovering = false

    private var canUse: Bool { status.installed && !status.inUse && status.download == nil }

    var body: some View {
        HStack(spacing: 0) {
            Button {
                inspect()
                if canUse { use() }
            } label: {
                RadioDot(isOn: status.inUse)
                    .opacity(status.installed ? 1 : 0.35)
                    .padding(.vertical, 9)
                    .padding(.leading, 14)
                    .padding(.trailing, 12)
                    .frame(maxHeight: .infinity)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(status.inUse ? "In use" : canUse ? "Use \(info.shortName)" : "Download it first")
            .accessibilityLabel(status.inUse ? "\(info.shortName), in use" : "Use \(info.shortName)")
            .accessibilityAddTraits(status.inUse ? [.isButton, .isSelected] : .isButton)
            Button(action: inspect) {
                HStack(spacing: 12) {
                    ModelGlyph(modelID: info.id, initial: String(info.shortName.prefix(1)), size: 28)
                        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                    VStack(alignment: .leading, spacing: 1) {
                        HStack(spacing: 6) {
                            Text(info.shortName).font(DS.Font.bodyMedium).foregroundStyle(DS.text).lineLimit(1)
                            if recommended { Pill("Recommended", kind: .brand) }
                        }
                        (Text(info.tagline + " · ").foregroundStyle(DS.textSecondary)
                         + Text(status.text(info)).foregroundStyle(status.textColor))
                            .font(DS.Font.caption)
                            .monospacedDigit()
                            .lineLimit(1)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    MiniScales(info: info)
                    Image(systemName: "chevron.right")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(inspected ? DS.brand : DS.textTertiary)
                        .frame(width: 10)
                }
                .padding(.vertical, 9)
                .padding(.trailing, 14)
                .frame(maxHeight: .infinity)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(info.shortName + (recommended ? ", recommended for your Mac" : ""))
            .accessibilityValue("\(status.text(info)). Accuracy \(info.ratings.accuracy) of 5, speed \(info.ratings.speed) of 5, "
                                + "\(info.ratings.memoryWord.lowercased()) memory")
            .accessibilityHint("Shows the details below")
            .accessibilityAddTraits(inspected ? [.isButton, .isSelected] : .isButton)
        }
        .fixedSize(horizontal: false, vertical: true)
        .frame(minHeight: 50)
        .background(inspected ? DS.control : hovering ? DS.hover : Color.clear)
        .onHover { hovering = $0 }
    }
}

/// Three fixed-width columns: a 9.5 pt caps label over 5 pt dots (memory: 5 segments, orange when heavy for
/// this Mac).
private struct MiniScales: View {
    let info: ModelInfo

    var body: some View {
        HStack(spacing: 8) {
            column("Acc") { ScaleDots(value: info.ratings.accuracy, dot: 5) }
            column("Speed") { ScaleDots(value: info.ratings.speed, dot: 5) }
            column("Mem") { MemoryScale(value: info.ratings.memory, heavy: ModelFormat.heavy(info), small: true) }
        }
        .accessibilityHidden(true)
    }

    private func column(_ label: String, @ViewBuilder scale: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(label.uppercased())
                .font(.system(size: 9, weight: .semibold))
                .kerning(0.4)
                .foregroundStyle(DS.textSecondary)
            scale()
        }
        .frame(width: 38, alignment: .leading)
    }
}

/// 5-step dots: filled `text`, empty `control2` (more is better).
struct ScaleDots: View {
    let value: Int
    var dot: CGFloat = 7

    var body: some View {
        HStack(spacing: dot * 0.45) {
            ForEach(1...5, id: \.self) { i in
                Circle().fill(i <= value ? DS.text : DS.control2).frame(width: dot, height: dot)
            }
        }
        .accessibilityElement()
        .accessibilityLabel("\(value) of 5")
    }
}

/// 5-segment memory bar, Light → Heavy; the filled part turns `catPunctuation` when the model is heavy for
/// this Mac.
struct MemoryScale: View {
    let value: Int
    var heavy = false
    var small = false

    var body: some View {
        HStack(spacing: 2) {
            ForEach(1...5, id: \.self) { i in
                RoundedRectangle(cornerRadius: small ? 1.5 : 2, style: .continuous)
                    .fill(i <= value ? (heavy ? DS.catPunctuation : DS.text) : DS.control2)
                    .frame(width: small ? 6 : 9, height: small ? 5 : 7)
            }
        }
        .accessibilityElement()
        .accessibilityLabel("Memory \(value) of 5")
    }
}

// MARK: - Details

/// The inspected model in full: header with badges, three scale tiles with their numbers, the memory
/// warning, download progress, actions and the disk-space line.
private struct ModelDetail: View {
    let info: ModelInfo
    let status: ModelStatus
    let recommended: Bool
    let actions: SettingsActions

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
            HStack(spacing: 8) {
                tile("Accuracy", detail: "Fixed \(info.errorsFixed) of 45 test mistakes") {
                    ScaleDots(value: info.ratings.accuracy)
                }
                tile("Speed", detail: String(format: "About %.1f s per paragraph", info.paragraphSeconds)) {
                    ScaleDots(value: info.ratings.speed)
                }
                tile("Memory · \(info.ratings.memoryWord)",
                     detail: String(format: "Up to %g GB of %d GB", (info.peakMemoryGB * 10).rounded() / 10, Catalog.ramGB)) {
                    MemoryScale(value: info.ratings.memory, heavy: ModelFormat.heavy(info))
                }
            }
            if ModelFormat.heavy(info) {
                note("exclamationmark.triangle.fill", DS.catPunctuation,
                     String(format: "Uses up to %g GB, almost half of this Mac's %d GB. Other apps may slow down while it checks.",
                            (info.peakMemoryGB * 10).rounded() / 10, Catalog.ramGB))
            }
            progress
            HStack(spacing: 8) {
                primary
                deleteButton
                Spacer(minLength: 8)
                diskLine
            }
            .frame(minHeight: 26)
            if let short = diskShortage {
                note("exclamationmark.triangle.fill", DS.catSpelling, short)
            }
            if case .failed(let message) = status.download {
                note("exclamationmark.triangle.fill", DS.catSpelling, message)
            }
        }
        .padding(14)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("\(info.shortName) details")
    }

    private var header: some View {
        HStack(spacing: 12) {
            ModelGlyph(modelID: info.id, initial: String(info.shortName.prefix(1)), size: 40)
                .clipShape(RoundedRectangle(cornerRadius: 11, style: .continuous))
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(info.shortName).font(.system(size: 15, weight: .semibold)).foregroundStyle(DS.text)
                        .padding(.trailing, 2)
                    if recommended { Pill("Recommended for your Mac", kind: .brand) }
                    if status.inUse { Pill("In use", kind: .success) } else if status.installed { Pill("Downloaded") }
                }
                (Text(info.tagline + " · ") + Text(.init("[\(info.license.name)](\(info.license.url.absoluteString))")))
                    .font(DS.Font.caption)
                    .foregroundStyle(DS.textSecondary)
                    .tint(DS.brand)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func tile(_ title: String, detail: String, @ViewBuilder scale: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(title).font(.system(size: 11, weight: .semibold)).foregroundStyle(DS.textSecondary)
            scale()
            Text(detail).font(DS.Font.footnote).foregroundStyle(DS.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.vertical, 8)
        .padding(.horizontal, 10)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(DS.control))
        .accessibilityElement(children: .combine)
    }

    private func note(_ symbol: String, _ color: Color, _ text: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Image(systemName: symbol).font(.system(size: 11))
            Text(text).fixedSize(horizontal: false, vertical: true)
        }
        .font(DS.Font.caption)
        .foregroundStyle(color)
    }

    @ViewBuilder private var progress: some View {
        switch status.download {
        case .downloading(let w, let t), .paused(let w, let t):
            VStack(alignment: .leading, spacing: 3) {
                DSMeter(value: status.download?.fraction ?? 0, height: 6).frame(maxWidth: 300)
                Text((status.isPaused ? "Paused · " : "") + ModelFormat.progress(written: w, total: t))
                    .font(DS.Font.footnote)
                    .monospacedDigit()
                    .foregroundStyle(DS.textSecondary)
            }
        default:
            EmptyView()
        }
    }

    @ViewBuilder private var primary: some View {
        switch status.download {
        case .downloading:
            Button("Pause") { actions.pause(info) }.buttonStyle(.ds(.secondary, small: true))
        case .paused:
            Button("Resume") { actions.download(info) }.buttonStyle(.ds(.primary, small: true))
                .disabled(diskShortage != nil)
        case .verifying:
            HStack(spacing: 6) {
                DSSpinner()
                Text("Checking SHA-256…").font(DS.Font.footnote).foregroundStyle(DS.textSecondary)
            }
        case .failed:
            Button("Retry") { actions.download(info) }.buttonStyle(.ds(.primary, small: true))
                .disabled(diskShortage != nil)
        case nil:
            if status.inUse {
                EmptyView()
            } else if status.installed {
                Button("Use \(info.shortName)") { actions.useModel(info) }.buttonStyle(.ds(.primary, small: true))
            } else {
                Button { actions.download(info) } label: {
                    DSLabel("Download " + ModelFormat.gb(info.bytes), systemImage: "arrow.down.to.line")
                }
                .buttonStyle(.ds(.primary, small: true))
                .disabled(diskShortage != nil)
            }
        }
    }

    /// Delete… for an installed model, Discard… for a paused or failed download. Disabled for the selected
    /// model (it is the one that runs).
    @ViewBuilder private var deleteButton: some View {
        let discard = !status.installed && (status.isPaused || status.isFailed)
        if status.installed || discard {
            Button { actions.delete(info) } label: {
                DSLabel(discard ? "Discard…" : "Delete…", systemImage: "trash")
            }
            .buttonStyle(.ds(.secondary, small: true))
            .disabled(status.selected && status.installed)
            .help(status.selected && status.installed ? "Switch to another model to delete this one"
                                                       : "Delete \(info.shortName) from this Mac")
        }
    }

    /// "Takes 4.59 GB on disk" / "Needs 5.6 GB · 48 GB free".
    @ViewBuilder private var diskLine: some View {
        if status.installed {
            Label("Takes \(ModelFormat.gb2(info.bytes)) on disk", systemImage: "internaldrive")
                .font(DS.Font.caption).foregroundStyle(DS.textSecondary).labelStyle(.titleAndIcon)
        } else if diskShortage == nil, let free = ModelStore.freeSpace {
            Label("Needs \(ModelFormat.gb(remaining + ModelStore.spaceMargin)) · \(String(format: "%.0f GB", Double(free) / 1e9)) free",
                  systemImage: "internaldrive")
                .font(DS.Font.caption).foregroundStyle(DS.textSecondary).monospacedDigit()
        }
    }

    /// Bytes still to download (a paused download needs only the rest).
    private var remaining: Int64 {
        switch status.download {
        case .downloading(let w, let t), .paused(let w, let t): max(0, t - w)
        default: info.bytes
        }
    }

    /// Why the download can't start: the rest of the file plus 1 GB must fit (as `ModelStore.download` checks).
    private var diskShortage: String? {
        guard !status.installed, let free = ModelStore.freeSpace else { return nil }
        switch status.download {
        case .downloading, .verifying: return nil
        default: break
        }
        let needed = remaining + ModelStore.spaceMargin
        guard free < needed else { return nil }
        return String(format: "Not enough disk space: needs %.1f GB, this Mac has %.1f GB free. Delete a model or free up space.",
                      Double(needed) / 1e9, Double(free) / 1e9)
    }
}

// MARK: - Apple's built-in model

/// The built-in row above the catalog (design_code.md §8.3): radio, glyph, "Apple Intelligence" over its status,
/// the Acc and Speed scales from its benchmark (`AppleModel`) with "Built in" for memory, chevron. The
/// radio switches to it only while it is available.
private struct AppleListRow: View {
    let availability: AppleModelAvailability
    let inUse: Bool
    let recommended: Bool
    let inspected: Bool
    let inspect: () -> Void
    let use: () -> Void
    @State private var hovering = false

    private var active: Bool { inUse && availability.isAvailable }
    private var canUse: Bool { availability.isAvailable && !inUse }
    /// Selected but gone (Apple Intelligence turned off): said in the status, in red, with no silent switch.
    private var lost: Bool { inUse && !availability.isAvailable }

    private var statusText: String {
        lost ? "Selected, but " + AppleIntelligence.shortStatus(availability).lowercased()
             : AppleIntelligence.statusText(availability, inUse: inUse)
    }

    private var statusColor: Color { active ? DS.ok : lost ? DS.catSpelling : DS.textSecondary }

    var body: some View {
        HStack(spacing: 0) {
            Button {
                inspect()
                if canUse { use() }
            } label: {
                RadioDot(isOn: active)
                    .opacity(availability.isAvailable ? 1 : 0.35)
                    .padding(.vertical, 9)
                    .padding(.leading, 14)
                    .padding(.trailing, 12)
                    .frame(maxHeight: .infinity)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(active ? "In use" : canUse ? "Use \(AppleModel.displayName)" : AppleModel.unavailableMessage(availability))
            .accessibilityLabel(active ? "\(AppleModel.displayName), in use" : "Use \(AppleModel.displayName)")
            .accessibilityAddTraits(active ? [.isButton, .isSelected] : .isButton)
            Button(action: inspect) {
                HStack(spacing: 12) {
                    ModelGlyph(modelID: AppleIntelligence.id, initial: "A", size: 28)
                        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                    VStack(alignment: .leading, spacing: 1) {
                        HStack(spacing: 6) {
                            Text(AppleModel.displayName).font(DS.Font.bodyMedium).foregroundStyle(DS.text).lineLimit(1)
                            if recommended { Pill("Recommended", kind: .brand) }
                        }
                        (Text("Built into macOS · ").foregroundStyle(DS.textSecondary)
                         + Text(statusText).foregroundStyle(statusColor))
                            .font(DS.Font.caption)
                            .lineLimit(1)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    HStack(spacing: 8) {
                        scaleColumn("Acc") { ScaleDots(value: AppleModel.accuracyRating, dot: 5) }
                        scaleColumn("Speed") { ScaleDots(value: AppleModel.speedRating, dot: 5) }
                        scaleColumn("Mem") {
                            Text("Built in").font(.system(size: 8.5)).foregroundStyle(DS.textTertiary).fixedSize()
                        }
                    }
                    .accessibilityHidden(true)
                    Image(systemName: "chevron.right")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(inspected ? DS.brand : DS.textTertiary)
                        .frame(width: 10)
                }
                .padding(.vertical, 9)
                .padding(.trailing, 14)
                .frame(maxHeight: .infinity)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(AppleModel.displayName + (recommended ? ", recommended" : ""))
            .accessibilityValue("Built into macOS. \(statusText). Accuracy \(AppleModel.accuracyRating) of 5, "
                                + "speed \(AppleModel.speedRating) of 5, no extra memory")
            .accessibilityHint("Shows the details below")
            .accessibilityAddTraits(inspected ? [.isButton, .isSelected] : .isButton)
        }
        .fixedSize(horizontal: false, vertical: true)
        .frame(minHeight: 50)
        .background(inspected ? DS.control : hovering ? DS.hover : Color.clear)
        .onHover { hovering = $0 }
    }

    /// Same column as `MiniScales` (width 38, caps label over the scale).
    private func scaleColumn(_ label: String, @ViewBuilder scale: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(label.uppercased())
                .font(.system(size: 9, weight: .semibold))
                .kerning(0.4)
                .foregroundStyle(DS.textSecondary)
            scale()
        }
        .frame(width: 38, alignment: .leading)
    }
}

/// Apple's model in Details: no file, so no Download or Delete. Accuracy and speed come from its benchmark
/// (`AppleModel`); memory is "Built in". A line says it is Apple's model, not an open one.
private struct AppleModelDetail: View {
    let availability: AppleModelAvailability
    let inUse: Bool
    let recommended: Bool
    let actions: SettingsActions

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 12) {
                ModelGlyph(modelID: AppleIntelligence.id, initial: "A", size: 40)
                    .clipShape(RoundedRectangle(cornerRadius: 11, style: .continuous))
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text(AppleModel.displayName).font(.system(size: 15, weight: .semibold)).foregroundStyle(DS.text)
                            .padding(.trailing, 2)
                        if recommended { Pill("Recommended for your Mac", kind: .brand) }
                        if inUse && availability.isAvailable { Pill("In use", kind: .success) } else { Pill("Built in") }
                    }
                    Text("Built into macOS · no download")
                        .font(DS.Font.caption)
                        .foregroundStyle(DS.textSecondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            HStack(spacing: 8) {
                tile("Accuracy", "Fixed \(AppleModel.errorsFixed) of 45 test mistakes") {
                    ScaleDots(value: AppleModel.accuracyRating)
                }
                tile("Speed", String(format: "About %.1f s per paragraph", AppleModel.paragraphSeconds)) {
                    ScaleDots(value: AppleModel.speedRating)
                }
                tile("Memory · Built in", "No extra memory or download") { EmptyView() }
            }
            note("lock.shield", DS.textSecondary,
                 "Apple's on-device model, part of macOS. It isn't an open model. The text you check stays on this Mac.")
            switch availability {
            case .available:
                if !inUse {
                    Button("Use \(AppleModel.displayName)", action: actions.useApple).buttonStyle(.ds(.primary, small: true))
                }
            case .notEnabled:
                note("exclamationmark.triangle.fill", DS.catPunctuation,
                     "Apple Intelligence is off. Turn it on in System Settings › Apple Intelligence & Siri; macOS then prepares the model.")
                Button("Open System Settings", action: actions.openAppleSettings).buttonStyle(.ds(.secondary, small: true))
            case .modelNotReady:
                note("hourglass", DS.textSecondary,
                     "macOS is still preparing the model. It downloads in the background after Apple Intelligence is turned on.")
            case .deviceNotEligible:
                note("exclamationmark.triangle.fill", DS.catPunctuation,
                     "Apple Intelligence isn't supported on this Mac, or in its current region or language.")
            case .osTooOld:
                note("info.circle", DS.textSecondary, "Needs macOS 26 or later with Apple Intelligence on.")
            }
            if inUse && !availability.isAvailable {
                note("exclamationmark.triangle.fill", DS.catSpelling,
                     "Checks are set to Apple Intelligence, which isn't available now. Choose another model above.")
            }
        }
        .padding(14)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("\(AppleModel.displayName) details")
    }

    private func tile(_ title: String, _ detail: String, @ViewBuilder scale: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(title).font(.system(size: 11, weight: .semibold)).foregroundStyle(DS.textSecondary)
            scale()
            Text(detail).font(DS.Font.footnote).foregroundStyle(DS.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.vertical, 8)
        .padding(.horizontal, 10)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(DS.control))
        .accessibilityElement(children: .combine)
    }

    private func note(_ symbol: String, _ color: Color, _ text: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Image(systemName: symbol).font(.system(size: 11))
            Text(text).fixedSize(horizontal: false, vertical: true)
        }
        .font(DS.Font.caption)
        .foregroundStyle(color)
    }
}

// MARK: - Cloud (BYOK)

/// Provider, API key (Keychain), model, test and use. Cloud is opt-in: nothing is sent until the user saves a
/// key and presses Use.
private struct CloudSection: View {
    @ObservedObject var model: SettingsModel
    @ObservedObject var settings: AppSettings
    @State private var keyDraft = ""
    @State private var keyError: String?
    @State private var customDraft = ""
    @State private var editingCustom = false

    private var provider: CloudProvider { settings.cloudProvider }
    private var hasKey: Bool { model.savedKeys.contains(provider) }
    private var cloudModel: CloudModel { settings.cloudModel }
    private var inUse: Bool { settings.modelSource == .cloud }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            SettingsGroupHeader("Cloud · your own API key")
            SettingsGroup {
                SettingsRow("Provider", subtitle: "OpenRouter: one key, models from many vendors") {
                    DSSegmented(selection: providerBinding, options: CloudProvider.allCases.map { ($0, $0.name) })
                }
                SettingsDivider()
                keyRow
                SettingsDivider()
                modelRow
                if editingCustom {
                    SettingsDivider()
                    customRow
                }
                SettingsDivider()
                useRow
            }
            SettingsFootnote(symbol: "cloud", text: privacyNote)
        }
    }

    private var providerBinding: Binding<CloudProvider> {
        Binding(get: { settings.cloudProvider }, set: { p in
            settings.cloudProvider = p
            keyDraft = ""
            keyError = nil
            editingCustom = false
        })
    }

    // MARK: Key

    @ViewBuilder private var keyRow: some View {
        if hasKey {
            SettingsRow("API key", subtitle: "Saved in your Keychain") {
                Button("Remove") {
                    model.actions.removeKey(provider)
                    keyDraft = ""
                }
                .buttonStyle(.ds(.secondary, small: true))
            }
        } else {
            SettingsRow(leading: {
                VStack(alignment: .leading, spacing: 1) {
                    Text("API key").font(DS.Font.bodyMedium).foregroundStyle(DS.text)
                    if let keyError {
                        Text(keyError).font(DS.Font.caption).foregroundStyle(DS.catSpelling)
                            .fixedSize(horizontal: false, vertical: true)
                    } else {
                        Link("Get a key at \(provider.keysPage.host() ?? provider.name)", destination: provider.keysPage)
                            .font(DS.Font.caption)
                            .foregroundStyle(DS.brand)
                    }
                }
            }, control: {
                HStack(spacing: 8) {
                    SecureField(provider.keyPlaceholder, text: $keyDraft)
                        .textFieldStyle(.plain)
                        .font(DS.Font.body)
                        .foregroundStyle(DS.text)
                        .padding(.horizontal, 8)
                        .frame(width: 200, height: 26)
                        .background(RoundedRectangle(cornerRadius: DS.Radius.field, style: .continuous).fill(DS.control))
                        .onSubmit(saveKey)
                        .accessibilityLabel("\(provider.name) API key")
                    Button("Save", action: saveKey)
                        .buttonStyle(.ds(.primary, small: true))
                        .disabled(keyDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
                .fixedSize()
            })
        }
    }

    private func saveKey() {
        let key = keyDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        if let problem = provider.keyProblem(key) {
            keyError = problem
            return
        }
        if let error = model.actions.saveKey(key, provider) {
            keyError = error
            return
        }
        keyDraft = ""
        keyError = nil
    }

    // MARK: Model

    private var modelRow: some View {
        SettingsRow("Model", subtitle: Self.stats(cloudModel)) {
            Menu {
                ForEach(CloudCatalog.models(for: provider)) { m in
                    Button {
                        setModel(m.id)
                    } label: {
                        if m.id == cloudModel.id { Label(m.name, systemImage: "checkmark") } else { Text(m.name) }
                    }
                }
                Divider()
                Button(cloudModel.isCustom ? "Other: \(cloudModel.id)…" : "Other model ID…") {
                    customDraft = cloudModel.isCustom ? cloudModel.id : ""
                    editingCustom = true
                }
            } label: {
                Text(cloudModel.name).font(DS.Font.small)
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            .accessibilityLabel("Cloud model")
        }
    }

    private var customRow: some View {
        SettingsRow("Model ID", subtitle: provider == .openRouter ? "As on openrouter.ai, like “mistralai/mistral-small”"
                                                                    : "As in the OpenAI docs, like “gpt-6-luna”") {
            HStack(spacing: 8) {
                TextField(provider == .openRouter ? "vendor/model" : "model", text: $customDraft)
                    .textFieldStyle(.plain)
                    .font(.system(size: 12.5, design: .monospaced))
                    .foregroundStyle(DS.text)
                    .padding(.horizontal, 8)
                    .frame(width: 200, height: 26)
                    .background(RoundedRectangle(cornerRadius: DS.Radius.field, style: .continuous).fill(DS.control))
                    .onSubmit(saveCustom)
                Button("Set", action: saveCustom)
                    .buttonStyle(.ds(.primary, small: true))
                    .disabled(customDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                Button("Cancel") { editingCustom = false }.buttonStyle(.ds(.secondary, small: true))
            }
            .fixedSize()
        }
    }

    private func saveCustom() {
        let id = customDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !id.isEmpty, !id.contains(where: \.isWhitespace) else { return }
        setModel(id)
        editingCustom = false
    }

    private func setModel(_ id: String) {
        settings.cloudModelIDs[provider.rawValue] = id
        model.cloudTest[provider] = nil
    }

    /// "45/45 errors fixed · 0.7 s · $0.04 per 1,000 checks".
    static func stats(_ m: CloudModel) -> String {
        guard let fixed = m.errorsFixed, let s = m.latencySeconds, let cost = m.costPer1000Checks else {
            return "Not benchmarked. Thinking stays at the model's default, which can be slow"
        }
        return "\(fixed)/45 errors fixed · " + String(format: "%.1f s · $%.2f per 1,000 checks", s, cost)
    }

    // MARK: Use

    private var useRow: some View {
        HStack(spacing: 14) {
            RadioDot(isOn: inUse).opacity(hasKey ? 1 : 0.35)
            VStack(alignment: .leading, spacing: 1) {
                Text("\(cloudModel.name) via \(provider.name)").font(DS.Font.bodyMedium).foregroundStyle(DS.text)
                testLine
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            Button("Test") { model.actions.testCloud(provider) }
                .buttonStyle(.ds(.secondary, small: true))
                .fixedSize()
                .disabled(!hasKey || model.cloudTest[provider] == .running)
            if inUse {
                Pill("In use", kind: .success)
            } else {
                Button("Use", action: model.actions.useCloud)
                    .buttonStyle(.ds(.primary, small: true))
                    .disabled(!hasKey)
            }
        }
        .padding(.vertical, 10)
        .padding(.horizontal, 14)
        .frame(minHeight: 46)
        .accessibilityElement(children: .contain)
    }

    @ViewBuilder private var testLine: some View {
        switch model.cloudTest[provider] {
        case .running:
            HStack(spacing: 6) {
                DSSpinner()
                Text("Sending a test sentence…").font(DS.Font.caption).foregroundStyle(DS.textSecondary)
            }
        case .passed(let text):
            Text(text).font(DS.Font.caption).foregroundStyle(DS.ok).fixedSize(horizontal: false, vertical: true)
        case .failed(let text):
            Text(text).font(DS.Font.caption).foregroundStyle(DS.catSpelling).fixedSize(horizontal: false, vertical: true)
        case nil:
            Text(hasKey ? "Text you check is sent to \(provider.name)" : "Save a key to use cloud models")
                .font(DS.Font.caption).foregroundStyle(DS.textSecondary)
        }
    }

    private var privacyNote: String {
        switch provider {
        case .openRouter:
            "Cloud is off until you press Use. Then the text you check goes to OpenRouter, routed only to hosts "
                + "with zero data retention. Keys stay in your Keychain."
        case .openAI:
            "Cloud is off until you press Use. Then the text you check goes to OpenAI with storage off; OpenAI "
                + "may keep API data up to 30 days for abuse checks. Keys stay in your Keychain."
        }
    }
}
