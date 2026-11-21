@testable import TraincullCore
import XCTest

/// The made-up DNG is a well-formed TIFF with the tags a DNG reader needs, and its picture has
/// the regions the raw tests rely on.
final class SyntheticDngTests: XCTestCase {
    func testStructure() throws {
        for orientation in [1, 6] {
            let bytes = SyntheticDng.make(width: 64, height: 48, orientation: orientation)
            let tiff = try Tiff(ArrayByteSource(bytes))
            let ifd = try tiff.readIfd(tiff.firstIfdOffset)
            let tags = ifd.entries.keys.sorted()
            for needed in [256, 257, 258, 262, 273, 274, 279, 33421, 33422, 50706, 50717, 50721, 50728, 50778] {
                XCTAssertTrue(tags.contains(needed), "tag \(needed)")
            }
            let (sw, sh) = orientation == 6 ? (48, 64) : (64, 48)
            XCTAssertEqual(tiff.value(ifd, 256), Int64(sw))
            XCTAssertEqual(tiff.value(ifd, 257), Int64(sh))
            XCTAssertEqual(tiff.value(ifd, 274), Int64(orientation))
            let start = try XCTUnwrap(tiff.value(ifd, 273)), count = try XCTUnwrap(tiff.value(ifd, 279))
            XCTAssertEqual(Int(start + count), bytes.count)
            XCTAssertEqual(Int(count), sw * sh * 2)
        }
    }

    /// The grey patch is neutral in the camera's colours; the clipped blocks are at the white level.
    func testRegions() throws {
        let w = 200, h = 100
        let layout = SyntheticDng.layout(width: w, height: h)
        let grey = SyntheticDng.scene(layout.greyPatch.centreX, layout.greyPatch.centreY, layout)
        XCTAssertEqual(grey.0, grey.1)
        XCTAssertEqual(grey.1, grey.2)
        let two = SyntheticDng.scene(layout.clippedTwo.centreX, layout.clippedTwo.centreY, layout)
        XCTAssertTrue(two.0 >= 1 && two.1 >= 1 && two.2 < 1)
        let one = SyntheticDng.scene(layout.clippedOne.centreX, layout.clippedOne.centreY, layout)
        XCTAssertTrue(one.0 >= 1 && one.1 < 1 && one.2 < 1)
        // Where the grey patch would be if the picture were flipped top to bottom, or turned, it is not grey.
        let flipped = SyntheticDng.scene(layout.greyPatch.centreX, h - 1 - layout.greyPatch.centreY, layout)
        XCTAssertGreaterThan(abs(flipped.0 - flipped.2), 0.05)
    }
}
