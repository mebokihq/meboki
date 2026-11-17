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
// "lines"} (`CodeDetector.verdict`: the automatic check skips a field that looks like code). For eval/code_report.py.
if CommandLine.arguments.contains("--code") {
    while let line = readLine(strippingNewline: true) {
        guard !line.isEmpty,
              let obj = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any],
              let text = obj["text"] as? String
        else {
            FileHandle.standardError.write(Data("bad line: \(line.prefix(80))\n".utf8))
            exit(1)
        }
        let v = CodeDetector.verdict(text)
        let out: [String: Any] = ["code": v.isCode, "codeChars": v.codeChars, "totalChars": v.totalChars,
                                  "codeLines": v.codeLines, "lines": v.lines, "strongLines": v.strongLines]
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
