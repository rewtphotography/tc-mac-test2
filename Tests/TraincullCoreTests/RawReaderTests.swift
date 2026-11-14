import XCTest
@testable import TraincullCore

/// Ported from the Android app's ArwParserTest, RecipeTest and the reader parts of
/// FaceFramingTest, with the same expected values.
final class RawReaderTests: XCTestCase {
    /// A synthetic file laid out like the α7 IV ARW.
    private func fakeArw(little: Bool, orientation: Int) -> Buf {
        let buf = Buf(20000, little: little)
        buf.put(little ? "II" : "MM").putShort(42).putInt(8)
        func ifd(_ at: Int, _ entries: [(Int, Int, Int)], _ next: Int) {
            buf.position(at)
            buf.putShort(entries.count)
            for (tag, type, value) in entries { buf.entry(tag, type, 1, value) }
            buf.putInt(next)
        }
        ifd(8, [(0x112, 3, orientation), (0x201, 4, 1000), (0x202, 4, 3000)], 200)
        ifd(200, [(0x201, 4, 500), (0x202, 4, 300)], 400) // IFD1 thumbnail
        ifd(400, [(0x201, 4, 5000), (0x202, 4, 12000)], 0) // IFD2 full JPEG
        return buf
    }

    private func parseArw(_ bytes: [UInt8]) throws -> RawInfo {
        try RecipeReader.read(BuiltInRecipes.arw, ArrayByteSource(bytes))
    }

    func testFindsPreviewFullAndOrientationLittleEndian() throws {
        let info = try parseArw(fakeArw(little: true, orientation: 8).bytes)
        XCTAssertEqual(info.jpegs.count, 3)
        XCTAssertEqual(info.full!.offset, 5000)
        XCTAssertEqual(info.full!.length, 12000)
        XCTAssertEqual(info.preview!.offset, 1000)
        XCTAssertEqual(info.preview!.length, 3000)
        XCTAssertEqual(info.orientation, 8)
        XCTAssertEqual(info.rotationDegrees, 270)
    }

    func testBigEndianWorksToo() throws {
        let info = try parseArw(fakeArw(little: false, orientation: 6).bytes)
        XCTAssertEqual(info.rotationDegrees, 90)
        XCTAssertEqual(info.preview!.offset, 1000)
    }

    func testSingleJpegIsBothPreviewAndFull() throws {
        let buf = fakeArw(little: true, orientation: 1)
        buf.putInt(at: 8 + 2 + 3 * 12, 0) // cut the chain after IFD0
        let info = try parseArw(buf.bytes)
        XCTAssertTrue(info.full === info.preview)
        XCTAssertEqual(info.rotationDegrees, 0)
    }

    func testRejectsNonTiff() {
        XCTAssertThrowsError(try parseArw([UInt8](repeating: 0, count: 100)))
    }

    func testIgnoresJpegPastEndOfFile() throws {
        let bytes = Array(fakeArw(little: true, orientation: 1).bytes.prefix(16000)) // full JPEG would end at 17000
        XCTAssertEqual(try parseArw(bytes).full!.offset, 1000)
    }

    func testBuiltInArwParses() {
        let r = BuiltInRecipes.arw
        XCTAssertEqual(r.id, "sony-arw")
        XCTAssertEqual(r.extensions, ["arw"])
        XCTAssertNotNil(r.focus)
    }

    private func recipe(_ extra: String) -> String {
        #"{"recipe": 1, "id": "test-x", "name": "Test", "extensions": ["xyz"], \#(extra)}"#
    }

