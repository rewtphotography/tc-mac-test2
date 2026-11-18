import XCTest
@testable import TraincullCore

/// Masking spec v7 and v7.1: edge colour from inside (the repaint), the Remove Colour box,
/// and the rollback to alpha 16, on pictures made from the owner's measured pixel values
/// (7451's debug bundle, alpha 17). The render is checked here through the blend's own
/// arithmetic (`render`); the Mac tests check the same through `Masking.apply`.
private extension SIMD2 where Scalar == Float {
    var dist: Float { (self * self).sum().squareRoot() }
}

final class SpecV7Tests: XCTestCase {
    static func fnv(_ bytes: [UInt8]) -> UInt64 {
        var h: UInt64 = 0xcbf29ce484222325
        for b in bytes { h = (h ^ UInt64(b)) &* 0x100000001b3 }
        return h
    }

    /// A straight vertical edge: `subject` on the left, then `edge` columns (inside to
    /// outside, each a colour in 0–255 and an alpha), then `ground`. Shares start as the
    /// engine's decontamination leaves them before this step (alpha 16's `Matte.shares`
    /// between the subject and the ground) on part-covered pixels, and 1 on covered ones.
    /// `paint` may change any pixel's colour afterwards (a rim, a speck).
    struct Edge {
        let w: Int, h: Int, x0 = 40
        var photo: Photo
        var alpha: [UInt8]
        var shares: [UInt8]
        var map: [UInt8]
        var stats = RepaintStats()

        init(subject: SIMD3<Float>, edge: [(SIMD3<Float>, Float)], ground: SIMD3<Float>, w: Int = 80, h: Int = 30,
             paint: ((Int, Int) -> SIMD3<Float>?)? = nil) {
            self.w = w; self.h = h
            var px = [UInt8](repeating: 255, count: w * h * 4)
            alpha = [UInt8](repeating: 0, count: w * h)
            for y in 0 ..< h {
                for x in 0 ..< w {
                    let i = y * w + x
                    var c = ground, a: Float = 0
                    if x < x0 { c = subject; a = 1 } else if x - x0 < edge.count { c = edge[x - x0].0; a = edge[x - x0].1 }
                    if let p = paint?(x, y) { c = p }
                    for ch in 0 ..< 3 { px[i * 4 + ch] = UInt8(c[ch]) }
                    alpha[i] = UInt8((a * 255).rounded())
                }
            }
            photo = Photo(w: w, h: h, rowBytes: w * 4, px: px)
            shares = [UInt8](repeating: 255, count: w * h * 4)
            map = Repaint.blank(count: w * h)
            let lin = Matte.toLinear.p, d = MatteSettings()
            for i in 0 ..< w * h {
                let a = Float(alpha[i]) / 255
                var sh = SIMD3<Float>(repeating: a)
                if a > 0.05 && a < 0.95 {
                    let I = SIMD3<Float>(Float(px[i * 4]), Float(px[i * 4 + 1]), Float(px[i * 4 + 2])) / 255
                    sh = Matte.shares(pixel: I, subject: subject / 255, background: ground / 255, alpha: a, lin: lin, low: d.colourLow, high: d.colourHigh,
                                      floor0: d.colourFloor, floor1: d.colourFull, falloff: d.costFalloff, plain: d.colourPlain).shares
                }
                for ch in 0 ..< 3 { shares[i * 4 + ch] = UInt8((min(max(sh[ch], 0), 1) * 255).rounded()) }
            }
        }

        mutating func run(_ s: InsideColourSettings = InsideColourSettings()) {
            let a = alpha, W = w, H = h
            stats = a.withUnsafeBufferPointer { ap in
                shares.withUnsafeMutableBufferPointer { sp in
                    map.withUnsafeMutableBufferPointer { mp in
                        Repaint.apply(photo: photo, alpha: ap.baseAddress!, shares: sp.baseAddress!, map: mp.baseAddress!, rect: PixelRect(x: 0, y: 0, w: W, h: H), settings: s)
                    }
                }
            }
        }

