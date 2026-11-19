import Foundation

/// Tells a field that holds code (a script, JSON, a terminal session, a stack trace) from prose, so the automatic
/// check leaves it alone in apps that aren't on the built-in skip list (`AppRules`). ⌃⌥G still checks it.
///
/// Precision first: a prose field taken for code silently loses its automatic check (and feeds learned Manual,
/// `CodeAppLearner`). Every line gets a level:
/// - **strong**: shapes prose never has (comments and directives, brace and bracket lines, a line ending in `{`,
///   tags, JSON, declarations, module imports, `def f(…):`, shell prompts, stack frames, `ls -l` lines, fenced
///   blocks, block comments);
/// - **weak**: shapes that chat and notes share with code (`x = 3`, `a -> b`, `;` endings, `$VARS`, symbol
///   density, keywords, calls). A line that reads as a sentence is never weak code.
/// A field is code only when code lines (strong or weak) hold at least `minCodeChars` characters, `minCodeShare`
/// of all characters and half of the lines, **and** at least two lines are strong (one in a one-line field). So
/// weak signals alone, however many, never make a field code. Scored by `eval/code_report.py` (the repo's prose
/// and code, plus `eval/code_cases.json`: adversarial prose from a review).
public enum CodeDetector {
    public struct Verdict: Equatable, Sendable {
        /// Characters (trimmed, non-empty lines) in code lines and in all lines.
        public var codeChars = 0
        public var totalChars = 0
        public var codeLines = 0
        public var lines = 0
        /// Lines with a strong code shape.
        public var strongLines = 0

        public var isCode: Bool {
            codeChars >= CodeDetector.minCodeChars
                && Double(codeChars) >= CodeDetector.minCodeShare * Double(totalChars)
                && codeLines * 2 >= lines
                && strongLines >= min(2, lines)
        }
    }

    enum Level: Comparable { case none, weak, strong }

    public static let minCodeChars = 80
    public static let minCodeShare = 0.7
    /// Only the start of a field is looked at: the check runs on every edit, on the main thread, and the start
    /// of a code field is code.
    public static let maxScanCharacters = 10_000
    /// A long line (minified JSON) is judged by its start; this also bounds every pattern's work per line.
    static let maxLineCharacters = 500

    public static func looksLikeCode(_ text: String) -> Bool {
        verdict(text).isCode
    }

    public static func verdict(_ text: String) -> Verdict {
        var v = Verdict()
        let scan = text.utf16.count > maxScanCharacters ? String(text.prefix(maxScanCharacters)) : text
        let rows = scan.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline)
        // Too short to be code (`minCodeChars`): counted, not judged.
        if scan.utf16.count < minCodeChars {
            for row in rows {
                let n = row.trimmingCharacters(in: .whitespaces).count
                if n > 0 { v.lines += 1; v.totalChars += n }
            }
            return v
        }
        // A fence that never closes (a chat message with one stray ```) opens nothing.
        let fences = rows.indices.filter { isFence(rows[$0]) }
        let lastFence = fences.count % 2 == 1 ? fences.last : nil

