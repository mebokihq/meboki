import AppKit
import ApplicationServices
import Carbon

/// Snapshot of the focused text field.
struct FieldSnapshot {
    /// The text the check reads and writes: the focused field, or the document it is part of (`SurfaceResolver`).
    let surface: TextSurface
    /// The focused element (the surface's anchor).
    var element: AXUIElement { surface.anchor }
    let pid: pid_t
    let text: String
    let selection: NSRange?
    /// Screen frame in Cocoa coordinates (bottom-left origin), if the app reports one.
    let frame: CGRect?
}

enum AXError2: Error, LocalizedError {
    /// `appHidesText`: the app draws its own text (Sublime Text, Zed, canvas apps) and its window has no text element
    /// at all, so nothing can be read. `noText`: a text field is focused but gives no text.
    case notTrusted, noFocusedField, secureField, secureInput, noText, appHidesText, textChanged, writeFailed

    var errorDescription: String? {
        switch self {
        case .notTrusted: "Meboki needs Accessibility permission (System Settings → Privacy & Security → Accessibility)."
        case .noFocusedField: "No text field is focused. Click into a text field and try again."
        case .secureField: "Password fields are never read."
        case .secureInput: "Secure input is on (a password field, or an app such as Terminal with Secure Keyboard Entry). Meboki doesn't read text while it's on."
        case .noText: "This field doesn't share its text with macOS."
        case .appHidesText: "This app doesn't share its text with macOS, so Meboki can't check it here."
        case .textChanged: "The text changed since it was checked. Run the check again."
        case .writeFailed: "This app didn't accept the change, so nothing was replaced. Details: menu → Show Meboki Log."
        }
    }
}

enum AX {
    static func isTrusted(prompt: Bool) -> Bool {
        let key = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
        return AXIsProcessTrustedWithOptions([key: prompt] as CFDictionary)
    }

