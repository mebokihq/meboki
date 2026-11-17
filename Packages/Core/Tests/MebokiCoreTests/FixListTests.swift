import Foundation
import Testing
@testable import MebokiCore

/// Deterministic RNG so random-order tests are reproducible.
struct SplitMix64: RandomNumberGenerator {
    var state: UInt64
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}

/// (input, corrected) pairs from eval/dataset.py ERR (first reference), the PARAGRAPH, and UTF-16 cases.
let applyCases: [(String, String)] = [
    ("She dont like apples.", "She doesn't like apples."),
    ("We was late for the meeting.", "We were late for the meeting."),
    ("Can you send me the the report?", "Can you send me the report?"),
    ("I am agree with you.", "I agree with you."),
    ("Could you please explain me the problem?", "Could you please explain the problem to me?"),
    ("She don't know nothing about it.", "She doesn't know anything about it."),
    ("The results was better then expected.", "The results were better than expected."),
    ("i think we shoud postpone the release. there is to many bugs.",
     "I think we should postpone the release. There are too many bugs."),
    ("Hi team, i wanted to give a quick update on the migration. We was able to move most of the services last week, "
        + "but their is still a few issues with the payment service. The logs shows timeouts when the database are under load. "
        + "I think we should of tested this more carefully before. Lets discuss it on tomorrow's call, and please send me any "
        + "informations you have.",
     "Hi team, I wanted to give a quick update on the migration. We were able to move most of the services last week, "
        + "but there are still a few issues with the payment service. The logs show timeouts when the database is under load. "
        + "I think we should have tested this more carefully before. Let's discuss it on tomorrow's call, and please send me any "
        + "information you have."),
    // UTF-16: emoji (surrogate pairs, ZWJ sequences, skin tones, flags) before, between and inside fixes.
    ("👍🏽 I has a car 🚗 and teh 🇺🇦 dog, we was 👨‍👩‍👧 happy.", "👍🏽 I have a car 🚗 and the 🇺🇦 dog, we were 👨‍👩‍👧 happy."),
    ("🎉🎉 Lets go 😀 to teh park 😀 tomorow", "🎉🎉 Let's go 😀 to the park 😀 tomorrow"),
    ("Thx 🙏 for you help 🙏🏿 i owe you", "Thx 🙏 for your help 🙏🏿 I owe you"),
    ("Ça va? Je suis 東京 nicht hier. I has 日本語 text", "Ça va? Je suis 東京 nicht hier. I have 日本語 text"),
]

/// Every pending or skipped fix's range points at its original in the current text.
func expectRangesValid(_ list: FixList, sourceLocation: SourceLocation = #_sourceLocation) {
    let ns = list.text as NSString
    for f in list.fixes {
        let r = f.currentRange
        #expect(NSMaxRange(r) <= ns.length, sourceLocation: sourceLocation)
        guard NSMaxRange(r) <= ns.length else { continue }
        let want = f.status == .applied ? f.edit.replacement : f.edit.original
        #expect(ns.substring(with: r) == want, "\(f.status) \(f.edit)", sourceLocation: sourceLocation)
    }
}