        func w(_ x: Int, _ y: Int) -> UInt8 { map[(y * w + x) * 4 + 2] }
        /// The clean colour C (linear) at a pixel.
        func clean(_ x: Int, _ y: Int) -> SIMD3<Float> { Repaint.clean(photo, map: map, x: x, y: y) }
        /// C at an edge column, in Oklab, on the middle row.
        func subjectSide(_ column: Int) -> SIMD3<Float> { Oklab.from(linear: clean(x0 + column, h / 2)) }

        /// The render as `Masking.apply` makes it with exposure only: the subject's gain on C,
        /// the background's on the photo, blended by the shares (linear light).
        func render(_ x: Int, _ y: Int, subject gS: Float, background gB: Float) -> SIMD3<Float> {
            let i = (y * w + x) * 4
            let s = SIMD3(Float(shares[i]), Float(shares[i + 1]), Float(shares[i + 2])) / 255
            return clean(x, y) * gS * s + InsideColour.linear(photo, x, y) * gB * (SIMD3<Float>(repeating: 1) - s)
        }

        func lab(_ c: SIMD3<Float>) -> SIMD3<Float> {
            let lin = Matte.toLinear.p
            return Oklab.from(linear: SIMD3(lin[Int(c.x)], lin[Int(c.y)], lin[Int(c.z)]))
        }
    }

    static let sleeveEdge: [(SIMD3<Float>, Float)] = [(SIMD3(26, 31, 29), 1), (SIMD3(18, 33, 30), 1), (SIMD3(0, 32, 28), 1), (SIMD3(0, 39, 33), 1),
                                                      (SIMD3(19, 44, 36), 0.84), (SIMD3(41, 51, 46), 0.49)]

    // MARK: (a)–(c) the owner's measured edges: the subject side takes the inside colour

    func testBlackSleeveLosesItsTeal() {
        var e = Edge(subject: SIMD3(29, 26, 25), edge: Self.sleeveEdge, ground: SIMD3(247, 247, 247))
        let before = (0 ..< 6).map { Oklab.chroma(e.subjectSide($0)) }
        e.run()
        let after = (0 ..< 6).map { Oklab.chroma(e.subjectSide($0)) }
        print("V7.1 (a) sleeve: chroma of the subject side per edge pixel \(before.map { String(format: "%.4f", $0) }) → \(after.map { String(format: "%.4f", $0) }) (sleeve \(String(format: "%.4f", Oklab.chroma(e.lab(SIMD3(29, 26, 25)))))) · \(e.stats.summary)")
        for c in after { XCTAssertLessThanOrEqual(c, 0.012) }
        XCTAssertGreaterThan(before.max() ?? 0, 0.03, "it was teal")
    }

    func testSkinEdgeLosesItsOlive() {
        let skin = SIMD3<Float>(155, 113, 85)
        var e = Edge(subject: skin, edge: [(SIMD3(126, 96, 70), 1), (SIMD3(113, 107, 79), 1), (SIMD3(107, 107, 91), 0.56)], ground: SIMD3(247, 247, 247))
        e.run()
        let t = e.lab(skin)
        let apart = (0 ..< 3).map { c -> Float in let p = e.subjectSide(c); return (SIMD2(p.y, p.z) - SIMD2(t.y, t.z)).dist }
        print("V7.1 (b) skin: (a, b) of the subject side from the skin's \(apart.map { String(format: "%.4f", $0) })")
        for d in apart { XCTAssertLessThanOrEqual(d, 0.015) }
    }

    func testWaistEdge() {
        let skin = SIMD3<Float>(127, 87, 63)
        var e = Edge(subject: skin, edge: [(SIMD3(122, 85, 54), 1), (SIMD3(117, 84, 47), 1), (SIMD3(124, 87, 45), 0.6)], ground: SIMD3(210, 150, 90))
        e.run()
        let t = e.lab(skin)
        let apart = (0 ..< 3).map { c -> Float in let p = e.subjectSide(c); return (SIMD2(p.y, p.z) - SIMD2(t.y, t.z)).dist }
        print("V7.1 (c) waist: (a, b) of the subject side from the skin's \(apart.map { String(format: "%.4f", $0) })")
        for d in apart { XCTAssertLessThanOrEqual(d, 0.015) }
    }

    // MARK: (d) rim light

