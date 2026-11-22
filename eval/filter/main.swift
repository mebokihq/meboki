// Applies MebokiCore's post-filters to recorded model replies, so eval/settings_report.py scores the
// settings (English variant, check level, casual, protected tokens) with exactly the app's code.
//
// stdin:  one JSON object per line: {"input", "output", "variant": "US"|"UK", "level": "spelling"|"grammar"|"full",
//         "casual": bool, "protect": bool, "unfiltered": bool (PostFilter.judge only, the pre-stage-9 behavior)}
// stdout: one JSON object per line: {"final": text after the kept edits, "verdict": "unchanged"|"rejected"|"edited"}
//
// `--print-prompts` prints {"US": Prompt.system, "UK": Prompt.systemUK} instead, so the report can check that
// eval/bench.py's prompts are byte-identical to the app's. `--language`: see below.
import Foundation
import MebokiCore

if CommandLine.arguments.contains("--print-prompts") {
    let data = try JSONSerialization.data(withJSONObject: ["US": Prompt.system(for: .us), "UK": Prompt.system(for: .uk)])
    FileHandle.standardOutput.write(data + Data("\n".utf8))
    exit(0)
}

let encoder = JSONEncoder()
encoder.outputFormatting = [.withoutEscapingSlashes]

// `--language`: stdin one JSON object per line {"text"}; stdout {"foreign": [sentences the check leaves out]}
// (`LanguageGate.foreignRanges`, what the app never sends to the model). For eval/language_report.py.
if CommandLine.arguments.contains("--language") {
    while let line = readLine(strippingNewline: true) {
        guard !line.isEmpty,
              let obj = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any],
              let text = obj["text"] as? String
        else {
            FileHandle.standardError.write(Data("bad line: \(line.prefix(80))\n".utf8))
            exit(1)
        }
        let ns = text as NSString
        let foreign = LanguageGate.foreignRanges(in: text).map { ns.substring(with: $0) }
        FileHandle.standardOutput.write(try encoder.encode(["foreign": foreign]) + Data("\n".utf8))
    }
    exit(0)
}
// `--code`: stdin one JSON object per line {"text"}; stdout {"code": bool, "codeChars", "totalChars", "codeLines",
// "lines", "strongLines", "residual": bool, "skip": bool, "blocks": [[location, length], …]} (`CodeDetector.scan`:
// the verdict and residual prose as the app's main thread sees them (10k cap); `blocks` from the whole text, as the
// check pipeline protects them; `skip` is `skipsAutomaticCheck` with protection on). For eval/code_report.py.
if CommandLine.arguments.contains("--code") {
    while let line = readLine(strippingNewline: true) {
        guard !line.isEmpty,
              let obj = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any],
              let text = obj["text"] as? String
        else {
            FileHandle.standardError.write(Data("bad line: \(line.prefix(80))\n".utf8))
            exit(1)
        }
        let scan = CodeDetector.scan(text)
        let v = scan.verdict
        let out: [String: Any] = ["code": v.isCode, "codeChars": v.codeChars, "totalChars": v.totalChars,
                                  "codeLines": v.codeLines, "lines": v.lines, "strongLines": v.strongLines,
                                  "residual": scan.hasResidualProse,
                                  "skip": CodeDetector.skipsAutomaticCheck(scan, protectTokens: true),
                                  "blocks": CodeDetector.blocks(in: text).map { [$0.location, $0.length] }]
        FileHandle.standardOutput.write(try JSONSerialization.data(withJSONObject: out) + Data("\n".utf8))
    }
    exit(0)
}
// `--rewrite`: stdin {"input", "output"} (a recorded model reply); stdout {"verdict", "edits", "grouped", "fixes"}:
// the verdict of `PostFilter.judge`, the edits before and after `RewriteDetector.group`, and the grouped
// edits' categories. For eval/rewrite_report.py.
if CommandLine.arguments.contains("--rewrite") {
    while let line = readLine(strippingNewline: true) {
        guard !line.isEmpty,
              let obj = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any],
              let input = obj["input"] as? String, let output = obj["output"] as? String
        else { FileHandle.standardError.write(Data("bad line\n".utf8)); exit(1) }
        var out: [String: Any] = [:]
        switch PostFilter.judge(input: input, rawOutput: output) {
        case .unchanged: out = ["verdict": "unchanged", "edits": 0, "grouped": 0, "fixes": [String]()]
        case .rejected: out = ["verdict": "rejected", "edits": 0, "grouped": 0, "fixes": [String]()]
        case .corrected(let fixed):
            var o = CheckOptions(); o.groupRewrites = false
            let plain = ProofreadEngine.edits(chunk: input, corrected: fixed, options: o)
            let grouped = ProofreadEngine.edits(chunk: input, corrected: fixed, options: CheckOptions())
            out = ["verdict": "corrected", "edits": plain.count, "grouped": grouped.count,
                   "fixes": grouped.map { FixClassifier.classify($0, in: input).rawValue },
                   "ratio": RewriteDetector.structuralRatio(plain, sentence: input)]
        }
        FileHandle.standardOutput.write(try JSONSerialization.data(withJSONObject: out) + Data("\n".utf8))
    }
    exit(0)
}
// `--false-fixes`: replays eval/false_fixes.jsonl through `CheckPipeline` with a recorded-reply model.
// stdin one case per line: {"id", "options"?: {"variant", "level", "casual", "protect"}, and either
//   "input", "output", "expected" (one check of one paragraph), or
//   "steps": [{"text", "replies": {sent text: reply}, "expected", "typing"?: bool, "cursor"?: Int,
//   "notSent"?: [substrings no text sent to the model may contain]}]
//   (checks in order on one pipeline, so the sentence cache carries over, as while typing)}.
// A sent text with no recorded reply comes back unchanged. The cursor defaults to the end of the text.
// stdout one line per step: {"id", "step", "ok", "got", "expected", "sent": [texts sent to the model]}.
if CommandLine.arguments.contains("--false-fixes") {
    final class Replay: Corrector, @unchecked Sendable {
        let lock = NSLock()
        var replies: [String: String] = [:]
        var sent: [String] = []
        func correct(_ text: String, system: String) async throws -> LLMClient.Reply {
            let out = lock.withLock { () -> String in sent.append(text); return replies[text] ?? text }
            return LLMClient.Reply(text: out, truncated: false)
        }
    }
    while let line = readLine(strippingNewline: true) {
        guard !line.isEmpty,
              let obj = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any],
              let id = obj["id"] as? String
        else { FileHandle.standardError.write(Data("bad line: \(line.prefix(80))\n".utf8)); exit(1) }
        let o = obj["options"] as? [String: Any] ?? [:]
        let options = CheckOptions(
            variant: EnglishVariant(rawValue: o["variant"] as? String ?? "US") ?? .us,
            level: CheckLevel(rawValue: o["level"] as? String ?? "full") ?? .full,
            casual: o["casual"] as? Bool ?? false,
            protectTokens: o["protect"] as? Bool ?? true)
        var steps = obj["steps"] as? [[String: Any]] ?? []
        if steps.isEmpty, let input = obj["input"] as? String, let output = obj["output"] as? String,
           let expected = obj["expected"] as? String {
            steps = [["text": input, "replies": [input: output], "expected": expected]]
        }
        guard !steps.isEmpty else { FileHandle.standardError.write(Data("no steps: \(id)\n".utf8)); exit(1) }
        let model = Replay()
        let pipe = CheckPipeline(client: model, options: options)
        for (i, step) in steps.enumerated() {
            guard let text = step["text"] as? String, let expected = step["expected"] as? String
            else { FileHandle.standardError.write(Data("bad step \(i): \(id)\n".utf8)); exit(1) }
            model.lock.withLock {
                model.replies.merge(step["replies"] as? [String: String] ?? [:]) { $1 }
                model.sent = []
            }
            let cursor = step["cursor"] as? Int ?? (text as NSString).length
            let scope = CheckPipeline.Scope(cursor: cursor, maxLength: .max, typing: step["typing"] as? Bool ?? false)
            let got = Diff.apply(try await pipe.check(text, scope: scope).edits, to: text)
            let sent = model.lock.withLock { model.sent }
            let leaked = (step["notSent"] as? [String] ?? []).filter { part in sent.contains { $0.contains(part) } }
            let out: [String: Any] = ["id": id, "step": i, "ok": got == expected && leaked.isEmpty, "got": got,
                                      "expected": expected, "sent": sent, "leaked": leaked]
            FileHandle.standardOutput.write(try JSONSerialization.data(withJSONObject: out) + Data("\n".utf8))
        }
    }
    exit(0)
}