@Suite struct FixListTests {
    @Test func applyInRandomOrdersMatchesDiffApply() {
        var rng = SplitMix64(state: 42)
        for (input, corrected) in applyCases {
            let edits = Diff.edits(from: input, to: corrected)
            let want = Diff.apply(edits, to: input)
            #expect(want == corrected)
            for _ in 0..<20 {
                var list = FixList(text: input, edits: edits)
                #expect(list.fixes.count == edits.count)
                for i in list.fixes.indices.shuffled(using: &rng) {
                    do { let r = list.applyOne(at: i); #expect(r != nil) }
                    expectRangesValid(list)
                }
                #expect(list.text == want, "\(input)")
                #expect(list.isDone)
                #expect(list.appliedCount == edits.count)
            }
        }
    }

    @Test func applyAllMatchesDiffApply() {
        for (input, corrected) in applyCases {
            var list = FixList(text: input, edits: Diff.edits(from: input, to: corrected))
            #expect(list.applyAllOrder() == Array(list.fixes.indices.reversed()))
            do { let r = list.applyAll(); #expect(r == corrected) }
            expectRangesValid(list)
        }
    }

    /// Applying a random subset in random order, skipping the rest, equals Diff.apply of that subset.
    @Test func randomSubsetWithSkips() {
        var rng = SplitMix64(state: 7)
        for (input, corrected) in applyCases {
            let edits = Diff.edits(from: input, to: corrected)
            for _ in 0..<20 {
                var list = FixList(text: input, edits: edits)
                var applied: [Edit] = []
                for i in list.fixes.indices.shuffled(using: &rng) {
                    if Bool.random(using: &rng) {
                        applied.append(edits.sorted { $0.range.location < $1.range.location }[i])
                        list.applyOne(at: i)
                    } else {
                        do { let r = list.skip(at: i); #expect(r) }
                    }
                    expectRangesValid(list)
                }
                #expect(list.text == Diff.apply(applied, to: input))
                #expect(list.appliedCount + list.skippedCount == edits.count)
            }
        }
    }

    /// Mixed: apply some fixes one by one in random order, then Apply all for the rest.
    @Test func applySomeThenApplyAll() {
        var rng = SplitMix64(state: 99)
        for (input, corrected) in applyCases {
            let edits = Diff.edits(from: input, to: corrected)
            var list = FixList(text: input, edits: edits)
            for i in list.fixes.indices.shuffled(using: &rng).prefix(edits.count / 2) { list.applyOne(at: i) }
            do { let r = list.applyAll(); #expect(r == corrected) }
        }
    }

    @Test func emojiRangesShiftInUTF16() {
        let input = "👍🏽 I has a car 🚗 and teh dog"
        var list = FixList(text: input, edits: Diff.edits(from: input, to: "👍🏽 I have a car 🚗 and the dog"))
        #expect(list.fixes.map(\.edit.original) == ["has", "teh"])
        // "👍🏽" is 4 UTF-16 units, so "has" starts at 4 + 1 + 2 = 7.
        #expect(list.fixes[0].edit.range == NSRange(location: 7, length: 3))
        let tehBefore = list.fixes[1].edit.range
        list.applyOne(at: 0)
        // "has" → "have" is +1, so "teh" moves by one; the applied fix now covers "have".
        #expect(list.fixes[1].edit.range.location == tehBefore.location + 1)
        #expect(list.fixes[0].currentRange == NSRange(location: 7, length: 4))
        expectRangesValid(list)
        // Applying a later fix never moves an earlier one.
        let earlier = list.fixes[0].edit.range
        list.applyOne(at: 1)
        #expect(list.fixes[0].edit.range == earlier)
        #expect(list.text == "👍🏽 I have a car 🚗 and the dog")
    }

    @Test func navigationAndCounts() {
        let input = "i think we shoud go. there is to many bugs. Lets fix them."
        let corrected = "I think we should go. There are too many bugs. Let's fix them."
        var list = FixList(text: input, edits: Diff.edits(from: input, to: corrected))
        #expect(list.fixes.map(\.edit.original) == ["i", "shoud", "there is to", "Lets"])
        #expect(list.current == 0)
        #expect(list.currentPosition! == (1, 4))

        do { let r = list.selectPrevious(); #expect(r == false) }
        do { let r = list.selectNext(); #expect(r) }
        #expect(list.current == 1)
        #expect(list.currentPosition! == (2, 4))

        // Skip the current fix: moves to the next pending one, count drops.
        do { let r = list.skip(at: 1); #expect(r) }
        #expect(list.current == 2)
        #expect(list.currentPosition! == (2, 3))
        do { let r = list.skip(at: 1); #expect(r == false) }  // already skipped

        // Apply a fix that isn't current: current stays.
        list.applyOne(at: 3)
        #expect(list.current == 2)
        #expect(list.currentPosition! == (2, 2))
        do { let r = list.selectNext(); #expect(r == false) }  // 3 is applied, no wrap
        do { let r = list.applyOne(at: 3); #expect(r == nil) }  // already applied
        do { let r = list.select(1); #expect(r == false) }  // skipped

        // Apply the last fix in reading order: current falls back to the previous pending one.
        list.applyOne(at: 2)
        #expect(list.current == 0)
        #expect(list.currentPosition! == (1, 1))
        #expect(list.applyAllOrder() == [0])

        list.applyOne(at: 0)
        #expect(list.isDone)
        #expect(list.currentPosition == nil)
        #expect(list.appliedCount == 3)
        #expect(list.skippedCount == 1)
        #expect(list.text == "I think we shoud go. There are too many bugs. Let's fix them.")
    }

    @Test func textApplyingDoesNotMutate() {
        let list = FixList(text: "I has a car.", edits: Diff.edits(from: "I has a car.", to: "I have a car."))
        #expect(list.textApplying(0) == "I have a car.")
        #expect(list.text == "I has a car.")
        #expect(list.fixes[0].status == .pending)
    }

    @Test func dropsUnverifiableEdits() {
        let text = "I has a car."
        let good = Edit(range: NSRange(location: 2, length: 3), original: "has", replacement: "have")
        let mismatch = Edit(range: NSRange(location: 8, length: 3), original: "cat", replacement: "dog")
        let overlap = Edit(range: NSRange(location: 3, length: 2), original: "as", replacement: "ad")
        let outside = Edit(range: NSRange(location: 20, length: 1), original: "x", replacement: "y")
        let noop = Edit(range: NSRange(location: 0, length: 1), original: "I", replacement: "I")
        let list = FixList(text: text, edits: [outside, mismatch, overlap, good, noop])
        #expect(list.fixes.map(\.edit) == [good])
        #expect(FixList(text: "", edits: []).isDone)
    }
}

@Suite struct FixClassifierTests {
    /// Classifies every edit of input → corrected.
    func categories(_ input: String, _ corrected: String) -> [String: FixCategory] {
        let list = FixList(text: input, edits: Diff.edits(from: input, to: corrected))
        return Dictionary(list.fixes.map { (FixClassifier.trimmed($0.edit.original), $0.category) },
                          uniquingKeysWith: { a, _ in a })
    }

    /// Examples from eval/dataset.py.
    @Test(arguments: [
        // Spelling
        ("I recieved your email yesterday.", "I received your email yesterday.", "recieved", FixCategory.spelling),
        ("I definately need more time.", "I definitely need more time.", "definately", .spelling),
        ("teh deploy failed again", "the deploy failed again", "teh", .spelling),
        ("see you tomorow", "see you tomorrow", "tomorow", .spelling),
        ("we shoud postpone", "we should postpone", "shoud", .spelling),
        ("i think so", "I think so", "i", .spelling),
        // Clarity
        ("Can you send me the the report?", "Can you send me the report?", "the", .clarity),
        // Punctuation
        ("Lets meet at 5pm.", "Let's meet at 5pm.", "Lets", .punctuation),
        ("Its a beautiful day.", "It's a beautiful day.", "Its", .punctuation),
        ("but he didnt.", "but he didn't.", "didnt", .punctuation),
        ("She dont like apples.", "She don't like apples.", "dont", .punctuation),
        ("Please find attached the document's you requested.", "Please find attached the documents you requested.", "document's", .punctuation),
        ("Hello world", "Hello, world", "", .punctuation),
        // Grammar
        ("We was late for the meeting.", "We were late for the meeting.", "was", .grammar),
        ("I has a car.", "I have a car.", "has", .grammar),
        ("She dont like apples.", "She doesn't like apples.", "dont", .grammar),
        ("Their going to the store tomorrow.", "They're going to the store tomorrow.", "Their", .grammar),
        ("Your welcome, glad I could help.", "You're welcome, glad I could help.", "Your", .grammar),
        ("Who's book is this?", "Whose book is this?", "Who's", .grammar),
        ("Thanks for you help!", "Thanks for your help!", "you", .grammar),
        ("because of the whether.", "because of the weather.", "whether", .grammar),
        ("The results were better then expected.", "The results were better than expected.", "then", .grammar),
        ("there is to many bugs", "there is too many bugs", "to", .grammar),
        ("He go to school every day.", "He goes to school every day.", "go", .grammar),
        ("I need a new pair of shoe.", "I need a new pair of shoes.", "shoe", .grammar),
        ("He is a honest man.", "He is an honest man.", "a", .grammar),
        ("Neither of them want to go.", "Neither of them wants to go.", "want", .grammar),
        ("I look forward to hear from you.", "I look forward to hearing from you.", "hear", .grammar),
        ("I am agree with you.", "I agree with you.", "am", .grammar),
        ("I could of done it better.", "I could have done it better.", "of", .grammar),
        ("I seen him yesterday.", "I saw him yesterday.", "seen", .grammar),
        ("I bought new laptop last week.", "I bought a new laptop last week.", "", .grammar),
        ("If I was you, I would apologize.", "If I were you, I would apologize.", "was", .grammar),
        ("The informations you sent", "The information you sent", "informations", .grammar),
        ("She don't know nothing about it.", "She don't know anything about it.", "nothing", .grammar),
        ("I tommorow go", "I tomorrow go", "tommorow", .spelling),
    ])
    func classifies(input: String, corrected: String, original: String, want: FixCategory) {
        let got = categories(input, corrected)
        #expect(got[original] == want, "\(input) → \(corrected): \(got)")
    }

    @Test func reasonTemplates() {
        func reason(_ input: String, _ corrected: String) -> String {
            FixList(text: input, edits: Diff.edits(from: input, to: corrected)).fixes[0].reason
        }
        #expect(reason("Can you send me the the report?", "Can you send me the report?") == "The word “the” is repeated.")
        #expect(reason("Lets meet.", "Let's meet.") == "“Let's” needs different punctuation.")
        #expect(reason("Hello world", "Hello, world") == "“Hello,” needs different punctuation.")
        #expect(reason("I recieved it.", "I received it.") == "“received” is the correct spelling.")
        #expect(reason("i think", "I think") == "“I” should be capitalized.")
        #expect(reason("We was late.", "We were late.") == "Grammar: “was” → “were”.")
        #expect(reason("I am agree.", "I agree.") == "Grammar: remove “am”.")
        #expect(reason("I bought new laptop.", "I bought a new laptop.") == "Grammar: add “a”.")
    }

    @Test func distanceCountsTransposition() {
        #expect(FixClassifier.distance("teh", "the") == 1)
        #expect(FixClassifier.distance("recieved", "received") == 1)
        #expect(FixClassifier.distance("kitten", "sitting") == 3)
        #expect(FixClassifier.distance("", "abc") == 3)
    }

    @Test func titles() {
        #expect(FixCategory.allCases.map(\.title) == ["Spelling", "Grammar", "Clarity", "Punctuation", "Rewrite"])
    }
}

@Suite struct FixDisplayTests {
    /// (input, corrected, expected swaps in reading order).
    static let cases: [(String, String, [FixSwap])] = [
        ("I will see you tomorow.", "I will see you tomorrow.", [FixSwap(old: "tomorow", new: "tomorrow")]),
        ("We was late.", "We were late.", [FixSwap(old: "was", new: "were")]),
        ("Hello world", "Hello, world", [FixSwap(old: "Hello", new: "Hello,")]),
        ("Lets go", "Let's go", [FixSwap(old: "Lets", new: "Let's")]),
        ("Send me the the report", "Send me the report", [FixSwap(old: "the", new: "")]),
        ("I agree.", "I agree!", [FixSwap(old: "agree.", new: "agree!")]),
        (", and so", "and so", [FixSwap(old: ", and", new: "and")]),
        ("👍🏽 hello world 🚗", "👍🏽 Hello, world 🚗", [FixSwap(old: "hello", new: "Hello,")]),
    ]

    @Test(arguments: cases.indices)
    func swaps(_ i: Int) {
        let (input, corrected, expected) = Self.cases[i]
        let list = FixList(text: input, edits: Diff.edits(from: input, to: corrected))
        let swaps = list.fixes.indices.compactMap { list.swap(at: $0) }
        #expect(swaps == expected, "\(input) → \(corrected)")
    }

    /// (input, corrected, expected underlined substrings in reading order).
    static let markCases: [(String, String, [String])] = [
        ("I will see you tomorow.", "I will see you tomorrow.", ["tomorow"]),
        ("Hello world", "Hello, world", ["Hello"]),
        ("Lets go", "Let's go", ["Lets"]),
        ("Send me the the report", "Send me the report", ["the"]),
        ("I agree.", "I agree!", ["agree."]),
        (", and so", "and so", [", and"]),
        ("a  b", "a b", ["a"]),
        ("👍🏽 hello world 🚗", "👍🏽 Hello, world 🚗", ["hello"]),
        ("We was late, tomorow", "We were late, tomorrow", ["was", "tomorow"]),
    ]

    @Test(arguments: markCases.indices)
    func markRanges(_ i: Int) {
        let (input, corrected, expected) = Self.markCases[i]
        let list = FixList(text: input, edits: Diff.edits(from: input, to: corrected))
        let ns = input as NSString
        let marks = list.fixes.indices.compactMap { list.markRange(at: $0) }.map { ns.substring(with: $0) }
        #expect(marks == expected, "\(input) → \(corrected)")
    }

    @Test func markRangeOfAppliedFix() {
        let input = "Hello world, we was here tomorow"
        var list = FixList(text: input, edits: Diff.edits(from: input, to: "Hello, world, we were here tomorrow"))
        list.applyOne(at: 1)
        let ns = list.text as NSString
        #expect(ns.substring(with: list.markRange(at: 1)!) == "were")
        #expect(ns.substring(with: list.markRange(at: 2)!) == "tomorow")
        list.applyOne(at: 0)
        #expect((list.text as NSString).substring(with: list.markRange(at: 0)!) == "Hello,")
        #expect(FixDisplay.markRange(NSRange(location: 1, length: 1), in: " - ").length == 1)
        #expect(FixDisplay.markRange(NSRange(location: 0, length: 1), in: " ").length == 0)
    }

    @Test func swapAfterEarlierApply() {
        let input = "Hello world, we was here tomorow"
        var list = FixList(text: input, edits: Diff.edits(from: input, to: "Hello, world, we were here tomorrow"))
        #expect(list.fixes.count == 3)
        list.applyOne(at: 0)
        #expect(list.swap(at: 1) == FixSwap(old: "was", new: "were"))
        #expect(list.swap(at: 2) == FixSwap(old: "tomorow", new: "tomorrow"))
    }
}

@Suite struct ApplyGroupTests {
    static func list(_ text: String, _ corrected: String) -> FixList {
        FixList(text: text, edits: Diff.edits(from: text, to: corrected, merge: false))
    }

    /// Grouped writes, last group first, give the same text as one fix at a time, for every case.
    @Test func groupsGiveTheSameTextAsSingleFixes() {
        for (input, corrected) in applyCases {
            var one = Self.list(input, corrected)
            let expected = one.applyAll()
            for joinAll in [true, false] {
                var grouped = Self.list(input, corrected)
                for g in grouped.applyAllGroups(canJoin: { _ in joinAll }) {
                    let ns = grouped.text as NSString
                    #expect(ns.substring(with: g.range) == g.original)
                    let written = ns.replacingCharacters(in: g.range, with: g.replacement)
                    #expect(grouped.applyGroup(g) == written)
                }
                #expect(grouped.text == expected, "\(input)")
                #expect(grouped.isDone)
                #expect(grouped.appliedCount == one.appliedCount)
            }
        }
    }

    @Test func groupsStayInsideAParagraph() {
        let text = "i have a cat. i has two.\ni has three.\u{FFFC}i has four."
        let list = Self.list(text, "I have a cat. I have two.\nI have three.\u{FFFC}I have four.")
        let groups = list.applyAllGroups(canJoin: { _ in true })
        // Last group first; the first paragraph's three fixes are one write.
        #expect(groups.map(\.indices.count) == [2, 2, 3])
        #expect(groups.last?.original == "i have a cat. i has")
        #expect(groups.last?.replacement == "I have a cat. I have")
        #expect(list.applyAllGroups(canJoin: { _ in false }).count == 7)
        #expect(list.applyAllGroups(maxSpan: 4, canJoin: { _ in true }).count == 7)
    }

    @Test func skippedFixesStayAsWrittenInsideAGroup() {
        var list = Self.list("i has a cat and i has a dog.", "I have a cat and I have a dog.")
        #expect(list.fixes.count == 4)
        list.skip(at: 1)
        let groups = list.applyAllGroups(canJoin: { _ in true })
        #expect(groups.count == 1)
        #expect(groups[0].indices == [0, 2, 3])
        #expect(groups[0].replacement == "I has a cat and I have")
        list.applyGroup(groups[0])
        #expect(list.text == "I has a cat and I have a dog.")
        #expect(list.applyGroup(groups[0]) == nil)
    }

    @Test func insertionNextToAReplacementKeepsItsPlace() {
        // An insertion right where a replacement starts: the group must write it before the replacement.
        var list = FixList(text: "ab cd", edits: [
            Edit(range: NSRange(location: 3, length: 0), original: "", replacement: "X"),
            Edit(range: NSRange(location: 3, length: 2), original: "cd", replacement: "CD"),
        ])
        var single = list
        let expected = single.applyAll()
        let g = list.applyAllGroups(canJoin: { _ in true })
        #expect(g.count == 1)
        list.applyGroup(g[0])
        #expect(list.text == expected)
        #expect(expected == "ab XCD")
    }
}
