import XCTest
@testable import TraincullCore

/// Masking spec v7.2: the background colour B̂, the cut of background-coloured edge pixels,
/// the background side's repaint, Remove Colour's automatic guess and eyedropper, Refine
/// Hair's strength. Pictures made in code; numbers printed for the build notes ("V7.2").
final class SpecV72Tests: XCTestCase {
    /// A scene: a photo, its mask, and the edge colour step run over all of it.
    struct Scene {
        let w: Int, h: Int
        var photo: Photo
        var alpha: [UInt8]
        var shares: [UInt8]
        var map: [UInt8]
        var back: [UInt8]
        var stats = EdgeColour.Stats()

        /// `paint` gives each pixel's colour (0–255) and alpha.
        init(w: Int, h: Int, paint: (Int, Int) -> (SIMD3<Float>, Float)) {
            self.w = w; self.h = h
            var px = [UInt8](repeating: 255, count: w * h * 4)
            alpha = [UInt8](repeating: 0, count: w * h)
            for y in 0 ..< h {
                for x in 0 ..< w {
                    let (c, a) = paint(x, y)
                    for ch in 0 ..< 3 { px[(y * w + x) * 4 + ch] = UInt8(min(max(c[ch], 0), 255).rounded()) }
                    alpha[y * w + x] = UInt8((min(max(a, 0), 1) * 255).rounded())
                }
            }
            photo = Photo(w: w, h: h, rowBytes: w * 4, px: px)
            shares = [UInt8](repeating: 255, count: w * h * 4)
            for i in 0 ..< w * h { for ch in 0 ..< 3 { shares[i * 4 + ch] = alpha[i] } }
            map = Repaint.blank(count: w * h)
            back = Repaint.blank(count: w * h)
        }

        mutating func run(_ s: InsideColourSettings = InsideColourSettings(), skip: @escaping (Int, Int, SIMD3<Float>) -> Bool = { _, _, _ in false }) {
            let W = w, H = h, photo = self.photo
            stats = alpha.withUnsafeMutableBufferPointer { ap in
                shares.withUnsafeMutableBufferPointer { sp in
                    map.withUnsafeMutableBufferPointer { mp in
                        back.withUnsafeMutableBufferPointer { bp in
                            EdgeColour.run(photo: photo, alpha: ap.baseAddress!, shares: sp.baseAddress!, map: mp.baseAddress!, back: bp.baseAddress!,
                                           rect: PixelRect(x: 0, y: 0, w: W, h: H), settings: s, skip: skip)
                        }
                    }
                }
            }
        }

        func a(_ x: Int, _ y: Int) -> Float { Float(alpha[y * w + x]) / 255 }
        func wS(_ x: Int, _ y: Int) -> UInt8 { map[(y * w + x) * 4 + 2] }
        func wB(_ x: Int, _ y: Int) -> UInt8 { back[(y * w + x) * 4 + 2] }
        func lab(_ c: SIMD3<Float>) -> SIMD3<Float> {
            let lin = Matte.toLinear.p
            return Oklab.from(linear: SIMD3(lin[Int(c.x)], lin[Int(c.y)], lin[Int(c.z)]))
        }
    }

    /// Two colours (0–255) mixed as a lens mixes them, in linear light (the engine's 2.2 curve).
    static func mix(_ a: SIMD3<Float>, _ b: SIMD3<Float>, _ t: Float) -> SIMD3<Float> {
        func lin(_ c: SIMD3<Float>) -> SIMD3<Float> { SIMD3(pow(c.x / 255, 2.2), pow(c.y / 255, 2.2), pow(c.z / 255, 2.2)) }
        let m = lin(a) * t + lin(b) * (1 - t)
        return SIMD3(pow(m.x, 1 / 2.2), pow(m.y, 1 / 2.2), pow(m.z, 1 / 2.2)) * 255
    }

    /// A smooth vertical edge at x0: subject left, ground right, alpha falling over one pixel.
    static func edge(_ x: Int, x0: Int) -> Float { min(max(Float(x0 - x) + 0.5, 0), 1) }

