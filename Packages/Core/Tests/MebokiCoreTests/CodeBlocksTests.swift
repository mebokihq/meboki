import Foundation
import Testing
@testable import MebokiCore

/// `CodeDetector.blocks`: runs of code lines inside a prose field, protected in a check.
@Suite struct CodeBlocksTests {
    static let swift = """
    func check(text: String) -> Bool {
        let result = engine.run(text)
        guard result.ok else { return false }
        return true
    }
    """

    /// Per non-blank line: "c" in a block, "p" outside; compared with the lab's truth minus blank lines.
    static func marks(_ text: String, _ blocks: [NSRange]) -> String {
        CodeDetector.splitRows(text).compactMap { r -> String? in
            guard !r.text.trimmingCharacters(in: .whitespaces).isEmpty else { return nil }
            let mid = r.offset + r.text.utf16.count / 2
            return blocks.contains { NSLocationInRange(mid, $0) } ? "c" : "p"
        }.joined()
    }

    @Test(arguments: MixedCases.all.filter { !["c1", "c3"].contains($0.id) })
    func labCases(_ c: MixedCases.Case) {
        // The truth has one character per row; blank rows (in a block or not) don't count.
        let rows = CodeDetector.splitRows(c.text)
        let expected = zip(rows, c.truth).filter { !$0.0.text.trimmingCharacters(in: .whitespaces).isEmpty }
            .map { String($0.1) }.joined()
        #expect(Self.marks(c.text, CodeDetector.blocks(in: c.text)) == expected, "case \(c.id)")
    }

    @Test func labKnownMisses() {
        // Three code lines with one strong line: no block (two strong lines are needed).
        let c1 = MixedCases.all.first { $0.id == "c1" }!
        #expect(CodeDetector.blocks(in: c1.text).isEmpty)
        // Fenced code is the fence pattern's job; nothing outside the fence is a block.
        let c3 = MixedCases.all.first { $0.id == "c3" }!
        let marks = Self.marks(c3.text, CodeDetector.blocks(in: c3.text))
        #expect(marks.first == "p" && marks.last == "p")
    }

    @Test func prosePlusCodeFieldIsNotCode() {
        // Prose lab cases (e1-e4, d1): no block at all.
        for id in ["d1", "e1", "e2", "e3", "e4"] {
            let c = MixedCases.all.first { $0.id == id }!
            #expect(CodeDetector.blocks(in: c.text).isEmpty, "case \(id)")
        }
    }

    @Test func blockRangeIsTrimmedToCodeLines() {
        let text = "Please look at this, it dont work.\n\n" + Self.swift + "\n\nThanks a lot for your help."
        let blocks = CodeDetector.blocks(in: text)
        #expect(blocks.count == 1)
        let ns = text as NSString
        #expect(ns.substring(with: blocks[0]) == Self.swift)
    }

    @Test func oneBlankLineBridgesTwoDoNot() {
        let a = "func alpha(text: String) {\n    run(text)\n    stop(text)\n}"
        let b = "func beta(text: String) {\n    run(text)\n    stop(text)\n}"
        let one = "Look at this please, thanks.\n" + a + "\n\n" + b
        #expect(CodeDetector.blocks(in: one).count == 1)
        let two = "Look at this please, thanks.\n" + a + "\n\n\n" + b
        #expect(CodeDetector.blocks(in: two).count == 2)
    }

    @Test func needsTwoStrongLines() {
        // One strong line (`{` ending) among weak ones: no block. Weak lines alone: none either.
        let one = "I think the fix is below, please have a look at it today.\nfunc a() {\n    x = 1\n    y = 2\n    z = 3"
        #expect(CodeDetector.blocks(in: one).isEmpty)
        let weak = "I think the fix is below, please have a look at it today.\nx = 1\ny = 2\nz = x + y\nw = z * 2\nv = w - 1"
        #expect(CodeDetector.blocks(in: weak).isEmpty)
    }

    @Test func weakLineAfterABlankStaysOut() {
        let text = Self.swift + "\n\nreturn true\n\nSee you soon, I hope this helps you a lot."
        let blocks = CodeDetector.blocks(in: text)
        #expect(blocks.count == 1 && (text as NSString).substring(with: blocks[0]) == Self.swift)
    }

    @Test func shortFieldHasNoBlocks() {
        #expect(CodeDetector.blocks(in: "func a() {\n}").isEmpty)
    }

    @Test func shellOutputDoesNotSwallowLowercaseProse() {
        let text = "$ git status\nOn branch master\nnothing to commit\n$ ls -l\nfile.txt\nthis is only some lowercase prose that follows it\nso it should not be protected at all."
        let blocks = CodeDetector.blocks(in: text)
        #expect(blocks.count == 1)
        let ns = text as NSString
        #expect(!ns.substring(with: blocks[0]).contains("lowercase prose"))
    }

