import XCTest
@testable import TraincullCore

final class ExportTests: XCTestCase {
    // MARK: ZIP framing

    func testAdler32MatchesKnownValues() {
        XCTAssertEqual(TiffWriter.adler32([]), 1)
        XCTAssertEqual(TiffWriter.adler32(Array("Wikipedia".utf8)), 0x11E6_0398)
        // Long enough to need the sums reduced part-way.
        XCTAssertEqual(TiffWriter.adler32([UInt8](repeating: 0xFF, count: 100_000)), 0x149A_302C)
    }

    func testStoredDeflateSplitsIntoBlocks() {
        let empty = TiffWriter.storedDeflate([])
        XCTAssertEqual(empty, [1, 0, 0, 0xFF, 0xFF])
        let bytes = (0 ..< 70000).map { UInt8($0 % 251) }
        let out = TiffWriter.storedDeflate(bytes)
        XCTAssertEqual(out.count, 70000 + 10)
        XCTAssertEqual(Array(out[0 ..< 5]), [0, 0xFF, 0xFF, 0, 0]) // a full block, more to come
        XCTAssertEqual(Array(out[5 ..< 8]), [0, 1, 2])
        let second = 5 + 65535
        XCTAssertEqual(out[second], 1) // the last block
        XCTAssertEqual(Int(out[second + 1]) | (Int(out[second + 2]) << 8), 70000 - 65535)
    }

    func testZlibStreamHasHeaderAndChecksum() {
        let out = TiffWriter.zlibStream(deflated: [9, 9], adler: 0x0102_0304)
        XCTAssertEqual(out, [0x78, 0x9C, 9, 9, 1, 2, 3, 4])
        XCTAssertEqual((Int(out[0]) * 256 + Int(out[1])) % 31, 0)
    }

    // MARK: Pixels

    /// Two RGBA pixels per row, big-endian, with padding at the end of each row.
    func testStripDropsAlphaSwapsBytesAndDifferences() {
        let row0: [UInt8] = [0x01, 0x00, 0x02, 0x00, 0x03, 0x00, 0xFF, 0xFF, 0x01, 0x10, 0x01, 0xFF, 0x04, 0x00, 0xFF, 0xFF, 0xEE, 0xEE]
        let row1: [UInt8] = [0xFF, 0xFF, 0x00, 0x00, 0x80, 0x00, 0xFF, 0xFF, 0x00, 0x01, 0x00, 0x00, 0x80, 0x00, 0xFF, 0xFF, 0xEE, 0xEE]
        let out = (row0 + row1).withUnsafeBytes {
            TiffWriter.strip($0, rowBytes: 18, rows: 2, width: 2, samplesPerPixel: 4, firstSample: 0, littleEndian: false)
        }
        XCTAssertEqual(out, [
            0x00, 0x01, 0x00, 0x02, 0x00, 0x03, // first pixel as it is: 0x0100, 0x0200, 0x0300
            0x10, 0x00, 0xFF, 0xFF, 0x00, 0x01, // then differences: +0x0010, -1, +0x0100
            0xFF, 0xFF, 0x00, 0x00, 0x00, 0x80, // each row starts afresh
            0x02, 0x00, 0x00, 0x00, 0x00, 0x00, // 0x0001 - 0xFFFF wraps to 2
        ])
    }

    func testStripReadsLittleEndianAndAlphaFirst() {
        let argb: [UInt8] = [0xFF, 0xFF, 0x34, 0x12, 0x78, 0x56, 0xBC, 0x9A]
        let out = argb.withUnsafeBytes {
            TiffWriter.strip($0, rowBytes: 8, rows: 1, width: 1, samplesPerPixel: 4, firstSample: 1, littleEndian: true)
        }
        XCTAssertEqual(out, [0x34, 0x12, 0x78, 0x56, 0xBC, 0x9A])
    }

    func testRowsPerStrip() {
        XCTAssertEqual(TiffWriter.rowsPerStrip(width: 7008, height: 4672), 99)
        XCTAssertEqual(TiffWriter.rowsPerStrip(width: 10, height: 4), 4)
        XCTAssertEqual(TiffWriter.rowsPerStrip(width: 2_000_000, height: 4), 1)
    }

    // MARK: The whole file

