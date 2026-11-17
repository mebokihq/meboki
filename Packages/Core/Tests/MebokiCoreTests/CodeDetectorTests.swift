import Foundation
import Testing
@testable import MebokiCore

/// `CodeDetector`: the automatic check skips a field that looks like code. Precision first: prose must never
/// count as code (eval/code_report.py scores the repo's docs and sources; these are the shapes it lacks).
@Suite struct CodeDetectorTests {
    // MARK: Prose: never code

    static let prose: [String] = [
        // Email
        """
        Hi Sarah,

        Thanks for sending the report (and the slides). I had a look at both; the numbers in section 3 don't match
        the totals on page 12 = we should fix that before Friday.

        Could we meet at 10:30? Otherwise, Thursday works too.

        Best,
        Tom
        --
        Tom Baker | Product Manager
        +1 (555) 123-4567
        """,
        // Chat, lowercase, emoticons
        """
        lol yes :) ;)
        let me know when ur free
        for real tho, i tried (twice) and it still crashed <3
        if you want: call me after 5
        ok
        done
        sounds good -> see you at 6
        """,
        // Markdown note: headings, tasks, a table, links, bold, quotes, nested lists
        """
        # Weekly plan

        ## Tasks
        - [ ] Buy milk (and eggs)
        - [x] Fix the [docs](https://example.com/docs?a=1&b=2) for the release
        - [ ] Call **Mum** about the trip
          - book the train (Friday)
          - pack [chargers] and {cables}

        > Quote: "Simplicity is the ultimate sophistication."

        | Day | Plan |
        |-----|------|
        | Mon | Gym  |
        | Tue | Read |

        **Note:** total = 3 hours per day, more or less.
        """,
        // A poem: short lines, no sentence punctuation
        """
        The fog comes
        on little cat feet
        it sits looking
        over harbor and city
        on silent haunches
        and then moves on
        """,
        // Prose that talks about code
        """
        To fix the crash, call `AX.text(el)` instead of reading the value directly. The old helper used
        `kAXValueAttribute`, which returns nothing in Chrome. Then run swift build and swift test.
        If the test fails, look at the log in ~/Library/Logs/Proofreader/proofreader.log for details.
        """,
        // A numbered list and an address
        """
        1. Preheat the oven to 200 °C (400 °F).
        2. Mix flour, sugar & butter; add eggs.
        3. Bake for 25–30 minutes.

        221B Baker Street
        London NW1 6XE
        """,
        // A long single paragraph with parentheses and symbols
        String(repeating: "The quick brown fox (a very quick one) jumps over the lazy dog; then it rests. ", count: 8),
        // Headings and lines that look like prompts, no blank lines
        """
        # Shopping list
        apples, pears and a big bag of oranges for the weekend trip
        ## Ideas
        ... and then we could go to the lake if the weather holds up
        $ 5 for coffee, $ 12 for lunch, and whatever the parking costs today
        % of people who came: about half, which is more than last year
        >> forwarded from Anna: the meeting moved to Tuesday afternoon
        """,
        // A git commit message: prose with a file path
        """
        Fix the paste fallback in Obsidian

        CodeMirror ignores the AX write, so the paste fallback runs. It was refused because Obsidian reported
        no focused field while our key panel was up. AX.replace now hides the panels before the focus check.
        """,
    ]

    @Test(arguments: prose)
    func proseIsNotCode(_ text: String) {
        let v = CodeDetector.verdict(text)
        #expect(!v.isCode, "\(v.codeChars)/\(v.totalChars) chars, \(v.codeLines)/\(v.lines) lines: \(text.prefix(60))")
    }

    // MARK: Code

    static let code: [String] = [
        // Swift
        """
        import SwiftUI

        struct ContentView: View {
            @State private var count = 0
            var body: some View {
                Button("Tap") { count += 1 }
                    .padding()
            }
        }
        """,
        // Python
        """
        import os, sys

        def main(argv):
            \"\"\"Prints the files.\"\"\"
            for name in os.listdir(argv[1]):
                if name.endswith(".py"):
                    print(name)
            return 0

        if __name__ == "__main__":
            sys.exit(main(sys.argv))
        """,
        // JavaScript
        """
        const items = await fetch(url).then((r) => r.json());
        export function total(items) {
          return items.reduce((sum, x) => sum + x.price, 0);
        }
        console.log(total(items));
        """,
        // Pretty JSON
        """
        {
          "name": "proofreader",
          "version": "1.0.0",
          "scripts": {
            "build": "swift build",
            "test": "swift test"
          },
          "private": true
        }
        """,
        // Minified JSON on one line
        #"[{"id":"gemma-4-e4b","name":"Gemma 4 E4B","bytes":5123456789,"sha256":"abc123","url":"https://huggingface.co/x/y"}]"#,
        // Terminal session
        """
        $ git status
        On branch master
        $ swift build -c release
        Building for production...
        $ ls -la ~/Library/Logs/Proofreader
        total 48
        -rw-r--r--  1 user  staff  21004 Nov 16 10:12 proofreader.log
        """,
        // SQL
        """
        SELECT u.name, COUNT(o.id) AS orders
        FROM users u
        LEFT JOIN orders o ON o.user_id = u.id
        WHERE u.created_at > '2026-01-01'
        GROUP BY u.name
        ORDER BY orders DESC;
        """,
        // HTML
        """
        <div class="card">
          <h2 id="title">Hello</h2>
          <p>Some text</p>
          <a href="/next">Next</a>
        </div>
        """,
        // A stack trace
        """
        Traceback (most recent call last):
          File "/app/main.py", line 12, in <module>
            main()
          File "/app/main.py", line 8, in main
            x = data["key"]
        KeyError: 'key'
        """,
        // A Markdown note that is mostly one code block
        """
        Run this:
        ```
        brew install cmake ninja
        cmake -S . -B build -G Ninja -DLLAMA_METAL=ON
        cmake --build build -j 8 --target llama-server
        ```
        """,
    ]