    static let skin = SIMD3<Float>(180, 130, 100), bokeh = SIMD3<Float>(70, 140, 60)

    // MARK: (p) a green streak on a finger edge goes

    func testGreenStreakIsCut() {
        let x0 = 60
        let paleGreen = SIMD3<Float>(150, 205, 140) // lighter than the skin
        var s = Scene(w: 120, h: 100) { x, y in
            let a = Self.edge(x, x0: x0)
            if (20 ..< 80).contains(y) && (x0 - 3 ..< x0).contains(x) { return (paleGreen, 1) }
            return (a >= 1 ? Self.skin : (a <= 0 ? Self.bokeh : Self.mix(Self.skin, Self.bokeh, a)), a)
        }
        let before = s.alpha
        s.run()
        var worst: Float = 0
        for y in 20 ..< 80 { for x in x0 - 3 ..< x0 { worst = max(worst, s.a(x, y)) } }
        var moved: Float = 0
        for y in 0 ..< s.h {
            for x in 0 ..< s.w {
                let inStreak = (20 ..< 80).contains(y) && (x0 - 3 ..< x0).contains(x)
                let far = y < 16 || y >= 84 || x < x0 - 7
                if inStreak || !far { continue }
                moved = max(moved, abs(s.a(x, y) - Float(before[y * s.w + x]) / 255))
            }
        }
        print("V7.2 (p) green streak: the most coverage left on the streak \(worst) · the skin edge 4 px or more away changed by at most \(moved) · \(s.stats.lines.first ?? "")")
        XCTAssertLessThanOrEqual(worst, 0.05)
        XCTAssertLessThanOrEqual(moved, 0.02)
    }

    // MARK: (q) same-colour safety

    func testNothingIsCutWhereSubjectAndBackgroundShareAColour() {
        let cases: [(String, SIMD3<Float>, SIMD3<Float>)] = [("black sleeve on a dark background", SIMD3(29, 26, 25), SIMD3(45, 42, 40)),
                                                             ("green subject on green foliage", SIMD3(70, 130, 55), SIMD3(55, 110, 45))]
        for (name, subject, ground) in cases {
            var s = Scene(w: 120, h: 80) { x, y in
                // A wavy edge with some texture, as foliage has.
                let x0 = 60 + Int(4 * sin(Float(y) / 7))
                let a = Self.edge(x, x0: x0)
                let noise = Float((x * 37 + y * 91) % 13) - 6
                return (Self.mix(subject, ground, a) + SIMD3(repeating: noise), a)
            }
            let before = s.alpha
            s.run()
            let changed = zip(before, s.alpha).filter { $0 != $1 }.count
            print("V7.2 (q) \(name): \(changed) px cut · \(s.stats.lines.first ?? "")")
            XCTAssertEqual(changed, 0, name)
        }
    }

    // MARK: (r) a real rim is kept

    func testRealRimIsKept() {
        let rim = SIMD3<Float>(222, 150, 92), grey = SIMD3<Float>(128, 128, 128), x0 = 40
        var s = Scene(w: 80, h: 330) { x, y in
            let a = Self.edge(x, x0: x0)
            if (15 ..< 315).contains(y) && (x0 - 3 ..< x0).contains(x) { return (rim, 1) }
            return (a >= 1 ? Self.skin : (a <= 0 ? grey : Self.mix(Self.skin, grey, a)), a)
        }
        let before = s.alpha
        s.run()
        var kept = 0, total = 0, cut = 0
        for y in 15 ..< 315 {
            for x in x0 - 3 ..< x0 {
                total += 1
                if s.wS(x, y) == 0 { kept += 1 }
                if s.alpha[y * s.w + x] != before[y * s.w + x] { cut += 1 }
            }
        }
        print("V7.2 (r) real rim: \(kept) of \(total) rim pixels keep their colour (w = 0), \(cut) cut · \(s.stats.lines.first ?? "") · \(s.stats.repaint.summary)")
        XCTAssertEqual(kept, total)
        XCTAssertEqual(cut, 0)
    }