    static func openAccessibilitySettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(url)
        }
    }

    // MARK: Attributes

    static func copy(_ el: AXUIElement, _ attr: String) -> CFTypeRef? {
        var v: CFTypeRef?
        guard AXUIElementCopyAttributeValue(el, attr as CFString, &v) == .success else { return nil }
        return v
    }

    static func string(_ el: AXUIElement, _ attr: String) -> String? {
        copy(el, attr) as? String
    }

    static func selectedRange(_ el: AXUIElement) -> NSRange? {
        guard let v = copy(el, kAXSelectedTextRangeAttribute), CFGetTypeID(v) == AXValueGetTypeID() else { return nil }
        var r = CFRange()
        guard AXValueGetValue(v as! AXValue, .cfRange, &r) else { return nil }
        return NSRange(location: r.location, length: r.length)
    }

    @discardableResult
    static func setSelectedRange(_ el: AXUIElement, _ range: NSRange) -> Bool {
        var cf = CFRange(location: range.location, length: range.length)
        guard let v = AXValueCreate(.cfRange, &cf) else { return false }
        return AXUIElementSetAttributeValue(el, kAXSelectedTextRangeAttribute as CFString, v) == .success
    }

    static func setSelectedText(_ el: AXUIElement, _ text: String) -> Bool {
        AXUIElementSetAttributeValue(el, kAXSelectedTextAttribute as CFString, text as CFString) == .success
    }

    /// Element frame converted from AX (top-left origin of the primary screen) to Cocoa coordinates.
    static func frame(_ el: AXUIElement) -> CGRect? {
        guard var r = axFrame(el) else { return nil }
        if let shift = VCLGeometry.elementShift(el) { r.origin.y += shift }
        return cocoa(r)
    }

    /// Element frame as AX reports it (top-left origin, y down), with no app quirk applied.
    static func axFrame(_ el: AXUIElement) -> CGRect? {
        guard let p = copy(el, kAXPositionAttribute), let s = copy(el, kAXSizeAttribute),
              CFGetTypeID(p) == AXValueGetTypeID(), CFGetTypeID(s) == AXValueGetTypeID() else { return nil }
        var point = CGPoint.zero, size = CGSize.zero
        guard AXValueGetValue(p as! AXValue, .cgPoint, &point), AXValueGetValue(s as! AXValue, .cgSize, &size) else { return nil }
        return CGRect(origin: point, size: size)
    }

    /// AX global coordinates (top-left origin of the primary screen, y down) → Cocoa (bottom-left, y up).
    static func cocoa(_ r: CGRect) -> CGRect? {
        guard let primary = NSScreen.screens.first else { return nil }
        return CGRect(x: r.minX, y: primary.frame.maxY - r.minY - r.height, width: r.width, height: r.height)
    }

    static func element(_ el: AXUIElement, _ attr: String) -> AXUIElement? {
        guard let v = copy(el, attr), CFGetTypeID(v) == AXUIElementGetTypeID() else { return nil }
        return (v as! AXUIElement)
    }

    /// The window that holds `el`.
    static func window(of el: AXUIElement) -> AXUIElement? {
        element(el, kAXWindowAttribute)
    }

    /// The nearest scroll area around `el` (a few levels up), or nil.
    static func scrollArea(around el: AXUIElement) -> AXUIElement? {
        var cur = el
        for _ in 0..<8 {
            guard let parent = element(cur, kAXParentAttribute) else { return nil }
            if string(parent, kAXRoleAttribute) == (kAXScrollAreaRole as String) { return parent }
            cur = parent
        }
        return nil
    }

    // MARK: Text bounds (underlines)

    /// One screen rect per line for `range` of `text` (the field's current value). A range that wraps comes
    /// back from AX as one tall rect, so it is split by asking for each character and grouping by line.
    /// Nil when AX gives no bounds.
    static func lineRects(_ el: AXUIElement, range: NSRange, in text: String) -> [CGRect]? {
        let ns = text as NSString
        guard range.length > 0, NSMaxRange(range) <= ns.length, let whole = bounds(el, range, text: text) else { return nil }
        let first = ns.rangeOfComposedCharacterSequence(at: range.location)
        guard let f = bounds(el, first, text: text), whole.height > f.height * 1.5 else { return [whole] }
        var lines: [CGRect] = []
        var i = range.location
        while i < NSMaxRange(range) {
            let c = ns.rangeOfComposedCharacterSequence(at: i)
            i = NSMaxRange(c)
            // Spaces at a line end can report odd rects; the words around them are enough.
            if ns.substring(with: c).trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { continue }
            guard let r = bounds(el, c, text: text) else { continue }
            if let last = lines.last, abs(last.midY - r.midY) < min(last.height, r.height) / 2 {
                lines[lines.count - 1] = last.union(r)
            } else {
                lines.append(r)
            }
        }
        return lines.isEmpty ? [whole] : lines
    }

    /// The part of `el` the user can see: its frame clipped to its scroll area and window. Nil if unknown.
    static func visibleFrame(_ el: AXUIElement) -> CGRect? {
        var clip = frame(el)
        // A field frame that lies wholly outside its own window is wrong (an app that flips y with the wrong
        // screen height): clip to the window, which apps report correctly, so bounds can still be checked.
        if let own = clip, let w = window(of: el).flatMap(frame), !own.intersects(w) { clip = w }
        for other in [scrollArea(around: el), window(of: el)].compactMap({ $0 }) {
            guard let f = frame(other) else { continue }
            clip = clip.map { $0.intersection(f) } ?? f
        }
        guard let clip, !clip.isNull, clip.width > 1, clip.height > 1 else { return nil }
        return clip
    }

    /// The characters the field shows (`AXVisibleCharacterRange`; for an editable web area, which has none, the
    /// text markers at the corners of its visible frame; for a Chromium rich editor, which reports the whole
    /// field or 0+0, its text leaves on screen). Nil when unknown.
    static func visibleCharacterRange(_ el: AXUIElement) -> NSRange? {
        var reported: NSRange?
        if let v = copy(el, kAXVisibleCharacterRangeAttribute), CFGetTypeID(v) == AXValueGetTypeID() {
            var r = CFRange()
            if AXValueGetValue(v as! AXValue, .cfRange, &r), r.length > 0 {
                reported = NSRange(location: r.location, length: r.length)
            }
        }
        if isEditableWebArea(el) { return reported ?? visibleMarkerRange(el) }
        // Chromium `contenteditable` says the whole field is visible (or 0+0 before it has focus), and gives no
        // bounds on the field itself: its leaves tell what's on screen. Only worth it for a long field.
        if reported.map({ $0.location == 0 }) ?? true, let text = text(el), (text as NSString).length > 1500,
           reported.map({ $0.length >= (text as NSString).length }) ?? true,
           nativeBounds(el, NSRange(location: 0, length: 1)) == nil {
            var why: [String] = []
            // Failed frames and the search's end, not the frames that were fine.
            if let onScreen = leafVisibleRange(el, text: text, trace: { if !$0.contains(": {{") { why.append($0) } }) {
                return onScreen
            }
            // Once per field: the check then covers the whole field (slow on a long page), so say why.
            if fallbackLogged.map({ !CFEqual($0, el) }) ?? true {
                fallbackLogged = el
                Log.write("visible range: whole field (\((text as NSString).length) UTF-16); leaves gave none: \(why.suffix(4).joined(separator: "; "))")
            }
        }
        return reported
    }

    /// The last field whose visible range fell back to the whole field (logged once).
    nonisolated(unsafe) private static var fallbackLogged: AXUIElement?

    /// A multi-line text area the user can type in (the checking-as-you-type target), an editable web area
    /// (Mail compose), or a prose field that reports as single-line (`isProseTextField`). Other single-line
    /// fields (URL bars, search boxes, forms) and read-only text (terminal output) are left to the hotkey.
    static func isEditableTextArea(_ el: AXUIElement) -> Bool {
        let role = string(el, kAXRoleAttribute)
        guard role == (kAXTextAreaRole as String) || role == "AXWebArea" || isProseTextField(el) else { return false }
        return isValueSettable(el)
    }

    private static func isValueSettable(_ el: AXUIElement) -> Bool {
        var settable = DarwinBoolean(false)
        guard AXUIElementIsAttributeSettable(el, kAXValueAttribute as CFString, &settable) == .success else { return false }
        return settable.boolValue
    }

    /// Apps whose prose fields report as single-line `AXTextField`s, with the `AXIdentifier`s that qualify (nil:
    /// any plain text field with no description). Messages: the Catalyst composer, which grows to several lines
    /// (its search box is an `AXSearchField`). Reminders: the title and notes of each reminder (the sidebar's
    /// list names are text fields too, but carry the list name as their description). 2026-11-20.
    private static let proseTextFields: [String: Set<String>?] = [
        "com.apple.MobileSMS": ["messageBodyField"],
        "com.apple.reminders": nil,
    ]

    /// An `AXTextField` that holds prose in an app listed in `proseTextFields`: checked as you type like a text area.
    static func isProseTextField(_ el: AXUIElement) -> Bool {
        guard string(el, kAXRoleAttribute) == (kAXTextFieldRole as String),
              (string(el, kAXSubroleAttribute) ?? "").isEmpty else { return false }
        var pid: pid_t = 0
        guard AXUIElementGetPid(el, &pid) == .success,
              let id = NSRunningApplication(processIdentifier: pid)?.bundleIdentifier,
              let rule = proseTextFields[id] else { return false }
        if let ids = rule { return string(el, kAXIdentifierAttribute).map(ids.contains) ?? false }
        return (string(el, kAXDescriptionAttribute) ?? "").isEmpty
    }

    /// The app gives real text bounds for `text` in `el`: two different characters get two different, non-empty
    /// rects (some web and Electron fields answer every range with the field's or the caret's rect).
    /// `visible` (the field's visible characters, when known) keeps the probe on screen.
    static func hasTextBounds(_ el: AXUIElement, text: String, visible: NSRange? = nil) -> Bool {
        let ns = text as NSString
        let all = NSRange(location: 0, length: ns.length)
        var search = visible.map { NSIntersectionRange($0, all) } ?? all
        if ns.rangeOfCharacter(from: .letters, range: search).location == NSNotFound { search = all }
        let f = ns.rangeOfCharacter(from: .letters, range: search)
        guard f.location != NSNotFound else { return false }
        let first = ns.rangeOfComposedCharacterSequence(at: f.location)
        let last = ns.rangeOfComposedCharacterSequence(
            at: ns.rangeOfCharacter(from: .letters, options: .backwards, range: search).location)
        guard let a = bounds(el, first, text: text) else { return false }
        guard last != first else { return true }
        guard let b = bounds(el, last, text: text) else { return false }
        return a != b
    }

    static func isSecureField(_ el: AXUIElement) -> Bool {
        let role = string(el, kAXRoleAttribute) ?? ""
        let subrole = string(el, kAXSubroleAttribute) ?? ""
        return subrole == (kAXSecureTextFieldSubrole as String) || role == "AXSecureTextField"
    }

    // MARK: App quirks

    private static let chromiumBundlePrefixes = [
        "com.google.Chrome", "org.chromium", "com.brave.Browser", "com.microsoft.edgemac",
        "company.thebrowser", "com.vivaldi", "com.operasoftware",
    ]

    /// Gecko apps (Firefox and its forks, Thunderbird).
    private static let geckoBundlePrefixes = [
        "org.mozilla.", "app.zen-browser.", "io.gitlab.librewolf-community", "net.waterfox.", "one.ablaze.floorp",
    ]

    /// Gecko's `AXSelectedText` setter ignores the selection it reports: in a `contenteditable` it replaced the
    /// whole field with the replacement, in a `<textarea>` it wrote at another offset (Firefox, 2026-11-20), while
    /// `AXSelectedTextRange` and `AXSelectedText` read back the range asked for, so `select`'s proof can't catch
    /// it. These apps are written by select + paste only.
    static func neverWritesByAccessibility(pid: pid_t) -> Bool {
        guard let id = NSRunningApplication(processIdentifier: pid)?.bundleIdentifier else { return false }
        return geckoBundlePrefixes.contains(where: { id.hasPrefix($0) })
    }

    /// Electron apps and Chromium browsers keep their accessibility tree off until asked (PLAN.md §5).
    static func prepare(app: NSRunningApplication) {
        let el = AXUIElementCreateApplication(app.processIdentifier)
        AXUIElementSetAttributeValue(el, "AXManualAccessibility" as CFString, kCFBooleanTrue)
        if let id = app.bundleIdentifier, chromiumBundlePrefixes.contains(where: { id.hasPrefix($0) }) {
            AXUIElementSetAttributeValue(el, "AXEnhancedUserInterface" as CFString, kCFBooleanTrue)
        }
    }

    // MARK: Read

    static func focusedElement(pid: pid_t) -> AXUIElement? {
        let app = AXUIElementCreateApplication(pid)
        if let v = copy(app, kAXFocusedUIElementAttribute), CFGetTypeID(v) == AXUIElementGetTypeID() {
            return (v as! AXUIElement)
        }
        let sys = AXUIElementCreateSystemWide()
        if let v = copy(sys, kAXFocusedUIElementAttribute), CFGetTypeID(v) == AXUIElementGetTypeID() {
            return (v as! AXUIElement)
        }
        return nil
    }

    static func snapshot(pid: pid_t) throws -> FieldSnapshot {
        guard isTrusted(prompt: false) else { throw AXError2.notTrusted }
        // Secure input is system-wide: some app (often a password field or a terminal's
        // "Secure Keyboard Entry") has it on. Don't read anything while it's on.
        if IsSecureEventInputEnabled() { throw AXError2.secureInput }
        guard var el = focusedElement(pid: pid) else { throw AXError2.noFocusedField }
        if isSecureField(el) { throw AXError2.secureField }
        // The focused field may be one paragraph of a bigger document: the surface decides what the text is.
        var surface = SurfaceResolver.surface(for: el, pid: pid)
        if surface.isSecure { throw AXError2.secureField }
        var text = surface.text()
        if text == nil, missingTextError(el) == .appHidesText {
            // Chromium and Electron build their tree only after `prepare`: the first read can see a bare window.
            Thread.sleep(forTimeInterval: 0.3)
            if let again = focusedElement(pid: pid) {
                el = again
                if isSecureField(el) { throw AXError2.secureField }
                surface = SurfaceResolver.surface(for: el, pid: pid)
                if surface.isSecure { throw AXError2.secureField }
                text = surface.text()
            }
        }
        guard let text else {
            let error = missingTextError(el)
            Log.write("snapshot: no text, focused role \(string(el, kAXRoleAttribute) ?? "none") → \(error)")
            throw error
        }
        return FieldSnapshot(surface: surface, pid: pid, text: text, selection: surface.selection(),
                             frame: surface.frame())
    }

    private static let textRoles: Set<String> = ["AXTextArea", "AXTextField", "AXComboBox"]

    /// Why a focused element gave no text. A text role: the field hides its text (`noText`). The window or the app
    /// itself, with no text element anywhere in the window: the app draws its own text and shares nothing
    /// (`appHidesText`; Sublime Text reports its window as focused, probed 2026-11-16). Anything else (a button, a list,
    /// a window that does hold text fields): no text field is focused.
    static func missingTextError(_ el: AXUIElement) -> AXError2 {
        let role = string(el, kAXRoleAttribute) ?? ""
        if textRoles.contains(role) || isEditableWebArea(el) { return .noText }
        guard role == kAXWindowRole as String || role == kAXApplicationRole as String else { return .noFocusedField }
        return containsTextElement(el) ? .noFocusedField : .appHidesText
    }

    /// True when a text field or a web area sits under `el` (breadth-first, at most `budget` elements looked at).
    private static func containsTextElement(_ el: AXUIElement, budget: Int = 400) -> Bool {
        var queue = (copy(el, kAXChildrenAttribute) as? [AXUIElement]) ?? []
        var seen = 0
        while !queue.isEmpty, seen < budget {
            let child = queue.removeFirst()
            seen += 1
            let role = string(child, kAXRoleAttribute) ?? ""
            if textRoles.contains(role) || role == "AXWebArea" { return true }
            queue += (copy(child, kAXChildrenAttribute) as? [AXUIElement]) ?? []
        }
        // Out of budget: a big tree is a real UI with content, not a self-drawn editor.
        return seen >= budget
    }

    // MARK: Write

    /// Polls the element's text (`text(el)`) until `done` accepts it or `timeout` passes.
    /// Chromium and Electron update AXValue asynchronously after a write.
    static func waitForValue(_ el: AXUIElement, timeout: TimeInterval, until done: (String?) -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        repeat {
            if done(text(el)) { return true }
            Thread.sleep(forTimeInterval: 0.01)
        } while Date() < deadline
        return false
    }

    static func isFocused(_ el: AXUIElement, pid: pid_t) -> Bool {
        guard let f = focusedElement(pid: pid) else { return false }
        return CFEqual(f, el)
    }

    /// Polls `isFocused` until it holds or `timeout` passes. After our key panel hides, focus goes back to the
    /// target app's window a moment later (Electron reports no focused field while its window isn't key).
    static func waitForFocus(_ el: AXUIElement, pid: pid_t, timeout: TimeInterval) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        repeat {
            if isFocused(el, pid: pid) { return true }
            Thread.sleep(forTimeInterval: 0.01)
        } while Date() < deadline
        return false
    }

    /// What the app reports as focused, for the log: role and owning pid, no text.
    static func focusDescription(pid: pid_t) -> String {
        guard let f = focusedElement(pid: pid) else { return "nothing focused" }
        var owner: pid_t = 0
        AXUIElementGetPid(f, &owner)
        return "\(string(f, kAXRoleAttribute) ?? "?") in pid \(owner)" + (owner == pid ? "" : " (not the target app)")
    }

    /// Replaces `range` (which must still contain `original`) with `replacement` in `el`.
    ///
    /// Success means: the field changed, and everything up to the end of the replacement is what we expect.
    /// Text after the range isn't compared: some apps report it slightly differently after an edit, and
    /// edits are applied from the end, so that text was already handled.
    /// Tries the Accessibility API first. Falls back to select + paste only if the field is still untouched,
    /// the range could be selected, and `el` is still focused, so a keystroke never lands in another field.
    /// Paste uses the clipboard; the caller saves and restores it around the whole apply (`ClipboardGuard`).
    /// `beforeKeystroke` runs before the fallback's focus check and keys (e.g. to hide our panel so the keys reach
    /// the field); it runs only when the field is provably untouched.
    /// `pasteOnly` skips the Accessibility write (and its 1 s wait) when an earlier fix in this session already
    /// needed the paste fallback; the paste path keeps all of its checks. An editable web area (Mail compose)
    /// always pastes: it has no `AXSelectedText` to set, and its range is selected through text markers.
    static func replace(in el: AXUIElement, pid: pid_t, range: NSRange, original: String, replacement: String,
                        pasteOnly: Bool = false, beforeKeystroke: () -> Void = {}) -> Bool {
        let tag = "edit @\(range.location)+\(range.length) \(Log.pair(original, replacement))"
        guard let before = text(el) else {
            Log.write("\(tag): can't read value")
            return false
        }
        let bns = before as NSString
        guard NSMaxRange(range) <= bns.length, bns.substring(with: range) == original else {
            Log.write("\(tag): field no longer has the original text there: \(Log.snippet(before, around: range))")
            return false
        }
        let prefix = bns.substring(to: range.location) + replacement
        let applied: (String?) -> Bool = { v in
            guard let v, v != before else { return false }
            return v.hasPrefix(prefix)
        }

        var written = false
        if !pasteOnly, !isEditableWebArea(el), !neverWritesByAccessibility(pid: pid) {
            // The selection is proven (its text is `original`) before anything is written: Chrome's offsets can
            // land elsewhere while reading back as the range asked for.
            written = select(el, range, in: before) && setSelectedText(el, replacement)
            // The value decides, not the AX result: some apps (Telegram) apply the write and still return an
            // error. `applied` is the same strict check either way; a reported failure just gets a shorter wait.
            if waitForValue(el, timeout: written ? 1.0 : 0.3, until: applied) {
                Log.write("\(tag): ok (accessibility" + (written ? ")" : ", though the app reported an error)"))
                return true
            }
        }

        // Only fall back if the field is provably untouched; otherwise we'd risk a double insert.
        let now = text(el)
        guard now == before else {
            Log.write("\(tag): write=\(written), value changed unexpectedly: \(Log.snippet(now ?? "<nil>", around: range))")
            return false
        }
        // Our panels go first: while one of them is key, the target app may report no focused field (Electron,
        // e.g. Obsidian), and the keystrokes must reach the field anyway. The focus check itself stays strict.
        beforeKeystroke()
        // Keystrokes go to the frontmost app: it must be the field's (our panels never activate).
        guard NSWorkspace.shared.frontmostApplication?.processIdentifier == pid else {
            Log.write("\(tag): write=\(written), field unchanged but its app isn't in front; no paste fallback")
            return false
        }
        guard waitForFocus(el, pid: pid, timeout: 0.5) else {
            Log.write("\(tag): write=\(written), field unchanged and no longer focused (\(focusDescription(pid: pid))); no paste fallback")
            return false
        }
        guard select(el, range, in: before) else {
            Log.write("\(tag): write=\(written), field unchanged, and can't select the range for the paste fallback")
            return false
        }
        if replacement.isEmpty {
            guard range.length > 0 else { return true }
            postKey(51)  // Delete removes the selected range
        } else {
            pasteNow(replacement)
        }
        let ok = waitForValue(el, timeout: 1.5, until: applied)
        let after = Log.snippet(text(el) ?? "<nil>", around: range)
        Log.write("\(tag): " + (ok ? "ok (paste fallback)" : "paste fallback failed: \(after)"))
        return ok
    }

    static func postKey(_ code: CGKeyCode, flags: CGEventFlags = []) {
        let src = CGEventSource(stateID: .combinedSessionState)
        let down = CGEvent(keyboardEventSource: src, virtualKey: code, keyDown: true)
        let up = CGEvent(keyboardEventSource: src, virtualKey: code, keyDown: false)
        down?.flags = flags
        up?.flags = flags
        down?.post(tap: .cghidEventTap)
        up?.post(tap: .cghidEventTap)
    }

    /// Puts `text` on the clipboard and sends ⌘V. Does not restore the clipboard: see `ClipboardGuard`.
    static func pasteNow(_ text: String) {
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(text, forType: .string)
        postKey(9, flags: .maskCommand)  // 9 = V
    }
}