    /// A small picture written the way the app writes one, then read back with the TIFF reader.
    private func sampleFile(width: Int, height: Int, meta: TiffMeta) -> (file: [UInt8], rows: Int, strips: Int) {
        var pixels: [UInt8] = []
        for y in 0 ..< height {
            for x in 0 ..< width {
                let r = UInt16(truncatingIfNeeded: x * 257), g = UInt16(truncatingIfNeeded: y * 521), b = UInt16(truncatingIfNeeded: (x + y) * 97)
                for v in [r, g, b, 0xFFFF] { pixels += [UInt8(v & 0xFF), UInt8(v >> 8)] }
            }
        }
        let rows = max(1, height / 3)
        var strips: [[UInt8]] = []
        var y = 0
        while y < height {
            let n = min(rows, height - y)
            let raw = pixels.withUnsafeBytes {
                TiffWriter.strip(UnsafeRawBufferPointer(rebasing: $0[(y * width * 8)...]), rowBytes: width * 8, rows: n, width: width,
                                 samplesPerPixel: 4, firstSample: 0, littleEndian: true)
            }
            strips.append(TiffWriter.zlibStream(deflated: TiffWriter.storedDeflate(raw), adler: TiffWriter.adler32(raw)))
            y += n
        }
        let head = TiffWriter.head(width: width, height: height, rowsPerStrip: rows, stripSizes: strips.map { $0.count }, meta: meta)
        return (head + strips.flatMap { $0 }, rows, strips.count)
    }

    func testFileReadsBackWithEveryTable() throws {
        var shot = ShotInfo(focalMm: 85, fNumber: 1.6, exposureS: 1 / 125.0, iso: 100, model: "ILCE-7M4")
        shot.make = "SONY"
        shot.lens = "FE 85mm F1.4 GM"
        shot.taken = "2026:11:14 17:49:00"
        let icc = (0 ..< 301).map { UInt8($0 % 256) }
        let (file, rows, strips) = sampleFile(width: 37, height: 20, meta: TiffMeta(software: "TrainCull test", shot: shot, icc: icc))
        if let path = ProcessInfo.processInfo.environment["TRAINCULL_TIFF_OUT"] {
            try Data(file).write(to: URL(fileURLWithPath: path))
        }

        let tiff = try Tiff(ArrayByteSource(file))
        XCTAssertTrue(tiff.littleEndian)
        let ifd = try tiff.readIfd(tiff.firstIfdOffset)
        XCTAssertEqual(ifd.nextOffset, 0)
        XCTAssertEqual(tiff.value(ifd, 0x100), 37)
        XCTAssertEqual(tiff.value(ifd, 0x101), 20)
        XCTAssertEqual(tiff.values(ifd.entries[0x102]!), [16, 16, 16])
        XCTAssertEqual(tiff.value(ifd, 0x103), 8)
        XCTAssertEqual(tiff.value(ifd, 0x106), 2)
        XCTAssertEqual(tiff.value(ifd, 0x112), 1)
        XCTAssertEqual(tiff.value(ifd, 0x115), 3)
        XCTAssertEqual(tiff.value(ifd, 0x116), Int64(rows))
        XCTAssertEqual(tiff.value(ifd, 0x13D), 2)
        XCTAssertEqual(tiff.rational(ifd, 0x11A), 300)
        XCTAssertEqual(tiff.string(ifd, 0x10F), "SONY")
        XCTAssertEqual(tiff.string(ifd, 0x110), "ILCE-7M4")
        XCTAssertEqual(tiff.string(ifd, 0x131), "TrainCull test")
        XCTAssertEqual(tiff.string(ifd, 0x132), "2026:11:14 17:49:00")
        let iccEntry = try XCTUnwrap(ifd.entries[0x8773])
        XCTAssertEqual(iccEntry.count, 301)
        XCTAssertEqual(Array(file[Int(iccEntry.valuePos) ..< Int(iccEntry.valuePos) + 301]), icc)

        // Entries are in ascending tag order, as the format requires.
        let count = Int(file[8]) | (Int(file[9]) << 8)
        let tags = (0 ..< count).map { Int(file[10 + $0 * 12]) | (Int(file[11 + $0 * 12]) << 8) }
        XCTAssertEqual(tags, tags.sorted())

        // The strips tile the rest of the file exactly.
        let offsets = tiff.values(ifd.entries[0x111]!), sizes = tiff.values(ifd.entries[0x117]!)
        XCTAssertEqual(offsets.count, strips)
        XCTAssertEqual(sizes.count, strips)
        for i in 1 ..< strips { XCTAssertEqual(offsets[i], offsets[i - 1] + sizes[i - 1]) }
        XCTAssertEqual(offsets.last! + sizes.last!, Int64(file.count))
        XCTAssertEqual(offsets[0] % 2, 0)
        XCTAssertEqual(Array(file[Int(offsets[0]) ..< Int(offsets[0]) + 2]), [0x78, 0x9C])

        // The settings survive, through the same reader the app uses on raw files.
        let read = try XCTUnwrap(ShotInfo.fromTiff(tiff, ifd))
        XCTAssertEqual(read.label(), "85mm @ f/1.6 · 1/125s · 100 ISO · a7IV")
        XCTAssertEqual(read.lens, "FE 85mm F1.4 GM")
        XCTAssertEqual(read.taken, "2026:11:14 17:49:00")
        XCTAssertEqual(read.make, "SONY")
    }

