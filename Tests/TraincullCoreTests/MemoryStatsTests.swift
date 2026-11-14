import XCTest
@testable import TraincullCore

final class MemoryStatsTests: XCTestCase {
    private let mb: UInt64 = 1_048_576

    func testAverageAndPeak() {
        var stats = MemoryStats()
        XCTAssertEqual(stats.average, 0)
        XCTAssertTrue(stats.add(400 * mb))
        XCTAssertTrue(stats.add(1200 * mb))
        XCTAssertFalse(stats.add(800 * mb))
        XCTAssertEqual(stats.average, 800 * mb)
        XCTAssertEqual(stats.peak, 1200 * mb)
        XCTAssertEqual(stats.last, 800 * mb)
    }

    func testPlainSizes() {
        XCTAssertEqual(MemoryStats.plain(0), "0 MB")
        XCTAssertEqual(MemoryStats.plain(850 * mb), "850 MB")
        XCTAssertEqual(MemoryStats.plain(1000 * mb), "1.0 GB")
        XCTAssertEqual(MemoryStats.plain(2355 * mb), "2.3 GB")
    }

    func testDurations() {
        XCTAssertEqual(MemoryStats.duration(20), "less than a minute")
        XCTAssertEqual(MemoryStats.duration(60), "1 minute")
        XCTAssertEqual(MemoryStats.duration(14 * 60 + 59), "14 minutes")
        XCTAssertEqual(MemoryStats.duration(3600), "1 hour")
        XCTAssertEqual(MemoryStats.duration(3900), "1 hour 5 minutes")
    }

    func testSentenceIsPlainLanguage() {
        var stats = MemoryStats()
        XCTAssertEqual(stats.sentence(elapsed: 0), "No memory readings yet.")
        stats.add(900 * mb)
        stats.add(2400 * mb)
        stats.add(1100 * mb)
        XCTAssertEqual(stats.sentence(elapsed: 840),
                       "TrainCull is using 1.1 GB of memory right now. Over this session (14 minutes) it has averaged 1.4 GB and peaked at 2.3 GB.")
    }
}