    // MARK: (s) the background side's line

    /// Test (a)'s sleeve against white, with a 2-px teal fringe on the background side.
    /// The render as `Masking.apply` makes it with exposure only: alpha 16's sequential path
    /// where w = wb = 0, the single blend of the subject's gain on C and the background's on
    /// Cb weighted in by max(w, wb).
    func testBackgroundSideHasNoDarkLine() {
        let sleeve = SIMD3<Float>(29, 26, 25), white = SIMD3<Float>(247, 247, 247), teal = SIMD3<Float>(0, 39, 33)
        let edgeCols: [(SIMD3<Float>, Float)] = [(SIMD3(26, 31, 29), 1), (SIMD3(18, 33, 30), 1), (SIMD3(0, 32, 28), 1), (SIMD3(0, 39, 33), 1),
                                                 (SIMD3(19, 44, 36), 0.84), (SIMD3(41, 51, 46), 0.49)]
        let x0 = 40
        var s = Scene(w: 90, h: 30) { x, _ in
            if x < x0 { return (sleeve, 1) }
            if x - x0 < edgeCols.count { return edgeCols[x - x0] }
            if x - x0 < edgeCols.count + 2 { return (teal, 0) }
            return (white, 0)
        }
        s.run()
        let y = s.h / 2, gS: Float = 8, gB: Float = 0.125
        func clean(_ m: [UInt8], _ x: Int) -> SIMD3<Float> { Repaint.clean(s.photo, map: m, x: x, y: y) }
        func render(_ x: Int) -> SIMD3<Float> {
            let i = (y * s.w + x) * 4
            let sh = SIMD3(Float(s.shares[i]), Float(s.shares[i + 1]), Float(s.shares[i + 2])) / 255
            let one = SIMD3<Float>(repeating: 1)
            let I = InsideColour.linear(s.photo, x, y)
            let lift: SIMD3<Float> = sh * gS + (one - sh)
            let drop: SIMD3<Float> = (one - sh) * gB + sh
            let alpha16: SIMD3<Float> = I * lift * drop
            let front: SIMD3<Float> = clean(s.map, x) * gS * sh
            let single: SIMD3<Float> = front + clean(s.back, x) * gB * (one - sh)
            let k = Float(max(s.wS(x, y), s.wB(x, y))) / 255
            return alpha16 + (single - alpha16) * k
        }
        // Each pixel within 3 px outside the half-way line against what it should be: its own
        // coverage's mix of the brightened sleeve (6 px in) and the darkened wall (6 px out); for
        // the background pixels there, the wall. (The edge pixel itself is half sleeve: it sits
        // between the two, as it should.)
        var edgeX = x0
        for x in 0 ..< s.w where s.alpha[y * s.w + x] < 128 { edgeX = x; break }
        let wallLin = render(edgeX + 5 + 6), sleeveLin = render(x0 - 6)
        let wall = Oklab.from(linear: wallLin)
        func ideal(_ x: Int) -> SIMD3<Float> { let a = s.a(x, y); return sleeveLin * a + wallLin * (1 - a) }
        var darkest: Float = -1, darkestWall: Float = -1
        for x in edgeX ..< edgeX + 3 {
            darkest = max(darkest, Oklab.from(linear: ideal(x)).x - Oklab.from(linear: render(x)).x)
            if s.a(x, y) <= 0.02 { darkestWall = max(darkestWall, wall.x - Oklab.from(linear: render(x)).x) }
        }
        // Without the background side's repaint, for comparison.
        var plainDark: Float = -1
        for x in edgeX ..< edgeX + 3 {
            let i = (y * s.w + x) * 4
            let sh = SIMD3(Float(s.shares[i]), Float(s.shares[i + 1]), Float(s.shares[i + 2])) / 255
            let one = SIMD3<Float>(repeating: 1)
            let I = InsideColour.linear(s.photo, x, y)
            let lift: SIMD3<Float> = sh * gS + (one - sh)
            let drop: SIMD3<Float> = (one - sh) * gB + sh
            let alpha16: SIMD3<Float> = I * lift * drop
            let front: SIMD3<Float> = clean(s.map, x) * gS * sh
            let single: SIMD3<Float> = front + I * gB * (one - sh)
            let k = Float(s.wS(x, y)) / 255
            plainDark = max(plainDark, Oklab.from(linear: ideal(x)).x - Oklab.from(linear: alpha16 + (single - alpha16) * k).x)
        }
        print("V7.2 (s) background side, Subject +3 / Background −3: within 3 px outside the edge, the background pixels at most \(darkestWall) L darker "
            + "than the darkened wall 6 px out; every pixel at most \(darkest) L darker than its own coverage's mix of brightened sleeve and darkened wall "
            + "(without the background repaint \(plainDark)) · \(s.stats.lines.last ?? "")")
        XCTAssertLessThanOrEqual(darkestWall, 0.03)
        XCTAssertLessThanOrEqual(darkest, 0.03)
    }