    @Test(arguments: code)
    func codeIsCode(_ text: String) {
        let v = CodeDetector.verdict(text)
        #expect(v.isCode, "\(v.codeChars)/\(v.totalChars) chars, \(v.codeLines)/\(v.lines) lines: \(text.prefix(60))")
    }

    // MARK: Thresholds

    @Test func shortCodeIsLeftToTheModel() {
        // Under `minCodeChars`: not enough to judge, still checked.
        #expect(!CodeDetector.looksLikeCode("x = 1;\ny = 2;"))
        #expect(!CodeDetector.looksLikeCode(""))
    }

    @Test func proseWithAFewCodeLinesStaysProse() {
        let text = """
        Here's what I changed in the build script today. The release build now strips symbols, which saves
        about 4 MB, and the install step restarts the app so you don't have to do it by hand anymore.
        The only command you need is this one:
        Scripts/make-app.sh --install
        Let me know if anything breaks on your Mac; I tested it on mine with macOS 15 and it worked fine.
        """
        #expect(!CodeDetector.looksLikeCode(text))
    }

    @Test func linesInsideAFenceAreCode() {
        let v = CodeDetector.verdict("```\nhello world, these are plain words\nmore plain words inside a fenced block of text here\n```")
        #expect(v.codeLines == 4)
    }

    /// eval/code_cases.json: prose written to look like code by a review (chat, notes, legal text, poems, lists).
    @Test func adversarialProseIsNotCode() throws {
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("eval/code_cases.json")
        let obj = try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any]
        let cases = try #require(obj?["cases"] as? [[String: String]])
        let prose = cases.filter { $0["kind"] == "prose" }
        #expect(prose.count > 50)
        for c in prose {
            let v = CodeDetector.verdict(c["text"] ?? "")
            #expect(!v.isCode, "\(c["name"] ?? ""): \(v.codeChars)/\(v.totalChars), strong \(v.strongLines)")
        }
    }

    @Test func weakSignalsAloneNeverMakeCode() {
        // Every line is weak code (assignments, `->`, `;` with brackets), none strong.
        let text = """
        x = 3
        y = 2x + 1 = 7
        rent = 1200
        from paris -> london on friday morning
        when you get home (after six); feed the cat;
        $TSLA up 8% premarket, not selling a single share
        """
        let v = CodeDetector.verdict(text)
        #expect(v.strongLines == 0 && !v.isCode)
    }

    @Test func unclosedFenceOpensNothing() {
        let text = "```\nhey, the build is broken again on main and nobody knows why\nplease have a look when you can, thanks"
        #expect(!CodeDetector.looksLikeCode(text))
        let inline = "```git pull```\nafter that it should work. let me know if it doesn't, i'm around all afternoon"
        #expect(!CodeDetector.looksLikeCode(inline))
    }

    @Test func pathologicalInputIsFast() {
        // Long dotted runs used to backtrack quadratically in the call pattern.
        let dotted = Array(repeating: String(repeating: "a.", count: 1000), count: 5).joined(separator: "\n")
        let oneLine = String(repeating: "word ", count: 100_000)
        let start = Date()
        _ = CodeDetector.verdict(dotted)
        _ = CodeDetector.verdict(oneLine)
        #expect(Date().timeIntervalSince(start) < 0.5)
    }

    @Test func hugeLineIsJudgedByItsStart() {
        let json = "{\"data\":[" + String(repeating: "{\"id\":\"model\",\"description\":\"A model.\"},", count: 20_000) + "]}"
        let start = Date()
        #expect(CodeDetector.looksLikeCode(json))
        #expect(Date().timeIntervalSince(start) < 1)
    }
}

