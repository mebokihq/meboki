import XCTest
@testable import MebokiCore

final class KeyGuardPolicyTests: XCTestCase {
    private let t0 = Date(timeIntervalSince1970: 1_000)

    func testHoldsWhileActiveAndInTail() {
        var p = KeyGuardPolicy()
        XCTAssertFalse(p.holdsKeys(at: t0))
        p.begin(at: t0)
        XCTAssertTrue(p.holdsKeys(at: t0.addingTimeInterval(1)))
        p.end(tail: true, at: t0.addingTimeInterval(2))
        XCTAssertTrue(p.holdsKeys(at: t0.addingTimeInterval(2.3)))
        XCTAssertFalse(p.holdsKeys(at: t0.addingTimeInterval(2.6)))
    }

    func testEndWithoutTailReleasesAtOnce() {
        var p = KeyGuardPolicy()
        p.begin(at: t0)
        p.end(tail: false, at: t0.addingTimeInterval(1))
        XCTAssertFalse(p.holdsKeys(at: t0.addingTimeInterval(1)))
    }

    func testIdleGuardIsStuck() {
        var p = KeyGuardPolicy()
        p.begin(at: t0)
        XCTAssertNil(p.stuckFor(at: t0.addingTimeInterval(3.9)))
        XCTAssertNotNil(p.stuckFor(at: t0.addingTimeInterval(4.1)))
    }

    func testWritesKeepALongApplyAlive() {
        var p = KeyGuardPolicy()
        p.begin(at: t0)
        for s in stride(from: 3.0, through: 60.0, by: 3.0) { p.touch(at: t0.addingTimeInterval(s)) }
        XCTAssertNil(p.stuckFor(at: t0.addingTimeInterval(62)))
        XCTAssertTrue(p.holdsKeys(at: t0.addingTimeInterval(62)))
    }

    func testHardCapWinsOverActivity() {
        var p = KeyGuardPolicy()
        p.begin(at: t0)
        p.touch(at: t0.addingTimeInterval(121))
        XCTAssertNotNil(p.stuckFor(at: t0.addingTimeInterval(122)))
    }

    func testReleaseClearsEverything() {
        var p = KeyGuardPolicy()
        p.begin(at: t0)
        p.end(tail: true, at: t0.addingTimeInterval(1))
        p.begin(at: t0.addingTimeInterval(1))
        p.release()
        XCTAssertFalse(p.holdsKeys(at: t0.addingTimeInterval(1)))
        XCTAssertNil(p.stuckFor(at: t0.addingTimeInterval(500)))
    }

    func testTouchWhenIdleDoesNothing() {
        var p = KeyGuardPolicy()
        p.touch(at: t0)
        XCTAssertFalse(p.holdsKeys(at: t0))
    }
}