        var fenced = false        // inside a Markdown ``` block
        var docstring = false     // inside a Python """ string
        var blockComment = false  // inside /* … */
        var shellOutput = false   // after a `$ command` line: its output, until a blank line or a sentence
        for (i, row) in rows.enumerated() {
            let line = row.trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty else {
                shellOutput = false
                continue
            }
            let level: Level
            if isFence(row), i != lastFence {
                fenced.toggle()
                level = .strong
            } else if fenced {
                level = .strong
            } else if blockComment {
                level = .strong
                if line.contains("*/") { blockComment = false }
            } else if matches(shellPrompt, line) {
                shellOutput = true
                level = .strong
            } else if shellOutput, !isSentence(line) {
                level = .weak
            } else {
                shellOutput = false
                let quotes = line.components(separatedBy: "\"\"\"").count - 1
                if docstring || quotes > 0 {
                    if quotes % 2 == 1 { docstring.toggle() }
                    level = .weak
                } else {
                    level = lineLevel(row.count > maxLineCharacters ? row.prefix(maxLineCharacters) : row)
                    if line.hasPrefix("/*"), !line.contains("*/") { blockComment = true }
                }
            }
            let n = line.count
            v.lines += 1
            v.totalChars += n
            if level != .none {
                v.codeLines += 1
                v.codeChars += n
            }
            if level == .strong { v.strongLines += 1 }
        }
        return v
    }

    /// A fence line: ``` at the start, not closed on the same line (```git pull``` is inline code).
    static func isFence(_ row: Substring) -> Bool {
        let line = row.trimmingCharacters(in: .whitespaces)
        return line.hasPrefix("```") && !line.dropFirst(3).contains("```")
    }

    // MARK: Lines

    static func lineLevel(_ raw: Substring) -> Level {
        var indent = 0
        for ch in raw {
            if ch == " " { indent += 1 } else if ch == "\t" { indent += 4 } else { break }
        }
        let trimmed = raw.trimmingCharacters(in: .whitespaces)

        // Strong shapes: prose never looks like these.
        if strongPrefixes.contains(where: { trimmed.hasPrefix($0) }) { return .strong }
        if trimmed.allSatisfy({ "{}[]();,".contains($0) }) || trimmed.hasSuffix("{") { return .strong }
        for re in strongShapes where matches(re, trimmed) { return .strong }
        // An assignment from a member call: `res = json.load(open(f))` (math homework has no dotted calls).
        if matches(assignment, trimmed), matches(callChain, trimmed) { return .strong }

        // Markdown list, quote and heading markers go; links and URLs become plain words.
        let (body, listItem) = stripMarkdown(trimmed)
        guard !body.isEmpty, !isSentence(body) else { return .none }

        // Weak shapes: code, but chat and notes have them too.
        if pythonBlocks.contains(body) || body.hasSuffix(" \\") || body.contains(" // ") { return .weak }
        for re in weakShapes where matches(re, body) { return .weak }
        if isShellCommand(body) { return .weak }
        if body.hasSuffix(";"), body.contains(where: { "(=)[".contains($0) }) { return .weak }
        if startsWithKeyword(body), body.hasSuffix(";") || codeOperators.contains(where: body.contains) { return .weak }

        // Symbol density: code is full of brackets and operators, prose isn't.
        var symbols = 0, visible = 0
        for ch in body where !ch.isWhitespace {
            visible += 1
            if densitySymbols.contains(ch) { symbols += 1 }
        }
        if symbols >= 3, Double(symbols) >= 0.12 * Double(visible) { return .weak }
        // An indented line with code punctuation (not a nested list item).
        if indent >= 2, !listItem, body.contains(where: { "(){}[];=".contains($0) }) { return .weak }
        return .none
    }

    static var strongShapes: [NSRegularExpression] {
        [tagLine, jsonKey, jsonStart, stringConcatenation, stackFrame, fileMode, declaration, moduleImport,
         pythonDefinition, callDecorator, memberCallLine, shellScript, sqlStatement]
    }
    static var weakShapes: [NSRegularExpression] {
        [pythonHeader, assignment, decorator, importLine, caseLine, returnLine, shellVariable, stringLiteral,
         loneCall, operatorContinuation, sql, callChain]
    }

    static let strongPrefixes = ["//", "/*", "*/", "#include", "#import", "#define", "#if ", "#ifdef", "#endif",
                                 "#pragma", "#else", "#elseif", "#!", "<?php", "<?xml", "<!DOCTYPE", "<!doctype", "<html", "Traceback (most recent call last)"]
    /// Lines that are one block keyword (common English words like "done" or "pass" are left out).
    static let pythonBlocks: Set<String> = ["else:", "try:", "finally:", "fi", "esac", "end;", "};"]
    static let keywords = ["func", "def", "fn", "let", "var", "const", "val", "import", "from", "package", "class",
                           "struct", "enum", "interface", "protocol", "extension", "public", "private", "protected",
                           "internal", "static", "return", "if", "else", "elif", "for", "while", "switch", "case",
                           "guard", "try", "catch", "except", "async", "await", "export", "type", "impl", "pub",
                           "use", "throw", "raise", "yield", "echo", "local"]
    static let codeOperators = ["==", "!=", "&&", "||", ":=", "+=", "-=", "=>", "->", "::", "){", ") {"]
    static let densitySymbols: Set<Character> = ["{", "}", "[", "]", "(", ")", "<", ">", ";", "=", "$", "\\", "&",
                                                 "^", "~"]
    static let shellCommands: Set<String> = [
        "git", "npm", "npx", "yarn", "pnpm", "brew", "pip", "pip3", "python", "python3", "node", "cargo", "go",
        "swift", "make", "docker", "kubectl", "curl", "wget", "ssh", "scp", "cd", "ls", "cat", "grep", "rm", "mv",
        "cp", "mkdir", "chmod", "chown", "sudo", "export", "source", "xcodebuild", "defaults", "codesign", "tail",
        "kill", "ps", "find", "sed", "awk", "set", "cmake", "otool", "pkill", "killall", "xcrun", "launchctl",
        "swiftc", "clang", "tar", "zip", "unzip", "ln", "touch", "open", "env", "uv",
    ]

    static func startsWithKeyword(_ s: String) -> Bool {
        keywords.contains { k in
            guard s.hasPrefix(k) else { return false }
            let rest = s.dropFirst(k.count)
            return rest.first == " " || rest.first == "("
        }
    }

    /// A shell command line: a known command, then a flag, a path, a pipe or a redirect.
    static func isShellCommand(_ s: String) -> Bool {
        let words = s.split(separator: " ")
        guard let first = words.first, shellCommands.contains(String(first)), words.count >= 2 else { return false }
        return words.dropFirst().contains { w in
            matches(flag, String(w)) || w.hasPrefix("/") || w.hasPrefix("./") || w.hasPrefix("~/")
                || w == "|" || w == ">" || w == ">>" || w == "&&"
        }
    }

    /// Reads as a sentence: starts with a capital (or a digit), ends with . ! ? (maybe in quotes or brackets),
    /// at least four words with letters. Code lines almost never do all three.
    static func isSentence(_ s: String) -> Bool {
        guard let first = s.first, first.isUppercase || first.isNumber else { return false }
        guard let e = s.reversed().drop(while: { "\"'”’)]*_".contains($0) }).first, ".!?".contains(e) else {
            return false
        }
        let words = s.split(separator: " ").filter { $0.contains(where: \.isLetter) }
        return words.count >= 4
    }

    /// Drops a leading list, task, quote or heading marker, and turns links and URLs into plain words.
    static func stripMarkdown(_ s: String) -> (String, listItem: Bool) {
        var body = s
        var listItem = false
        let ns = body as NSString
        if let m = listMarker.firstMatch(in: body, range: NSRange(location: 0, length: ns.length)) {
            body = ns.substring(from: m.range.length)
            listItem = true
        }
        var out = body as NSString
        out = mdLink.stringByReplacingMatches(in: out as String, range: NSRange(location: 0, length: out.length),
                                              withTemplate: "$1") as NSString
        out = url.stringByReplacingMatches(in: out as String, range: NSRange(location: 0, length: out.length),
                                           withTemplate: "link") as NSString
        return ((out as String).trimmingCharacters(in: .whitespaces), listItem)
    }

    static func matches(_ re: NSRegularExpression, _ s: String) -> Bool {
        re.firstMatch(in: s, range: NSRange(location: 0, length: (s as NSString).length)) != nil
    }

    static let listMarker = try! NSRegularExpression(pattern: #"^(?:(?:[-*+•]|\d{1,3}[.)])\s+(?:\[[ xX]\]\s+)?|>+\s*|#{1,6}\s+)"#)
    static let mdLink = try! NSRegularExpression(pattern: #"!?\[([^\]]*)\]\([^)\s]*\)"#)
    static let url = try! NSRegularExpression(pattern: #"\b(?:https?|ftp)://\S+"#)
    /// `-la`, `--build`, `-j`: a command-line flag (`--` alone, a dash in prose, isn't one).
    static let flag = try! NSRegularExpression(pattern: #"^--?[A-Za-z][\w-]*(?:=\S*)?$"#)

    // Strong

    /// `<div class="x">`, `</p>`, `<br/>`: a line that is one tag or starts and ends with tags.
    static let tagLine = try! NSRegularExpression(pattern: #"^</?[A-Za-z][\w:-]*+(?:\s[^<>]*)?/?>(?:.*>)?$"#)
    /// `"name": "Proofreader",`, `"count": 3`, `"items": [` in JSON: a key, then a JSON value.
    static let jsonKey = try! NSRegularExpression(pattern: #"^"[^"]{1,80}"\s*:\s*(?:"(?:[^"\\]|\\.)*"|-?\d[\d.eE+-]*|true|false|null|\{|\[)\s*(?:,|\{|\[|\}|\])?$"#)
    /// Minified JSON on one line: `{"id": …` or `[{"id": …`.
    static let jsonStart = try! NSRegularExpression(pattern: #"^\[?\{\s*"[^"]{1,80}"\s*:"#)
    /// `+ "more text"`: a string concatenation continued on the next line.
    static let stringConcatenation = try! NSRegularExpression(pattern: #"^\+\s*""#)
    /// Stack frames and errors: `File "x.py", line 3, in main`, `at Foo.bar (app.js:12:5)`, `KeyError: 'key'`,
    /// `#3 0x00012ab in main`, `Thread 0 Crashed:`, `2  libsystem 0x0001 …`.
    static let stackFrame = try! NSRegularExpression(pattern: #"^File "[^"]+", line \d+|^at [\w$<>]++(?:\.[\w$<>\[\]]++)++ ?\(.*:\d+(?::\d+)?\)$|^[A-Z]\w*+(?:Error|Exception)(?::\s|$)|^#\d+\s+0x[0-9a-fA-F]+|^Thread \d+ Crashed|^\d+\s+\S+\s+0x[0-9a-fA-F]+ "#)
    /// `ls -l` output: `-rw-r--r--  1 user  staff  …`, `drwxr-xr-x@ …`.
    static let fileMode = try! NSRegularExpression(pattern: #"^[-dlcbps][rwxsStT-]{9}[@+.]?\s"#)
    /// `let rgb: UInt32`, `@Published var pane: SettingsPane`, `private var window: NSWindow?`, `const x = 1`.
    static let declaration = try! NSRegularExpression(pattern: #"^(?:(?:@\w+(?:\([^)]*\))?|public|private|fileprivate|internal|open|static|final|override|weak|lazy|nonisolated|mutating|export|default|readonly|async)\s+)*(?:let|var|const|val)\s+[A-Za-z_$][\w$]*\s*(?::\s*[A-Z\[(]|=)"#)
    /// `import SwiftUI`, `@testable import MebokiCore`, `import os.path`, `from x import y`,
    /// `import { a } from "b"`, `import React from 'react'`.
    static let moduleImport = try! NSRegularExpression(pattern: #"^(?:@testable\s+)?import\s+(?:[A-Z][\w.]*|\w+(?:\.\w+)+|\{.*\}\s+from\s+["'].*|\w+\s+from\s+["'].*)$|^from\s+[\w.]+\s+import\s+\S"#)
    /// `def check(text):`, `def f(a) -> str:`, `class Foo(Bar):`, `class Foo:`.
    static let pythonDefinition = try! NSRegularExpression(pattern: #"^(?:async\s+)?def\s+\w+\s*\(.*\)\s*(?:->\s*[^:]+)?:$|^class\s+[A-Z]\w*\s*(?:\(.*\))?\s*:$"#)
    /// `@Test("x")`, `@app.route("/")`, `@objc(name)`: a decorator with arguments or a path.
    static let callDecorator = try! NSRegularExpression(pattern: #"^@(?:\w+\(.*\)|\w+(?:\.\w+)+(?:\(.*\))?)$"#)
    /// A line that is one member call: `sys.path.insert(0, d)`, `console.log(x);`, `self.view.layout()`.
    static let memberCallLine = try! NSRegularExpression(pattern: #"^(?:await |try )?[A-Za-z_]\w*+(?:\.[A-Za-z_]\w*+)++\(.*\)[;,]?$"#)
    /// Shell script shapes: `ROOT="$(cd …)"`, `cp "$BIN" "$APP"`, `$(sysctl -n hw.ncpu)`, `set -euo pipefail`,
    /// `if [ -x "$X" ]; then`.
    static let shellScript = try! NSRegularExpression(pattern: #"^[A-Z_][A-Z0-9_]*=\S|"\$\{?[A-Z_][A-Z0-9_]*|\$\([a-z]|^set -[a-z]+\b|^(?:if|elif|while) \[\[? "#)
    /// SQL that prose never has: `SELECT … FROM users`, `COUNT(o.id)`, `VALUES (`, `o.user_id = u.id`.
    static let sqlStatement = try! NSRegularExpression(pattern: #"^(?:SELECT|INSERT INTO|UPDATE|DELETE FROM)\s.*(?:\b[A-Z]{2,}\(|\bFROM\s+[a-z_]|\bVALUES\s*\()|\b[a-z_]\w*\.[a-z_]\w*\s*=\s*[a-z_]\w*\.[a-z_]\w*"#)
    /// `$ git status`, `user@host:~/x$ make`, `user@mac ~/Projects % git status`: a prompt, then a lowercase
    /// command (`$ 5` isn't one; `>>> ` is a chat quote more often than Python).
    static let shellPrompt = try! NSRegularExpression(pattern: #"^\$\s+[a-z./~][\w./~-]*(?:\s|$)|^[\w.-]+@[\w.-]+(?::|\s+)[~/]\S*\s*[$%#]\s+\S"#)

    // Weak

    /// `elif x:`, `except Error as e:`, `with open(p) as f:`, `for x in xs:`, `if a == b:`.
    static let pythonHeader = try! NSRegularExpression(pattern: #"^(?:elif|except|with|for|while|if)\b[^:]*(?:\(|==|!=|\bin\b|\bas\b|\bnot\b|\bis\b)[^:]*:$"#)
    /// `x = 1`, `self.count += 1`, `items[0] = x`, `out := f()`.
    static let assignment = try! NSRegularExpression(pattern: #"^(?:(?:let|var|const|val|auto|my|local|export|final)\s+)?[A-Za-z_$][\w$]*+(?:(?:\.|->)[A-Za-z_$][\w$]*+|\[[^\]]*\])*(?:\s*:\s*[\w<>\[\]?.]+)?\s*(?:=|:=|\+=|-=|\*=|/=|\?\?=|\|\|=)(?!=)\s*\S"#)
    /// `@MainActor`, `@Published`.
    static let decorator = try! NSRegularExpression(pattern: #"^@[A-Z]\w*$"#)
    /// `import os, sys`.
    static let importLine = try! NSRegularExpression(pattern: #"^import\s+[\w.]+(?:\s*,\s*[\w.]+)*$"#)
    /// `case .general: "General"`, `case general, writing`, `case .passed(let text):`.
    static let caseLine = try! NSRegularExpression(pattern: #"^case\s+(?:\.|[A-Za-z_]\w*\s*[,(])"#)
    /// `return true`, `return w;`: return and one token.
    static let returnLine = try! NSRegularExpression(pattern: #"^return(?:\s+\S+)?;?$"#)
    /// `"$ROOT/App"`, `${TAG}`, `$(sysctl -n hw.ncpu)`: shell variables and command substitution.
    static let shellVariable = try! NSRegularExpression(pattern: #"\$(?:\{?[A-Z_][A-Z0-9_]*\b|\()"#)
    /// A string literal in a list or a call: `"com.apple.Terminal",`, `"Make minimal changes. " +`.
    static let stringLiteral = try! NSRegularExpression(pattern: #"^(?:[A-Za-z_]\w*:\s*)?"(?:[^"\\]|\\.)*+"(?:\s*,\s*"(?:[^"\\]|\\.)*+")*\s*(?:,|\+|\)|;|\]|\)\s*,)\s*(?://.*)?$"#)
    /// One call on its own line: `main()`, `run(args);`, `self.setup(view: v)`.
    static let loneCall = try! NSRegularExpression(pattern: #"^(?:await |try )?[A-Za-z_][\w.]*+\([^()]*\)[;,]?$"#)
    /// A continued expression: `|| x`, `&& y`, `?? z`, `+ (a ? b : c)`.
    static let operatorContinuation = try! NSRegularExpression(pattern: #"^(?:\|\||&&|\?\?)\s*[("\w]|^\+\s*\("#)
    /// SQL statements and clauses in capitals, followed by lowercase or code: `SELECT name`, `WHERE id = 1`
    /// (all-caps shouting, `FROM NOW ON`, isn't).
    static let sql = try! NSRegularExpression(pattern: #"^(?:SELECT|INSERT INTO|UPDATE \w+ SET|DELETE FROM|CREATE (?:TABLE|INDEX|VIEW)|ALTER TABLE|DROP TABLE|WHERE|FROM|(?:LEFT |RIGHT |INNER |OUTER )?JOIN|ORDER BY|GROUP BY|HAVING|LIMIT|VALUES|SET)\s+(?:[a-z_*(`"'\d]|[A-Za-z_]\w*\.)"#)
    /// `foo.bar(`, `self.items.append(`, `console.log(`: a member call outside a sentence. Possessive, so a long
    /// dotted run can't backtrack.
    static let callChain = try! NSRegularExpression(pattern: #"\b[A-Za-z_]\w*+(?:\.[A-Za-z_]\w*+)++\("#)
}
