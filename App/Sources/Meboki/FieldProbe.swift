#if DEBUG
import AppKit

/// DEBUG-only: `.build/debug/Meboki --probe-field <bundle id> [word …] [--select word] [--caret word]
/// [--write word replacement]` reads the app's focused field the way a check does and prints what the text
/// adapter sees: role, kind, text length, selection, and the bounds of each `word` (native and adapted).
/// `--select` / `--caret` (after the word) only move the selection. `--write` is for test pages only: a proven
/// selection, then an Accessibility write (`AXSelectedText`); never keystrokes, so it's safe with the app in the
/// background. For app-compatibility notes (PLAN.md §5) and the text-marker adapter (`RichText.swift`).
/// Prints only lengths and the words asked for, never the field's text.
enum FieldProbe {
    static func run(_ args: [String]) {
        guard let i = args.firstIndex(of: "--probe-field"), args.indices.contains(i + 1),
              let app = NSRunningApplication.runningApplications(withBundleIdentifier: args[i + 1]).first else {
            print("usage: --probe-field <running app bundle id> [word …] [--select word]")
            return
        }
        AX.prepare(app: app)
        Thread.sleep(forTimeInterval: 0.3)
        guard let el = AX.focusedElement(pid: app.processIdentifier) else { print("nothing focused"); return }
        let role = AX.string(el, kAXRoleAttribute) ?? "?"
        print("role \(role), editable web area \(AX.isEditableWebArea(el)), automatic-check target \(AX.isEditableTextArea(el))")
        let t0 = Date()
        guard let text = AX.text(el) else { print("no text (\(AX.missingTextError(el)))"); return }
        let ns = text as NSString
        print("text \(ns.length) UTF-16, AXValue \((AX.string(el, kAXValueAttribute) as NSString?)?.length ?? -1)"
            + String(format: ", read in %.0f ms", Date().timeIntervalSince(t0) * 1000))
        print("selection \(AX.selection(el).map(NSStringFromRange) ?? "nil"), visible \(AX.visibleCharacterRange(el).map(NSStringFromRange) ?? "nil")")
        print("frame \(AX.frame(el).map { NSStringFromRect($0) } ?? "nil"), visible frame \(AX.visibleFrame(el).map { NSStringFromRect($0) } ?? "nil")")
        let leafRange = AX.leafVisibleRange(el, text: text) { print("  leaves: \($0)") }
        print("leaf visible range \(leafRange.map(NSStringFromRange) ?? "nil")")
        let t1 = Date()
        let has = AX.hasTextBounds(el, text: text, visible: AX.visibleCharacterRange(el))
        print("hasTextBounds \(has)" + String(format: " (%.0f ms)", Date().timeIntervalSince(t1) * 1000))
        var words: [String] = []
        var select: String?, caret: String?, write: (String, String)?
        var j = i + 2
        while j < args.count {
            if args[j] == "--select", args.indices.contains(j + 1) { select = args[j + 1]; j += 2; continue }
            if args[j] == "--caret", args.indices.contains(j + 1) { caret = args[j + 1]; j += 2; continue }
            if args[j] == "--write", args.indices.contains(j + 2) { write = (args[j + 1], args[j + 2]); j += 3; continue }
            words.append(args[j]); j += 1
        }
        for w in words {
            let r = ns.range(of: w)
            guard r.location != NSNotFound else { print("\(w.debugDescription): not in the text"); continue }
            let t = Date()
            let lines = AX.lineRects(el, range: r, in: text)?.map { NSStringFromRect($0) } ?? []
            print("\(w.debugDescription) @\(r.location)+\(r.length): native \(AX.nativeBounds(el, r).map { NSStringFromRect($0) } ?? "nil"), "
                + "bounds \(AX.bounds(el, r, text: text).map { NSStringFromRect($0) } ?? "nil"), lines \(lines)"
                + String(format: " (%.0f ms)", Date().timeIntervalSince(t) * 1000))
        }
        if let select {
            let r = ns.range(of: select)
            guard r.location != NSNotFound else { print("select: not in the text"); return }
            let ok = AX.select(el, r, in: text)
            Thread.sleep(forTimeInterval: 0.1)
            print("select \(NSStringFromRange(r)): \(ok), now \(AX.selection(el).map(NSStringFromRange) ?? "nil")")
        }
        if let caret {
            let r = ns.range(of: caret)
            guard r.location != NSNotFound else { print("caret: not in the text"); return }
            print("caret after \(caret.debugDescription) @\(NSMaxRange(r)): \(AX.select(el, NSRange(location: NSMaxRange(r), length: 0), in: text))")
        }
        if let (word, replacement) = write {
            let r = ns.range(of: word)
            guard r.location != NSNotFound else { print("write: not in the text"); return }
            guard AX.select(el, r, in: text) else { print("write: selection not proven; nothing written"); return }
            let ok = AX.setSelectedText(el, replacement)
            let expected = ns.replacingCharacters(in: r, with: replacement)
            let applied = AX.waitForValue(el, timeout: 1) { $0 == expected }
            print("write \(word.debugDescription) → \(replacement.debugDescription) @\(r.location): AX \(ok), field as expected \(applied)")
        }
    }
}
#endif
