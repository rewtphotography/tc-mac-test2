import XCTest
@testable import TraincullCore

/// The refine tools and the colour rules of masking spec v5, on made-up pictures.
final class RefineTests: XCTestCase {
    /// A dark disc on a light ground. `fringe` paints the one-pixel ring at its edge green,
    /// as a fast lens does at a black-on-white edge.
    private func disc(size: Int = 200, radius: Float = 60, dark: SIMD3<Float> = SIMD3(0.10, 0.09, 0.09), light: SIMD3<Float> = SIMD3(0.97, 0.97, 0.97),
                      fringe: Bool = false) -> (photo: Photo, truth: Gray) {
        let w = size, h = size, c = Float(size) / 2
        var px = [UInt8](repeating: 255, count: w * h * 4)
        var truth = Gray(w: w, h: h)
        for y in 0 ..< h {
            for x in 0 ..< w {
                let dx = Float(x) + 0.5 - c, dy = Float(y) + 0.5 - c
                let r = (dx * dx + dy * dy).squareRoot()
                let a = min(max(radius - r + 0.5, 0), 1)
                truth.v[y * w + x] = a
                var v = dark * a + light * (1 - a)
                if fringe && abs(r - radius) < 1.2 { v = SIMD3(0.34, 0.50, 0.43) }
                for ch in 0 ..< 3 { px[(y * w + x) * 4 + ch] = UInt8(min(max(v[ch], 0), 1) * 255 + 0.5) }
            }
        }
        return (Photo(w: w, h: h, rowBytes: w * 4, px: px), truth)
    }

    private let farFace = PixelRect(x: 2, y: 2, w: 8, h: 8)

    // MARK: Colour

    /// The bug of alpha 13: at a black-on-white edge with a green lens fringe, darkening the
    /// background must not leave the fringe behind, greener than the photo has it.
    func testMaskingNeverAddsColourAtAFringedEdge() {
        let scene = disc(fringe: true)
        var soft = scene.truth
        PlaneMath.boxBlur(&soft.v, w: 200, h: 200, radius: 2)
        let out = Matte(photo: scene.photo, coarse: soft, faces: [farFace]).run(tier: .off)
        let lin = Refine.toLinear
        var worst: Float = 0, edgePixels = 0
        for y in 0 ..< 200 {
            for x in 0 ..< 200 where out.alpha[y * 200 + x] > 0 && out.alpha[y * 200 + x] < 255 {
                edgePixels += 1
                let o = (y * 200 + x) * 4
                let c = scene.photo.rgb(x, y)
                let I = SIMD3(lin[Int(c.x * 255)], lin[Int(c.y * 255)], lin[Int(c.z * 255)])
                let s = SIMD3(Float(out.shares[o]), Float(out.shares[o + 1]), Float(out.shares[o + 2])) / 255
                // The background three stops darker.
                let dimmed = I * (s + (SIMD3<Float>(repeating: 1) - s) * 0.125)
                let before = Oklab.from(linear: I), after = Oklab.from(linear: dimmed)
                let gained = Oklab.chroma(after) / max(after.x, 0.02) - Oklab.chroma(before) / max(before.x, 0.02)
                worst = max(worst, gained)
            }
        }
        XCTAssertGreaterThan(edgePixels, 200)
        XCTAssertLessThan(worst, 0.05, "no edge pixel comes out more saturated than the photo has it")
        XCTAssertTrue(out.log.contains { $0.hasPrefix("colour guard") })
        print("REFINE fringe: worst gain in saturation \(worst) · \(out.log.filter { $0.hasPrefix("colour guard") || $0.hasPrefix("decontaminated") }.joined(separator: " · "))")
    }

