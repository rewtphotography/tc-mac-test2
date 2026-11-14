import XCTest
@testable import TraincullCore

final class CompareTests: XCTestCase {
    private let shown = Array(0 ..< 30)

    func testArrowsMoveOnlyTheActiveSide() {
        var pair = ComparePair(left: 10, right: 20, active: .right)
        XCTAssertEqual(pair.stepTarget(1, in: shown), 21)
        pair.activeFrame = 21
        XCTAssertEqual(pair, ComparePair(left: 10, right: 21, active: .right))
        XCTAssertEqual(pair.stepTarget(-1, in: shown), 20)
        pair.active = .left
        XCTAssertEqual(pair.stepTarget(1, in: shown), 11)
        XCTAssertEqual(pair.otherFrame, 21)
    }

    func testStepsOverTheFrameOnTheOtherSide() {
        XCTAssertEqual(ComparePair(left: 10, right: 11, active: .left).stepTarget(1, in: shown), 12)
        XCTAssertEqual(ComparePair(left: 10, right: 11, active: .right).stepTarget(-1, in: shown), 9)
    }

    func testStopsAtTheEnds() {
        XCTAssertNil(ComparePair(left: 0, right: 5, active: .left).stepTarget(-1, in: shown))
        XCTAssertNil(ComparePair(left: 5, right: 29, active: .right).stepTarget(1, in: shown))
        // The only frame further on is the one on the other side.
        XCTAssertNil(ComparePair(left: 28, right: 29, active: .left).stepTarget(1, in: shown))
        XCTAssertNil(ComparePair(left: 0, right: 1, active: .right).stepTarget(-1, in: shown))
    }

    func testFollowsTheFilteredList() {
        let rated = [2, 7, 9, 15]
        XCTAssertEqual(ComparePair(left: 2, right: 9, active: .left).stepTarget(1, in: rated), 7)
        XCTAssertEqual(ComparePair(left: 7, right: 9, active: .left).stepTarget(1, in: rated), 15)
        // An active frame the filter hid starts again from the first frame shown.
        XCTAssertEqual(ComparePair(left: 3, right: 2, active: .left).stepTarget(1, in: rated), 7)
        XCTAssertNil(ComparePair(left: 3, right: 2, active: .left).stepTarget(1, in: []))
    }
}
