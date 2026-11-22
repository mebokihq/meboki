import Foundation
import Testing
@testable import MebokiCore

@Suite struct WhatsNewTests {
    let all = [
        WhatsNewRelease(version: "1.0.7", date: "2026-11-24", items: [.init(kind: .fixed, text: "c")]),
        WhatsNewRelease(version: "1.0.6", date: "2026-11-21", highlights: [.init(kind: .new, title: "b", body: "b")]),
        WhatsNewRelease(version: "1.0.5", date: "2026-11-20", items: [.init(kind: .improved, text: "a")]),
    ]

    @Test func decodesTheFileShape() throws {
        let json = """
        [{"version": "1.0.7", "date": "2026-11-24",
          "highlights": [{"kind": "new", "symbol": "doc.text", "title": "T", "body": "B", "image": "images/x.png"}],
          "items": [{"kind": "fixed", "text": "F"}]},
         {"version": "1.0.6", "date": "2026-11-21", "items": [{"kind": "improved", "text": "I"}]}]
        """
        let r = try WhatsNew.decode(Data(json.utf8))
        #expect(r.count == 2)
        #expect(r[0].highlights[0].image == "images/x.png")
        #expect(r[1].highlights.isEmpty)
        #expect(r[0].displayDate == "24 Nov 2026")
        #expect(throws: (any Error).self) { try WhatsNew.decode(Data(#"[{"version":"1","date":"x","items":[{"kind":"other","text":"t"}]}]"#.utf8)) }
    }

    @Test func picksTheVersionsSinceTheLastOne() {
        #expect(WhatsNew.releases(all, from: "1.0.6", to: "1.0.7").map(\.version) == ["1.0.7"])
        #expect(WhatsNew.releases(all, from: "1.0.4", to: "1.0.7").map(\.version) == ["1.0.7", "1.0.6", "1.0.5"])
        #expect(WhatsNew.releases(all, from: "1.0.5", to: "1.0.6").map(\.version) == ["1.0.6"])
        #expect(WhatsNew.releases(all, from: nil, to: "1.0.6").map(\.version) == ["1.0.6"])
        #expect(WhatsNew.releases(all, from: nil, to: "1.0.9").isEmpty)
        // Out of order in the file: still newest first.
        #expect(WhatsNew.releases(all.reversed(), from: "1.0.4", to: "1.0.7").map(\.version) == ["1.0.7", "1.0.6", "1.0.5"])
    }

    @Test func decidesAtLaunch() {
        // Fresh install: only recorded, the Welcome window explains the app.
        #expect(WhatsNew.decide(current: "1.0.7", lastSeen: nil, onboardingDone: false, all: all) == .record)
        // Same version: nothing.
        #expect(WhatsNew.decide(current: "1.0.7", lastSeen: "1.0.7", onboardingDone: true, all: all) == .none)
        // An update.
        #expect(WhatsNew.decide(current: "1.0.7", lastSeen: "1.0.5", onboardingDone: true, all: all)
                == .show(from: "1.0.5", releases: Array(all.prefix(2))))
        // From a build older than the window: this version's entry only.
        #expect(WhatsNew.decide(current: "1.0.7", lastSeen: nil, onboardingDone: true, all: all)
                == .show(from: nil, releases: [all[0]]))
        // Downgrade, no entry, dev version.
        #expect(WhatsNew.decide(current: "1.0.5", lastSeen: "1.0.7", onboardingDone: true, all: all) == .record)
        #expect(WhatsNew.decide(current: "1.0.9", lastSeen: "1.0.8", onboardingDone: true, all: all) == .record)
        #expect(WhatsNew.decide(current: "dev", lastSeen: "1.0.7", onboardingDone: true, all: all) == .none)
    }

    @Test func hiddenReleasesShowNothing() throws {
        let r = try WhatsNew.decode(Data(#"[{"version": "1.0.8", "date": "2026-11-25", "hidden": true}]"#.utf8))
        #expect(r[0].hidden && r[0].isEmpty)
        let list = r + all
        // 1.0.8 alone: recorded, no window.
        #expect(WhatsNew.decide(current: "1.0.8", lastSeen: "1.0.7", onboardingDone: true, all: list) == .record)
        // Skipped 1.0.7 on the way to a hidden 1.0.8: 1.0.7 still shows.
        #expect(WhatsNew.decide(current: "1.0.8", lastSeen: "1.0.6", onboardingDone: true, all: list)
                == .show(from: "1.0.6", releases: [all[0]]))
    }

    @Test func changelogHistory() {
        let list = [WhatsNewRelease(version: "1.0.8", date: "2026-11-25", hidden: true)] + all
        #expect(WhatsNew.history(list, upTo: "1.0.8").map(\.version) == ["1.0.7", "1.0.6", "1.0.5"])
        #expect(WhatsNew.history(list, upTo: "1.0.6").map(\.version) == ["1.0.6", "1.0.5"])
        #expect(WhatsNew.history(list, upTo: "1.0.0").map(\.version) == ["1.0.7", "1.0.6", "1.0.5"])
        #expect(WhatsNew.changelogSubtitle(Array(all.prefix(2))) == "Version 1.0.7 · 2 releases")
    }

    @Test func subtitle() {
        #expect(WhatsNew.subtitle(from: "1.0.6", releases: [all[0]]) == "Updated from 1.0.6 · 24 Nov 2026")
        #expect(WhatsNew.subtitle(from: "1.0.5", releases: Array(all.prefix(2))) == "Updated from 1.0.5 · 2 versions")
        #expect(WhatsNew.subtitle(from: nil, releases: [all[0]]) == "Released 24 Nov 2026")
    }

    /// The shipped file decodes, newest first, every entry has something to show.
    @Test func shippedFileIsValid() throws {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("App/WhatsNew/\(WhatsNew.fileName)")
        let r = try WhatsNew.decode(Data(contentsOf: url))
        #expect(!r.isEmpty)
        for (a, b) in zip(r, r.dropFirst()) { #expect(UpdateNudge.isNewer(a.version, than: b.version)) }
        for e in r { #expect(!e.isEmpty) }
    }
}
