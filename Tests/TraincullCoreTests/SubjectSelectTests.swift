import XCTest
@testable import TraincullCore

final class SubjectSelectTests: XCTestCase {
    /// A made-up scene: a large crisp "person" with a face, a crisp "prop" touching them, a
    /// blurred "person behind" touching them, and a crisp shape far away.
    private struct Scene {
        let w = 400, h = 300
        var luma: Gray
        var soft: Gray
        /// A small face (under a twentieth of the frame's height), so sharpness is applied strictly.
        let face = PixelRect(x: 103, y: 60, w: 14, h: 14)

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
            paint(PixelRect(x: 60, y: 262, w: 90, h: 34), blur: 6, into: &soft) // someone behind, out of focus (2 px gap)
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

    /// Strictness follows the size of the face, and the user's setting scales it.
    func testStrictnessFollowsTheFaceAndTheSetting() {
        var rules = SubjectRules()
        XCTAssertEqual(rules.strictness(faceHeight: 40, frameHeight: 1000), 1.0, accuracy: 1e-5, "a small face: strict")
        XCTAssertEqual(rules.strictness(faceHeight: 250, frameHeight: 1000), 0.2, accuracy: 1e-5, "a large face: very loose")
        XCTAssertEqual(rules.strictness(faceHeight: 125, frameHeight: 1000), 0.6, accuracy: 1e-5, "half way between")
        rules.focusStrictness = 1.4
        XCTAssertEqual(rules.strictness(faceHeight: 40, frameHeight: 1000), 1.4, accuracy: 1e-5)

        // The same scene, the face made large: the blurred piece behind now stays, because a
        // close subject is allowed to fall out of focus.
        let scene = Scene()
        let map = SharpnessMap(luma: scene.luma)
        let strict = SubjectSelect.keep(scene.soft, sharpness: map, face: scene.face).decision
        XCTAssertEqual(strict.dropped["defocused"], 1)
        XCTAssertEqual(strict.limit, strict.subjectSharpness + 1 / strict.strictness, accuracy: 1e-4)
        var loose = SubjectRules()
        loose.focusStrictness = 0.1
        XCTAssertNil(SubjectSelect.keep(scene.soft, sharpness: map, face: scene.face, rules: loose).decision.dropped["defocused"])
        XCTAssertTrue(strict.details.contains { $0.contains("dropped: defocused") && $0.contains("edge blur") }, "\(strict.details)")
        XCTAssertTrue(strict.details.contains { $0.contains("kept: primary") })
    }

    /// A piece the body pose confirms is kept however soft it is; and with no face at all the
    /// largest piece is the subject.
    func testPoseConfirmedPiecesStayAndNoFaceStillWorks() {
        let scene = Scene()
        let map = SharpnessMap(luma: scene.luma)
        // A "wrist" in the blurred piece behind, an "elbow" in the person.
        let pose = BodyPose(joints: ["leftElbow": .init(x: 105, y: 240, confidence: 0.9), "leftWrist": .init(x: 105, y: 280, confidence: 0.8),
                                     "rightWrist": .init(x: 345, y: 70, confidence: 0.1)])
        let limbs = pose.confirmed(radius: 8, w: scene.w, h: scene.h)
        XCTAssertTrue(limbs[260 * scene.w + 105], "on the line between the two joints")
        XCTAssertFalse(limbs[260 * scene.w + 125], "well to the side of it")
        XCTAssertFalse(limbs[70 * scene.w + 345], "a joint the detector wasn't sure of counts for nothing")
        let (mask, decision) = SubjectSelect.keep(scene.soft, sharpness: map, face: scene.face) { piece in
            zip(piece, limbs).contains { $0 && $1 }
        }
        XCTAssertGreaterThanOrEqual(mask.at(105, 280), 0.5, "soft, but the pose says it is the subject's arm")
        XCTAssertTrue(decision.kept.contains("confirmed body"))
        XCTAssertLessThan(mask.at(345, 70), 0.5)

        let (faceless, _) = SubjectSelect.keep(scene.soft, sharpness: map, face: nil)
        XCTAssertGreaterThanOrEqual(faceless.at(110, 150), 0.5, "the largest piece")

        // Matching a pose to a face: the nearest head, if it is near enough.
        let near = BodyPose(joints: ["nose": .init(x: 111, y: 70, confidence: 0.9)])
        let far = BodyPose(joints: ["nose": .init(x: 300, y: 90, confidence: 0.9)])
        XCTAssertEqual(BodyPose.match([far, near], face: scene.face), 1)
        XCTAssertNil(BodyPose.match([far], face: scene.face))
    }