    // MARK: Remove Colour

    private func removeColour(_ s: Scene, box: PixelRect, samples: [SIMD3<Float>] = [], automatic: Bool, tolerance: Float = 0.05)
        -> (alpha: [UInt8], result: RefineResult) {
        var settings = MatteSettings()
        settings.insideColour = true
        let r = Refine.removeColour(box: box, samples: samples, automatic: automatic, tolerance: tolerance, alpha: s.alpha, shares: s.shares,
                                    repaint: Repaint.blank(count: s.w * s.h), repaintBack: Repaint.blank(count: s.w * s.h),
                                    context: RefineContext(photo: s.photo, faces: [], settings: settings))
        var a = s.alpha, sh = s.shares
        Refine.paste(r.output, at: r.patch, weight: r.weight, alpha: &a, shares: &sh, width: s.w)
        return (a, r)
    }

    // (t) The cut follows the mix: a diagonal edge stays smooth.
    func testRemoveColourOnADiagonalIsSmooth() {
        let pink = SIMD3<Float>(230, 150, 170), orange = SIMD3<Float>(230, 120, 40), green = SIMD3<Float>(60, 140, 60)
        let nx: Float = -0.4 / (1.16 as Float).squareRoot(), ny: Float = 1 / (1.16 as Float).squareRoot()
        func d(_ x: Float, _ y: Float) -> Float { (x - 20) * nx + (y - 60) * ny }
        let s = Scene(w: 200, h: 160) { x, y in
            var col = SIMD3<Float>(repeating: 0), cov: Float = 0
            func lin(_ c: SIMD3<Float>) -> SIMD3<Float> { SIMD3(pow(c.x / 255, 2.2), pow(c.y / 255, 2.2), pow(c.z / 255, 2.2)) }
            for sy in 0 ..< 4 {
                for sx in 0 ..< 4 {
                    let dd = d(Float(x) + (Float(sx) + 0.5) / 4, Float(y) + (Float(sy) + 0.5) / 4)
                    col += lin(dd < 0 ? pink : (dd < 4 ? orange : green))
                    cov += dd < 4 ? 1 : 0
                }
            }
            col /= 16
            return (SIMD3(pow(col.x, 1 / 2.2), pow(col.y, 1 / 2.2), pow(col.z, 1 / 2.2)) * 255, cov / 16)
        }
        let (a, r) = removeColour(s, box: PixelRect(x: 30, y: 20, w: 140, h: 120), samples: [orange / 255], automatic: false)
        func bil(_ x: Float, _ y: Float) -> Float {
            let x0 = Int(floor(x - 0.5)), y0 = Int(floor(y - 0.5)), fx = x - 0.5 - Float(x0), fy = y - 0.5 - Float(y0)
            func v(_ i: Int, _ j: Int) -> Float { Float(a[j * s.w + i]) / 255 }
            return (v(x0, y0) * (1 - fx) + v(x0 + 1, y0) * fx) * (1 - fy) + (v(x0, y0 + 1) * (1 - fx) + v(x0 + 1, y0 + 1) * fx) * fy
        }
        // Along the edge: lines parallel to it, every photo pixel.
        let tx = ny, ty = -nx
        var along: Float = 0
        for off in stride(from: Float(-2), through: 2, by: 0.25) {
            var prev: Float?
            for t in stride(from: Float(50), to: 140, by: 1) {
                let x = 20 + tx * t + nx * off, y = 60 + ty * t + ny * off
                guard x > 45 && x < 155 && y > 35 && y < 125 else { prev = nil; continue }
                let v = bil(x, y)
                if let p = prev { along = max(along, abs(v - p)) }
                prev = v
            }
        }
        // Neighbouring photo pixels, each pixel against the one beside it along the edge's
        // direction (right or down, whichever lies nearer it).
        var pixelSteps: Float = 0, inputSteps: Float = 0
        for y in 40 ..< 120 {
            for x in 50 ..< 150 {
                let here = Float(a[y * s.w + x]) / 255
                pixelSteps = max(pixelSteps, abs(Float(a[y * s.w + x + 1]) / 255 - here))
                inputSteps = max(inputSteps, abs(Float(s.alpha[y * s.w + x + 1]) - Float(s.alpha[y * s.w + x])) / 255)
            }
        }
        print("V7.2 (t) diagonal: largest step along the edge \(along) · largest step between horizontal neighbours \(pixelSteps) "
            + "(across the edge too; the photo's own anti-aliased edge before the box: \(inputSteps)) · \(r.log.first ?? "")")
        XCTAssertLessThanOrEqual(along, 0.3)
    }

