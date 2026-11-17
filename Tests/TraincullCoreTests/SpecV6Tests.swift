import XCTest
@testable import TraincullCore

/// Masking spec v6: the subject light bound, shares without per-channel clipping, a region's
/// focus judged from inside it, the limits on what a box may take out, the hair zone, and
/// the brushes' Tightness. All on pictures made here.
final class SpecV6Tests: XCTestCase {
    private let farFace = PixelRect(x: 2, y: 2, w: 8, h: 8)

    /// A dark disc on a white ground with a one-pixel green ring just outside its edge: a
    /// lens's fringe. (Wider, and the colour read "beside the edge" on the subject's side is
    /// the fringe itself.)
    private func fringedDisc(size: Int = 200, radius: Float = 60) -> (photo: Photo, coarse: Gray) {
        let c = Float(size) / 2
        var px = [UInt8](repeating: 255, count: size * size * 4)
        var truth = Gray(w: size, h: size)
        let dark = SIMD3<Float>(0.08, 0.07, 0.07), light = SIMD3<Float>(0.97, 0.97, 0.97)
        for y in 0 ..< size {
            for x in 0 ..< size {
                let dx = Float(x) + 0.5 - c, dy = Float(y) + 0.5 - c
                let r = (dx * dx + dy * dy).squareRoot()
                let a = min(max(radius - r + 0.5, 0), 1)
                truth.v[y * size + x] = a
                var v = dark * a + light * (1 - a)
                if abs(r - radius - 0.3) < 0.6 { v = SIMD3(0.30, 0.52, 0.42) }
                for ch in 0 ..< 3 { px[(y * size + x) * 4 + ch] = UInt8(min(max(v[ch], 0), 1) * 255 + 0.5) }
            }
        }
        PlaneMath.boxBlur(&truth.v, w: size, h: size, radius: 2)
        return (Photo(w: size, h: size, rowBytes: size * 4, px: px), truth)
    }

    // MARK: 1.1 The subject light bound

    /// A black subject against white with a green fringe: the fringe's green is the
    /// background's, and with the bound it goes with the background.
    func testLightBoundTakesTheGreenOutOfAFringe() {
        let scene = fringedDisc()
        var off = MatteSettings()
        off.lightBound = false
        let with = Matte(photo: scene.photo, coarse: scene.coarse, faces: [farFace]).run(tier: .off)
        let without = Matte(photo: scene.photo, coarse: scene.coarse, faces: [farFace], settings: off).run(tier: .off)
        /// The green the subject keeps at the fringe once the background is gone: the subject's
        /// part of each fringe pixel's light, green over the mean of red and blue.
        func green(_ out: MatteOutput) -> Float {
            var sum: Float = 0, n: Float = 0
            let lin = Matte.toLinear.p
            for y in 0 ..< 200 {
                for x in 0 ..< 200 {
                    let dx = Float(x) + 0.5 - 100, dy = Float(y) + 0.5 - 100
                    if abs((dx * dx + dy * dy).squareRoot() - 60.3) >= 0.6 { continue }
                    let o = (y * 200 + x) * 4
                    let c = scene.photo.rgb(x, y)
                    let I = SIMD3(lin[Int(c.x * 255)], lin[Int(c.y * 255)], lin[Int(c.z * 255)])
                    let s = SIMD3(Float(out.shares[o]), Float(out.shares[o + 1]), Float(out.shares[o + 2])) / 255
                    let kept = I * s
                    sum += kept.y - (kept.x + kept.z) / 2
                    n += 1
                }
            }
            return sum / max(n, 1)
        }
        let before = green(without), after = green(with)
        print("V6 light bound: green kept at the fringe \(before) → \(after) · \(with.log.filter { $0.hasPrefix("light bound") }.joined())")
        XCTAssertGreaterThan(with.lightBounded, 50, "the bound lowered the fringe's shares")
        XCTAssertGreaterThan(before, 0.01, "without the bound the subject keeps the fringe's green")
        XCTAssertLessThan(after, 0.7 * before, "the fringe's green goes with the background, down to the bound's tolerance")
        XCTAssertLessThan(after, 0.008)
        XCTAssertTrue(with.log.contains { $0.hasPrefix("light bound:") })
        // Only ever lowers.
        var raised = 0
        for i in 0 ..< 200 * 200 * 4 where i % 4 != 3 && Int(with.shares[i]) > Int(without.shares[i]) + 1 { raised += 1 }
        XCTAssertEqual(raised, 0)
        XCTAssertEqual(with.alpha, without.alpha, "the mask itself is the same")
        // Inside the subject nothing changes.
        XCTAssertEqual(with.shares[(100 * 200 + 100) * 4 + 1], 255)
    }

