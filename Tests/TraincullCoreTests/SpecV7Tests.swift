import XCTest
@testable import TraincullCore

/// Masking spec v7: edge colour from inside (section 2) and the Remove Colour box (3), on
/// pictures made from the owner's measured pixel values (7451's debug bundle, alpha 17),
/// and the rollback to alpha 16 (1).
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
    struct Edge {
        let w = 80, h = 30, x0 = 40
        var photo: Photo
        var alpha: [UInt8]
        var shares: [UInt8]
        let columns: [(colour: SIMD3<Float>, alpha: Float)]

        init(subject: SIMD3<Float>, edge: [(SIMD3<Float>, Float)], ground: SIMD3<Float>) {
            columns = edge
            var px = [UInt8](repeating: 255, count: w * h * 4)
            alpha = [UInt8](repeating: 0, count: w * h)
            for y in 0 ..< h {
                for x in 0 ..< w {
                    let i = y * w + x
                    var c = ground, a: Float = 0
                    if x < x0 { c = subject; a = 1 } else if x - x0 < edge.count { c = edge[x - x0].0; a = edge[x - x0].1 }
                    for ch in 0 ..< 3 { px[i * 4 + ch] = UInt8(c[ch]) }
                    alpha[i] = UInt8((a * 255).rounded())
                }
            }
            photo = Photo(w: w, h: h, rowBytes: w * 4, px: px)
            shares = [UInt8](repeating: 255, count: w * h * 4)
            let lin = Matte.toLinear.p, d = MatteSettings()
            for i in 0 ..< w * h {
                let a = Float(alpha[i]) / 255
                var sh = SIMD3<Float>(repeating: a)
                if a > 0.05 && a < 0.95 {
                    let x = i % w
                    let I = SIMD3<Float>(Float(px[i * 4]), Float(px[i * 4 + 1]), Float(px[i * 4 + 2])) / 255
                    _ = x
                    sh = Matte.shares(pixel: I, subject: subject / 255, background: ground / 255, alpha: a, lin: lin, low: d.colourLow, high: d.colourHigh,
                                      floor0: d.colourFloor, floor1: d.colourFull, falloff: d.costFalloff, plain: d.colourPlain).shares
                }
                for ch in 0 ..< 3 { shares[i * 4 + ch] = UInt8((min(max(sh[ch], 0), 1) * 255).rounded()) }
            }
        }

        mutating func run(_ s: InsideColourSettings = InsideColourSettings()) -> InsideColourStats {
            let a = alpha
            return a.withUnsafeBufferPointer { ap in
                shares.withUnsafeMutableBufferPointer { sp in
                    InsideColour.apply(photo: photo, alpha: ap.baseAddress!, shares: sp.baseAddress!, rect: PixelRect(x: 0, y: 0, w: w, h: h), settings: s)
                }
            }
        }

        /// The subject's part over alpha (P/α, linear) at an edge column, in Oklab, on the middle row.
        func portion(_ column: Int) -> SIMD3<Float> {
            let x = x0 + column, y = h / 2, i = y * w + x
            let I = InsideColour.linear(photo, x, y)
            let s = SIMD3(Float(shares[i * 4]), Float(shares[i * 4 + 1]), Float(shares[i * 4 + 2])) / 255
            return Oklab.from(linear: I * s / max(Float(alpha[i]) / 255, 1e-6))
        }

        func lab(_ c: SIMD3<Float>) -> SIMD3<Float> {
            let lin = Matte.toLinear.p
            return Oklab.from(linear: SIMD3(lin[Int(c.x)], lin[Int(c.y)], lin[Int(c.z)]))
        }

        /// No share vector with a channel at 0 beside one over 0.1, unless the photo has no light in that channel.
        func loneZeros() -> Int {
            var bad = 0
            for i in 0 ..< w * h {
                let s = [shares[i * 4], shares[i * 4 + 1], shares[i * 4 + 2]]
                guard let hi = s.max(), hi > 25 else { continue }
                for ch in 0 ..< 3 where s[ch] == 0 && photo.p[i * 4 + ch] != 0 { bad += 1 }
            }
            return bad
        }
    }

    // MARK: (a)–(c) the owner's measured edges

    /// (a) 7451's black sleeve: the teal edge's subject part comes out as neutral as the sleeve.
    func testBlackSleeveLosesItsTeal() {
        var e = Edge(subject: SIMD3(29, 26, 25), edge: [(SIMD3(26, 31, 29), 1), (SIMD3(18, 33, 30), 1), (SIMD3(0, 32, 28), 1), (SIMD3(0, 39, 33), 1),
                                                         (SIMD3(19, 44, 36), 0.84), (SIMD3(41, 51, 46), 0.49)], ground: SIMD3(247, 247, 247))
        let beforeChroma = (0 ..< 6).map { Oklab.chroma(e.portion($0)) }
        let stats = e.run()
        let after = (0 ..< 6).map { Oklab.chroma(e.portion($0)) }
        print("V7 (a) sleeve: chroma of P/α per edge pixel \(beforeChroma.map { String(format: "%.4f", $0) }) → \(after.map { String(format: "%.4f", $0) }) (sleeve \(String(format: "%.4f", Oklab.chroma(e.lab(SIMD3(29, 26, 25)))))) · \(stats.summary)")
        for c in after { XCTAssertLessThanOrEqual(c, 0.012) }
        XCTAssertGreaterThan(beforeChroma.max() ?? 0, 0.03, "it was teal")
        XCTAssertEqual(e.loneZeros(), 0)
    }

    /// (b) 7451's skin in the arm–waist gap: the olive edge's subject part comes out skin.
    func testSkinEdgeLosesItsOlive() {
        let skin = SIMD3<Float>(155, 113, 85)
        var e = Edge(subject: skin, edge: [(SIMD3(126, 96, 70), 1), (SIMD3(113, 107, 79), 1), (SIMD3(107, 107, 91), 0.56)], ground: SIMD3(247, 247, 247))
        _ = e.run()
        let target = e.lab(skin)
        let apart = (0 ..< 3).map { c -> Float in
            let p = e.portion(c)
            return (SIMD2(p.y, p.z) - SIMD2(target.y, target.z)).dist
        }
        print("V7 (b) skin: (a, b) of P/α from the skin's \(apart.map { String(format: "%.4f", $0) })")
        for d in apart { XCTAssertLessThanOrEqual(d, 0.015) }
        XCTAssertEqual(e.loneZeros(), 0)
    }

    /// (c) 7451's right waist, against warm light.
    func testWaistEdge() {
        let skin = SIMD3<Float>(127, 87, 63)
        var e = Edge(subject: skin, edge: [(SIMD3(122, 85, 54), 1), (SIMD3(117, 84, 47), 1), (SIMD3(124, 87, 45), 0.6)], ground: SIMD3(210, 150, 90))
        _ = e.run()
        let target = e.lab(skin)
        let apart = (0 ..< 3).map { c -> Float in
            let p = e.portion(c)
            return (SIMD2(p.y, p.z) - SIMD2(target.y, target.z)).dist
        }
        print("V7 (c) waist: (a, b) of P/α from the skin's \(apart.map { String(format: "%.4f", $0) })")
        for d in apart { XCTAssertLessThanOrEqual(d, 0.015) }
        XCTAssertEqual(e.loneZeros(), 0)
    }

    // MARK: (d) rim light

    func testRimLightIsKept() {
        let skin = SIMD3<Float>(180, 130, 100)
        // Warm orange, about 20% brighter than the skin.
        let rim = SIMD3<Float>(222, 150, 92)
        var e = Edge(subject: skin, edge: [(rim, 1), (rim, 1), (rim, 0.7)], ground: SIMD3(40, 40, 50))
        let start = e.shares
        let stats = e.run()
        print("V7 (d) rim: \(stats.summary) · rim lightness \(e.lab(rim).x) against skin \(e.lab(skin).x)")
        XCTAssertEqual(e.shares, start, "a 3-px rim light is left as it is")
        XCTAssertGreaterThan(stats.rim, 0)
        // A 20-px rim band: its outer pixels take their colour from the rim itself.
        var wide = Edge(subject: skin, edge: Array(repeating: (rim, Float(1)), count: 20) + [(rim, 0.7)], ground: SIMD3(40, 40, 50))
        _ = wide.run()
        let rimLab = wide.lab(rim)
        for c in 16 ..< 21 {
            let p = wide.portion(c)
            let d = (SIMD2(p.y, p.z) - SIMD2(rimLab.y, rimLab.z)).dist
            print("V7 (d) wide rim, column \(c): (a, b) from the rim's \(d)")
            XCTAssertLessThan(d, 0.01, "the outer pixels keep the rim's colour")
        }
    }

    // MARK: (e), (f) through the whole engine

    private let face = PixelRect(x: 120, y: 130, w: 80, h: 80) // its hair zone covers the whole disc's edge

    func testHairZoneUnchangedUnlessSkin() {
        let scene = EdgePlaceTests.Disc(subject: SIMD3(0.35, 0.22, 0.12), ground: SIMD3(0.80, 0.86, 0.80), lensBlur: 1)
        var on = MatteSettings()
        on.insideColour = true
        let off = Matte(photo: scene.photo, coarse: scene.coarse, faces: [face], firstPassPixel: 3.2).run(tier: .off)
        let with = Matte(photo: scene.photo, coarse: scene.coarse, faces: [face], settings: on, firstPassPixel: 3.2).run(tier: .off)
        print("V7 (e) hair zone: \(with.insideColourStats?.summary ?? "")")
        XCTAssertEqual(with.shares, off.shares, "in the hair zone nothing changes where the inside isn't skin")
        XCTAssertEqual(with.insideColourStats?.recoloured, 0)
        // The same subject, with a skin model that says its colour is skin: then it does.
        let skin = SkinModel(samples: Array(repeating: SIMD3<Float>(0.35, 0.22, 0.12), count: 40) + Array(repeating: SIMD3<Float>(0.37, 0.23, 0.13), count: 40))
        let asSkin = Matte(photo: scene.photo, coarse: scene.coarse, faces: [face], settings: on, firstPassPixel: 3.2, skin: skin).run(tier: .off)
        print("V7 (e) as skin: \(asSkin.insideColourStats?.summary ?? "")")
        XCTAssertGreaterThan(asSkin.insideColourStats?.recoloured ?? 0, 100)
    }

    /// (f) Alpha is never changed, so the edge is where alpha 16 put it, and the photo with no
    /// adjustments (which never uses the mask) is as it was.
    func testAlphaUntouched() {
        let scene = EdgePlaceTests.Disc(subject: SIMD3(0.10, 0.10, 0.10), ground: SIMD3(0.97, 0.97, 0.97), lensBlur: 1)
        var on = MatteSettings()
        on.insideColour = true
        let far = [PixelRect(x: 2, y: 2, w: 8, h: 8)]
        let off = Matte(photo: scene.photo, coarse: scene.coarse, faces: far, firstPassPixel: 3.2).run(tier: .off)
        let with = Matte(photo: scene.photo, coarse: scene.coarse, faces: far, settings: on, firstPassPixel: 3.2).run(tier: .off)
        print("V7 (f): \(with.insideColourStats?.summary ?? "")")
        XCTAssertEqual(with.alpha, off.alpha)
        XCTAssertGreaterThan(with.insideColourStats?.recoloured ?? 0, 100)
        XCTAssertTrue(with.log.contains { $0.hasPrefix("edge colour from inside:") })
        // (g) through the engine too.
        var bad = 0
        for i in 0 ..< with.w * with.h {
            let s = [with.shares[i * 4], with.shares[i * 4 + 1], with.shares[i * 4 + 2]]
            guard let hi = s.max(), hi > 25 else { continue }
            for ch in 0 ..< 3 where s[ch] == 0 && scene.photo.p[i * 4 + ch] != 0 { bad += 1 }
        }
        XCTAssertEqual(bad, 0)
    }

    // MARK: (h) Remove Colour

    func testRemoveColourTakesOutAnOrangeCrescent() {
        let size = 260, c: Float = 130, radius: Float = 70
        let pink = SIMD3<Float>(230, 150, 170), orange = SIMD3<Float>(230, 120, 40), green = SIMD3<Float>(60, 140, 60)
        var px = [UInt8](repeating: 255, count: size * size * 4)
        var alpha = [UInt8](repeating: 0, count: size * size)
        func crescent(_ dx: Float, _ dy: Float, _ r: Float) -> Bool { r >= radius && r < radius + 8 && dx > 20 }
        for y in 0 ..< size {
            for x in 0 ..< size {
                let dx = Float(x) + 0.5 - c, dy = Float(y) + 0.5 - c, r = (dx * dx + dy * dy).squareRoot()
                var col = green
                let disc = min(max(radius - r + 0.5, 0), 1)
                if disc > 0 { col = pink * disc + green * (1 - disc) }
                if crescent(dx, dy, r) { col = orange }
                if r < 12 { col = orange } // orange deep inside, 58 px in: never to be touched
                for ch in 0 ..< 3 { px[(y * size + x) * 4 + ch] = UInt8(col[ch].rounded()) }
                let a: Float = crescent(dx, dy, r) ? min(max(radius + 8 - r + 0.5, 0), 1) : disc
                alpha[y * size + x] = UInt8((a * 255).rounded())
            }
        }
        let photo = Photo(w: size, h: size, rowBytes: size * 4, px: px)
        var shares = [UInt8](repeating: 255, count: size * size * 4)
        for i in 0 ..< size * size { for ch in 0 ..< 3 { shares[i * 4 + ch] = alpha[i] } }
        let box = PixelRect(x: 20, y: 20, w: 220, h: 220)
        var settings = MatteSettings()
        settings.insideColour = true
        let result = Refine.removeColour(box: box, samples: [orange / 255], tolerance: 0.05, alpha: alpha, shares: shares,
                                         context: RefineContext(photo: photo, faces: [], settings: settings))
        var a = alpha, s = shares
        let changed = Refine.paste(result.output, at: result.patch, weight: result.weight, alpha: &a, shares: &s, width: size)
        print("V7 (h): \(changed) px changed · \(result.log.joined(separator: " · "))")
        // The crescent is gone.
        var left = 0
        var most: UInt8 = 0
        for y in 0 ..< size {
            for x in 0 ..< size {
                let dx = Float(x) + 0.5 - c, dy = Float(y) + 0.5 - c, r = (dx * dx + dy * dy).squareRoot()
                if crescent(dx, dy, r) && r > radius + 1.5 {
                    most = max(most, a[y * size + x])
                    if a[y * size + x] > 38 { left += 1 }
                }
            }
        }
        print("V7 (h): the most coverage left on the crescent \(most) of 255")
        XCTAssertEqual(left, 0, "the crescent is removed (under 15% left anywhere: the 1.5 px softening at its corners)")
        // The disc's edge moved less than a pixel, where the crescent was and where it wasn't.
        func crossing(_ dirX: Float, _ dirY: Float) -> Float {
            var r: Float = 40
            while r < 110 {
                let x = Int(c + dirX * r), y = Int(c + dirY * r)
                if a[y * size + x] < 128 { return r }
                r += 0.25
            }
            return r
        }
        let at = crossing(1, 0), elsewhere = crossing(-1, 0)
        print("V7 (h): disc edge at \(at) px where the crescent was, \(elsewhere) px elsewhere (radius \(radius))")
        XCTAssertLessThan(abs(at - radius), 1)
        XCTAssertLessThan(abs(elsewhere - radius), 1)
        // The orange deep inside is untouched.
        for y in 122 ..< 138 { for x in 122 ..< 138 { XCTAssertEqual(a[y * size + x], 255); XCTAssertEqual(s[(y * size + x) * 4], 255) } }
        XCTAssertTrue(result.log.contains { $0.hasPrefix("remove colour:") })
        // (g) no lone zero channel in what it wrote.
        var bad = 0
        for i in 0 ..< size * size {
            let v = [s[i * 4], s[i * 4 + 1], s[i * 4 + 2]]
            guard let hi = v.max(), hi > 25 else { continue }
            for ch in 0 ..< 3 where v[ch] == 0 && photo.p[i * 4 + ch] != 0 { bad += 1 }
        }
        XCTAssertEqual(bad, 0)
    }

    // MARK: (i) the rollback

    /// With edge colour from inside off (and no Remove Colour), the engine's output is alpha
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