    // (w) The automatic guess finds an enclosed patch.
    func testAutomaticGuessTakesTheEnclosedPatch() {
        let size = 300, c: Float = 150, radius: Float = 120
        let pink = SIMD3<Float>(230, 150, 170), orange = SIMD3<Float>(230, 120, 40), green = SIMD3<Float>(60, 140, 60)
        func patch(_ x: Int, _ y: Int) -> Bool { (130 ..< 170).contains(x) && (140 ..< 160).contains(y) }
        let specks = [(41, 150), (150, 41), (255, 150)]
        func speck(_ x: Int, _ y: Int) -> Bool { specks.contains { abs(x - $0.0) <= 1 && abs(y - $0.1) <= 1 } }
        // Orange outside the mask too, in the box (a wall beyond the ground).
        func wall(_ x: Int, _ y: Int) -> Bool { y >= 280 && x < 100 }
        let s = Scene(w: size, h: size) { x, y in
            let dx = Float(x) + 0.5 - c, dy = Float(y) + 0.5 - c, r = (dx * dx + dy * dy).squareRoot()
            let disc = min(max(radius - r + 0.5, 0), 1)
            if patch(x, y) || speck(x, y) { return (orange, 1) }
            if disc <= 0 && wall(x, y) { return (orange, 0) }
            return (Self.mix(pink, green, disc), disc)
        }
        let (a, r) = removeColour(s, box: PixelRect(x: 10, y: 10, w: 280, h: 285), automatic: true)
        var left: UInt8 = 0
        for y in 0 ..< size { for x in 0 ..< size where patch(x, y) || speck(x, y) { left = max(left, a[y * size + x]) } }
        var pinkChange = 0
        for y in 0 ..< size {
            for x in 0 ..< size {
                let nearPatch = (128 ..< 172).contains(x) && (138 ..< 162).contains(y)
                let nearSpeck = specks.contains { abs(x - $0.0) <= 3 && abs(y - $0.1) <= 3 }
                if nearPatch || nearSpeck || patch(x, y) || speck(x, y) { continue }
                pinkChange = max(pinkChange, abs(Int(a[y * size + x]) - Int(s.alpha[y * size + x])))
            }
        }
        let used = r.samples.map { c -> [Int] in [Int(c.x * 255), Int(c.y * 255), Int(c.z * 255)] }
        print("V7.2 (w) automatic guess, enclosed patch: the most coverage left on the patch and specks \(left) of 255 · the pink changed at most "
            + "\(pinkChange) of 255 more than 2 px away · samples used \(used) · \(r.log.first ?? "")")
        XCTAssertLessThanOrEqual(Float(left) / 255, 0.05)
        XCTAssertLessThanOrEqual(Float(pinkChange) / 255, 0.02)
        XCTAssertNil(r.message)
    }