    func testRimLightIsKept() {
        let skin = SIMD3<Float>(180, 130, 100), rim = SIMD3<Float>(222, 150, 92)
        var e = Edge(subject: skin, edge: [(rim, 1), (rim, 1), (rim, 0.7)], ground: SIMD3(40, 40, 50))
        let start = e.shares
        e.run()
        print("V7.1 (d) rim: \(e.stats.summary)")
        for y in 0 ..< e.h {
            for x in e.x0 ..< e.x0 + 3 {
                XCTAssertEqual(e.w(x, y), 0, "a 3-px rim along the whole edge keeps w = 0")
                for ch in 0 ..< 3 { XCTAssertEqual(e.shares[(y * e.w + x) * 4 + ch], start[(y * e.w + x) * 4 + ch]) }
            }
        }
        XCTAssertGreaterThan(e.stats.rimKept, 0)
        var wide = Edge(subject: skin, edge: Array(repeating: (rim, Float(1)), count: 20) + [(rim, 0.7)], ground: SIMD3(40, 40, 50))
        wide.run()
        let r = wide.lab(rim)
        for c in 16 ..< 21 {
            let p = wide.subjectSide(c)
            XCTAssertLessThan((SIMD2(p.y, p.z) - SIMD2(r.y, r.z)).dist, 0.01, "the outer pixels of a 20-px rim keep its colour")
        }
    }

    // MARK: (e), (e2) the hair zone, (f) alpha

    private let face = PixelRect(x: 120, y: 130, w: 80, h: 80) // its hair zone covers the whole disc's edge

    func testHairZoneUnchangedUnlessSkin() {
        let scene = EdgePlaceTests.Disc(subject: SIMD3(0.35, 0.22, 0.12), ground: SIMD3(0.80, 0.86, 0.80), lensBlur: 1)
        var on = MatteSettings()
        on.insideColour = true
        let off = Matte(photo: scene.photo, coarse: scene.coarse, faces: [face], firstPassPixel: 3.2).run(tier: .off)
        let with = Matte(photo: scene.photo, coarse: scene.coarse, faces: [face], settings: on, firstPassPixel: 3.2).run(tier: .off)
        print("V7.1 (e) hair zone: \(with.repaintStats?.summary ?? "")")
        XCTAssertEqual(with.shares, off.shares, "in the hair zone nothing changes where the inside isn't skin")
        XCTAssertEqual(with.repaintStats?.core, 0)
        XCTAssertEqual(with.repaint?.enumerated().filter { $0.offset % 4 == 2 && $0.element > 0 }.count, 0, "and w is 0 everywhere")
        let skin = SkinModel(samples: Array(repeating: SIMD3<Float>(0.35, 0.22, 0.12), count: 40) + Array(repeating: SIMD3<Float>(0.37, 0.23, 0.13), count: 40))
        let asSkin = Matte(photo: scene.photo, coarse: scene.coarse, faces: [face], settings: on, firstPassPixel: 3.2, skin: skin).run(tier: .off)
        print("V7.1 (e) as skin: \(asSkin.repaintStats?.summary ?? "")")
        XCTAssertGreaterThan(asSkin.repaintStats?.core ?? 0, 100)
    }