    func testSharesFollowTheColoursOnlyWhereTheyExplainThePixel() {
        let lin = Matte.toLinear.p
        func shares(_ I: SIMD3<Float>, _ F: SIMD3<Float>, _ B: SIMD3<Float>, _ a: Float) -> SIMD3<Float> {
            Matte.shares(pixel: I, subject: F, background: B, alpha: a, lin: lin, low: 0.08, high: 0.20, floor0: 0.10, floor1: 0.25, falloff: 50)
        }
        // Half a black top, half a mid-grey wall: nearly all the pixel's light is the wall's.
        let dark = shares(SIMD3(0.42, 0.42, 0.42), SIMD3(0.08, 0.08, 0.08), SIMD3(0.6, 0.6, 0.6), 0.5)
        XCTAssertLessThan(dark.x, 0.1)
        // Beside a blown-out window every channel gets the same share, whatever tint the pixel has.
        let blown = shares(SIMD3(0.34, 0.50, 0.43), SIMD3(0.08, 0.08, 0.08), SIMD3(1, 1, 1), 0.6)
        XCTAssertEqual(blown.x, blown.y, accuracy: 1e-4)
        XCTAssertEqual(blown.y, blown.z, accuracy: 1e-4)
        XCTAssertLessThan(blown.y, 0.15)
        // A blonde strand over a navy suit against a dark room: neither colour is the strand's, so coverage stands.
        let strand = shares(SIMD3(0.75, 0.68, 0.5), SIMD3(0.05, 0.07, 0.2), SIMD3(0.06, 0.06, 0.06), 0.6)
        XCTAssertEqual(strand.x, 0.6, accuracy: 0.02)
        XCTAssertEqual(strand.z, 0.6, accuracy: 0.02)
        // Skin over green: the subject keeps more of the red than of the green.
        let skin = shares(SIMD3(0.55, 0.6, 0.4), SIMD3(0.8, 0.6, 0.5), SIMD3(0.3, 0.6, 0.3), 0.5)
        XCTAssertGreaterThan(skin.x, skin.y)
        for v in [dark, blown, strand, skin] { for c in 0 ..< 3 { XCTAssertTrue(v[c] >= 0 && v[c] <= 1) } }

        let grey = Oklab.from(linear: SIMD3(0.2, 0.2, 0.2))
        XCTAssertLessThan(Oklab.chroma(grey), 1e-3)
        XCTAssertEqual(Oklab.hueApart(Oklab.from(linear: SIMD3(0.5, 0.1, 0.1)), Oklab.from(linear: SIMD3(0.1, 0.5, 0.1))), 122, accuracy: 6)
    }

    // MARK: Where a tool acts

    func testBoxAndStrokeWeights() {
        let patch = PixelRect(x: 100, y: 200, w: 80, h: 60)
        let box = Refine.weight(box: PixelRect(x: 110, y: 210, w: 40, h: 30), in: patch, feather: 6)
        XCTAssertEqual(box.at(30, 25), 1)
        XCTAssertEqual(box.at(5, 5), 0)
        XCTAssertEqual(box.at(10, 25), 0.5 / 6, accuracy: 1e-4)
        let stroke = RefineStroke(points: [SIMD2(120, 220), SIMD2(160, 220)], radius: 10)
        let s = Refine.weight(stroke: stroke, in: patch)
        XCTAssertEqual(s.at(40, 20), 1, "on the line")
        XCTAssertEqual(s.at(40, 35), 0, "more than a radius away")
        XCTAssertGreaterThan(s.at(40, 28), 0)
        XCTAssertLessThan(s.at(40, 28), 1)
        XCTAssertEqual(Refine.bounds(of: stroke, w: 1000, h: 1000), PixelRect(x: 109, y: 209, w: 62, h: 22))
        let around = Refine.patch(around: PixelRect(x: 109, y: 209, w: 62, h: 22), margin: 30, w: 150, h: 1000)
        XCTAssertEqual(around.x % 4, 0)
        XCTAssertEqual(around.maxX, 150)
    }

    func testABoxKeepsWhatBelongsToTheSubjectAndNoPasserBy() {
        let w = 100, h = 60
        var current = Gray(w: w, h: h), answer = Gray(w: w, h: h)
        for y in 0 ..< h { for x in 0 ..< 30 { current.v[y * w + x] = 1 } }
        // The closer look: the subject a little wider, and a stranger at the far side.
        for y in 0 ..< h { for x in 0 ..< w where x < 34 || x > 80 { answer.v[y * w + x] = 1 } }
        let (kept, pieces, dropped) = Refine.keepTouching(answer, current: current)
        XCTAssertEqual(pieces, 1)
        XCTAssertEqual(dropped, 1)
        XCTAssertEqual(kept.at(32, 30), 1)
        XCTAssertEqual(kept.at(90, 30), 0)
        let border = Refine.touchesBorder(kept)
        XCTAssertTrue(border.left && border.top && border.bottom)
        XCTAssertFalse(border.right)
        XCTAssertEqual(Refine.firm(Gray(w: 1, h: 1, fill: 0.95)).v[0], 1)
        XCTAssertEqual(Refine.firm(Gray(w: 1, h: 1, fill: 0.3)).v[0], 0.5 + (((0.3 - 0.06) / 0.88) - 0.5) * 2, accuracy: 1e-4)
    }

    // MARK: Clean Edge