    // (x) The automatic guess takes a green fringe off skin.
    func testAutomaticGuessTakesAGreenFringeOffSkin() {
        let x0 = 80, fringe = 2
        let s = Scene(w: 160, h: 120) { x, _ in
            let a = Self.edge(x, x0: x0)
            if (x0 - fringe ..< x0).contains(x) { return (Self.bokeh, 1) }
            return (a >= 1 ? Self.skin : (a <= 0 ? Self.bokeh : Self.mix(Self.skin, Self.bokeh, a)), a)
        }
        let (a, r) = removeColour(s, box: PixelRect(x: 20, y: 10, w: 120, h: 100), automatic: true)
        // Where each row crosses a half now, against the skin's own edge (where the fringe began).
        var worstMove: Float = 0, greenLeft: UInt8 = 0
        for y in 20 ..< 100 {
            var cross: Float = 0
            for x in 1 ..< s.w where a[y * s.w + x - 1] >= 128 && a[y * s.w + x] < 128 {
                let p = Float(a[y * s.w + x - 1]) / 255, q = Float(a[y * s.w + x]) / 255
                cross = Float(x) - 0.5 + (p - 0.5) / max(p - q, 1e-6)
                break
            }
            worstMove = max(worstMove, abs(cross - Float(x0 - fringe)))
            for x in x0 - fringe ..< x0 { greenLeft = max(greenLeft, a[y * s.w + x]) }
        }
        print("V7.2 (x) automatic guess, green fringe on skin: the most coverage left on the fringe \(greenLeft) of 255 · the skin's edge "
            + "\(worstMove) px from where it is · \(r.log.first ?? "")")
        XCTAssertLessThanOrEqual(Float(greenLeft) / 255, 0.05)
        XCTAssertLessThan(worstMove, 1)
    }

    // (y) Nothing clear: nothing done, and the status line says so.
    func testAutomaticGuessWithNothingClearDoesNothing() {
        let green = SIMD3<Float>(70, 130, 55)
        let s = Scene(w: 120, h: 100) { x, y in
            let a = Self.edge(x, x0: 60)
            // The subject is half the ground's green (stripes of it).
            let col = (y / 4) % 2 == 0 ? green : SIMD3<Float>(150, 90, 60)
            return (a >= 1 ? col : (a <= 0 ? green : Self.mix(col, green, a)), a)
        }
        let (a, r) = removeColour(s, box: PixelRect(x: 10, y: 10, w: 100, h: 80), automatic: true)
        let changed = zip(a, s.alpha).filter { $0 != $1 }.count
        print("V7.2 (y) nothing clear: \(changed) px changed · message: \(r.message ?? "none") · \(r.log.first ?? "")")
        XCTAssertEqual(changed, 0)
        XCTAssertEqual(r.message, "No clear background colour in the box — click one with the eyedropper.")
    }

    // (z) The eyedropper overrides every judgement: a colour that is 40% of the inside goes.
    func testEyedropperRemovesItsColourEverywhereInTheBox() {
        let orange = SIMD3<Float>(230, 120, 40), pink = SIMD3<Float>(230, 150, 170), green = SIMD3<Float>(60, 140, 60)
        let s = Scene(w: 160, h: 140) { x, y in
            let a = Self.edge(x, x0: 110)
            let col = (y / 5) % 5 < 2 ? orange : pink // 40% orange stripes through the subject
            return (a >= 1 ? col : (a <= 0 ? green : Self.mix(col, green, a)), a)
        }
        var inside = 0, orangeInside = 0
        for y in 10 ..< 130 { for x in 10 ..< 150 where s.alpha[y * s.w + x] >= 250 { inside += 1; if (y / 5) % 5 < 2 { orangeInside += 1 } } }
        let (a, r) = removeColour(s, box: PixelRect(x: 10, y: 10, w: 140, h: 120), samples: [orange / 255], automatic: false)
        var left: UInt8 = 0
        for y in 17 ..< 123 { for x in 17 ..< 108 where (y / 5) % 5 < 2 { left = max(left, a[y * s.w + x]) } }
        print("V7.2 (z) eyedropper: orange is \(100 * orangeInside / max(inside, 1))% of the inside · the most coverage left on it \(left) of 255 · \(r.log.first ?? "")")
        XCTAssertLessThanOrEqual(Float(left) / 255, 0.05)
    }