    /// With Decontamination off the shares are the mask, bound or not.
    func testLightBoundNeedsDecontamination() {
        let scene = fringedDisc()
        var plain = MatteSettings()
        plain.decontaminate = false
        let out = Matte(photo: scene.photo, coarse: scene.coarse, faces: [farFace], settings: plain).run(tier: .off)
        XCTAssertEqual(out.lightBounded, 0)
        for i in 0 ..< 200 * 200 { XCTAssertEqual(out.shares[i * 4 + 1], out.alpha[i]) }
    }

    // MARK: 1.3 No per-channel clipping

    func testSharesKeepTheirHue() {
        // Over 1 in one channel: all three scaled down together.
        let own = SIMD3<Float>(0.5, 0.2, 0.1), I = SIMD3<Float>(0.25, 0.3, 0.3)
        let each = Matte.unclipped(own: own, pixel: I, together: 0.6)
        XCTAssertEqual(each.max(), 1, accuracy: 1e-6)
        XCTAssertEqual(each.x / each.y, (0.5 / 0.25) / (0.2 / 0.3), accuracy: 1e-4, "the ratio between channels is kept")
        XCTAssertEqual(each.y / each.z, 2, accuracy: 1e-4)
        // Below 0 in one channel: moved towards the single share just far enough.
        let negative = Matte.unclipped(own: SIMD3(-0.06, 0.2, 0.2), pixel: SIMD3(0.3, 0.3, 0.3), together: 0.4)
        XCTAssertEqual(negative.min(), 0, accuracy: 1e-5)
        XCTAssertLessThan(negative.y, 0.2 / 0.3, "the others moved towards the single share too")
        XCTAssertEqual(negative.y, negative.z, accuracy: 1e-6)
        // A channel with no light of its own takes the single share instead of blowing the others away.
        let dark = Matte.unclipped(own: SIMD3(0.2, 0.1, 0.00001), pixel: SIMD3(0.4, 0.2, 0.0001), together: 0.5)
        XCTAssertEqual(dark.x, 0.5, accuracy: 1e-5)
        XCTAssertEqual(dark.y, 0.5, accuracy: 1e-5)
        XCTAssertEqual(dark.z, 0.5, accuracy: 1e-5)
    }

    // MARK: 1.2 The sRGB curve

    func testExactSRGBCurve() {
        XCTAssertEqual(srgbToLinear(0), 0)
        XCTAssertEqual(srgbToLinear(1), 1, accuracy: 1e-6)
        XCTAssertEqual(srgbToLinear(0.5), 0.21404, accuracy: 1e-4)
        XCTAssertEqual(srgbToLinear(0.02), 0.02 / 12.92, accuracy: 1e-7, "the straight part near black")
        for v in stride(from: Float(0), through: 1, by: 0.05) { XCTAssertEqual(linearToSRGB(srgbToLinear(v)), v, accuracy: 1e-5) }
        XCTAssertEqual(Matte.toLinear.p[128], srgbToLinear(128 / 255), accuracy: 1e-7)
    }

    // MARK: 2.2 A region's focus, and what a box may take out

    /// A textured square, sharp or blurred, painted into a brightness plane.
    private func paint(_ luma: inout Gray, _ r: PixelRect, blur: Int) {
        var shape = Gray(w: luma.w, h: luma.h)
        for y in r.y ..< r.maxY { for x in r.x ..< r.maxX { shape.v[y * luma.w + x] = (x / 12 + y / 12) % 2 == 0 ? 0.9 : 0.25 } }
        if blur > 0 { shape = shape.blurred(radius: blur).blurred(radius: blur) }
        for y in r.y ..< r.maxY { for x in r.x ..< r.maxX { luma.v[y * luma.w + x] = shape.v[y * luma.w + x] } }
    }