    /// (e2) An edge inside the hair zone whose inside is skin, with a green fringe (6303's
    /// fingers beside the face): repainted, the green gone, both an olive-strength green and
    /// a strong one; without a skin model left alone.
    func testSkinInTheHairZoneLosesItsGreen() {
        for green in [SIMD3<Float>(112, 124, 84), SIMD3<Float>(88, 118, 70)] {
            let size = 240, c: Float = 120, radius: Float = 60
            let skin = SIMD3<Float>(155, 113, 85), white = SIMD3<Float>(247, 247, 247)
            var px = [UInt8](repeating: 255, count: size * size * 4)
            var truth = Gray(w: size, h: size)
            func ring(_ r: Float) -> Bool { r > radius - 1.4 && r <= radius - 0.4 }
            for y in 0 ..< size {
                for x in 0 ..< size {
                    let dx = Float(x) + 0.5 - c, dy = Float(y) + 0.5 - c, r = (dx * dx + dy * dy).squareRoot()
                    let a = min(max(radius - r + 0.5, 0), 1)
                    truth.v[y * size + x] = a
                    let col = ring(r) ? green : skin * a + white * (1 - a)
                    for ch in 0 ..< 3 { px[(y * size + x) * 4 + ch] = UInt8(col[ch].rounded()) }
                }
            }
            PlaneMath.boxBlur(&truth.v, w: size, h: size, radius: 2)
            let photo = Photo(w: size, h: size, rowBytes: size * 4, px: px)
            let face = PixelRect(x: 95, y: 110, w: 50, h: 50)
            var on = MatteSettings()
            on.insideColour = true
            let model = SkinModel(samples: (0 ..< 60).map { i in skin / 255 + SIMD3<Float>(repeating: Float(i % 5 - 2) * 0.004) })
            let matte = Matte(photo: photo, coarse: truth, faces: [face], settings: on, skin: model)
            let out = matte.run(tier: .off)
            let noSkin = Matte(photo: photo, coarse: truth, faces: [face], settings: on).run(tier: .off)
            let target = Oklab.from(linear: SIMD3(Matte.toLinear.p[155], Matte.toLinear.p[113], Matte.toLinear.p[85]))
            var worst: Float = 0, inZone = 0, count = 0, repainted = 0, untouched = 0, feathered = 0
            let map = out.repaint ?? []
            for y in 0 ..< size {
                for x in 0 ..< size {
                    let dx = Float(x) + 0.5 - c, dy = Float(y) + 0.5 - c, r = (dx * dx + dy * dy).squareRoot()
                    let i = y * size + x
                    guard ring(r), out.alpha[i] >= 128 else { continue }
                    count += 1
                    if matte.sample1(matte.hairFaces.p, x, y) >= 0.5 { inZone += 1 }
                    if map[i * 4 + 2] == 255 { repainted += 1 }
                    let wNoSkin = noSkin.repaint?[i * 4 + 2] ?? 0
                    if wNoSkin < 255 { untouched += 1 }
                    if wNoSkin > 0 { feathered += 1 }
                    let p = Oklab.from(linear: Repaint.clean(photo, map: map, x: x, y: y))
                    worst = max(worst, (SIMD2(p.y, p.z) - SIMD2(target.y, target.z)).dist)
                }
            }
            print("V7.1 (e2) skin in the hair zone, green \(green): \(count) fringe pixels, \(inZone) in the zone, \(repainted) repainted (w = 1) · without a skin model: \(untouched) with no core of their own, \(feathered) of them reached by the feather of a core just outside the zone · worst (a, b) of the subject side from the skin's \(worst)")
            XCTAssertGreaterThan(count, 100)
            XCTAssertEqual(inZone, count)
            XCTAssertEqual(repainted, count)
            XCTAssertEqual(untouched, count)
            XCTAssertLessThanOrEqual(worst, 0.015)
        }
    }

    /// (f) Alpha is never changed. (The rendered Photo view is checked on the Mac.)
    func testAlphaUntouched() {
        let scene = EdgePlaceTests.Disc(subject: SIMD3(0.10, 0.10, 0.10), ground: SIMD3(0.97, 0.97, 0.97), lensBlur: 1)
        var on = MatteSettings()
        on.insideColour = true
        let far = [PixelRect(x: 2, y: 2, w: 8, h: 8)]
        let off = Matte(photo: scene.photo, coarse: scene.coarse, faces: far, firstPassPixel: 3.2).run(tier: .off)
        let with = Matte(photo: scene.photo, coarse: scene.coarse, faces: far, settings: on, firstPassPixel: 3.2).run(tier: .off)
        print("V7.1 (f): \(with.repaintStats?.summary ?? "")")
        XCTAssertEqual(with.alpha, off.alpha)
        XCTAssertGreaterThan(with.repaintStats?.core ?? 0, 100)
        XCTAssertTrue(with.log.contains { $0.hasPrefix("edge colour from inside:") })
        // Where w > 0 the shares are alpha, one value for all three.
        let map = with.repaint ?? []
        for i in 0 ..< with.w * with.h where map[i * 4 + 2] > 0 {
            XCTAssertEqual(with.shares[i * 4], with.alpha[i]); XCTAssertEqual(with.shares[i * 4 + 1], with.alpha[i]); XCTAssertEqual(with.shares[i * 4 + 2], with.alpha[i])
        }
    }

    // MARK: (j), (k) rendered