/// Saves the clipboard once before an apply and restores it once after, however many pastes happened.
final class ClipboardGuard {
    private let saved: [[NSPasteboard.PasteboardType: Data]]
    private let changeCount: Int

    init() {
        let pb = NSPasteboard.general
        changeCount = pb.changeCount
        saved = (pb.pasteboardItems ?? []).map { item in
            var d: [NSPasteboard.PasteboardType: Data] = [:]
            for t in item.types { if let v = item.data(forType: t) { d[t] = v } }
            return d
        }
    }

    /// Restores the saved contents, but only if we changed the clipboard. Delayed so the target app
    /// has read the last paste first.
    func restore(after delay: TimeInterval = 0.5) {
        let pb = NSPasteboard.general
        guard pb.changeCount != changeCount else { return }
        let saved = saved
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
            pb.clearContents()
            let items = saved.map { d -> NSPasteboardItem in
                let item = NSPasteboardItem()
                for (t, v) in d { item.setData(v, forType: t) }
                return item
            }
            if !items.isEmpty { pb.writeObjects(items) }
        }
    }
}

/// Local diagnostics log: ~/Library/Logs/Meboki/meboki.log (never leaves the Mac). Written only while
/// Settings › Privacy › Logs is on (default off).
enum Log {
    static var enabled: Bool { UserDefaults.standard.bool(forKey: AppSettings.Key.logEnabled) }
    static var snippetsEnabled: Bool { UserDefaults.standard.bool(forKey: AppSettings.Key.logSnippets) }

