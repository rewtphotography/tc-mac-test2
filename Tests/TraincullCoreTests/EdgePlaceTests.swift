import XCTest
@testable import TraincullCore

/// The final masking round: where the mask's edge sits against the photo's, how wide it is,
/// the light just inside it, and the guard's lightness bound. All on pictures made here.
final class EdgePlaceTests: XCTestCase {
    static let lin: [Float] = (0 ..< 256).map { pow(Float($0) / 255, 2.2) }

    /// A disc on a plain ground, mixed in linear light as a lens would, optionally blurred
    /// (in linear light too). The first-pass mask is a disc `grown` pixels larger, as soft
    /// as a model's answer enlarged three or four times.
    struct Disc {
        let size: Int, radius: Float
        var photo: Photo
        var coarse: Gray
        let subject: SIMD3<Float>, ground: SIMD3<Float>

        init(size: Int = 320, subject: SIMD3<Float>, ground: SIMD3<Float>, lensBlur: Int = 0, grown: Float = 0, soft: Int = 4) {
            self.size = size; self.subject = subject; self.ground = ground
            radius = Float(size) * 0.28
            let c = Float(size) * 0.5, r = radius
            func cover(_ x: Int, _ y: Int, _ radius: Float) -> Float {
                let dx = Float(x) + 0.5 - c, dy = Float(y) + 0.5 - c
                return min(max(radius - (dx * dx + dy * dy).squareRoot() + 0.5, 0), 1)
            }
            func linear(_ v: SIMD3<Float>) -> SIMD3<Float> { SIMD3(pow(v.x, 2.2), pow(v.y, 2.2), pow(v.z, 2.2)) }
            let s = linear(subject), g = linear(ground)
            var planes = [[Float]](repeating: [Float](repeating: 0, count: size * size), count: 3)
            var mask = [Float](repeating: 0, count: size * size)
            for y in 0 ..< size {
                for x in 0 ..< size {
                    let a = cover(x, y, r)
                    let v = s * a + g * (1 - a)
                    for ch in 0 ..< 3 { planes[ch][y * size + x] = v[ch] }
                    mask[y * size + x] = cover(x, y, r + grown)
                }
            }
            if lensBlur > 0 {
                for ch in 0 ..< 3 {
                    PlaneMath.boxBlur(&planes[ch], w: size, h: size, radius: lensBlur)
                    PlaneMath.boxBlur(&planes[ch], w: size, h: size, radius: lensBlur)
                }
            }
            var px = [UInt8](repeating: 255, count: size * size * 4)
            for i in 0 ..< size * size {
                for ch in 0 ..< 3 { px[i * 4 + ch] = UInt8(min(max(pow(planes[ch][i], 1 / 2.2), 0), 1) * 255 + 0.5) }
            }
            photo = Photo(w: size, h: size, rowBytes: size * 4, px: px)
            PlaneMath.boxBlur(&mask, w: size, h: size, radius: soft)
            coarse = Gray(w: size, h: size, v: mask).resized(w: size / 2, h: size / 2)
        }

        /// The row through the middle: the pixel's brightness with the background three
        /// stops down, as the app's Background −3 EV shows it, and the mask there.
        func row(_ out: MatteOutput) -> [(alpha: Float, shown: Float, photo: Float)] {
            let y = size / 2
            return (0 ..< size).map { x in
                let i = y * size + x
                let c = photo.rgb(x, y)
                let I = SIMD3(EdgePlaceTests.lin[Int(c.x * 255)], EdgePlaceTests.lin[Int(c.y * 255)], EdgePlaceTests.lin[Int(c.z * 255)])
                let s = SIMD3(Float(out.shares[i * 4]), Float(out.shares[i * 4 + 1]), Float(out.shares[i * 4 + 2])) / 255
                let kept = s + (SIMD3<Float>(repeating: 1) - s) * 0.125
                return (Float(out.alpha[i]) / 255, luma(I * kept), luma(I))
            }
        }
    }

    let face = PixelRect(x: 2, y: 2, w: 8, h: 8) // far from the disc: its edge is not hair

