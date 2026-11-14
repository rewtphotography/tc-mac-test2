import XCTest
@testable import TraincullCore

/// Ported from the Android app's ShotInfoTest, with the same expected values.
final class ShotInfoTests: XCTestCase {
    func testLabelMatchesTheAgreedLayout() {
        XCTAssertEqual(ShotInfo(focalMm: 85, fNumber: 2.8, exposureS: 1 / 250.0, iso: 400, model: "ILCE-7M4").label(),
                       "85mm @ f/2.8 · 1/250s · 400 ISO · a7IV")
        XCTAssertEqual(ShotInfo(focalMm: 24.5, fNumber: 8, exposureS: 2, iso: 100).label(), "24.5mm @ f/8 · 2s · 100 ISO")
        XCTAssertEqual(ShotInfo(exposureS: 0.000125).label(), "1/8000s")
    }

    func testRealWorldCameraNames() {
        let names = [
            "ILCE-7M4": "a7IV", "ILCE-7RM5": "a7RV", "ILCE-7RM4A": "a7RIVA", "ILCE-1": "a1",
            "ILCE-6700": "a6700", "ILCE-7C": "a7C", "ILCE-7CM2": "a7CII", "ILCE-7SM3": "a7SIII",
            "ILCE-9M3": "a9III", "DSC-RX100M7": "RX100VII", "NIKON D800E": "D800E", "NIKON Z 6_2": "Z6II",
            "NIKON Z 8": "Z8", "Canon EOS R5": "EOS R5", "X-T5": "X-T5",
        ]
        for (model, name) in names { XCTAssertEqual(ShotInfo.cameraName(model), name, model) }
    }

    /// IFD0 (model, JPEG, Exif pointer) → Exif IFD with rationals and ISO.
    func testReadsSettingsFromTheRaw() throws {
        let b = Buf(4000, little: true)
        b.put("II").putShort(42).putInt(8)
        b.position(8).putShort(4)
        b.entry(0x110, 2, 9, 600); b.entry(0x201, 4, 1, 2000); b.entry(0x202, 4, 1, 1000); b.entry(0x8769, 4, 1, 300); b.putInt(0)
        b.position(300).putShort(4)
        b.entry(0x829A, 5, 1, 700); b.entry(0x829D, 5, 1, 708); b.entry(0x8827, 3, 1, 400); b.entry(0x920A, 5, 1, 716); b.putInt(0)
        b.position(600).put("ILCE-7M4").put(0)
        b.position(700).putInt(1).putInt(250).putInt(28).putInt(10).putInt(850).putInt(10)
        let shot = try XCTUnwrap(try RecipeReader.read(BuiltInRecipes.arw, ArrayByteSource(b.bytes)).shot)
        XCTAssertEqual(shot.label(), "85mm @ f/2.8 · 1/250s · 400 ISO · a7IV")
    }
}