    /// A mask three pixels too wide round a dark disc on a light ground: one stroke round
    /// the edge puts it on the disc, and the result goes back through the engine and into
    /// the photo's mask only under the stroke.
    func testCleanEdgePutsAHardEdgeWhereTheColoursChange() {
        let scene = disc(light: SIMD3(0.55, 0.72, 0.5))
        let w = 200
        var wide = Gray(w: w, h: w)
        for y in 0 ..< w {
            for x in 0 ..< w {
                let dx = Float(x) + 0.5 - 100, dy = Float(y) + 0.5 - 100
                wide.v[y * w + x] = min(max(63 - (dx * dx + dy * dy).squareRoot() + 0.5, 0), 1)
            }
        }
        // Round the right-hand half of the disc.
        var points: [SIMD2<Float>] = []
        for k in 0 ... 20 { let t = -Float.pi / 2 + Float(k) / 20 * Float.pi; points.append(SIMD2(100 + 61 * cos(t), 100 + 61 * sin(t))) }
        let stroke = RefineStroke(points: points, radius: 9)
        let patch = PixelRect(x: 0, y: 0, w: w, h: w)
        let weight = Refine.weight(stroke: stroke, in: patch)
        let (cleaned, log) = Refine.cleanEdge(photo: scene.photo, alpha: wide, weight: weight, defocus: nil, subjectSharpness: nil)
        print("REFINE clean edge: \(log)")
        XCTAssertGreaterThan(cleaned.at(100 + 58, 100), 0.9, "inside the disc")
        XCTAssertLessThan(cleaned.at(100 + 62, 100), 0.1, "the three pixels of ground the mask had taken")
        XCTAssertEqual(cleaned.at(100 - 62, 100), wide.at(100 - 62, 100), "the other side was not painted")

        // Tighter pulls the edge in; half strength moves it half as far.
        var tight = CleanSettings()
        tight.tightness = 1
        let tighter = Refine.cleanEdge(photo: scene.photo, alpha: wide, weight: weight, defocus: nil, subjectSharpness: nil, settings: tight).alpha
        XCTAssertLessThanOrEqual(tighter.v.reduce(0, +), cleaned.v.reduce(0, +))
        var half = CleanSettings()
        half.strength = 0.5
        let halfway = Refine.cleanEdge(photo: scene.photo, alpha: wide, weight: weight, defocus: nil, subjectSharpness: nil, settings: half).alpha
        XCTAssertEqual(halfway.at(100 + 62, 100), 0.5 * (wide.at(100 + 62, 100) + cleaned.at(100 + 62, 100)), accuracy: 0.05)

        // Through the engine and back into the mask.
        let out = Matte(photo: scene.photo, coarse: cleaned, faces: [farFace], settings: Refine.patchSettings()).run(tier: .off)
        var alpha = wide.v.map { UInt8($0 * 255) }, shares = [UInt8](repeating: 255, count: w * w * 4)
        for i in 0 ..< w * w { shares[i * 4] = alpha[i]; shares[i * 4 + 1] = alpha[i]; shares[i * 4 + 2] = alpha[i] }
        let before = alpha
        let changed = Refine.paste(out, at: patch, weight: weight, alpha: &alpha, shares: &shares, width: w)
        XCTAssertGreaterThan(changed, 100)
        XCTAssertLessThan(alpha[100 * w + 162], 30)
        XCTAssertEqual(alpha[100 * w + 38], before[100 * w + 38], "untouched where the brush didn't go")
        XCTAssertEqual(out.guardCorrections, 0, "\(out.log)")
    }

    // MARK: Gaps

    func testABoxOpensAnEnclosedPocketOfBackground() {
        // A dark ring: its hole shows the green ground, but the mask has it filled.
        let w = 160
        var px = [UInt8](repeating: 255, count: w * w * 4)
        var filled = Gray(w: w, h: w)
        for y in 0 ..< w {
            for x in 0 ..< w {
                let dx = Float(x) + 0.5 - 80, dy = Float(y) + 0.5 - 80
                let r = (dx * dx + dy * dy).squareRoot()
                let ring = r < 60 && r > 14
                let v: SIMD3<Float> = ring ? SIMD3(0.12, 0.1, 0.1) : SIMD3(0.5, 0.7, 0.45)
                for ch in 0 ..< 3 { px[(y * w + x) * 4 + ch] = UInt8(v[ch] * 255) }
                filled.v[y * w + x] = r < 60 ? 1 : 0
            }
        }
        let photo = Photo(w: w, h: w, rowBytes: w * 4, px: px)
        let patch = PixelRect(x: 0, y: 0, w: w, h: w)
        let box = Refine.weight(box: PixelRect(x: 30, y: 30, w: 100, h: 100), in: patch, feather: 6)
        let (opened, count, log) = Refine.openGaps(photo: photo, alpha: filled, box: box)
        XCTAssertEqual(count, 1, "\(log)")
        XCTAssertLessThan(opened.at(80, 80), 0.05, "the hole is open")
        XCTAssertEqual(opened.at(80, 40), 1, "the ring is whole")

        // The same shape, but the hole is the subject's own colour: nothing to open.
        for y in 0 ..< w { for x in 0 ..< w where (x - 80) * (x - 80) + (y - 80) * (y - 80) < 14 * 14 { for ch in 0 ..< 3 { px[(y * w + x) * 4 + ch] = [30, 25, 25][ch] } } }
        let solid = Photo(w: w, h: w, rowBytes: w * 4, px: px)
        XCTAssertEqual(Refine.openGaps(photo: solid, alpha: filled, box: box).opened, 0)
    }

