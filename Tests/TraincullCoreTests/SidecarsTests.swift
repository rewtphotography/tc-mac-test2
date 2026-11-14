import XCTest
@testable import TraincullCore

/// In-memory folder. `atomic` mimics a volume with atomic replace; false mimics one without.
final class MemDir: DirOps {
    var files: [String: String] = [:]
    var log: [String] = []
    let atomic: Bool

    init(atomic: Bool) { self.atomic = atomic }

    func exists(_ name: String) -> Bool { files[name] != nil }
    func readText(_ name: String) -> String? { files[name] }

    func createAndWrite(_ name: String, _ bytes: [UInt8]) throws {
        precondition(files[name] == nil)
        files[name] = String(decoding: bytes, as: UTF8.self)
        log.append("create \(name)")
    }

    func rename(_ from: String, _ to: String) throws {
        precondition(files[to] == nil)
        files[to] = files.removeValue(forKey: from)!
        log.append("rename \(from) \(to)")
    }

    func delete(_ name: String) throws {
        files.removeValue(forKey: name)
        log.append("delete \(name)")
    }

    func replace(_ from: String, _ to: String) -> Bool {
        if !atomic { return false }
        files[to] = files.removeValue(forKey: from)!
        log.append("replace \(from) \(to)")
        return true
    }
}

/// Ported from the Android app's SidecarsTest, with the same expected values.
final class SidecarsTests: XCTestCase {
    func testWritesNewSidecar() throws {
        let d = MemDir(atomic: false)
        try Sidecars.write(d, "DSC01234.xmp", Xmp.newSidecar(4))
        XCTAssertEqual(Array(d.files.keys), ["DSC01234.xmp"])
        XCTAssertEqual(Xmp.readRating(d.files["DSC01234.xmp"]!), 4)
    }

    func testReplacesExistingWithoutAtomicRename() throws {
        let d = MemDir(atomic: false)
        d.files["A.xmp"] = Xmp.newSidecar(1)
        try Sidecars.write(d, "A.xmp", Xmp.newSidecar(5))
        XCTAssertEqual(Array(d.files.keys), ["A.xmp"])
        XCTAssertEqual(Xmp.readRating(d.files["A.xmp"]!), 5)
    }

    func testReplacesExistingAtomically() throws {
        let d = MemDir(atomic: true)
        d.files["A.xmp"] = Xmp.newSidecar(1)
        try Sidecars.write(d, "A.xmp", Xmp.newSidecar(-1))
        XCTAssertEqual(d.log, ["create A.xmp.tmp", "replace A.xmp.tmp A.xmp"])
        XCTAssertEqual(Xmp.readRating(d.files["A.xmp"]!), -1)
    }

    func testRecoversEveryInterruptionPoint() {
        // Crash after old → .bak, before temp → .xmp: the complete temp wins.
        var d = MemDir(atomic: false)
        d.files["A.xmp.bak"] = Xmp.newSidecar(1); d.files["A.xmp.tmp"] = Xmp.newSidecar(3)
        Sidecars.recover(d, Array(d.files.keys))
        XCTAssertEqual(Array(d.files.keys), ["A.xmp"]); XCTAssertEqual(Xmp.readRating(d.files["A.xmp"]!), 3)

        // A torn temp plus a .bak: the .bak wins.
        d = MemDir(atomic: false)
        d.files["A.xmp.bak"] = Xmp.newSidecar(1); d.files["A.xmp.tmp"] = "<x:xmpmeta"
        Sidecars.recover(d, Array(d.files.keys))
        XCTAssertEqual(Array(d.files.keys), ["A.xmp"]); XCTAssertEqual(Xmp.readRating(d.files["A.xmp"]!), 1)

        // Crash before deleting .bak: the new .xmp stays, leftovers go.
        d = MemDir(atomic: false)
        d.files["A.xmp"] = Xmp.newSidecar(2); d.files["A.xmp.bak"] = Xmp.newSidecar(1)
        Sidecars.recover(d, Array(d.files.keys))
        XCTAssertEqual(Array(d.files.keys), ["A.xmp"]); XCTAssertEqual(Xmp.readRating(d.files["A.xmp"]!), 2)

        // Torn temp for a brand-new sidecar: removed.
        d = MemDir(atomic: false)
        d.files["A.xmp.tmp"] = "<x:xm"
        Sidecars.recover(d, Array(d.files.keys))
        XCTAssertTrue(d.files.isEmpty)
    }
}