    /// A flat region beside a sharp edge has no focus of its own to measure: "can't tell".
    /// (Measured just inside its boundary, as the selection rules do, it would read as sharp
    /// as the edge beside it; and the dense map fills it from that edge too.)
    func testFlatRegionBesideASharpEdgeCantBeTold() {
        let w = 240, h = 240
        var luma = Gray(w: w, h: h, fill: 0.5)
        paint(&luma, PixelRect(x: 120, y: 40, w: 100, h: 160), blur: 0) // sharp texture to the right
        let map = SharpnessMap(luma: luma)
        var flat = [Bool](repeating: false, count: w * h)
        for y in 50 ..< 190 { for x in 40 ..< 122 { flat[y * w + x] = true } } // the flat area, touching the sharp edge
        let judged = Refine.regionBlur(flat, w: w, h: h, origin: (0, 0), photoW: w, photoH: h, map: map)
        XCTAssertNil(judged.blur, "no edges inside a flat region once it is shrunk: its focus can't be told")
        XCTAssertNotNil(SubjectSelect.edgeSharp(flat, map), "the boundary measure finds the neighbour's sharp edge")
        XCTAssertLessThan(map.dense.v[120 * w + 100], 2, "and the dense map calls it sharp")
    }

    /// Inside a box, the model's answer would take out two areas the mask calls subject: one
    /// as sharp as the subject (kept), one well out of focus (taken out).
    func testBoxKeepsAnInFocusRegionAndTakesOutADefocusedOne() {
        let w = 360, h = 240
        var luma = Gray(w: w, h: h, fill: 0.5)
        let sharpArea = PixelRect(x: 40, y: 60, w: 110, h: 120), softArea = PixelRect(x: 210, y: 60, w: 110, h: 120)
        paint(&luma, sharpArea, blur: 0)
        paint(&luma, softArea, blur: 3)
        // The photo: the brightness as grey, on a blue ground outside the subject.
        var px = [UInt8](repeating: 255, count: w * h * 4)
        var current = Gray(w: w, h: h)
        let subject = PixelRect(x: 20, y: 40, w: 320, h: 160)
        for y in 0 ..< h {
            for x in 0 ..< w {
                let i = y * w + x
                let inside = subject.contains(x, y)
                current.v[i] = inside ? 1 : 0
                let v: SIMD3<Float> = inside ? SIMD3(repeating: luma.v[i]) : SIMD3(0.2, 0.3, 0.8)
                for ch in 0 ..< 3 { px[i * 4 + ch] = UInt8(v[ch] * 255) }
            }
        }
        let photo = Photo(w: w, h: h, rowBytes: w * 4, px: px)
        let map = SharpnessMap(luma: luma)
        func blur(_ r: PixelRect) -> Float? {
            var region = [Bool](repeating: false, count: w * h)
            for y in r.y ..< r.maxY { for x in r.x ..< r.maxX { region[y * w + x] = true } }
            let judged = Refine.regionBlur(region, w: w, h: h, origin: (0, 0), photoW: w, photoH: h, map: map)
            print("V6 region \(r): blur \(String(describing: judged.blur)) from \(judged.edges) edges")
            return judged.blur
        }
        let sharp = try! XCTUnwrap(blur(sharpArea)), soft = try! XCTUnwrap(blur(softArea))
        XCTAssertGreaterThan(soft, sharp + 1)
        // The model's answer: the subject's outline, but both squares gone.
        var proposal = current
        for r in [sharpArea, softArea] { for y in r.y ..< r.maxY { for x in r.x ..< r.maxX { proposal.v[y * w + x] = 0 } } }
        let context = RefineContext(photo: photo, faces: [], sharpness: map, focusLimit: sharp + 1)
        let limited = Refine.limitRemovals(proposal: proposal, current: current, box: Gray(w: w, h: h, fill: 1),
                                           look: PixelRect(x: 0, y: 0, w: w, h: h), modelPixel: 1, context: context)
        print("V6 box regions: \(limited.log)")
        XCTAssertEqual(limited.proposal.v[120 * w + 95], 1, "the in-focus region is kept")
        XCTAssertEqual(limited.proposal.v[120 * w + 265], 0, "the out-of-focus region is taken out")
        XCTAssertEqual(limited.proposal.v[62 * w + 42], 1, "to its corner")
        XCTAssertTrue(limited.log.contains { $0.contains("removed: out of focus") })
        XCTAssertTrue(limited.log.contains { $0.contains("kept:") })
    }

