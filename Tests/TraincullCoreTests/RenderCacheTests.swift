@testable import TraincullCore
import XCTest

final class RenderCacheTests: XCTestCase {
    private let mb = 1 << 20

    func testBudgetIsRespected() {
        // A 61-megapixel render is about 240 MB: the 900 MB budget keeps three of them.
        var cache = RenderCache<String>(budget: 900 * mb)
        for id in 0 ..< 6 {
            cache.insert(id, [:], "frame \(id)", bytes: 240 * mb)
            XCTAssertLessThanOrEqual(cache.bytes, 900 * mb)
        }
        XCTAssertEqual(cache.count, 3)
        XCTAssertEqual(cache.entries.map { $0.id }, [3, 4, 5])
        XCTAssertEqual(cache.evictions, 3)
        // A 33-megapixel render is about 131 MB: six of them fit.
        var small = RenderCache<String>(budget: 900 * mb)
        for id in 0 ..< 10 { small.insert(id, [:], "", bytes: 131 * mb) }
        XCTAssertEqual(small.count, 6)
        XCTAssertLessThanOrEqual(small.bytes, 900 * mb)
    }

    func testLeastRecentlyShownGoesFirst() {
        var cache = RenderCache<String>(budget: 300)
        cache.insert(1, [:], "one", bytes: 100)
        cache.insert(2, [:], "two", bytes: 100)
        cache.insert(3, [:], "three", bytes: 100)
        // Showing 1 again makes 2 the least recently shown.
        guard case .hit("one") = cache.lookup(1, [:]) else { return XCTFail("1 should be kept") }
        let out = cache.insert(4, [:], "four", bytes: 100)
        XCTAssertEqual(out.map { $0.id }, [2])
        XCTAssertEqual(cache.entries.map { $0.id }, [3, 1, 4])
        // A large one lets several go, oldest first.
        let more = cache.insert(5, [:], "five", bytes: 250)
        XCTAssertEqual(more.map { $0.id }, [3, 1, 4])
        XCTAssertEqual(cache.entries.map { $0.id }, [5])
    }

    func testNewestIsKeptEvenAboveBudget() {
        var cache = RenderCache<String>(budget: 100)
        cache.insert(1, [:], "one", bytes: 50)
        let out = cache.insert(2, [:], "two", bytes: 400)
        XCTAssertEqual(out.map { $0.id }, [1])
        XCTAssertEqual(cache.entries.map { $0.id }, [2])
    }

    func testMissReasons() {
        var cache = RenderCache<String>(budget: 200)
        guard case .miss(.cold) = cache.lookup(1, [:]) else { return XCTFail("never rendered") }
        cache.insert(1, ["exposure": 0.5], "one", bytes: 100)
        guard case .miss(.edited) = cache.lookup(1, [:]) else { return XCTFail("other edits") }
        guard case .hit = cache.lookup(1, ["exposure": 0.5]) else { return XCTFail("same edits") }
        cache.insert(2, [:], "two", bytes: 100)
        cache.insert(3, [:], "three", bytes: 100)
        guard case .miss(.evicted) = cache.lookup(1, ["exposure": 0.5]) else { return XCTFail("let go") }
        // Rendered again, it is no longer counted as let go.
        cache.insert(1, ["exposure": 0.5], "one", bytes: 100)
        guard case .hit = cache.lookup(1, ["exposure": 0.5]) else { return XCTFail("back") }
        cache.removeAll()
        guard case .miss(.cold) = cache.lookup(2, [:]) else { return XCTFail("a new folder starts cold") }
        XCTAssertEqual(cache.bytes, 0)
    }

    func testOneRenderPerFrame() {
        var cache = RenderCache<String>(budget: 1000)
        cache.insert(1, [:], "before", bytes: 100)
        cache.insert(1, ["exposure": 1], "after", bytes: 100)
        XCTAssertEqual(cache.count, 1)
        XCTAssertEqual(cache.bytes, 100)
        guard case .hit("after") = cache.lookup(1, ["exposure": 1]) else { return XCTFail("the newer render") }
    }
}
