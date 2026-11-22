import XCTest
@testable import MebokiCore

final class ClipboardLeaseTests: XCTestCase {
    /// Simulates one paste: snapshot when asked, then the pasteboard's count goes up.
    private func paste(_ l: inout ClipboardLease<String>, clipboard: String, count: inout Int) {
        if l.needsSnapshot(changeCount: count) { l.save(clipboard) }
        count += 1
        l.didPaste(changeCount: count)
    }

    func testNoPasteSavesNothingAndRestoresNothing() {
        var l = ClipboardLease<String>()
        l.begin()
        XCTAssertNil(l.end())
        XCTAssertFalse(l.hasSaved)
    }

    func testSeveralPastesRestoreTheOriginalOnce() {
        var l = ClipboardLease<String>()
        var count = 10
        l.begin()
        paste(&l, clipboard: "user", count: &count)
        paste(&l, clipboard: "fix 1", count: &count)  // Meboki's own paste is never saved
        paste(&l, clipboard: "fix 2", count: &count)
        let r = l.end()
        XCTAssertNotNil(r)
        XCTAssertEqual(r?.delay, ClipboardLease<String>.settledDelay)
        XCTAssertEqual(l.restore(token: r!.token, changeCount: count), "user")
        XCTAssertFalse(l.hasSaved)
        XCTAssertNil(l.restore(token: r!.token, changeCount: count))
    }

    func testUserCopyAfterThePasteWins() {
        var l = ClipboardLease<String>()
        var count = 0
        l.begin()
        paste(&l, clipboard: "user", count: &count)
        let r = l.end()!
        count += 1  // the user copies something before the restore is due
        XCTAssertNil(l.restore(token: r.token, changeCount: count))
        XCTAssertFalse(l.hasSaved)
    }

    func testNewApplyWhilePendingKeepsTheOriginal() {
        var l = ClipboardLease<String>()
        var count = 0
        l.begin()
        paste(&l, clipboard: "user", count: &count)
        let first = l.end()!
        l.begin()
        XCTAssertNil(l.restore(token: first.token, changeCount: count), "the newer apply holds the clipboard")
        paste(&l, clipboard: "fix 1", count: &count)
        let second = l.end()!
        XCTAssertEqual(l.restore(token: second.token, changeCount: count), "user")
    }

    func testNewApplyWithoutPasteStillRestoresThePendingSnapshot() {
        var l = ClipboardLease<String>()
        var count = 0
        l.begin()
        paste(&l, clipboard: "user", count: &count)
        let first = l.end()!
        l.begin()  // this apply writes through Accessibility only
        let second = l.end()!
        XCTAssertNil(l.restore(token: first.token, changeCount: count))
        XCTAssertEqual(l.restore(token: second.token, changeCount: count), "user")
    }

    func testUserCopyWhilePendingIsWhatTheNextApplySaves() {
        var l = ClipboardLease<String>()
        var count = 0
        l.begin()
        paste(&l, clipboard: "user", count: &count)
        _ = l.end()!
        count += 1  // the user copies "newer" before the restore
        l.begin()
        paste(&l, clipboard: "newer", count: &count)
        let r = l.end()!
        XCTAssertEqual(l.restore(token: r.token, changeCount: count), "newer")
    }

    func testNestedHoldsRestoreAtTheOuterEnd() {
        var l = ClipboardLease<String>()
        var count = 0
        l.begin()
        l.begin()
        paste(&l, clipboard: "user", count: &count)
        XCTAssertNil(l.end())
        let r = l.end()!
        XCTAssertEqual(l.restore(token: r.token, changeCount: count), "user")
    }

    func testEmptyClipboardRestoresToEmpty() {
        var l = ClipboardLease<[String]>()
        var count = 3
        l.begin()
        if l.needsSnapshot(changeCount: count) { l.save([]) }
        count += 1
        l.didPaste(changeCount: count)
        let r = l.end()!
        XCTAssertEqual(l.restore(token: r.token, changeCount: count), [])
    }

    func testUnsettledPasteWaitsLonger() {
        var l = ClipboardLease<String>()
        var count = 0
        l.begin()
        paste(&l, clipboard: "user", count: &count)
        l.pasteSettled(false)
        XCTAssertEqual(l.end()?.delay, ClipboardLease<String>.unsettledDelay)
    }

    func testRestoreNowOnQuit() {
        var l = ClipboardLease<String>()
        var count = 0
        l.begin()
        paste(&l, clipboard: "user", count: &count)
        XCTAssertEqual(l.restoreNow(changeCount: count), "user")
        XCTAssertFalse(l.holding)
        XCTAssertNil(l.restoreNow(changeCount: count))
    }

    func testEndWithoutBeginIsIgnored() {
        var l = ClipboardLease<String>()
        XCTAssertNil(l.end())
        XCTAssertEqual(l.depth, 0)
    }
}