    func testBlackSleeveRendered() {
        var e = Edge(subject: SIMD3(29, 26, 25), edge: Self.sleeveEdge, ground: SIMD3(247, 247, 247))
        e.run()
        let y = e.h / 2, gS: Float = 8, gB: Float = 0.125
        // Every pixel the rule repaints has w = 1: here all six edge pixels.
        for c in 0 ..< 6 { XCTAssertEqual(e.w(e.x0 + c, y), 255, "edge pixel \(c) has w = 1") }
        let inside = Oklab.from(linear: e.render(e.x0 - 6, y, subject: gS, background: gB))
        var darkest: Float = 0
        for c in 0 ..< 6 where Float(e.alpha[y * e.w + e.x0 + c]) / 255 >= 0.9 {
            darkest = max(darkest, inside.x - Oklab.from(linear: e.render(e.x0 + c, y, subject: gS, background: gB)).x)
        }
        let chroma = (0 ..< 6).map { Oklab.chroma(e.subjectSide($0)) }.max() ?? 1
        let chromaLit = (0 ..< 6).map { Oklab.chroma(Oklab.from(linear: e.clean(e.x0 + $0, y) * gS)) }.max() ?? 1
        // The repainted band's limits along the row, and the steps across them.
        let ws = (0 ..< e.w).map { e.w($0, y) }
        let first = ws.firstIndex { $0 > 0 } ?? 0, last = ws.lastIndex { $0 > 0 } ?? 0
        var worstL: Float = 0, worstAB: Float = 0
        for (a, b) in [(first - 1, first), (first, first + 1), (last - 1, last), (last, last + 1)] {
            let p = Oklab.from(linear: e.render(a, y, subject: gS, background: gB)), q = Oklab.from(linear: e.render(b, y, subject: gS, background: gB))
            worstL = max(worstL, abs(p.x - q.x)); worstAB = max(worstAB, (SIMD2(p.y, p.z) - SIMD2(q.y, q.z)).dist)
        }
        // Subject 0, Background −3.
        var plainChroma: Float = 0
        for c in 0 ..< 6 where Float(e.alpha[y * e.w + e.x0 + c]) / 255 >= 0.9 {
            plainChroma = max(plainChroma, Oklab.chroma(Oklab.from(linear: e.render(e.x0 + c, y, subject: 1, background: gB))))
        }
        print("V7.1 (j) sleeve, Subject +3 Background −3: darkest edge pixel at α ≥ 0.9 against the sleeve 6 px in \(darkest) (L) · subject side chroma \(chroma) (after +3: \(chromaLit)) · band columns \(first - e.x0)…\(last - e.x0), steps across its limits L \(worstL), (a, b) \(worstAB) · Subject 0: chroma at α ≥ 0.9 \(plainChroma)")
        XCTAssertLessThanOrEqual(darkest, 0.03)
        XCTAssertLessThanOrEqual(chroma, 0.012)
        XCTAssertLessThanOrEqual(worstL, 0.03)
        XCTAssertLessThanOrEqual(worstAB, 0.015)
        XCTAssertLessThanOrEqual(plainChroma, 0.012)
    }

    func testStrongGreenOnSkinRendered() {
        let skin = SIMD3<Float>(155, 113, 85)
        var e = Edge(subject: skin, edge: [(SIMD3(88, 118, 70), 1), (skin, 0.5)], ground: SIMD3(247, 247, 247))
        e.run()
        let y = e.h / 2, gS = Float(pow(2.0, 1.5))
        let fringe = Oklab.from(linear: e.render(e.x0, y, subject: gS, background: 1)), lit = Oklab.from(linear: e.render(e.x0 - 8, y, subject: gS, background: 1))
        let dL = abs(fringe.x - lit.x), dAB = (SIMD2(fringe.y, fringe.z) - SIMD2(lit.y, lit.z)).dist
        print("V7.1 (k) strong green on skin, Subject +1.5: fringe against the brightened skin L \(dL), (a, b) \(dAB)")
        XCTAssertLessThanOrEqual(dL, 0.03)
        XCTAssertLessThanOrEqual(dAB, 0.015)
    }

    // MARK: (l) specks against rims