    @Test func unclosedBlockCommentDoesNotSwallowTheRest() {
        let text = "/* the config\nfunc a() {\n    run()\n}\n\nThis paragraph is plain prose that must stay checked, please."
        let blocks = CodeDetector.blocks(in: text)
        for b in blocks { #expect(!(text as NSString).substring(with: b).contains("plain prose")) }
        #expect(!CodeDetector.scan(text).verdict.isCode || CodeDetector.scan(text).hasResidualProse)
    }

    @Test func codeAfterTheScanCapIsFoundByBlocks() {
        let prose = String(repeating: "This is a plain sentence about nothing much at all.\n", count: 220)
        #expect(prose.utf16.count > CodeDetector.maxScanCharacters)
        let text = prose + "\n" + Self.swift
        #expect(CodeDetector.scan(text).blocks.isEmpty)       // main thread: capped
        let blocks = CodeDetector.blocks(in: text)             // pipeline: whole text
        #expect(blocks.count == 1 && (text as NSString).substring(with: blocks[0]) == Self.swift)
    }

    @Test func lineSeparatorSplitsRows() {
        let text = "A short note on top, with a mistake.\u{2028}" + Self.swift.replacingOccurrences(of: "\n", with: "\u{2028}")
        let blocks = CodeDetector.blocks(in: text)
        #expect(blocks.count == 1)
        #expect(blocks[0].location == ("A short note on top, with a mistake.\u{2028}" as NSString).length)
    }

    @Test func crlfOffsetsAreRight() {
        let text = "Please check this, it dont run.\r\n\r\n" + Self.swift.replacingOccurrences(of: "\n", with: "\r\n")
        let blocks = CodeDetector.blocks(in: text)
        #expect(blocks.count == 1)
        #expect((text as NSString).substring(with: blocks[0]).hasPrefix("func check"))
        #expect((text as NSString).substring(with: blocks[0]).hasSuffix("}"))
    }

    @Test func emojiBeforeCodeKeepsUTF16Offsets() {
        let text = "Look 😀😀 at it, thanks a lot.\n\n" + Self.swift
        let blocks = CodeDetector.blocks(in: text)
        #expect(blocks.count == 1 && (text as NSString).substring(with: blocks[0]) == Self.swift)
    }

    // MARK: Residual prose

    @Test func pureCodeHasNoResidualProse() {
        let a5 = MixedCases.all.first { $0.id == "a5" }!
        let s = CodeDetector.scan(a5.text)
        #expect(s.verdict.isCode && !s.hasResidualProse)
        #expect(CodeDetector.skipsAutomaticCheck(s, protectTokens: true))
    }

    @Test func pythonHashCommentsAreNotProse() {
        let text = """
        # Load the configuration file and check that every key is present
        # then we build the index for all the users in the database
        import os, sys
        def load(path):
            with open(path) as f:
                data = json.load(f)
            return data
        class Loader:
            def __init__(self, root):
                self.root = root
                self.cache = {}
                self.items = []
            def add(self, item):
                self.items.append(item)
                self.cache[item.id] = item
        """
        let s = CodeDetector.scan(text)
        #expect(!s.hasResidualProse)
        // Short comments keep the field code; the long ones above only add to the lines outside the blocks.
        let short = text.replacingOccurrences(of: "# Load the configuration file and check that every key is present\n", with: "# load config\n")
            .replacingOccurrences(of: "# then we build the index for all the users in the database\n", with: "# build index\n")
        let t = CodeDetector.scan(short)
        #expect(t.verdict.isCode && !t.hasResidualProse)
        #expect(CodeDetector.skipsAutomaticCheck(t, protectTokens: true))
    }

    @Test func codePlusSentencesIsNotSkipped() {
        let a1 = MixedCases.all.first { $0.id == "a1" }!
        let s = CodeDetector.scan(a1.text)
        #expect(s.verdict.isCode && s.hasResidualProse)
        #expect(!CodeDetector.skipsAutomaticCheck(s, protectTokens: true))
        // With protection off, nothing shields the code: the whole field stays skipped.
        #expect(CodeDetector.skipsAutomaticCheck(s, protectTokens: false))
    }

    @Test func oddLinesInACodeFileAreNotProse() {
        let text = Self.swift + "\n\nThread 0 Crashed:\n\n" + Self.swift
        #expect(!CodeDetector.scan(text).hasResidualProse)
    }

    @Test func mixedFieldIsNoLearnerEvidence() {
        let a1 = MixedCases.all.first { $0.id == "a1" }!
        let s = CodeDetector.scan(a1.text)
        #expect(CodeAppLearner.isEvidence(s.verdict))
        #expect(!CodeAppLearner.isEvidence(s.verdict, residualProse: s.hasResidualProse))
        var l = CodeAppLearner()
        for _ in 0..<5 { l.note("x", verdict: s.verdict, residualProse: true) }
        #expect(!l.isLearned("x") && l.codeFields["x"] == nil)
    }

    // MARK: Stack frames

    @Test func errorLinesAreStrong() {
        #expect(CodeDetector.lineLevel("KeyError: 'key'") == .strong)
        #expect(CodeDetector.lineLevel("ValueError: bad") == .strong)
        #expect(CodeDetector.lineLevel("RuntimeException") == .strong)
        #expect(CodeDetector.lineLevel("Errors are fun to read about today.") != .strong)
    }
}