    /// Close-up tiles cover the subject's box, stay in the picture and are never too many.
    func testCloseUpTilesCoverTheBox() {
        let rules = SubjectRules()
        func covered(_ box: Box, _ tiles: [Box]) -> Bool {
            for y in stride(from: box.y0, to: box.y1, by: 7) {
                for x in stride(from: box.x0, to: box.x1, by: 7) where !tiles.contains(where: { x >= $0.x0 && x < $0.x1 && y >= $0.y0 && y < $0.y1 }) { return false }
            }
            return true
        }
        // A full-length figure: a tall narrow box.
        let tall = Box(x0: 700, y0: 60, x1: 1300, y1: 1340)
        let a = CloseUps.tiles(covering: tall, w: 2048, h: 1365, rules: rules)
        XCTAssertEqual(a.count, 3)
        XCTAssertTrue(a.allSatisfy { $0.x1 - $0.x0 == 600 && $0.y1 - $0.y0 == 600 })
        XCTAssertTrue(covered(tall, a))
        // A box nearly as wide as it is tall: tiles are at most half its longer side, so the
        // model always sees at least twice the detail it had of the whole frame.
        let squarish = Box(x0: 100, y0: 0, x1: 1300, y1: 1365)
        let s = CloseUps.tiles(covering: squarish, w: 2048, h: 1365, rules: rules)
        XCTAssertTrue(s.allSatisfy { $0.x1 - $0.x0 <= 1024 }, "\(s)")
        XCTAssertGreaterThanOrEqual(s.count, 4)
        XCTAssertLessThanOrEqual(s.count, rules.tilesMost)
        XCTAssertTrue(covered(squarish, s))
        // A small subject: one tile, no smaller than the least size, inside the picture.
        let small = Box(x0: 10, y0: 20, x1: 150, y1: 300)
        let b = CloseUps.tiles(covering: small, w: 2048, h: 1365, rules: rules)
        XCTAssertEqual(b.count, 1)
        XCTAssertEqual(b[0].x0, 0)
        XCTAssertEqual(b[0].x1 - b[0].x0, rules.tileLeast)
        XCTAssertTrue(covered(small, b))
        // The whole frame: tiles as large as allowed, never more than the limit.
        let whole = Box(x0: 0, y0: 0, x1: 2048, y1: 1365)
        let c = CloseUps.tiles(covering: whole, w: 2048, h: 1365, rules: rules)
        XCTAssertLessThanOrEqual(c.count, rules.tilesMost)
        XCTAssertTrue(covered(whole, c))
        XCTAssertTrue(c.allSatisfy { $0.x0 >= 0 && $0.y0 >= 0 && $0.x1 <= 2048 && $0.y1 <= 1365 })
        XCTAssertTrue(CloseUps.tiles(covering: Box(x0: 5, y0: 5, x1: 5, y1: 9), w: 100, h: 100).isEmpty)
    }

    /// A closer look moves the edge that is there, at a finer size, and adds nothing far from it.
    func testCloseUpsOnlyMoveTheEdgeThatIsThere() {
        // The mask so far: the left half, its edge at x = 50. The closer look says the edge is
        // at x = 53, and also (wrongly) claims a blob far away on the right.
        let w = 100, h = 80
        var base = Gray(w: w, h: h)
        for y in 0 ..< h { for x in 0 ..< 50 { base.v[y * w + x] = 1 } }
        let zone = CloseUps.edgeZone(base, radius: 8)
        XCTAssertEqual(zone.at(50, 40), 1)
        XCTAssertEqual(zone.at(44, 40), 1)
        XCTAssertEqual(zone.at(70, 40), 0)
        XCTAssertEqual(zone.at(20, 40), 0)
        var answer = Gray(w: 2 * w, h: 2 * h)
        for y in 0 ..< 2 * h { for x in 0 ..< 2 * w where x < 106 || (x > 170 && x < 190) { answer.v[y * 2 * w + x] = 1 } }
        var canvas = CloseUps.Canvas(w: 2 * w, h: 2 * h, scale: 2)
        canvas.add(answer, box: Box(x0: 0, y0: 0, x1: w, y1: h), feather: 4)
        XCTAssertEqual(canvas.tiles, 1)
        let out = canvas.merged(over: base, zone: zone)
        XCTAssertEqual(out.w, 2 * w)
        XCTAssertGreaterThan(out.at(104, 80), 0.9, "the edge has moved out to where the closer look put it")
        XCTAssertLessThan(out.at(108, 80), 0.1)
        XCTAssertLessThan(out.at(180, 80), 0.01, "the far blob is not near the edge, so it is not taken")
        XCTAssertGreaterThan(out.at(40, 80), 0.99)
        XCTAssertEqual(CloseUps.mergeRadius(faceHeight: 200, longEdge: 2048), 16, accuracy: 1e-4)
        XCTAssertNil(canvas.seamRatio(out), "one tile over the whole picture has no border inside it")

        // Two tiles that disagree about where the edge is, overlapping: where they meet must not show.
        var left = Gray(w: 120, h: 160), right = Gray(w: 120, h: 160)
        for y in 0 ..< 160 { for x in 0 ..< 120 { left.v[y * 120 + x] = y < 80 ? 1 : 0; right.v[y * 120 + x] = y < 84 ? 1 : 0 } }
        var flat = Gray(w: 200, h: 160)
        for y in 0 ..< 82 { for x in 0 ..< 200 { flat.v[y * 200 + x] = 1 } }
        var two = CloseUps.Canvas(w: 200, h: 160, scale: 1)
        two.add(left, box: Box(x0: 0, y0: 0, x1: 120, y1: 160), feather: 24)
        two.add(right, box: Box(x0: 80, y0: 0, x1: 200, y1: 160), feather: 24)
        let joined = two.merged(over: flat, zone: CloseUps.edgeZone(flat, radius: 10))
        var worst: Float = 0
        for x in 1 ..< 200 { worst = max(worst, abs(joined.at(x, 82) - joined.at(x - 1, 82))) }
        XCTAssertLessThan(worst, 0.1, "the two tiles' answers fade into each other")
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
}