    func testRejectsBadRecipesWithReadableMessages() {
        let cases: [(String, String)] = [
            (#"{"recipe": 2, "id": "a", "name": "A", "extensions": ["a"], "structure": "tiff", "previews": [{}]}"#, "version 1"),
            (recipe(#""structure": "tiff", "previews": []"#), "1–8 preview"),
            (recipe(#""structure": "cr3", "previews": [{}]"#), "structure"),
            (#"{"recipe": 1, "id": "Bad Id", "name": "A", "extensions": ["a"], "structure": "tiff", "previews": [{}]}"#, "id"),
            (#"{"recipe": 1, "id": "a", "name": "A", "extensions": ["xmp"], "structure": "tiff", "previews": [{}]}"#, "can't be a raw"),
            (recipe(#""structure": "tiff", "previews": [{"offsetTag": "0x1FFFF"}]"#), "out of range"),
            (recipe(#""structure": "header", "previews": [{"offsetAt": 84, "lengthAt": 88}], "focus": {"tag": 1, "values": ["x","y"]}"#), "focus"),
        ]
        for (text, expect) in cases {
            XCTAssertThrowsError(try Recipe.parse(text), "accepted: \(text)") { error in
                XCTAssertTrue("\(error)".contains(expect), "\(error) should mention \(expect)")
            }
        }
    }

    /// NEF-like: IFD0 with two SubIFDs (full JPEG, raw data); maker note with its own TIFF header.
    private func nefLike() -> [UInt8] {
        let b = Buf(40000, little: false)
        b.put("MM").putShort(42).putInt(8)
        // IFD0: orientation 6, SubIFDs (2 offsets at 600), Exif at 700
        b.position(8).putShort(3)
        b.entry(0x112, 3, 1, 6); b.entry(0x14A, 4, 2, 600); b.entry(0x8769, 4, 1, 700); b.putInt(0)
        b.position(600).putInt(300).putInt(400)
        // SubIFD 0: JPEG 20000 bytes at 10000; SubIFD 1: raw (compression 34713), not a JPEG
        b.position(300).putShort(3); b.entry(0x103, 3, 1, 6); b.entry(0x201, 4, 1, 10000); b.entry(0x202, 4, 1, 20000); b.putInt(0)
        b.position(400).putShort(3); b.entry(0x103, 3, 1, 34713); b.entry(0x111, 4, 1, 30000); b.entry(0x117, 4, 1, 5000); b.putInt(0)
        // Exif → maker note at 800: "Nikon\0\2\0\0\0" + embedded TIFF (II) with tag 0x1234 = [6000, 4000, 1500, 900]
        b.position(700).putShort(1); b.entry(0x927C, 7, 200, 800); b.putInt(0)
        b.position(800).put("Nikon").put([0, 2, 0, 0, 0])
        let le = Buf(64, little: true)
        le.put("II").putShort(42).putInt(8)
        le.putShort(1).putShort(0x1234).putShort(3).putInt(4).putInt(26).putInt(0)
        le.position(26).putShort(6000).putShort(4000).putShort(1500).putShort(900)
        b.position(810).put(Array(le.bytes.prefix(34)))
        return b.bytes
    }

    private let nefRecipe = #"""
    {
      "recipe": 1, "id": "nikon-nef-test", "name": "Nikon NEF (test)", "extensions": ["nef"], "structure": "tiff",
      "previews": [{"from": "subifds", "requireTag": "0x0103", "requireValues": [6, 7]}],
      "orientation": {"from": "ifd0"},
      "focus": {"makerNote": {"prefix": "Nikon", "skip": 10, "offsets": "embedded-tiff"}, "tag": "0x1234", "values": ["width", "height", "x", "y"]}
    }
    """#

    func testSubIfdsAndEmbeddedTiffMakerNote() throws {
        let info = try RecipeReader.read(try Recipe.parse(nefRecipe), ArrayByteSource(nefLike()))
        XCTAssertEqual(info.jpegs.count, 1) // the raw-data SubIFD is skipped by the compression check
        XCTAssertEqual(info.full!.offset, 10000)
        XCTAssertEqual(info.rotationDegrees, 90)
        let f = try XCTUnwrap(info.focus)
        XCTAssertEqual(f.frameWidth, 6000); XCTAssertEqual(f.x, 1500); XCTAssertEqual(f.y, 900)
    }

    func testHeaderStructureWithEmbeddedJpegOrientation() throws {
        let b = Buf(4000, little: false)
        b.put("FUJIFILMCCD-RAW ")
        b.position(84).putInt(200).putInt(1500)
        // JPEG at 200: SOI, APP1 Exif with a little-endian TIFF whose IFD0 has orientation 8
        b.position(200).put([0xFF, 0xD8, 0xFF, 0xE1]).putShort(40)
        b.put("Exif").put([0, 0])
        let t = Buf(30, little: true)
        t.put("II").putShort(42).putInt(8).putShort(1).putShort(0x112).putShort(3).putInt(1).putShort(8).putShort(0).putInt(0)
        b.put(Array(t.bytes.prefix(26)))
        let r = try Recipe.parse(#"""
        {"recipe": 1, "id": "fuji-raf-test", "name": "Fujifilm RAF (test)", "extensions": ["raf"], "structure": "header",
        "magic": "FUJIFILMCCD-RAW", "byteOrder": "big", "previews": [{"offsetAt": 84, "lengthAt": 88}],
        "orientation": {"from": "embedded-jpeg"}}
        """#)
        let info = try RecipeReader.read(r, ArrayByteSource(b.bytes))
        XCTAssertEqual(info.full!.offset, 200)
        XCTAssertEqual(info.rotationDegrees, 270)
        XCTAssertNil(info.focus)
        XCTAssertThrowsError(try RecipeReader.read(r, ArrayByteSource([UInt8](repeating: 0, count: 200)))) { error in
            XCTAssertTrue("\(error)".contains("FUJIFILMCCD-RAW"))
        }
    }

    func testImportedFormatsJoinTheWhitelist() throws {
        let formats = Formats()
        XCTAssertFalse(formats.isRaw("DSC_0001.NEF"))
        let clashing = BuiltInRecipes.arwJson.replacingOccurrences(of: "sony-arw", with: "other")
        let problems = formats.setImported([try Recipe.parse(nefRecipe), try Recipe.parse(clashing)])
        XCTAssertEqual(problems.count, 1) // the second one clashes with the built-in .arw
        XCTAssertTrue(formats.isRaw("DSC_0001.NEF"))
        XCTAssertTrue(formats.isRaw("_DSC0001.ARW"))
        XCTAssertFalse(formats.isRaw("._DSC0001.ARW"))
        XCTAssertEqual(formats.forName("x.nef")!.id, "nikon-nef-test")
        formats.setImported([])
        XCTAssertFalse(formats.isRaw("DSC_0001.NEF"))
    }

    /// IFD0 (orientation 8, Exif pointer, one JPEG) → Exif IFD → Sony maker note with FocusLocation.
    func testReadsSonyFocusLocation() throws {
        let b = Buf(4000, little: true)
        b.put("II").putShort(42).putInt(8)
        b.position(8).putShort(4)
        b.entry(0x112, 3, 1, 8); b.entry(0x201, 4, 1, 2000); b.entry(0x202, 4, 1, 1000); b.entry(0x8769, 4, 1, 300)
        b.putInt(0)
        b.position(300).putShort(1); b.entry(0x927C, 7, 60, 400); b.putInt(0)
        b.position(400).put("SONY DSC ").put([0, 0, 0])
        b.position(412).putShort(1); b.entry(0x2027, 3, 4, 500); b.putInt(0)
        b.position(500).putShort(7008).putShort(4672).putShort(5792).putShort(2404)
        let f = try XCTUnwrap(try parseArw(b.bytes).focus)
        XCTAssertEqual(f, FocusPoint(frameWidth: 7008, frameHeight: 4672, x: 5792, y: 2404))
    }
}