    /// A first pass three pixels too large and several times too soft, on a sharp photo:
    /// the figure in the log says so, and the finished edge sits on the photo's and is
    /// about as narrow.
    func testAnEdgeTooFarOutAndTooWideIsPutOnThePhotos() {
        let scene = Disc(subject: SIMD3(0.45, 0.30, 0.25), ground: SIMD3(0.80, 0.86, 0.80), lensBlur: 1, grown: 3)
        let out = Matte(photo: scene.photo, coarse: scene.coarse, faces: [face], firstPassPixel: 3.2).run(tier: .off)
        let before = try! XCTUnwrap(out.edgeOffsetBefore.mean), after = try! XCTUnwrap(out.edgeOffset.mean)
        print("EDGE placed: first pass \(out.edgeOffsetBefore.summary) → \(out.edgeOffset.summary)")
        XCTAssertGreaterThan(before, 2, "positive: the first pass reaches beyond the true edge")
        XCTAssertLessThan(abs(after), 0.5)
        XCTAssertLessThan(try! XCTUnwrap(out.edgeOffset.far), 0.05)
        XCTAssertGreaterThan(try! XCTUnwrap(out.edgeOffsetBefore.maskWidth), 2 * (try! XCTUnwrap(out.edgeOffsetBefore.photoWidth)))
        XCTAssertLessThan(try! XCTUnwrap(out.edgeOffset.maskWidth), 1.6 * (try! XCTUnwrap(out.edgeOffset.photoWidth)))
        XCTAssertTrue(out.log.contains { $0.hasPrefix("edge placement") })

        // Without the step (alpha 14's edge) it stays out, and the figure shows that too.
        var old = MatteSettings()
        old.recentre = false
        let stayed = Matte(photo: scene.photo, coarse: scene.coarse, faces: [face], settings: old, firstPassPixel: 3.2).run(tier: .off)
        XCTAssertGreaterThan(try! XCTUnwrap(stayed.edgeOffset.mean), 0.8)

        // Too small is put right as well, and reads negative: inside the subject.
        let small = Disc(subject: SIMD3(0.45, 0.30, 0.25), ground: SIMD3(0.80, 0.86, 0.80), lensBlur: 1, grown: -3)
        let grownBack = Matte(photo: small.photo, coarse: small.coarse, faces: [face], firstPassPixel: 3.2).run(tier: .off)
        XCTAssertLessThan(try! XCTUnwrap(grownBack.edgeOffsetBefore.mean), -2)
        XCTAssertLessThan(abs(try! XCTUnwrap(grownBack.edgeOffset.mean)), 0.5)
    }

    /// Where the photo's own edge is soft (a hand a little out of focus), the mask's edge
    /// is left as wide as the photo's: not made hard.
    func testASoftPhotoEdgeKeepsASoftMaskEdge() {
        let scene = Disc(subject: SIMD3(0.45, 0.30, 0.25), ground: SIMD3(0.80, 0.86, 0.80), lensBlur: 3)
        let out = Matte(photo: scene.photo, coarse: scene.coarse, faces: [face], firstPassPixel: 3.2).run(tier: .off)
        let own = try! XCTUnwrap(out.edgeOffset.maskWidth), photos = try! XCTUnwrap(out.edgeOffset.photoWidth)
        print("EDGE soft: \(out.edgeOffset.summary)")
        XCTAssertGreaterThan(photos, 4)
        XCTAssertGreaterThan(own, 0.6 * photos)
        XCTAssertLessThan(own, 1.5 * photos)
    }

