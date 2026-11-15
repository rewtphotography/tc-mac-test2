import XCTest
@testable import TraincullCore

final class SubjectSelectTests: XCTestCase {
    /// A made-up scene: a large crisp "person" with a face, a crisp "prop" touching them, a
    /// blurred "person behind" touching them, and a crisp shape far away.
    private struct Scene {
        let w = 400, h = 300
        var luma: Gray
        var soft: Gray
        let face = PixelRect(x: 80, y: 60, w: 60, h: 60)

        init() {
            luma = Gray(w: 400, h: 300, fill: 0.2)
            soft = Gray(w: 400, h: 300)
            func paint(_ rect: PixelRect, blur: Int, into mask: inout Gray) {
                var shape = Gray(w: 400, h: 300)
                for y in rect.y ..< rect.maxY { for x in rect.x ..< rect.maxX { shape.v[y * 400 + x] = 1 } }
                // Texture inside, so there are edges to measure all over it.
                var textured = shape
                for y in rect.y ..< rect.maxY { for x in rect.x ..< rect.maxX where (x / 8 + y / 8) % 2 == 0 { textured.v[y * 400 + x] = 0.55 } }
                if blur > 0 { textured = textured.blurred(radius: blur).blurred(radius: blur) }
                for i in 0 ..< 400 * 300 {
                    luma.v[i] = max(luma.v[i], 0.2 + 0.7 * textured.v[i])
                    mask.v[i] = max(mask.v[i], shape.v[i])
                }
            }
            paint(PixelRect(x: 50, y: 40, w: 120, h: 220), blur: 0, into: &soft) // the person
            paint(PixelRect(x: 172, y: 100, w: 50, h: 40), blur: 0, into: &soft) // a prop in their hand (2 px gap)
            paint(PixelRect(x: 60, y: 262, w: 90, h: 34), blur: 4, into: &soft) // someone behind, out of focus (2 px gap)
            paint(PixelRect(x: 320, y: 40, w: 50, h: 60), blur: 0, into: &soft) // far away
        }
    }

    func testLabelsAndTidies() {
        let w = 12, h = 6
        var mask = [Bool](repeating: false, count: w * h)
        for (x, y) in [(1, 1), (2, 1), (2, 2), (3, 3), (8, 1), (9, 1)] { mask[y * w + x] = true }
        let (labels, count) = SubjectSelect.label(mask, w: w, h: h)
        XCTAssertEqual(count, 2, "pieces touching at a corner are one piece")
        XCTAssertEqual(labels[1 * w + 1], labels[3 * w + 3])
        XCTAssertNotEqual(labels[1 * w + 1], labels[1 * w + 8])

        // A big block with a pinhole and a speck beside it.
        let W = 200, H = 200
        var big = [Bool](repeating: false, count: W * H)
        for y in 20 ..< 180 { for x in 20 ..< 150 { big[y * W + x] = true } }
        big[100 * W + 80] = false
        big[100 * W + 190] = true
        let tidied = SubjectSelect.tidy(big, w: W, h: H)
        XCTAssertTrue(tidied[100 * W + 80], "the pinhole is filled")
        XCTAssertFalse(tidied[100 * W + 190], "the speck is gone")
        XCTAssertFalse(tidied[5 * W + 5], "the surround is not a hole")
    }

    func testKeepsThePersonAndTheirPropAndDropsTheRest() {
        let scene = Scene()
        let map = SharpnessMap(luma: scene.luma)
        let (mask, decision) = SubjectSelect.keep(scene.soft, sharpness: map, face: scene.face)
        print("SELECT \(decision.summary) · subject sharpness \(decision.subjectSharpness)")
        XCTAssertEqual(decision.components, 4)
        XCTAssertGreaterThanOrEqual(mask.at(110, 150), 0.5, "the person")
        XCTAssertGreaterThanOrEqual(mask.at(195, 120), 0.5, "the prop: attached and as sharp")
        XCTAssertLessThan(mask.at(105, 280), 0.5, "the person behind: attached but out of focus")
        XCTAssertLessThan(mask.at(345, 70), 0.5, "the far shape: sharp but not attached")
        XCTAssertEqual(decision.dropped["defocused"], 1)
        XCTAssertEqual(decision.dropped["disconnected"], 1)
        XCTAssertEqual(decision.kept, ["primary", "attached"])
    }

    func testHybridKeepsWhatTheOtherModelAgreesOn() {
        let scene = Scene()
        let map = SharpnessMap(luma: scene.luma)
        // The second model says the subject is the person and, wrongly sized, part of the far shape.
        var which = Gray(w: scene.w, h: scene.h)
        for y in 40 ..< 260 { for x in 50 ..< 170 { which.v[y * scene.w + x] = 1 } }
        for y in 40 ..< 100 { for x in 320 ..< 370 { which.v[y * scene.w + x] = 1 } }
        let (mask, decision) = SubjectSelect.hybrid(shape: scene.soft, which: which, sharpness: map, face: scene.face)
        XCTAssertGreaterThanOrEqual(mask.at(345, 70), 0.5, "kept because the second model claims it")
        XCTAssertGreaterThanOrEqual(mask.at(195, 120), 0.5, "the prop still comes along")
        XCTAssertLessThan(mask.at(105, 280), 0.5)
        XCTAssertTrue(decision.kept.contains("overlap"))
    }

    func testMergeFadesACloserLookIn() {
        let whole = Gray(w: 100, h: 100, fill: 0)
        let inside = Gray(w: 10, h: 10, fill: 1)
        let box = Box(x0: 20, y0: 20, x1: 80, y1: 80)
        let out = SubjectSelect.merge(whole, inside: inside, box: box)
        XCTAssertEqual(out.at(50, 50), 1, accuracy: 1e-4)
        XCTAssertEqual(out.at(10, 10), 0)
        XCTAssertEqual(out.at(20, 50), 0, accuracy: 1e-4, "nothing right at the box's edge")
        XCTAssertEqual(out.at(32, 50), 0.5, accuracy: 0.05, "half way across the feather")
        XCTAssertEqual(Box(x0: 10, y0: 10, x1: 30, y1: 50).expanded(by: 0.1, w: 31, h: 100), Box(x0: 8, y0: 6, x1: 31, y1: 54))
    }

    func testPointsForTheSubject() {
        let face = PixelRect(x: 100, y: 100, w: 40, h: 50)
        let both = SubjectSelect.points(face: face, h: 600)
        XCTAssertEqual(both.count, 2)
        XCTAssertEqual(both[1].y, 225)
        XCTAssertEqual(SubjectSelect.points(face: face, h: 200).count, 1, "no chest point when it would fall outside the picture")
    }
}