    func testFileWithNothingKnownAboutThePhoto() throws {
        let (file, _, _) = sampleFile(width: 3, height: 1, meta: TiffMeta(software: "TrainCull"))
        let tiff = try Tiff(ArrayByteSource(file))
        let ifd = try tiff.readIfd(tiff.firstIfdOffset)
        XCTAssertNil(ifd.entries[0x8769])
        XCTAssertNil(ifd.entries[0x8773])
        XCTAssertNil(ifd.entries[0x110])
        XCTAssertEqual(tiff.values(ifd.entries[0x111]!).count, 1)
        XCTAssertEqual(tiff.value(ifd, 0x111)! + tiff.value(ifd, 0x117)!, Int64(file.count))
    }

    func testExposureFractions() {
        XCTAssertTrue(TiffWriter.exposure(1 / 8000.0) == (1, 8000))
        XCTAssertTrue(TiffWriter.exposure(0.5) == (5, 10))
        XCTAssertTrue(TiffWriter.exposure(30) == (300, 10))
    }

    // MARK: Embedded JPEG

    private let bareJpeg: [UInt8] = [0xFF, 0xD8, 0xFF, 0xDB, 0x00, 0x04, 1, 2, 0xFF, 0xDA, 0x00, 0x02, 7, 7, 0xFF, 0xD9]

    func testUprightJpegIsSavedUnchanged() {
        XCTAssertEqual(JpegTools.forSaving(bareJpeg, orientation: 1), bareJpeg)
    }

    func testTurnedJpegGainsAnOrientationAndNothingElseChanges() throws {
        let out = JpegTools.forSaving(bareJpeg, orientation: 6)
        XCTAssertEqual(out.count, bareJpeg.count + 36)
        XCTAssertEqual(Array(out[0 ..< 2]), [0xFF, 0xD8])
        XCTAssertEqual(Array(out[38...]), Array(bareJpeg[2...]))
        // The reader the app uses finds the orientation in it.
        let ref = JpegRef(offset: 0, length: out.count, ifdIndex: 0)
        XCTAssertEqual(RecipeReader.jpegOrientation(ArrayByteSource(out), ref), 6)
        // Saving it again changes nothing: it has Exif now.
        XCTAssertEqual(JpegTools.forSaving(out, orientation: 6), out)
    }

    func testOrientationGoesAfterAJfifSegment() {
        let jfif: [UInt8] = [0xFF, 0xD8, 0xFF, 0xE0, 0x00, 0x04, 0x4A, 0x46] + Array(bareJpeg[2...])
        let out = JpegTools.forSaving(jfif, orientation: 8)
        XCTAssertEqual(Array(out[0 ..< 8]), Array(jfif[0 ..< 8]))
        XCTAssertEqual(Array(out[8 ..< 10]), [0xFF, 0xE1])
        XCTAssertEqual(Array(out[44...]), Array(jfif[8...]))
    }

    func testNotAJpegIsLeftAlone() {
        XCTAssertEqual(JpegTools.forSaving([1, 2, 3, 4, 5], orientation: 6), [1, 2, 3, 4, 5])
    }

    // MARK: Names

    func testExportNamesNeverReuseATakenName() {
        let taken: Set<String> = ["DSC1.tif", "DSC1-2.tif"]
        XCTAssertEqual(ExportNames.free(base: "DSC1", ext: "jpg") { taken.contains($0) }, "DSC1.jpg")
        XCTAssertEqual(ExportNames.free(base: "DSC1", ext: "tif") { taken.contains($0) }, "DSC1-3.tif")
    }
}