while let line = readLine(strippingNewline: true) {
    guard !line.isEmpty,
          let obj = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any],
          let input = obj["input"] as? String, let output = obj["output"] as? String
    else {
        FileHandle.standardError.write(Data("bad line: \(line.prefix(80))\n".utf8))
        exit(1)
    }
    let options = CheckOptions(
        variant: EnglishVariant(rawValue: obj["variant"] as? String ?? "US") ?? .us,
        level: CheckLevel(rawValue: obj["level"] as? String ?? "full") ?? .full,
        casual: obj["casual"] as? Bool ?? false,
        protectTokens: obj["protect"] as? Bool ?? false)
    // The app checks trimmed paragraphs (ProofreadEngine.chunks); dataset items are single trimmed lines.
    let final: String, verdict: String
    if obj["unfiltered"] as? Bool ?? false {
        // Before stage 9: PostFilter.judge only, the whole corrected text (what eval/guard.py scores).
        switch PostFilter.judge(input: input, rawOutput: output) {
        case .unchanged: (final, verdict) = (input, "unchanged")
        case .rejected: (final, verdict) = (input, "rejected")
        case .corrected(let fixed): (final, verdict) = (fixed, "edited")
        }
    } else {
        switch ProofreadEngine.process(chunk: input, rawOutput: output, options: options) {
        case .unchanged: (final, verdict) = (input, "unchanged")
        case .rejected: (final, verdict) = (input, "rejected")
        case .edits(let edits): (final, verdict) = (Diff.apply(edits, to: input), "edited")
        }
    }
    let data = try encoder.encode(["final": final, "verdict": verdict])
    FileHandle.standardOutput.write(data + Data("\n".utf8))
}