@Suite struct AppRulesTests {
    @Test func defaultsByCategory() {
        #expect(AppRules.defaultMode("com.apple.Terminal") == .manual)
        #expect(AppRules.defaultMode("com.microsoft.VSCode") == .manual)
        #expect(AppRules.defaultMode("com.1password.1password") == .off)
        #expect(AppRules.defaultMode("com.apple.ScreenSharing") == .off)
        #expect(AppRules.defaultMode("com.apple.TextEdit") == .on)
        #expect(AppRules.defaultMode(nil) == .on)
        // Prose apps that look like developer tools stay on.
        #expect(AppRules.defaultMode("com.anthropic.claudefordesktop") == .on)
        #expect(AppRules.defaultMode("com.openai.codex") == .on)
    }

    @Test func jetBrainsByPrefix() {
        #expect(AppRules.category(of: "com.jetbrains.goland") == .code)
        #expect(AppRules.category(of: "com.jetbrains.goland-EAP") == .code)
        #expect(AppRules.category(of: "com.jetbrains.fleet") == .code)
        #expect(AppRules.category(of: "com.jetbrains.toolbox") == nil)
    }

    @Test func userChoiceWinsOverListAndLearning() {
        let learned: Set<String> = ["com.example.SuperCode"]
        #expect(AppRules.mode("com.example.SuperCode", stored: [:], learned: learned) == .manual)
        #expect(AppRules.mode("com.example.SuperCode", stored: ["com.example.SuperCode": .on], learned: learned) == .on)
        #expect(AppRules.mode("com.apple.Terminal", stored: ["com.apple.Terminal": .on], learned: learned) == .on)
        // The built-in list comes before learning.
        #expect(AppRules.defaultMode("com.1password.1password", learned: ["com.1password.1password"]) == .off)
        #expect(AppRules.defaultMode("com.apple.Notes", learned: learned) == .on)
    }

    @Test func oldStoredValuesKeepTheirMeaning() {
        // Before the skip list was visible, only Off and Casual were stored, and terminals were skipped by the
        // automatic check only, which is Manual now.
        let stored: [String: AppMode] = ["com.apple.Terminal": .off, "com.tinyspeck.slackmacgap": .casual]
        #expect(AppRules.mode("com.apple.Terminal", stored: stored) == .off)
        #expect(AppRules.mode("com.googlecode.iterm2", stored: stored) == .manual)
        #expect(AppRules.mode("com.tinyspeck.slackmacgap", stored: stored) == .casual)
    }

    @Test func autoCheckByMode() {
        #expect(AppMode.on.allowsAutoCheck && AppMode.casual.allowsAutoCheck)
        #expect(!AppMode.manual.allowsAutoCheck && !AppMode.off.allowsAutoCheck)
    }
}

@Suite struct CodeAppLearnerTests {
    static let code = CodeDetector.Verdict(codeChars: 400, totalChars: 420, codeLines: 20, lines: 21, strongLines: 8)
    static let prose = CodeDetector.Verdict(codeChars: 0, totalChars: 300, codeLines: 0, lines: 3)
    static let short = CodeDetector.Verdict(codeChars: 0, totalChars: 20, codeLines: 0, lines: 1)

    @Test func learnsAfterThreeCodeFields() {
        var l = CodeAppLearner()
        let first = l.note("a", verdict: Self.code), second = l.note("a", verdict: Self.code)
        let third = l.note("a", verdict: Self.code)
        #expect(!first && !second && third)
        #expect(l.learned == ["a"])
        let again = l.note("a", verdict: Self.code)
        #expect(!again)  // already learned: no second announcement
    }

    @Test func oneProseFieldMeansNever() {
        var l = CodeAppLearner()
        l.note("a", verdict: Self.prose)
        for _ in 0..<10 { l.note("a", verdict: Self.code) }
        #expect(!l.isLearned("a"))
        // Prose after learning un-learns (only reachable if the app is followed again).
        var m = CodeAppLearner()
        for _ in 0..<3 { m.note("b", verdict: Self.code) }
        m.note("b", verdict: Self.prose)
        #expect(!m.isLearned("b"))
    }

    @Test func shortTextIsNoEvidence() {
        var l = CodeAppLearner()
        for _ in 0..<3 { l.note("a", verdict: Self.code) }
        l.note("a", verdict: Self.short)
        #expect(l.isLearned("a"))
        #expect(!CodeAppLearner.isEvidence(Self.short))
    }

    @Test func forgetAndPersist() throws {
        var l = CodeAppLearner()
        for _ in 0..<3 { l.note("a", verdict: Self.code) }
        let data = try JSONEncoder().encode(l)
        let back = try JSONDecoder().decode(CodeAppLearner.self, from: data)
        #expect(back == l && back.isLearned("a"))
        l.forget("a")
        #expect(l.learned.isEmpty)
    }
}