    func testSpeckRepaintedRimKept() {
        let skin = SIMD3<Float>(180, 130, 100), rim = SIMD3<Float>(222, 150, 92), green = SIMD3<Float>(120, 230, 120)
        var e = Edge(subject: skin, edge: [(skin, 1), (skin, 1), (skin, 1), (skin, 0.5)], ground: SIMD3(40, 40, 50), h: 330) { x, y in
            if (10 ..< 310).contains(y) && (40 ..< 43).contains(x) { return rim }     // a 3-px rim, 300 px along the edge
            if (316 ..< 319).contains(y) && (40 ..< 43).contains(x) { return green }  // a 3×3 speck at the edge
            return nil
        }
        e.run()
        var speck = 0, rimKept = 0, rimTouched = 0
        for y in 316 ..< 319 { for x in 40 ..< 43 where e.w(x, y) == 255 { speck += 1 } }
        for y in 10 ..< 310 { for x in 40 ..< 43 { if e.w(x, y) == 0 { rimKept += 1 } else { rimTouched += 1 } } }
        let s = e.lab(skin), p = Oklab.from(linear: e.clean(41, 317))
        print("V7.1 (l): speck pixels with w = 1: \(speck) of 9 (its subject side (a, b) from the skin's \((SIMD2(p.y, p.z) - SIMD2(s.y, s.z)).dist)) · rim pixels with w = 0: \(rimKept) of 900 · \(e.stats.summary)")
        XCTAssertEqual(speck, 9)
        XCTAssertLessThan((SIMD2(p.y, p.z) - SIMD2(s.y, s.z)).dist, 0.01)
        XCTAssertEqual(rimKept, 900)
        XCTAssertEqual(rimTouched, 0)
        XCTAssertGreaterThanOrEqual(e.stats.specks, 1)
    }

    // MARK: (h), (m), (n) Remove Colour

    private func removeColour(_ px: [UInt8], _ alpha: [UInt8], w: Int, h: Int, box: PixelRect, samples: [SIMD3<Float>], tolerance: Float = 0.05)
        -> (alpha: [UInt8], shares: [UInt8], result: RefineResult) {
        let photo = Photo(w: w, h: h, rowBytes: w * 4, px: px)
        var shares = [UInt8](repeating: 255, count: w * h * 4)
        for i in 0 ..< w * h { for ch in 0 ..< 3 { shares[i * 4 + ch] = alpha[i] } }
        var settings = MatteSettings()
        settings.insideColour = true
        let result = Refine.removeColour(box: box, samples: samples, tolerance: tolerance, alpha: alpha, shares: shares, repaint: Repaint.blank(count: w * h),
                                         context: RefineContext(photo: photo, faces: [], settings: settings))
        var a = alpha, s = shares
        Refine.paste(result.output, at: result.patch, weight: result.weight, alpha: &a, shares: &s, width: w)
        return (a, s, result)
    }

    func testRemoveColourTakesOutAnOrangeCrescent() {
        let size = 260, c: Float = 130, radius: Float = 70
        let pink = SIMD3<Float>(230, 150, 170), orange = SIMD3<Float>(230, 120, 40), green = SIMD3<Float>(60, 140, 60)
        var px = [UInt8](repeating: 255, count: size * size * 4)
        var alpha = [UInt8](repeating: 0, count: size * size)
        func crescent(_ dx: Float, _ r: Float) -> Bool { r >= radius && r < radius + 8 && dx > 20 }
        for y in 0 ..< size {
            for x in 0 ..< size {
                let dx = Float(x) + 0.5 - c, dy = Float(y) + 0.5 - c, r = (dx * dx + dy * dy).squareRoot()
                let disc = min(max(radius - r + 0.5, 0), 1)
                var col = disc > 0 ? pink * disc + green * (1 - disc) : green
                if crescent(dx, r) { col = orange }
                if r < 12 { col = orange }
                for ch in 0 ..< 3 { px[(y * size + x) * 4 + ch] = UInt8(col[ch].rounded()) }
                let a: Float = crescent(dx, r) ? min(max(radius + 8 - r + 0.5, 0), 1) : disc
                alpha[y * size + x] = UInt8((a * 255).rounded())
            }
        }
        // A box that keeps clear of the orange in the middle (since v7.1 a match is taken out
        // anywhere in the box); the crescent starts 4 px inside its 6 px soft border.
        let (a, _, result) = removeColour(px, alpha, w: size, h: size, box: PixelRect(x: 146, y: 20, w: 94, h: 220), samples: [orange / 255])
        print("V7.1 (h): \(result.log.joined(separator: " · "))")
        var most: UInt8 = 0
        for y in 0 ..< size {
            for x in 152 ..< 234 {
                let dx = Float(x) + 0.5 - c, dy = Float(y) + 0.5 - c, r = (dx * dx + dy * dy).squareRoot()
                if crescent(dx, r) && r > radius + 1.5 && y >= 26 && y < 234 { most = max(most, a[y * size + x]) }
            }
        }
        var edge: Float = 40
        while edge < 110 && a[130 * size + Int(c + edge)] >= 128 { edge += 1 }
        print("V7.1 (h): the most coverage left on the crescent \(most) of 255 · the disc's edge at \(edge) px (radius \(radius))")
        XCTAssertLessThanOrEqual(most, 13)
        XCTAssertLessThan(abs(edge - radius), 1.5)
        for y in 122 ..< 138 { for x in 122 ..< 138 { XCTAssertEqual(a[y * size + x], 255, "the orange in the middle, outside the box, is untouched") } }
    }