    // MARK: (u) Refine Hair's strength

    func testHairStrengthZeroAddsNothingBeyondTheEdge() {
        let w = 120, h = 80, x0 = 60
        var alpha = [UInt8](repeating: 0, count: w * h), shares = [UInt8](repeating: 0, count: w * h * 4)
        for y in 0 ..< h { for x in 0 ..< w { let a = UInt8(Self.edge(x, x0: x0) * 255); alpha[y * w + x] = a; for ch in 0 ..< 3 { shares[(y * w + x) * 4 + ch] = a } } }
        // What a stroke would make: the edge tidied (one pixel softer) and strands added out to 20 px.
        var made = alpha, madeShares = shares
        for y in 0 ..< h {
            for x in 0 ..< w {
                var a = Float(alpha[y * w + x]) / 255
                if x == x0 { a = 0.6 }
                if x == x0 - 1 { a = 0.95 }
                if x > x0 && x < x0 + 20 && y % 6 == 0 { a = 0.7 } // strands
                if x == x0 + 1 { a = max(a, 0.3) } // a fill just outside the edge
                made[y * w + x] = UInt8(a * 255)
                for ch in 0 ..< 3 { madeShares[(y * w + x) * 4 + ch] = UInt8(a * 255) }
            }
        }
        let patch = PixelRect(x: 0, y: 0, w: w, h: h)
        let out = MatteOutput(w: w, h: h, alpha: made, shares: madeShares, trimap: [], trimapW: 0, trimapH: 0, band: patch, unknownPixels: 0, log: [])
        let result = RefineResult(patch: patch, weight: Gray(w: w, h: h, v: [Float](repeating: 1, count: w * h)), output: out, log: [])
        let zero = Refine.limitHair(result, alpha: alpha, shares: shares, width: w, strength: 0)
        let one = Refine.limitHair(result, alpha: alpha, shares: shares, width: w, strength: 1)
        var added = 0, tidied = 0
        let outside = PlaneMath.distance(to: alpha.map { $0 >= 128 }, w: w, h: h)
        for i in 0 ..< w * h {
            if outside[i] > 2 && zero.output.alpha[i] > alpha[i] { added += 1 }
            if zero.output.alpha[i] != alpha[i] { tidied += 1 }
        }
        print("V7.2 (u) hair strength: at 0, \(added) px gain coverage more than 2 px outside the edge, \(tidied) px changed in all · at 1 the stroke's own result: \(one.output.alpha == made)")
        XCTAssertEqual(added, 0)
        XCTAssertGreaterThan(tidied, 0, "the edge itself is still tidied")
        XCTAssertEqual(one.output.alpha, made)
        XCTAssertEqual(one.output.shares, madeShares)
    }

    // MARK: The speck rule stays (owner, v7.2): (l) still passes with the cut on

    func testSoftEdgeIsNotHardened() {
        // A soft, defocused edge whose colours fit its coverage: the cut leaves it.
        var s = Scene(w: 120, h: 40) { x, _ in
            let a = min(max((Float(60 - x) + 3) / 6, 0), 1)
            return (Self.mix(Self.skin, Self.bokeh, a), a)
        }
        let before = s.alpha
        s.run()
        let most = zip(before, s.alpha).map { abs(Int($0) - Int($1)) }.max() ?? 0
        print("V7.2 soft edge (6 px ramp, colours fitting coverage): the most any pixel's alpha changed \(most) of 255 · \(s.stats.lines.first ?? "")")
        XCTAssertLessThanOrEqual(most, 5)
    }
}
