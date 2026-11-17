import Foundation
import Testing
@testable import MebokiCore

@Suite struct LanguageGateTests {
    private func foreign(_ text: String) -> String? {
        LanguageGate.foreignLanguage(LanguageGate.blanked(text) as String)
    }

    /// Precision first: English with typos, chat lines and code must never be judged foreign. The full
    /// dataset is checked by `eval/language_report.py`.
    @Test(arguments: [
        "np, happy to help :)",                       // 93% Polish to the bare recognizer (too short to judge)
        "brb, grabbing coffee",
        "teh build is green now",
        "lol yeah that works for me 👍",
        "She dont like teh new design.",
        "I definately need more time, its been a long week.",
        "Can you send me the отчет by Friday?",       // mixed: the Russian word is a protected token instead
        "stn1slv/Overtype https://github.com/stn1slv/Overtype MIT.",  // read as Danish with the URL left in
        "Set maxTokens to 256 in config.yaml and restart the server.",
        "Merci for the help yesterday, see you at the café on Friday.",
        "Hi team, i wanted to give a quick update on the migration. We was able to move most of the services last week.",
    ])
    func englishStaysEnglish(_ text: String) {
        #expect(foreign(text) == nil)
    }

    @Test(arguments: [
        ("Ich habe morgen keine Zeit, können wir das verschieben?", "de"),
        ("Je pense que nous devrions en parler demain.", "fr"),
        ("¿Puedes enviarme el informe antes del viernes?", "es"),
        ("Привет, как дела? Я завтра буду в офисе.", "ru"),
        ("Wysłałem ci raport wczoraj wieczorem.", "pl"),
    ])
    func foreignIsFound(_ text: String, _ language: String) {
        #expect(foreign(text) == language)
    }

    @Test func shortTextIsNotJudged() {
        #expect(foreign("Danke, bis morgen!") == nil)
        #expect(foreign("merci beaucoup") == nil)
    }

    @Test func blankedKeepsLengthAndWords() {
        let text = "Lies https://example.com/über und `code` — привет 👍"
        let b = LanguageGate.blanked(text)
        #expect(b.length == (text as NSString).length)
        #expect(!(b as String).contains("example"))
        #expect(!(b as String).contains("code"))
        #expect((b as String).contains("привет"))
    }

    @Test func shortEnglishNextToLongForeignKeepsItsCheck() {
        let text = "She dont like apples. Je pense que nous devrions en parler demain matin avec toute l'équipe."
        let found = LanguageGate.foreignRanges(in: text).map { (text as NSString).substring(with: $0) }
        #expect(found == ["Je pense que nous devrions en parler demain matin avec toute l'équipe."])
    }

    @Test func manyShortSentencesJudgedAsParagraph() {
        let text = "Danke! Bis morgen. Ich komme um acht Uhr. Alles gut bei dir?"
        let ns = text as NSString
        let p = NSRange(location: 0, length: ns.length)
        let s = CheckPipeline.sentences(in: ns, range: p)
        // Each sentence alone is too short to judge; together they're German.
        #expect(s.allSatisfy { foreign(ns.substring(with: $0)) == nil })
        let found = LanguageGate.foreignSentences(paragraph: p, sentences: s, blanked: LanguageGate.blanked(text),
                                                  isForeign: { LanguageGate.foreignLanguage($0) != nil })
        #expect(found.count == s.count)
    }

    @Test func englishRunsSkipForeignSentences() {
        let s = [NSRange(location: 0, length: 5), NSRange(location: 6, length: 5),
                 NSRange(location: 12, length: 5), NSRange(location: 18, length: 5)]
        #expect(LanguageGate.englishRuns(s, foreign: [1]) == [NSRange(location: 0, length: 5), NSRange(location: 12, length: 11)])
        #expect(LanguageGate.englishRuns(s, foreign: []) == [NSRange(location: 0, length: 23)])
        #expect(LanguageGate.englishRuns(s, foreign: [0, 1, 2, 3]).isEmpty)
    }

    // MARK: Engine and pipeline

    private let on = CheckOptions(englishOnly: true)

    private let fixes = [("We was", "We were"), ("tomorow", "tomorrow"), ("Zeit", "time"), ("dont", "don't")]
    private let german = "Ich habe morgen leider keine Zeit für das Meeting mit dem Team."
    private var text: String {
        "We was late again. \(german) See you tomorow.\n\n"
            + "Ich habe morgen keine Zeit, können wir das verschieben? Ich melde mich später.\n\nI dont know."
    }

    @Test func foreignTextIsNeverSent() async throws {
        let fake = FakeCorrector(fixes)
        let r = try await CheckPipeline(client: fake, options: on).check(text)
        #expect(fake.calls == ["We was late again.", "See you tomorow.", "I dont know."])
        #expect(r.foreignChunks == 1)
        #expect(r.covered.count == 3)
        #expect(Diff.apply(r.edits, to: text).hasPrefix("We were late again. \(german) See you tomorrow."))
        #expect(Diff.apply(r.edits, to: text).hasSuffix("I don't know."))
    }

    @Test func engineSendsWhatPipelineSends() async throws {
        let a = FakeCorrector(fixes), b = FakeCorrector(fixes)
        let p = try await CheckPipeline(client: a, options: on).check(text)
        let e = try await ProofreadEngine(client: b, options: on).check(text)
        #expect(a.calls == b.calls)
        #expect(p.edits == e.edits)
        #expect(e.foreignChunks == 1)
    }

    @Test func offByDefaultSendsEverything() async throws {
        #expect(CheckOptions().englishOnly == false)
        let fake = FakeCorrector(fixes)
        let pipe = CheckPipeline(client: fake)
        let r = try await pipe.check(text)
        #expect(fake.calls.count == 3)
        #expect(r.foreignChunks == 0)
        #expect(Diff.apply(r.edits, to: text).contains("keine time"))
    }

    @Test func foreignSentencesAreCheckedOncePerText() async throws {
        let fake = FakeCorrector(fixes)
        let pipe = CheckPipeline(client: fake, options: on)
        _ = try await pipe.check(text)
        let edited = text.replacingOccurrences(of: "I dont know.", with: "I dont know yet.")
        _ = try await pipe.check(edited)
        // Only the edited English sentence goes out; the German ones stay unsent.
        #expect(fake.calls.last == "I dont know yet.")
        #expect(fake.calls.count == 4)
    }

    @Test func editsInsideForeignRangesAreDropped() {
        let chunk = "We was late. \(german)"
        let corrected = "We were late. " + german.replacingOccurrences(of: "Zeit", with: "time")
        let g = NSRange(location: ("We was late. " as NSString).length, length: (german as NSString).length)
        let kept = ProofreadEngine.edits(chunk: chunk, corrected: corrected, options: on, foreign: [g])
        #expect(Diff.apply(kept, to: chunk) == "We were late. \(german)")
    }
}