    /// (m) An orange patch enclosed deep inside a pink disc, and orange specks at its edge.
    func testRemoveColourReachesAnEnclosedPatch() {
        let size = 300, c: Float = 150, radius: Float = 110
        let pink = SIMD3<Float>(230, 150, 170), orange = SIMD3<Float>(230, 120, 40), green = SIMD3<Float>(60, 140, 60)
        var px = [UInt8](repeating: 255, count: size * size * 4)
        var alpha = [UInt8](repeating: 0, count: size * size)
        var isOrange = [Bool](repeating: false, count: size * size)
        let patch = PixelRect(x: 130, y: 140, w: 40, h: 20)
        let specks = [(c + 0.0, c - radius + 1), (c + radius - 2, c + 0.0), (c - radius + 1, c + 10)]
        for y in 0 ..< size {
            for x in 0 ..< size {
                let dx = Float(x) + 0.5 - c, dy = Float(y) + 0.5 - c, r = (dx * dx + dy * dy).squareRoot()
                let disc = min(max(radius - r + 0.5, 0), 1)
                var col = disc > 0 ? pink * disc + green * (1 - disc) : green
                var a = disc
                if patch.contains(x, y) { col = orange; isOrange[y * size + x] = true }
                for (sx, sy) in specks where abs(Float(x) + 0.5 - sx) <= 1.5 && abs(Float(y) + 0.5 - sy) <= 1.5 {
                    col = orange; a = 1; isOrange[y * size + x] = true
                }
                for ch in 0 ..< 3 { px[(y * size + x) * 4 + ch] = UInt8(col[ch].rounded()) }
                alpha[y * size + x] = UInt8((a * 255).rounded())
            }
        }
        let (a, _, result) = removeColour(px, alpha, w: size, h: size, box: PixelRect(x: 20, y: 20, w: 260, h: 260), samples: [orange / 255])
        print("V7.1 (m): \(result.log.joined(separator: " · "))")
        var worstOrange: UInt8 = 0, worstPink = 0, worstOutline = 0
        let near = PlaneMath.distance(to: isOrange, w: size, h: size)
        for i in 0 ..< size * size {
            if isOrange[i] { worstOrange = max(worstOrange, a[i]) } else if near[i] > 2 {
                let d = abs(Int(a[i]) - Int(alpha[i]))
                if alpha[i] == 255 { worstPink = max(worstPink, d) } else if alpha[i] > 0 { worstOutline = max(worstOutline, d) }
            }
        }
        print("V7.1 (m): the most coverage left on the patch and specks \(worstOrange) of 255; the most the pink changed more than 2 px from them \(worstPink) of 255;"
            + " the disc's anti-aliased outline (pink against green, within 2× tolerance of the pink–orange line) \(worstOutline) of 255")
        XCTAssertLessThanOrEqual(worstOrange, 13)
        XCTAssertLessThanOrEqual(worstPink, 5)
    }