    /// A dark subject against a bright ground, through a lens: the pixels just inside the
    /// edge are all subject as far as the mask goes, and a fifth background light. With the
    /// background darkened they must not stand out as a pale line.
    func testNoPaleRimJustInsideADarkSubjectsEdge() {
        // (The subject is as bright as the ground will be three stops down, so that a
        // half-covered pixel shown rightly is no brighter than the subject either.)
        let scene = Disc(subject: SIMD3(0.50, 0.40, 0.35), ground: SIMD3(0.97, 0.94, 0.86), lensBlur: 2)
        func worst(_ out: MatteOutput) -> Float {
            let row = scene.row(out)
            let inside = row[scene.size / 2].shown
            var most: Float = 0
            // From the middle outwards to where the mask ends: nothing brighter than the subject.
            for x in scene.size / 2 ..< scene.size where row[x].alpha > 0.5 { most = max(most, row[x].shown / inside) }
            return most
        }
        let out = Matte(photo: scene.photo, coarse: scene.coarse, faces: [face], firstPassPixel: 3.2).run(tier: .off)
        var old = MatteSettings()
        old.recentre = false
        old.innerTail = false
        old.lightBound = false
        let before = Matte(photo: scene.photo, coarse: scene.coarse, faces: [face], settings: old, firstPassPixel: 3.2).run(tier: .off)
        print("EDGE tail: brightest pixel inside the mask, against the subject's own brightness: \(worst(before)) → \(worst(out)) · \(out.log.filter { $0.hasPrefix("decontaminated") }.joined())")
        XCTAssertGreaterThan(worst(before), 1.3, "the rim this is about")
        XCTAssertLessThan(worst(out), 1.12)
        XCTAssertTrue(out.log.contains { $0.contains("just inside the edge") })
        // And the middle of the subject is untouched.
        let centre = (scene.size / 2) * scene.size + scene.size / 2
        XCTAssertEqual(out.shares[centre * 4], 255)
    }

    /// Where the mask says "subject" and the colour says "background" (a mask a little too
    /// large, left as it is), the shares on their own would give the subject no light at
    /// all there: darker than the subject beside it, a dark seam. The guard's lightness
    /// bound brings it up to the subject's own brightness, and counts what it did.
    func testLightnessBoundStopsADarkSeam() {
        let scene = Disc(subject: SIMD3(0.55, 0.52, 0.50), ground: SIMD3(0.92, 0.92, 0.90), lensBlur: 1, grown: 2, soft: 1)
        var fixedEdge = MatteSettings()
        fixedEdge.recentre = false
        fixedEdge.colourSnap = false
        var unbounded = fixedEdge
        unbounded.guardLightness = 0
        func darkest(_ out: MatteOutput) -> Float {
            let row = scene.row(out)
            let inside = row[scene.size / 2].shown
            var least: Float = 10
            for x in scene.size / 2 ..< scene.size where row[x].alpha > 0.6 { least = min(least, row[x].shown / inside) }
            return least
        }
        let with = Matte(photo: scene.photo, coarse: scene.coarse, faces: [face], settings: fixedEdge).run(tier: .off)
        let without = Matte(photo: scene.photo, coarse: scene.coarse, faces: [face], settings: unbounded).run(tier: .off)
        print("EDGE lightness: darkest pixel inside the mask against the subject's brightness: \(darkest(without)) → \(darkest(with)) · \(with.log.filter { $0.hasPrefix("colour guard") }.joined())")
        XCTAssertLessThan(darkest(without), 0.8, "the seam this is about")
        XCTAssertGreaterThan(darkest(with), 0.9)
        XCTAssertGreaterThan(with.lightnessCorrections, 0)
        XCTAssertEqual(without.lightnessCorrections, 0)
        XCTAssertTrue(with.log.contains { $0.contains("lightness:") })
    }

