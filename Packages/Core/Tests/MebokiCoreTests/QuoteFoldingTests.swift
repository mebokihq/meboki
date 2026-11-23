import Foundation
import Testing
@testable import MebokiCore

@Suite struct QuoteFoldingTests {
    /// Seen 2026-11-22 in Slack: Apply all wrote "doesn't" and read back "doesn’t", and stopped.
    @Test func curlyApostropheReadsAsStraight() {
        #expect(QuoteFolding.fold("it doesn’t end") == "it doesn't end")
        #expect(QuoteFolding.fold("“quoted” and ‘single’") == "\"quoted\" and 'single'")
    }

    @Test func lengthInUTF16StaysTheSame() {
        let s = "a ‘b’ “c” d"
        #expect((QuoteFolding.fold(s) as NSString).length == (s as NSString).length)
    }

    @Test func otherTextIsUntouched() {
        #expect(QuoteFolding.fold("plain text, no quotes 😀") == "plain text, no quotes 😀")
    }

    @Test func noBreakSpaceFoldsToSpace() {
        #expect(QuoteFolding.fold("The second\u{00A0}item") == "The second item")
    }
}