    /// (n) A smooth colour gradient across the tolerance's limit: no hard steps.
    func testSoftTolerance() {
        let w = 220, h = 100
        let pink = SIMD3<Float>(230, 150, 170), orange = SIMD3<Float>(230, 120, 40), green = SIMD3<Float>(60, 140, 60)
        var px = [UInt8](repeating: 255, count: w * h * 4)
        var alpha = [UInt8](repeating: 0, count: w * h)
        for y in 0 ..< h {
            for x in 0 ..< w {
                var col = x < 160 ? pink : green
                if x >= 110 && x < 160 { col = pink + (orange - pink) * (Float(x - 110) / 49) }
                for ch in 0 ..< 3 { px[(y * w + x) * 4 + ch] = UInt8(col[ch].rounded()) }
                alpha[y * w + x] = x < 160 ? 255 : 0
            }
        }
        let (a, _, result) = removeColour(px, alpha, w: w, h: h, box: PixelRect(x: 60, y: 10, w: 140, h: 80), samples: [orange / 255])
        var worst = 0
        for y in 20 ..< 80 { for x in 70 ..< 160 { worst = max(worst, abs(Int(a[y * w + x + 1]) - Int(a[y * w + x]))) } }
        let row = (100 ..< 160).map { a[50 * w + $0] }
        print("V7.1 (n): largest step in alpha between neighbours \(worst) of 255 · row \(row) · \(result.log.first ?? "")")
        XCTAssertLessThanOrEqual(worst, 64)
        XCTAssertLessThanOrEqual(a[50 * w + 158], 13, "the orange end goes")
    }

    // MARK: (i) the rollback

    /// With edge colour from inside off (and no Remove Colour box), the engine's output is alpha
    /// 16's byte for byte: these figures were taken from the alpha 16 code (5c95b58) itself.
    func testOutputIsAlpha16sWithTheSwitchOff() {
        let scene = Scene()
        let off = Matte(photo: scene.photo, coarse: scene.coarse, faces: [scene.face]).run(tier: .off)
        XCTAssertEqual(Self.fnv(off.alpha), 17361057852014025889)
        XCTAssertEqual(Self.fnv(off.shares), 8324624077253939645)
        let high = Matte(photo: scene.photo, coarse: scene.coarse, faces: [scene.face]).run(tier: .high)
        XCTAssertEqual(Self.fnv(high.alpha), 3568119819957277446)
        XCTAssertEqual(Self.fnv(high.shares), 15404150910528196745)
        let disc = EdgePlaceTests.Disc(subject: SIMD3(0.45, 0.30, 0.25), ground: SIMD3(0.80, 0.86, 0.80), lensBlur: 1, grown: 3)
        let out = Matte(photo: disc.photo, coarse: disc.coarse, faces: [PixelRect(x: 2, y: 2, w: 8, h: 8)], firstPassPixel: 3.2).run(tier: .off)
        XCTAssertEqual(Self.fnv(out.alpha), 422314052229303569)
        XCTAssertEqual(Self.fnv(out.shares), 9421304776317381508)
        let noFace = Matte(photo: disc.photo, coarse: disc.coarse, faces: [], firstPassPixel: 3.2).run(tier: .off)
        XCTAssertEqual(Self.fnv(noFace.alpha), 12233134567273211589)
        XCTAssertEqual(Self.fnv(noFace.shares), 8023036531796025653)
        // The Refine Edges box, as alpha 16 had it.
        let box = PixelRect(x: 180, y: 120, w: 90, h: 80)
        let look = Refine.lookArea(box: box, w: disc.size, h: disc.size)
        var answer = Gray(w: look.w, h: look.h)
        for y in 0 ..< look.h {
            for x in 0 ..< look.w {
                let dx = Float(look.x + x) + 0.5 - 160, dy = Float(look.y + y) + 0.5 - 160
                answer.v[y * look.w + x] = (dx * dx + dy * dy).squareRoot() < disc.radius ? 1 : 0
            }
        }
        let made = Refine.edges(box: box, look: look, answer: answer, alpha: out.alpha, context: RefineContext(photo: disc.photo, faces: []))
        XCTAssertEqual(made.patch, PixelRect(x: 68, y: 12, w: 252, h: 296))
        XCTAssertEqual(Self.fnv(made.output.alpha), 402402047746240346)
        XCTAssertEqual(Self.fnv(made.output.shares), 7861841310982123841)
    }
}