    /// The look area: at least a face height and 1024 pixels a side, the box inside it, and
    /// moved rather than cut at the photo's edge.
    func testLookAreaGivesTheModelContext() {
        let box = PixelRect(x: 2000, y: 3000, w: 120, h: 80)
        let look = Refine.lookArea(box: box, w: 4672, h: 7008, faceHeight: 1300)
        XCTAssertGreaterThanOrEqual(look.w, 1300)
        XCTAssertGreaterThanOrEqual(look.h, 1300)
        XCTAssertTrue(look.x <= box.x && look.maxX >= box.maxX && look.y <= box.y && look.maxY >= box.maxY)
        let corner = Refine.lookArea(box: PixelRect(x: 10, y: 10, w: 100, h: 100), w: 4672, h: 7008)
        XCTAssertEqual(corner.x, 0)
        XCTAssertEqual(corner.w, 1024, "moved inside the photo, not cut")
        let big = Refine.lookArea(box: PixelRect(x: 100, y: 100, w: 2000, h: 2000), w: 4672, h: 7008)
        XCTAssertEqual(big.w, 2600, "a large box still gets its 15%")
    }

    // MARK: 3.1 Tightness

    func testTightness() {
        for v in stride(from: Float(0), through: 1, by: 0.1) { XCTAssertEqual(Refine.tighten(v, 0), v) }
        XCTAssertEqual(Refine.tighten(0.15, 0.5), 0, "faint flyaways drop out")
        XCTAssertEqual(Refine.tighten(1, 0.5), 1)
        XCTAssertGreaterThan(Refine.tighten(0.7, 0.5), 0.6, "the rest is steepened")
        XCTAssertEqual(Refine.tighten(0.9, -0.5), 1, "looser: the top goes solid")
        XCTAssertGreaterThan(Refine.tighten(0.2, -0.5), 0.2)
    }

    // MARK: 5 The hair zone

    func testHairZoneIsTheHeadNotTheBody() {
        let size = 400
        var px = [UInt8](repeating: 200, count: size * size * 4)
        for i in 0 ..< size * size { px[i * 4 + 3] = 255 }
        let photo = Photo(w: size, h: size, rowBytes: size * 4, px: px)
        var coarse = Gray(w: size / 4, h: size / 4)
        for y in 10 ..< 90 { for x in 20 ..< 80 { coarse.v[y * 100 + x] = 1 } }
        let face = PixelRect(x: 170, y: 100, w: 60, h: 60)
        // A forearm raised beside the face: elbow and wrist inside the old head box.
        let body = BodyPose(joints: [
            "nose": .init(x: 200, y: 135, confidence: 0.9),
            "leftShoulder": .init(x: 140, y: 220, confidence: 0.9), "rightShoulder": .init(x: 260, y: 220, confidence: 0.9),
            "leftElbow": .init(x: 120, y: 170, confidence: 0.9), "leftWrist": .init(x: 120, y: 110, confidence: 0.9),
        ])
        let withBody = Matte(photo: photo, coarse: coarse, faces: [face], body: body)
        let cell = { (x: Int, y: Int) in (y / 4) * withBody.qw + x / 4 }
        XCTAssertGreaterThan(withBody.hairQ.p[cell(200, 55)], 0.9, "above the head is hair")
        XCTAssertLessThan(withBody.hairQ.p[cell(120, 115)], 0.05, "the wrist beside the face is not")
        let old = Matte(photo: photo, coarse: coarse, faces: [face])
        XCTAssertLessThan(withBody.hairQ.p[cell(120, 140)], 0.05, "nor the forearm")
        // The box is 2.0 × 2.4 face sizes: 2.3 face widths from the middle is outside it.
        XCTAssertEqual(old.hairQ.p[cell(200 - 2 * 60 + 10, 120)], 0, "outside the tighter box")

        // No face: the pose's head places the zone.
        let fromPose = Matte(photo: photo, coarse: coarse, faces: [], body: body)
        XCTAssertGreaterThan(fromPose.hairQ.p[cell(200, 66)], 0.5)
        XCTAssertEqual(fromPose.hairZoneFrom, "the body pose's head")
        // No face and no pose: no hair zone at all, not "all hair".
        let none = Matte(photo: photo, coarse: coarse, faces: [])
        XCTAssertEqual(none.hairQ.array.max() ?? 1, 0)
        XCTAssertTrue(none.hairZoneFrom.hasPrefix("none"))
    }

    /// A photo with no face gets the plain edge's clean-up (it used to be all hair zone).
    func testNoFaceGetsEdgeCleanUp() {
        let scene = fringedDisc()
        let out = Matte(photo: scene.photo, coarse: scene.coarse, faces: []).run(tier: .off)
        let snap = out.log.first { $0.hasPrefix("snap") } ?? ""
        XCTAssertFalse(snap.contains("0 px in the ring"), snap)
        XCTAssertNotNil(out.edgeOffset.mean, "the edge is measured: none of it is hair")
        XCTAssertGreaterThan(out.lightBounded, 0)
    }
}