    static let url: URL = {
        let dir = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Logs/Meboki", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("meboki.log")
    }()

    static func write(_ line: String) {
        guard enabled else { return }
        let stamp = ISO8601DateFormatter().string(from: Date())
        let data = Data("\(stamp) \(line)\n".utf8)
        if let fh = try? FileHandle(forWritingTo: url) {
            fh.seekToEndOfFile()
            fh.write(data)
            try? fh.close()
        } else {
            try? data.write(to: url)
        }
    }

    /// "old" → "new" for a written edit: each side cut to 40 characters (a grouped write spans a sentence or
    /// more). With snippets off (the default), only the lengths.
    static func pair(_ old: String, _ new: String) -> String {
        guard snippetsEnabled else {
            return "(\(old.utf16.count) → \(new.utf16.count) chars)"
        }
        func cut(_ s: String) -> String { (s.count > 40 ? String(s.prefix(40)) + "…" : s).debugDescription }
        return "\(cut(old)) → \(cut(new))"
    }

    /// Up to 40 UTF-16 units either side of `range`, for debugging without logging whole documents. With
    /// Settings › Privacy › "Short text snippets in logs" off, only the length.
    static func snippet(_ s: String, around range: NSRange) -> String {
        let ns = s as NSString
        guard snippetsEnabled else {
            return "(len \(ns.length))"
        }
        let lo = max(0, min(range.location, ns.length) - 40)
        let hi = min(ns.length, NSMaxRange(range) + 40)
        return ns.substring(with: NSRange(location: lo, length: hi - lo)).debugDescription + " (len \(ns.length))"
    }
}
