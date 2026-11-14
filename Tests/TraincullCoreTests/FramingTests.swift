import XCTest
@testable import TraincullCore

/// Ported from the framing parts of the Android app's FaceFramingTest, with the same expected
/// values. (The MediaPipe mesh conversion is Android-only; subjects are built directly here.)
final class FramingTests: XCTestCase {
    /// A face at (cx, cy): box as the Android test's mesh extent, eyes `eyeGap` apart.
    private func face(_ cx: Double, _ cy: Double, eyeGap: Double = 200, iris: Double? = 37) -> Subject {
        var s = Subject(left: cx - 180, top: cy - 150, right: cx + 180, bottom: cy + 300)
        s.eye1X = cx - eyeGap / 2; s.eye1Y = cy
        s.eye2X = cx + eyeGap / 2; s.eye2Y = cy
        if let iris = iris {
            s.iris1X = s.eye1X; s.iris1Y = cy; s.iris2X = s.eye2X; s.iris2Y = cy
            s.irisDiameter = iris
        }
        return s
    }

    func testPrefersIrisThenEyes() {
        let r = Framing.fromSubject(face(1000, 800))
        XCTAssertEqual(r.method, .iris)
        XCTAssertEqual(r.anchor.x, 1000, accuracy: 0.5)
        XCTAssertEqual(r.eyeSpan!, 37 * Framing.eyeSpanPerIris, accuracy: 0.5)
        // Iris wildly inconsistent with the eyes (bad detection): fall back to the eyes.
        let e = Framing.fromSubject(face(1000, 800, iris: 150))
        XCTAssertEqual(e.method, .eyes)
        XCTAssertEqual(e.eyeSpan!, 200, accuracy: 0.5)
        // No iris at all, as with Apple's Vision: the eyes.
        XCTAssertEqual(Framing.fromSubject(face(1000, 800, iris: nil)).method, .eyes)
    }

    func testProfileFallsBackToFaceBox() {
        XCTAssertEqual(Framing.fromSubject(face(1000, 800, eyeGap: 10)).method, .faceBox)
    }

    func testFramesEyesAtAnchorCappedAt100Percent() {
        let small = Framing.frame(FaceResult(method: .iris, anchor: P(2000, 3000), eyeSpan: 100),
                                  viewW: 1600, viewH: 2560, minScale: 0.2, previousScale: nil, deadZone: 0.05)
        XCTAssertEqual(small.scale, 1) // tiny face: capped at actual pixels
        let big = Framing.frame(FaceResult(method: .iris, anchor: P(2000, 3000), eyeSpan: 1248),
                                viewW: 1600, viewH: 2560, minScale: 0.2, previousScale: nil, deadZone: 0.05)
        XCTAssertEqual(big.scale, Framing.targetEyeSpan(1600, 2560) / 1248, accuracy: 1e-4)
        // Anchor lands at 42% of the view height: centre is below the eyes by 8% of height / scale.
        XCTAssertEqual(big.center.y, 3000 + 2560 * 0.08 / big.scale, accuracy: 0.5)
        XCTAssertEqual(big.center.x, 2000, accuracy: 0.01)
    }

    func testDeadZoneKeepsPreviousZoom() {
        let r = FaceResult(method: .iris, anchor: P(0, 0), eyeSpan: 1248)
        let s = Framing.targetEyeSpan(1600, 2560) / 1248
        let kept = Framing.frame(r, viewW: 1600, viewH: 2560, minScale: 0.2, previousScale: s * 1.03, deadZone: 0.05)
        XCTAssertTrue(kept.keptPreviousZoom); XCTAssertEqual(kept.scale, s * 1.03, accuracy: 1e-5)
        let moved = Framing.frame(r, viewW: 1600, viewH: 2560, minScale: 0.2, previousScale: s * 1.2, deadZone: 0.05)
        XCTAssertFalse(moved.keptPreviousZoom); XCTAssertEqual(moved.scale, s, accuracy: 1e-5)
        let off = Framing.frame(r, viewW: 1600, viewH: 2560, minScale: 0.2, previousScale: s * 1.03, deadZone: 0)
        XCTAssertFalse(off.keptPreviousZoom)
    }

    func testPointOnlyGoesTo100Percent() {
        let f = Framing.frame(FaceResult(method: .point, anchor: P(10, 10), eyeSpan: nil),
                              viewW: 1600, viewH: 2560, minScale: 0.2, previousScale: nil, deadZone: 0.05)
        XCTAssertEqual(f.scale, 1)
    }

    func testEyesAt100KeepsActualPixelsAndIgnoresDeadZone() {
        let r = FaceResult(method: .iris, anchor: P(2000, 3000), eyeSpan: 1248)
        let f = Framing.frame(r, viewW: 1600, viewH: 2560, minScale: 0.2, previousScale: 0.5, deadZone: 0.05, eyesAt100: true)
        XCTAssertEqual(f.scale, 1)
        XCTAssertFalse(f.keptPreviousZoom)
    }
}