    /// A bright subject on a dark ground whose pixel is a little off the subject's average
    /// colour (skin has texture): that difference is the subject's, not the background's.
    /// Booked to the background it was the whole of a dim background's light, strongly coloured.
    func testAPixelsOwnColourStaysWithWhoeverLightsIt() {
        let lin = Matte.toLinear.p
        let F = SIMD3<Float>(0.70, 0.60, 0.52), B = SIMD3<Float>(0.08, 0.08, 0.10)
        // 60% subject, then a touch warmer than the average subject colour.
        func display(_ v: SIMD3<Float>) -> SIMD3<Float> { SIMD3(pow(v.x, 1 / 2.2), pow(v.y, 1 / 2.2), pow(v.z, 1 / 2.2)) }
        func linear(_ v: SIMD3<Float>) -> SIMD3<Float> { SIMD3(pow(v.x, 2.2), pow(v.y, 2.2), pow(v.z, 2.2)) }
        let mixed = linear(F) * 0.6 + linear(B) * 0.4 + SIMD3<Float>(0.012, 0, -0.012)
        let I = display(mixed)
        let fit = Matte.shares(pixel: I, subject: F, background: B, alpha: 0.6, lin: lin, low: 0.08, high: 0.20, floor0: 0.10, floor1: 0.25, falloff: 50)
        let s = fit.shares
        XCTAssertLessThan(s.max() - s.min(), 0.05, "one share for all three channels, near enough: \(s)")
        // What is left for the background is dim and nearly its own colour, not a saturated remainder.
        let left = linear(I) * (SIMD3<Float>(repeating: 1) - s)
        XCTAssertLessThan(Oklab.chroma(Oklab.from(linear: left)), 0.06)
        XCTAssertEqual(fit.coverage, 0.6, accuracy: 0.05)

        // The other way round, a dark subject on a bright ground, the difference is the ground's.
        let darkF = SIMD3<Float>(0.15, 0.13, 0.12), brightB = SIMD3<Float>(0.85, 0.88, 0.84)
        let other = display(linear(darkF) * 0.5 + linear(brightB) * 0.5 + SIMD3<Float>(0.02, 0, -0.02))
        let dark = Matte.shares(pixel: other, subject: darkF, background: brightB, alpha: 0.5, lin: lin, low: 0.08, high: 0.20, floor0: 0.10, floor1: 0.25, falloff: 50).shares
        XCTAssertLessThan(dark.max(), 0.08, "nearly all of this pixel's light is the ground's")
    }

    /// Two colours both bright and far apart count as clearly different (skin against a
    /// pale wall); two dark ones a little apart do not.
    func testBrightColoursFarApartCanBeToldApart() {
        let skin = SIMD3<Float>(0.53, 0.52, 0.41), wall = SIMD3<Float>(0.73, 0.89, 0.80)
        XCTAssertGreaterThan(Matte.apart(skin, wall, low: 0.08, high: 0.20, floor0: 0.10, floor1: 0.25, plain: 0.45), 0.95)
        let boot = SIMD3<Float>(0.11, 0.11, 0.11), asphalt = SIMD3<Float>(0.17, 0.17, 0.18)
        XCTAssertLessThan(Matte.apart(boot, asphalt, low: 0.08, high: 0.20, floor0: 0.10, floor1: 0.25, plain: 0.45), 0.05)
    }

    /// The hair brush's contrast figure spans its range: it used to read 1.00 for anything visible.
    func testHairContrastFigureIsNotSaturated() {
        func figure(_ subject: SIMD3<Float>, _ ground: SIMD3<Float>) -> Float {
            let scene = Disc(size: 160, subject: subject, ground: ground)
            var alpha = Gray(w: 160, h: 160), weight = Gray(w: 160, h: 160, fill: 1)
            for y in 0 ..< 160 { for x in 0 ..< 160 { alpha.v[y * 160 + x] = hypot(Float(x) - 79.5, Float(y) - 79.5) < scene.radius ? 1 : 0 } }
            weight.v[0] = 1
            return Refine.hairMethod(photo: scene.photo, alpha: alpha, weight: weight).contrast
        }
        let blackOnWhite = figure(SIMD3(0.03, 0.03, 0.03), SIMD3(0.97, 0.97, 0.97))
        let brownOnBeige = figure(SIMD3(0.30, 0.20, 0.12), SIMD3(0.75, 0.68, 0.58))
        let darkOnDark = figure(SIMD3(0.14, 0.10, 0.08), SIMD3(0.20, 0.16, 0.14))
        print("EDGE hair contrast: black on white \(blackOnWhite), brown on beige \(brownOnBeige), dark brown on darker brown \(darkOnDark)")
        XCTAssertGreaterThan(blackOnWhite, 0.95)
        XCTAssertGreaterThan(brownOnBeige, 0.35)
        XCTAssertLessThan(brownOnBeige, 0.9)
        XCTAssertLessThan(darkOnDark, 0.25)
    }
}