    // MARK: Hair

    func testHairBrushChoosesItsMethodByTheBackdrop() {
        let plain = disc()
        let patch = PixelRect(x: 0, y: 0, w: 200, h: 200)
        let stroke = Refine.weight(stroke: RefineStroke(points: [SIMD2(160, 60), SIMD2(160, 140)], radius: 16), in: patch)
        let onPlain = Refine.hairMethod(photo: plain.photo, alpha: plain.truth, weight: stroke)
        XCTAssertTrue(onPlain.colour, onPlain.why)
        // The same disc in front of a busy wall.
        var px = [UInt8](repeating: 255, count: 200 * 200 * 4)
        for y in 0 ..< 200 {
            for x in 0 ..< 200 {
                let a = plain.truth.v[y * 200 + x]
                let wall: Float = (x / 3 + y / 5) % 2 == 0 ? 0.85 : 0.35
                let v = 0.1 * a + wall * (1 - a)
                for ch in 0 ..< 3 { px[(y * 200 + x) * 4 + ch] = UInt8(v * 255) }
            }
        }
        let onBusy = Refine.hairMethod(photo: Photo(w: 200, h: 200, rowBytes: 800, px: px), alpha: plain.truth, weight: stroke)
        XCTAssertFalse(onBusy.colour, onBusy.why)
        XCTAssertGreaterThan(onBusy.texture, onPlain.texture)
    }

    /// Under a hair stroke everything is uncertain and colour matting runs there, guards off;
    /// away from the stroke the mask is as it was.
    func testAHairStrokeIsTheHairZone() {
        let scene = Scene()
        let patch = PixelRect(x: 0, y: 0, w: scene.w, h: scene.h)
        // The current mask: the truth made hard (strands lost), as an automatic mask leaves it.
        var current = Gray(w: scene.w, h: scene.h)
        var soft = scene.truth
        PlaneMath.boxBlur(&soft, w: scene.w, h: scene.h, radius: 5)
        for i in 0 ..< soft.count { current.v[i] = soft[i] >= 0.5 ? 1 : 0 }
        // A stroke over the strands on the right-hand side only.
        var points: [SIMD2<Float>] = []
        for k in 0 ... 16 { let t = -1.2 + Float(k) / 16 * 2.4; points.append(SIMD2(160 + 95 * cos(t), 160 + 95 * sin(t))) }
        let weight = Refine.weight(stroke: RefineStroke(points: points, radius: 34), in: patch)
        var settings = Refine.patchSettings()
        settings.relaxGuards = true
        let far = PixelRect(x: 2, y: 2, w: 8, h: 8)
        let brushed = Matte(photo: scene.photo, coarse: current, faces: [far], settings: settings, forced: weight).run(tier: .high)
        let plain = Matte(photo: scene.photo, coarse: current, faces: [far], settings: Refine.patchSettings()).run(tier: .off)
        var errorBefore: Float = 0, errorAfter: Float = 0, n: Float = 0, elsewhere = 0
        for y in 0 ..< scene.h {
            for x in 0 ..< scene.w {
                let i = y * scene.w + x
                if weight.v[i] > 0.9 {
                    errorBefore += abs(Float(plain.alpha[i]) / 255 - scene.truth[i])
                    errorAfter += abs(Float(brushed.alpha[i]) / 255 - scene.truth[i])
                    n += 1
                } else if weight.v[i] == 0 && brushed.zones[(y / 4) * brushed.trimapW + x / 4] == 2 {
                    elsewhere += 1
                }
            }
        }
        print("REFINE hair stroke: error under the stroke \(errorBefore / n) → \(errorAfter / n)")
        XCTAssertLessThan(errorAfter, errorBefore * 0.7, "strands come back under the stroke")
        XCTAssertTrue(brushed.zones.contains(2))
        XCTAssertLessThan(elsewhere, 600, "colour matting stays under the stroke (but for the quarter-size pixels at its rim)")
    }
}
