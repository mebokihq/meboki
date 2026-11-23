import AppKit
import ApplicationServices
import MebokiCore

/// Safari 27's multi-paragraph `contenteditable` fields: `AXValue` has two `\n` between paragraphs, while
/// `AXBoundsForRange`, `AXSelectedTextRange` and `AXVisibleCharacterRange` count one (`ParagraphBreakMap`). Probed
/// 2026-11-23 in Proton Docs, Safari 27.2 on macOS 27.2.1: underlines drifted right by a character per paragraph
/// and Apply pasted that far from the fix. Safari 26 counts the same everywhere.
///
/// A field gets the conversion only when both hold: its app is Safari 27 or later (or Safari Technology Preview),
/// and the field shows the quirk itself: at a paragraph start after a `\n\n`, the rect asked for `start − shift`
/// sits on the same line and left of the rect asked for `start`. A `<textarea>` with typed blank lines (real `\n\n`)
/// never passes: there `start − shift` is a line break on an earlier line. The `AX` helpers ask `offsets(for:)`
/// and convert; everything else keeps value offsets.
enum WebKitParagraphBreaks {
    private struct Verdict { let element: AXUIElement; let collapsed: Bool }

    nonisolated(unsafe) private static var verdicts: [Verdict] = []
    nonisolated(unsafe) private static var cached: (element: AXUIElement, value: String, map: ParagraphBreakMap)?
    nonisolated(unsafe) private static var appVersions: [pid_t: Bool] = [:]

    nonisolated(unsafe) private static var setters: [(element: AXUIElement, once: Bool)] = []

    /// How `el`'s `AXSelectedTextRange` setter counts, once a selection was proven: true when it takes one break
    /// per paragraph (like its getter), false when it takes value offsets; nil before the first proof.
    static func setterCounts(_ el: AXUIElement) -> Bool? {
        setters.first(where: { CFEqual($0.element, el) })?.once
    }

    static func learnSetter(_ el: AXUIElement, countsBreaksOnce once: Bool) {
        guard setterCounts(el) != once else { return }
        setters.removeAll { CFEqual($0.element, el) }
        setters.append((el, once))
        if setters.count > 32 { setters.removeFirst(setters.count - 32) }
        Log.write("paragraph breaks: the selection setter takes \(once ? "one break per paragraph" : "value offsets")")
    }

    /// The map for `el` when it has the quirk and its value has breaks to collapse; nil otherwise (value offsets
    /// are WebKit's). `text` is the value when the caller has just read it.
    static func map(for el: AXUIElement, text: String? = nil) -> ParagraphBreakMap? {
        guard let collapsed = verdict(el), collapsed else { return nil }
        guard let value = text ?? AX.string(el, kAXValueAttribute) else { return nil }
        if let c = cached, CFEqual(c.element, el), c.value == value { return c.map.isIdentity ? nil : c.map }
        let map = ParagraphBreakMap(text: value)
        cached = (el, value, map)
        return map.isIdentity ? nil : map
    }

    /// Cached per field; nil while it can't be told yet (no paragraph break to test on).
    private static func verdict(_ el: AXUIElement) -> Bool? {
        var pid: pid_t = 0
        guard AXUIElementGetPid(el, &pid) == .success, isSafari27OrLater(pid) else { return false }
        if let v = verdicts.first(where: { CFEqual($0.element, el) }) { return v.collapsed }
        guard let found = decide(el) else { return nil }
        verdicts.append(Verdict(element: el, collapsed: found))
        if verdicts.count > 32 { verdicts.removeFirst(verdicts.count - 32) }
        return found
    }

    private static func decide(_ el: AXUIElement) -> Bool? {
        guard AX.string(el, kAXRoleAttribute) == "AXTextArea", !AX.isEditableWebArea(el) else { return false }
        guard let value = AX.string(el, kAXValueAttribute) else { return nil }
        let map = ParagraphBreakMap(text: value)
        let starts = map.paragraphStarts(in: value)
        guard !starts.isEmpty else { return nil }
        var yes = 0, no = 0
        for s in starts where s.shift > 0 {
            guard let at = AX.rawBounds(el, NSRange(location: s.index, length: 1)),
                  let back = AX.rawBounds(el, NSRange(location: s.index - s.shift, length: 1)) else { no += 1; continue }
            if abs(at.midY - back.midY) < max(2, at.height / 2), back.minX < at.minX - 1 { yes += 1 } else { no += 1 }
        }
        let collapsed = yes > 0 && yes >= no
        Log.write("paragraph breaks: \(collapsed ? "field counts one break per paragraph in positions and selection; converting offsets" : "positions count like the text") (\(yes) of \(yes + no) paragraph starts)")
        return collapsed
    }

    /// Safari or Safari Technology Preview, version 27 or later (Technology Preview always counts).
    private static func isSafari27OrLater(_ pid: pid_t) -> Bool {
        if let known = appVersions[pid] { return known }
        var result = false
        if let app = NSRunningApplication(processIdentifier: pid), let id = app.bundleIdentifier {
            if id == "com.apple.SafariTechnologyPreview" {
                result = true
            } else if id == "com.apple.Safari", let url = app.bundleURL,
                      let v = Bundle(url: url)?.infoDictionary?["CFBundleShortVersionString"] as? String,
                      let major = Int(v.split(separator: ".").first ?? "") {
                result = major >= 27
            }
        }
        appVersions[pid] = result
        return result
    }
}
