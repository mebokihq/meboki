import Foundation
import Testing
@testable import MebokiCore

/// Fields whose text follows the scroll (Obsidian's CodeMirror keeps only the lines near the screen in the field).
@Suite struct ScrollFollowTests {
    let t0 = Date(timeIntervalSinceReferenceDate: 1_000)

    @Test func aChangeRightAfterAScrollIsAScrollChange() {
        var d = ScrollChangeDetector()
        d.scrolled(at: t0)
        #expect(d.isScrollChange(at: t0.addingTimeInterval(0.2)))
        #expect(d.isScrollChange(at: t0.addingTimeInterval(1.4)))
        #expect(!d.isScrollChange(at: t0.addingTimeInterval(1.6)))
    }

    @Test func aKeyAfterTheScrollMakesItAnEdit() {
        var d = ScrollChangeDetector()
        d.scrolled(at: t0)
        d.keyPressed(at: t0.addingTimeInterval(0.1))
        #expect(!d.isScrollChange(at: t0.addingTimeInterval(0.3)))
        // A new scroll after the key counts again.
        d.scrolled(at: t0.addingTimeInterval(0.5))
        #expect(d.isScrollChange(at: t0.addingTimeInterval(0.7)))
    }

    /// Underlines wait until neither a scroll nor a text change happened for the quiet time.
    @Test func settleWaitsForScrollAndTextToRest() {
        var d = ScrollChangeDetector()
        #expect(d.settleDelay(at: t0, textMovedAt: nil) == 0)
        d.scrolled(at: t0)
        #expect(abs(d.settleDelay(at: t0.addingTimeInterval(0.1), textMovedAt: nil) - 0.25) < 1e-9)
        #expect(d.settleDelay(at: t0.addingTimeInterval(0.4), textMovedAt: nil) == 0)
        // The text moved again 0.3 s after the scroll (Obsidian swapping lines in): wait from that.
        let moved = t0.addingTimeInterval(0.3)
        #expect(abs(d.settleDelay(at: t0.addingTimeInterval(0.4), textMovedAt: moved) - 0.25) < 1e-9)
        #expect(d.settleDelay(at: t0.addingTimeInterval(0.66), textMovedAt: moved) == 0)
        // A custom quiet time.
        #expect(abs(d.settleDelay(at: t0.addingTimeInterval(0.4), textMovedAt: moved, quiet: 0.5) - 0.4) < 1e-9)
    }

    @Test func noScrollNoScrollChange() {
        var d = ScrollChangeDetector()
        #expect(!d.isScrollChange(at: t0))
        d.keyPressed(at: t0)
        #expect(!d.isScrollChange(at: t0.addingTimeInterval(0.1)))
        // A key before the scroll doesn't matter.
        d.scrolled(at: t0.addingTimeInterval(1))
        #expect(d.isScrollChange(at: t0.addingTimeInterval(1.2)))
    }

    /// The point of re-checking at once after a scroll: the lines that stayed on screen come from the sentence
    /// cache (no model call), with their fixes at the right place in the new text; only lines new to the screen
    /// go to the model.
    @Test func afterAScrollOnlyNewLinesGoToTheModel() async throws {
        let lines = (1...12).map { "Line \($0) have a mistake." }
        let before = lines[0..<8].joined(separator: "\n")   // lines 1–8 on screen
        let after = lines[3..<12].joined(separator: "\n")   // scrolled: lines 4–12
        let fake = FakeCorrector([("have", "has")])
        let pipe = CheckPipeline(client: fake)
        let first = try await pipe.check(before, scope: .init(maxLength: .max))
        #expect(first.edits.count == 8)
        let callsBefore = fake.calls.count

        let second = try await pipe.check(after, scope: .init(maxLength: .max))
        let newCalls = Array(fake.calls.dropFirst(callsBefore))
        // Lines 4–8 came from the cache; only 9–12 were sent.
        #expect(newCalls == (9...12).map { "Line \($0) have a mistake." })
        #expect(second.requests == 4)
        // Every line's fix sits on that line's "have" in the new text.
        let ns = after as NSString
        #expect(second.edits.count == 9)
        for (i, e) in second.edits.enumerated() {
            let lineStart = ns.range(of: "Line \(i + 4) ").location
            #expect(e.range.location == lineStart + ("Line \(i + 4) " as NSString).length)
            #expect(e.original == "have" && e.replacement == "has")
        }
    }

    /// Scrolling back to lines already seen sends nothing at all.
    @Test func scrollingBackIsAllCached() async throws {
        let lines = (1...10).map { "Paragraph \($0) dont end here." }
        let top = lines[0..<6].joined(separator: "\n")
        let bottom = lines[4..<10].joined(separator: "\n")
        let fake = FakeCorrector([("dont", "doesn't")])
        let pipe = CheckPipeline(client: fake)
        _ = try await pipe.check(top, scope: .init(maxLength: .max))
        _ = try await pipe.check(bottom, scope: .init(maxLength: .max))
        let calls = fake.calls.count
        let back = try await pipe.check(top, scope: .init(maxLength: .max))
        #expect(fake.calls.count == calls)
        #expect(back.requests == 0)
        #expect(back.edits.count == 6)
    }
}
