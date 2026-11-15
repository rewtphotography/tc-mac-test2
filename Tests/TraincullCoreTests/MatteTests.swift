import XCTest
@testable import TraincullCore

/// A made-up portrait to measure the matting on: a dark "head" with fine strands of "hair"
/// radiating from it, in front of a backdrop of two colours with a bright stripe (a
/// "decoration") that some strands cross. Because it is made up, the true mask is known.
struct Scene {
    let w: Int, h: Int
    var truth: [Float]
    var photo: Photo
    var coarse: Gray
    let face: PixelRect

    init(size: Int = 320, noise: Float = 0) {
        w = size; h = size
        let c = Float(size) / 2, head = Float(size) * 0.22
        truth = [Float](repeating: 0, count: w * h)
        var px = [UInt8](repeating: 255, count: w * h * 4)
        var seed: UInt64 = 0x9E37_79B9_7F4A_7C15
        func random() -> Float {
            seed = seed &* 6364136223846793005 &+ 1442695040888963407
            return Float((seed >> 40) & 0xFFFF) / 65535
        }
        // 40 strands, each a thin line from the head outwards, fading towards its tip.
        var strands: [(Float, Float, Float)] = []
        for i in 0 ..< 40 {
            let angle: Float = Float(i) / 40 * 2 * Float.pi + 0.03 * Float(i % 5)
            let length: Float = head + Float(size) * (0.10 + 0.08 * Float(i % 4) / 3)
            let width: Float = 0.6 + 0.25 * Float(i % 3)
            strands.append((angle, length, width))
        }
        for y in 0 ..< h {
            for x in 0 ..< w {
                let dx = Float(x) + 0.5 - c, dy = Float(y) + 0.5 - c
                let r = (dx * dx + dy * dy).squareRoot()
                var a = min(max(head - r + 0.5, 0), 1)
                if r > head - 1 {
                    let angle = atan2(dy, dx)
                    for (th, length, width) in strands where r < length {
                        var d = abs(angle - th)
                        if d > Float.pi { d = 2 * Float.pi - d }
                        let across = d * r // distance from the strand's centre line, in pixels
                        let s = min(max(width - across + 0.5, 0), 1) * min((length - r) / 12, 1)
                        a = max(a, s)
                    }
                }
                truth[y * w + x] = a
                let fg = SIMD3<Float>(0.16, 0.10, 0.07) + SIMD3(repeating: 0.03 * sin(Float(x) * 0.7) * cos(Float(y) * 0.5))
                var bg = x < w / 2 ? SIMD3<Float>(0.55, 0.62, 0.74) : SIMD3<Float>(0.70, 0.68, 0.62)
                if abs(Float(y) - Float(h) * 0.30) < Float(h) * 0.05 { bg = SIMD3(0.86, 0.45, 0.15) } // the decoration
                var v = fg * a + bg * (1 - a)
                if noise > 0 { v += SIMD3(random() - 0.5, random() - 0.5, random() - 0.5) * noise }
                for ch in 0 ..< 3 { px[(y * w + x) * 4 + ch] = UInt8(min(max(v[ch], 0), 1) * 255 + 0.5) }
            }
        }
        photo = Photo(w: w, h: h, rowBytes: w * 4, px: px)
        // What a first-pass mask is like: the right shape, far too soft, the strands a vague halo.
        var blurred = truth
        PlaneMath.boxBlur(&blurred, w: w, h: h, radius: 7)
        coarse = Gray(w: w, h: h, v: blurred).resized(w: w / 4, h: h / 4)
        let f = Int(head * 1.1)
        face = PixelRect(x: Int(c) - f / 2, y: Int(c) - f / 2, w: f, h: f)
    }

    /// Mean absolute error against the truth over the uncertain band, in thousandths.
    func error(_ alpha: [UInt8], _ out: MatteOutput) -> Float {
        var sum: Float = 0, n: Float = 0
        for y in 0 ..< h {
            for x in 0 ..< w where out.trimap[(y / 4) * out.trimapW + x / 4] == 128 {
                sum += abs(Float(alpha[y * w + x]) / 255 - truth[y * w + x])
                n += 1
            }
        }
        return 1000 * sum / max(n, 1)
    }

    func error(coarseOver out: MatteOutput) -> Float {
        let up = coarse.resized(w: w, h: h)
        return error(up.v.map { UInt8(min(max($0, 0), 1) * 255) }, out)
    }
}

final class MatteTests: XCTestCase {
    private func writePGM(_ name: String, _ bytes: [UInt8], _ w: Int, _ h: Int, channels: Int = 1) {
        guard let dir = ProcessInfo.processInfo.environment["TRAINCULL_MATTE_OUT"] else { return }
        var data = Data("P\(channels == 1 ? 5 : 6)\n\(w) \(h)\n255\n".utf8)
        data.append(contentsOf: bytes)
        try? data.write(to: URL(fileURLWithPath: dir).appendingPathComponent(name))
    }

    // MARK: Building blocks

    func testErodeAndDilate() {
        var g = Gray(w: 9, h: 9)
        g.v[4 * 9 + 4] = 1
        let grown = PlaneMath.extremum(g, radius: 2, smallest: false)
        XCTAssertEqual(grown.v.filter { $0 == 1 }.count, 25)
        XCTAssertEqual(grown.at(2, 2), 1)
        XCTAssertEqual(grown.at(1, 4), 0)
        XCTAssertEqual(PlaneMath.extremum(grown, radius: 2, smallest: true).v, g.v)
    }

    func testBoxBlurIsTheMeanOfTheWindow() {
        var a: [Float] = (0 ..< 35).map { Float($0 % 7) }
        PlaneMath.boxBlur(&a, w: 7, h: 5, radius: 1)
        XCTAssertEqual(a[2 * 7 + 3], 3, accuracy: 1e-5) // interior: mean of 2, 3, 4
        XCTAssertEqual(a[0], 0.5, accuracy: 1e-5) // corner: mean of the 0s and 1s that exist
        var flat = [Float](repeating: 0.25, count: 60)
        PlaneMath.boxBlur(&flat, w: 10, h: 6, radius: 4)
        for v in flat { XCTAssertEqual(v, 0.25, accuracy: 1e-5) }
    }

    func testDistanceIsExact() {
        let w = 23, h = 17
        var inside = [Bool](repeating: false, count: w * h)
        let seeds = [(3, 4), (20, 2), (11, 15)]
        for (x, y) in seeds { inside[y * w + x] = true }
        let d = PlaneMath.distance(to: inside, w: w, h: h)
        for y in 0 ..< h {
            for x in 0 ..< w {
                var want = Float.infinity
                for (sx, sy) in seeds {
                    let dx = Float(sx - x), dy = Float(sy - y)
                    want = min(want, (dx * dx + dy * dy).squareRoot())
                }
                XCTAssertEqual(d[y * w + x], want, accuracy: 1e-3)
            }
        }
    }

    func testResizeKeepsARamp() {
        let g = Gray(w: 4, h: 1, v: [0, 1, 2, 3])
        let big = g.resized(w: 8, h: 1)
        XCTAssertEqual(big.v[0], 0, accuracy: 1e-5)
        XCTAssertEqual(big.v[3], 1.25, accuracy: 1e-5)
        XCTAssertEqual(big.v[7], 3, accuracy: 1e-5)
    }

    // MARK: Closed-form matting

    /// The window-by-window operator against the textbook matrix, built entry by entry.
    func testOperatorMatchesTheMatrixDefinition() {
        let w = 7, h = 6, n = w * h, eps = 1e-5
        var seed: UInt64 = 42
        func random() -> Double {
            seed = seed &* 6364136223846793005 &+ 1442695040888963407
            return Double((seed >> 33) & 0xFFFFFF) / Double(0xFFFFFF)
        }
        let rgb = (0 ..< n * 3).map { _ in random() }
        let lam = (0 ..< n).map { _ in random() * 0.5 }
        let x = (0 ..< n).map { _ in random() }

        var L = [[Double]](repeating: [Double](repeating: 0, count: n), count: n)
        for cy in 1 ..< h - 1 {
            for cx in 1 ..< w - 1 {
                var idx: [Int] = []
                for dy in -1 ... 1 { for dx in -1 ... 1 { idx.append((cy + dy) * w + cx + dx) } }
                var mu = [0.0, 0.0, 0.0]
                for i in idx { for c in 0 ..< 3 { mu[c] += rgb[i * 3 + c] / 9 } }
                var S = [[Double]](repeating: [0, 0, 0], count: 3)
                for i in idx { for a in 0 ..< 3 { for b in 0 ..< 3 { S[a][b] += (rgb[i * 3 + a] - mu[a]) * (rgb[i * 3 + b] - mu[b]) / 9 } } }
                for a in 0 ..< 3 { S[a][a] += eps / 9 }
                let M = MatteTests.inverse3(S)
                for i in idx {
                    for j in idx {
                        var q = 0.0
                        for a in 0 ..< 3 { for b in 0 ..< 3 { q += (rgb[i * 3 + a] - mu[a]) * M[a][b] * (rgb[j * 3 + b] - mu[b]) } }
                        L[i][j] += (i == j ? 1 : 0) - (1 + q) / 9
                    }
                }
            }
        }
        let tile = ClosedFormTile(w: w, h: h, rgb: rgb, lam: lam, active: [Bool](repeating: true, count: n), epsilon: eps)
        var xs = x, got = [Double](repeating: 0, count: n), diag = got
        xs.withUnsafeMutableBufferPointer { xp in got.withUnsafeMutableBufferPointer { tile.apply(xp.baseAddress!, $0.baseAddress!) } }
        diag.withUnsafeMutableBufferPointer { tile.diagonal($0.baseAddress!) }
        for i in 0 ..< n {
            var want = lam[i] * x[i]
            for j in 0 ..< n { want += L[i][j] * x[j] }
            XCTAssertEqual(got[i], want, accuracy: 1e-7 * max(1, abs(want)), "row \(i)")
            XCTAssertEqual(diag[i], L[i][i] + lam[i], accuracy: 1e-7 * max(1, abs(diag[i])), "diagonal \(i)")
        }

        // And the solve really solves it: (L + Λ) x = Λ·prior.
        let prior = (0 ..< n).map { _ in random() }
        var solved = prior
        let result = tile.solve(&solved, prior: prior, maxIterations: 2000, tolerance: 1e-10)
        XCTAssertGreaterThan(result.steps, 0)
        XCTAssertLessThanOrEqual(result.residual, 1e-10)
        for i in 0 ..< n {
            var lhs = lam[i] * solved[i]
            for j in 0 ..< n { lhs += L[i][j] * solved[j] }
            XCTAssertEqual(lhs, lam[i] * prior[i], accuracy: 1e-6, "equation \(i)")
        }
    }

    static func inverse3(_ m: [[Double]]) -> [[Double]] {
        let a = m[0][0], b = m[0][1], c = m[0][2], d = m[1][0], e = m[1][1], f = m[1][2], g = m[2][0], h = m[2][1], i = m[2][2]
        let det = a * (e * i - f * h) - b * (d * i - f * g) + c * (d * h - e * g)
        return [[(e * i - f * h) / det, (c * h - b * i) / det, (b * f - c * e) / det],
                [(f * g - d * i) / det, (a * i - c * g) / det, (c * d - a * f) / det],
                [(d * h - e * g) / det, (b * g - a * h) / det, (a * e - b * d) / det]]
    }

    /// Pixels that are not solved for keep their values exactly.
    func testInactivePixelsStayFixed() {
        let w = 12, h = 12, n = w * h
        let rgb = (0 ..< n * 3).map { Double(($0 * 37) % 101) / 101 }
        var active = [Bool](repeating: false, count: n)
        for y in 4 ..< 8 { for x in 4 ..< 8 { active[y * w + x] = true } }
        let tile = ClosedFormTile(w: w, h: h, rgb: rgb, lam: [Double](repeating: 0.01, count: n), active: active, epsilon: 1e-5)
        let start = (0 ..< n).map { Double($0 % 2) }
        var x = start
        _ = tile.solve(&x, prior: start, maxIterations: 50, tolerance: 1e-8)
        for i in 0 ..< n where !active[i] { XCTAssertEqual(x[i], start[i]) }
        XCTAssertNotEqual(x[5 * w + 5], start[5 * w + 5])
    }

    // MARK: The whole thing

    func testEachTierGetsCloserToTheTruth() {
        let scene = Scene()
        writePGM("photo.ppm", (0 ..< scene.w * scene.h).flatMap { i -> [UInt8] in
            let c = scene.photo.rgb(i % scene.w, i / scene.w)
            return [UInt8(c.x * 255), UInt8(c.y * 255), UInt8(c.z * 255)]
        }, scene.w, scene.h, channels: 3)
        writePGM("truth.pgm", scene.truth.map { UInt8($0 * 255) }, scene.w, scene.h)
        writePGM("coarse.pgm", scene.coarse.resized(w: scene.w, h: scene.h).v.map { UInt8(min(max($0, 0), 1) * 255) }, scene.w, scene.h)

        var errors: [Float] = []
        var last: MatteOutput?
        for tier in MatteTier.allCases {
            let matte = Matte(photo: scene.photo, coarse: scene.coarse, faces: [scene.face])
            let out = matte.run(tier: tier)
            errors.append(scene.error(out.alpha, out))
            writePGM("alpha-\(tier.name).pgm", out.alpha, scene.w, scene.h)
            if tier == .fast { writePGM("trimap.pgm", out.trimap, out.trimapW, out.trimapH) }
            print("MATTE \(tier.name): error \(errors.last!) per mille; \(out.log.joined(separator: "; "))")
            last = out
        }
        let out = try! XCTUnwrap(last)
        let coarse = scene.error(coarseOver: out)
        print("MATTE coarse: error \(coarse) per mille over \(out.unknownPixels) uncertain pixels")
        XCTAssertGreaterThan(out.unknownPixels, 2000)
        XCTAssertLessThan(errors[0], coarse, "Off, the snapped first pass, is already nearer than the first pass scaled up")
        XCTAssertLessThan(errors[1], coarse * 0.5, "Fast should at least halve the first pass's error")
        XCTAssertLessThan(errors[2], errors[1], "High should beat Fast where strands cross two backgrounds")
        XCTAssertLessThan(errors[3], errors[2] * 1.02, "Max should not be worse than High")
        XCTAssertLessThan(errors[3], 60)

        // Certain areas are exact, and the mask covers the whole photo.
        XCTAssertEqual(out.alpha[(scene.h / 2) * scene.w + scene.w / 2], 255)
        XCTAssertEqual(out.alpha[3 * scene.w + 3], 0)
        XCTAssertEqual(out.alpha.count, scene.w * scene.h)
        XCTAssertEqual(out.shares.count, scene.w * scene.h * 4)
    }

    /// On a strand, less of the light is the subject's than its coverage says when the
    /// background is brighter: that is what stops bright backdrop showing through darkened hair.
    func testSharesFollowWhoTheLightBelongsTo() {
        let scene = Scene()
        let out = Matte(photo: scene.photo, coarse: scene.coarse, faces: [scene.face]).run(tier: .high)
        var lower = 0, total = 0
        for y in 0 ..< scene.h {
            for x in 0 ..< scene.w {
                let i = y * scene.w + x
                XCTAssertEqual(out.shares[i * 4 + 3], 255)
                if out.alpha[i] == 0 || out.alpha[i] == 255 {
                    XCTAssertEqual(out.shares[i * 4], out.alpha[i])
                    continue
                }
                // Only where colour matting ran: well inside the hair zone.
                let cell = (y / 4) * out.trimapW + x / 4
                if out.zones[cell] == 2 && out.hair[cell] > 128 && out.alpha[i] > 60 && out.alpha[i] < 200 {
                    total += 1
                    if out.shares[i * 4 + 1] < out.alpha[i] { lower += 1 }
                }
            }
        }
        XCTAssertGreaterThan(total, 200)
        XCTAssertGreaterThan(Double(lower) / Double(total), 0.9, "dark hair on a bright backdrop: the subject's share of the light is below its coverage")
    }

    func testNothingUncertainMeansNothingToDo() {
        let px = [UInt8](repeating: 128, count: 64 * 64 * 4)
        let photo = Photo(w: 64, h: 64, rowBytes: 256, px: px)
        let out = Matte(photo: photo, coarse: Gray(w: 16, h: 16, fill: 0), faces: []).run(tier: .max)
        XCTAssertEqual(out.unknownPixels, 0)
        XCTAssertTrue(out.alpha.allSatisfy { $0 == 0 })
    }

    func testHeadPatchReplacesTheRoughMaskWhereItWasUncertain() {
        let scene = Scene()
        // A second look that is much sharper than the first: the truth, lightly blurred.
        var sharp = scene.truth
        PlaneMath.boxBlur(&sharp, w: scene.w, h: scene.h, radius: 1)
        let patch = HeadPatch(rect: PixelRect(x: 0, y: 0, w: scene.w, h: scene.h), mask: Gray(w: scene.w, h: scene.h, v: sharp))
        let plain = Matte(photo: scene.photo, coarse: scene.coarse, faces: [scene.face]).run(tier: .fast)
        let patched = Matte(photo: scene.photo, coarse: scene.coarse, faces: [scene.face], patches: [patch]).run(tier: .fast)
        XCTAssertLessThan(patched.unknownPixels, plain.unknownPixels)
    }

    // MARK: Refinement fixes

    /// Many small tiles instead of one: where they meet must not show, and the answer must be
    /// as good as before.
    func testTilesMeetWithoutASeam() {
        let scene = Scene()
        var small = MatteSettings()
        small.tileCore = 96
        small.tileApron = 16
        let whole = Matte(photo: scene.photo, coarse: scene.coarse, faces: [scene.face]).run(tier: .max)
        let tiled = Matte(photo: scene.photo, coarse: scene.coarse, faces: [scene.face], settings: small).run(tier: .max)
        print("MATTE tiled: \(tiled.log.filter { $0.hasPrefix("max") }.joined()) | warnings \(tiled.warnings)")
        XCTAssertFalse(tiled.warnings.contains("SEAM?"))
        XCTAssertTrue(tiled.log.contains { $0.contains("seam ratio") && $0.contains("OK") })
        XCTAssertLessThan(scene.error(tiled.alpha, tiled), scene.error(whole.alpha, whole) * 1.25 + 1)
        // Directly: across every tile boundary the mask steps no more than it does elsewhere.
        var worstAcross = 0, worstWithin = 0
        for y in 0 ..< scene.h {
            for x in 1 ..< scene.w where tiled.trimap[(y / 4) * tiled.trimapW + x / 4] == 128 && tiled.trimap[(y / 4) * tiled.trimapW + (x - 1) / 4] == 128 {
                let step = abs(Int(tiled.alpha[y * scene.w + x]) - Int(tiled.alpha[y * scene.w + x - 1]))
                if (x - tiled.band.x) % 96 == 0 { worstAcross = max(worstAcross, step) } else { worstWithin = max(worstWithin, step) }
            }
        }
        XCTAssertLessThanOrEqual(worstAcross, worstWithin)
    }

    /// Where the photo is well out of focus compared with the subject, the colour arithmetic is
    /// not trusted: the better tiers leave the Fast answer alone, and Fast stays with the rough mask.
    func testOutOfFocusAreasKeepTheRoughMask() {
        let scene = Scene()
        let blurred = Gray(w: 8, h: 8, fill: 8) // everything eight pixels out of focus
        let sharp = Gray(w: 8, h: 8, fill: 0.5)
        func run(_ defocus: Gray, _ tier: MatteTier) -> MatteOutput {
            Matte(photo: scene.photo, coarse: scene.coarse, faces: [scene.face], defocus: defocus, subjectSharpness: 0.5).run(tier: tier)
        }
        let fastBlurred = run(blurred, .fast), maxBlurred = run(blurred, .max), maxSharp = run(sharp, .max)
        XCTAssertEqual(maxBlurred.alpha, fastBlurred.alpha, "out of focus, High and Max add nothing")
        XCTAssertLessThan(scene.error(maxSharp.alpha, maxSharp), scene.error(maxBlurred.alpha, maxBlurred) * 0.5, "in focus, they do their work")
        XCTAssertTrue(maxBlurred.log.contains { $0.contains("out-of-focus 100% of band") })
        // And nothing in the sure background has been turned into half-subject.
        XCTAssertTrue(maxBlurred.log.contains { $0.contains("mid-in-confident-bg 0.0%") }, "\(maxBlurred.log)")
    }

    // MARK: Spec v3: Off, and matting in the hair zone only

    /// A dark disc on a light ground with a soft rough mask: no face, so no hair zone.
    private func disc(size: Int = 240, light: SIMD3<Float> = SIMD3(0.75, 0.78, 0.84), dark: SIMD3<Float> = SIMD3(0.16, 0.12, 0.10),
                      grain: Float = 0, blur: Int = 3) -> (photo: Photo, coarse: Gray, inside: (Int, Int) -> Float) {
        let w = size, h = size
        let cx = Float(size) * 0.5, cy = Float(size) * 0.5, r = Float(size) * 0.28
        func inside(_ x: Int, _ y: Int) -> Float {
            let dx = Float(x) + 0.5 - cx, dy = Float(y) + 0.5 - cy
            return min(max(r - (dx * dx + dy * dy).squareRoot() + 0.5, 0), 1)
        }
        var seed: UInt64 = 0x1234_5678_9ABC_DEF1
        func random() -> Float {
            seed = seed &* 6364136223846793005 &+ 1442695040888963407
            return Float((seed >> 40) & 0xFFFF) / 65535 - 0.5
        }
        var px = [UInt8](repeating: 255, count: w * h * 4)
        var truth = [Float](repeating: 0, count: w * h)
        for y in 0 ..< h {
            for x in 0 ..< w {
                let a = inside(x, y)
                truth[y * w + x] = a
                let v = dark * a + light * (1 - a) + SIMD3(repeating: grain * random())
                for ch in 0 ..< 3 { px[(y * w + x) * 4 + ch] = UInt8(min(max(v[ch], 0), 1) * 255 + 0.5) }
            }
        }
        PlaneMath.boxBlur(&truth, w: w, h: h, radius: blur * 4)
        return (Photo(w: w, h: h, rowBytes: w * 4, px: px), Gray(w: w, h: h, v: truth).resized(w: w / 4, h: h / 4), inside)
    }

    /// Off on a hard edge the photo shows clearly: the edge lands where the photo has it,
    /// and there is no halo around it.
    func testOffSnapsAHardEdgeToThePhoto() {
        // The first pass is about as soft as a model's edge is once enlarged: a few pixels.
        let scene = disc(blur: 1)
        let face = PixelRect(x: 2, y: 2, w: 8, h: 8) // far from the disc: its edge is not hair
        let out = Matte(photo: scene.photo, coarse: scene.coarse, faces: [face]).run(tier: .off)
        let w = 240, y = 120, edge = 120 + 67 // the disc's right-hand edge along the middle row
        XCTAssertEqual(out.alpha[y * w + 120], 255)
        XCTAssertGreaterThan(out.alpha[y * w + edge - 3], 230, "just inside the edge")
        XCTAssertLessThan(out.alpha[y * w + edge + 3], 25, "just outside the edge")
        XCTAssertEqual(out.alpha[y * w + edge + 30], 0)
        XCTAssertFalse(out.log.contains { $0.hasPrefix("fast") }, "Off runs no colour matting")
        XCTAssertTrue(out.zones.contains(1))
        XCTAssertFalse(out.zones.contains(2))
        XCTAssertLessThan(try! XCTUnwrap(out.edgeQuality.haloElsewhere), 0.02)
        XCTAssertLessThan(try! XCTUnwrap(out.edgeQuality.erosionElsewhere), 0.02)
        print("MATTE off, hard edge: \(out.edgeQuality.summary) · α at −3…+3 px: \((-3 ... 3).map { Int(out.alpha[y * w + edge + $0]) })")

        // Without the snap the edge is where the first pass left it: wider.
        var plain = MatteSettings()
        plain.snapPasses = 0
        plain.steepen = 1
        let unsnapped = Matte(photo: scene.photo, coarse: scene.coarse, faces: [face], settings: plain).run(tier: .off)
        var width = 0, plainWidth = 0
        for x in 0 ..< w {
            if out.alpha[y * w + x] > 25 && out.alpha[y * w + x] < 230 { width += 1 }
            if unsnapped.alpha[y * w + x] > 25 && unsnapped.alpha[y * w + x] < 230 { plainWidth += 1 }
        }
        XCTAssertLessThan(width * 2, plainWidth, "snapped: \(width) soft pixels across the row; as given: \(plainWidth)")
    }

    /// Off on an edge the photo barely shows (dark on dark, with grain): the model's edge
    /// stands, clean, where colour arithmetic would only make speckle.
    func testOffKeepsTheModelsEdgeWhereThePhotoShowsNone() {
        let scene = disc(light: SIMD3(0.13, 0.13, 0.14), dark: SIMD3(0.11, 0.11, 0.11), grain: 0.05, blur: 1)
        // A face far from the disc, so the disc's edge is outside the hair zone.
        let face = PixelRect(x: 2, y: 2, w: 8, h: 8)
        let off = Matte(photo: scene.photo, coarse: scene.coarse, faces: [face]).run(tier: .off)
        let w = 240
        var speckle = 0, edgePixels = 0
        for y in 0 ..< 240 {
            for x in 0 ..< 240 {
                let a = scene.inside(x, y), v = off.alpha[y * w + x]
                let dx = Float(x) + 0.5 - 120, dy = Float(y) + 0.5 - 120
                let r = (dx * dx + dy * dy).squareRoot()
                if r > 67.2 + 10 && v > 12 { speckle += 1 }
                if r < 67.2 - 10 && v < 243 { speckle += 1 }
                if a > 0 && a < 1 { edgePixels += 1 }
            }
        }
        XCTAssertGreaterThan(edgePixels, 100)
        XCTAssertEqual(speckle, 0, "nothing stray further than 10 px from the edge")
        XCTAssertLessThan(try! XCTUnwrap(off.edgeQuality.haloElsewhere), 0.05)
        XCTAssertNil(off.edgeQuality.haloHair, "no edge in the hair zone to measure")

        // The better tiers change nothing here: there is no hair zone on this edge.
        let high = Matte(photo: scene.photo, coarse: scene.coarse, faces: [face]).run(tier: .high)
        XCTAssertEqual(high.alpha, off.alpha)
        XCTAssertEqual(high.shares, off.shares)
        XCTAssertTrue(high.log.contains { $0.contains("nothing for colour matting to do") })
    }

    /// Outside the hair zone every tier gives Off's answer; inside it they differ. And one
    /// Matte run at several tiers in turn gives what a fresh one gives for each.
    func testMattingStaysInTheHairZoneAndTiersCanBeRerun() {
        let scene = Scene()
        let kept = Matte(photo: scene.photo, coarse: scene.coarse, faces: [scene.face])
        let max = kept.run(tier: .max), off = kept.run(tier: .off), high = kept.run(tier: .high)
        let freshHigh = Matte(photo: scene.photo, coarse: scene.coarse, faces: [scene.face]).run(tier: .high)
        XCTAssertEqual(high.alpha, freshHigh.alpha)
        XCTAssertEqual(high.shares, freshHigh.shares)
        var outside = 0, differInside = 0
        for y in 0 ..< scene.h {
            for x in 0 ..< scene.w {
                let cell = (y / 4) * off.trimapW + x / 4, i = y * scene.w + x
                if off.zones[cell] == 0 { continue }
                if off.hair[cell] == 0 {
                    outside += 1
                    XCTAssertEqual(max.alpha[i], off.alpha[i], "outside the hair zone at \(x),\(y)")
                } else if max.alpha[i] != off.alpha[i] {
                    differInside += 1
                }
            }
        }
        XCTAssertGreaterThan(outside, 500)
        XCTAssertGreaterThan(differInside, 500)
        XCTAssertTrue(max.zones.contains(2))
        XCTAssertFalse(off.zones.contains(2))
    }

    /// A crisp first-pass edge gets a thin band; a soft one keeps the full band.
    func testCrispEdgesGetAThinBand() {
        let crisp = disc(size: 480, blur: 0), soft = disc(size: 480, blur: 3)
        let face = PixelRect(x: 140, y: 100, w: 200, h: 280) // large enough for a wide full band
        var fixed = MatteSettings()
        fixed.adaptiveBand = false
        let thin = Matte(photo: crisp.photo, coarse: crisp.coarse, faces: [face])
        let full = Matte(photo: crisp.photo, coarse: crisp.coarse, faces: [face], settings: fixed)
        XCTAssertLessThan(Double(thin.unknownCount), 0.7 * Double(full.unknownCount), "the crisp edge's band is much thinner")
        let softAdaptive = Matte(photo: soft.photo, coarse: soft.coarse, faces: [face])
        let softFixed = Matte(photo: soft.photo, coarse: soft.coarse, faces: [face], settings: fixed)
        XCTAssertEqual(softAdaptive.unknownCount, softFixed.unknownCount, "a soft edge keeps the full band")
        XCTAssertTrue(thin.log.contains { $0.contains("crisp 100%") }, "\(thin.log)")
    }

    func testNarrowBandLeavesLessUncertain() {
        let scene = Scene()
        var narrow = MatteSettings()
        narrow.bandIn = 0.012
        narrow.bandOut = 0.04
        // A face large enough for the two widths to differ once rounded to whole pixels.
        let face = PixelRect(x: 0, y: 0, w: 320, h: 600)
        let wide = Matte(photo: scene.photo, coarse: scene.coarse, faces: [face])
        let thin = Matte(photo: scene.photo, coarse: scene.coarse, faces: [face], settings: narrow)
        XCTAssertLessThan(thin.unknownCount, wide.unknownCount)
    }

    // MARK: Sharpness and choosing the subject

    /// A picture of vertical edges: crisp on the left, blurred by a known amount on the right.
    private func edges(blur: Float) -> Gray {
        let w = 240, h = 120
        var g = Gray(w: w, h: h)
        for y in 0 ..< h {
            for x in 0 ..< w {
                let left = x < w / 2
                let period = 24, phase = Float((x % period) - period / 2) + 0.5
                let s: Float = left ? 0.35 : blur
                // A step through a Gaussian blur of width s is the error function.
                g.v[y * w + x] = 0.5 + 0.4 * erf(phase / (s * Float(2).squareRoot())) * ((x / period) % 2 == 0 ? 1 : -1)
            }
        }
        return g
    }

    func testSharpnessMeasuresHowBlurredAnEdgeIs() throws {
        let map = SharpnessMap(luma: edges(blur: 3))
        let crisp = try XCTUnwrap(map.median(in: PixelRect(x: 6, y: 10, w: 100, h: 100)))
        let soft = try XCTUnwrap(map.median(in: PixelRect(x: 132, y: 10, w: 100, h: 100)))
        XCTAssertLessThan(crisp, 1.0)
        XCTAssertEqual(soft, 3, accuracy: 0.6)
        // Between the edges the map is filled in.
        XCTAssertLessThan(map.dense.at(40, 60), 1.2)
        XCTAssertGreaterThan(map.dense.at(200, 60), 2.2)
        XCTAssertNil(map.median(in: PixelRect(x: 0, y: 0, w: 3, h: 3)), "too few edges to tell")
    }

    func testTheSubjectIsTheLargeSharpFace() {
        let map = SharpnessMap(luma: edges(blur: 3))
        let crisp = PixelRect(x: 20, y: 20, w: 60, h: 80), blurredBigger = PixelRect(x: 140, y: 10, w: 80, h: 100)
        let tiny = PixelRect(x: 4, y: 4, w: 3, h: 3)
        let ranked = SubjectChoice.rank([blurredBigger, tiny, crisp], sharpness: map)
        XCTAssertEqual(ranked.map { $0.face }, [crisp, blurredBigger], "the tiny face is not a candidate; the sharp one wins though it is smaller")
        XCTAssertLessThan(ranked[0].sharp!, ranked[1].sharp!)

        let box = SubjectChoice.bodyBox(face: PixelRect(x: 100, y: 100, w: 40, h: 50), w: 400, h: 300)
        XCTAssertEqual(box, PixelRect(x: 0, y: 50, w: 240, h: 250), "three widths either side, one height above, clamped at the left and the bottom")
    }

    // MARK: Skin

    func testSkinModelPicksSkinAndNotHairOrBackdrop() throws {
        let skin = SIMD3<Float>(0.80, 0.60, 0.50)
        var samples: [SIMD3<Float>] = []
        for i in 0 ..< 98 { samples.append(skin + SIMD3(repeating: Float(i % 7 - 3) * 0.01) + SIMD3(Float(i % 3) * 0.01, 0, Float(i % 2) * 0.01)) }
        let model = try XCTUnwrap(SkinModel(samples: samples))
        XCTAssertGreaterThan(model.value(skin), 0.9)
        XCTAssertGreaterThan(model.value(skin * 0.92), 0.5, "the same skin a little darker")
        XCTAssertLessThan(model.value(SIMD3(0.16, 0.10, 0.07)), 0.05, "dark hair")
        XCTAssertLessThan(model.value(SIMD3(0.55, 0.62, 0.74)), 0.05, "a blue backdrop")
        XCTAssertLessThan(model.value(SIMD3(0.75, 0.20, 0.22)), 0.05, "red lips")
        XCTAssertNil(SkinModel(samples: [skin]))

        // The mask: skin colour, inside the subject, outside the excluded area.
        let w = 40, h = 20
        var px = [UInt8](repeating: 255, count: w * h * 4)
        for i in 0 ..< w * h { px[i * 4] = 204; px[i * 4 + 1] = 153; px[i * 4 + 2] = 128 }
        let photo = Photo(w: w, h: h, rowBytes: w * 4, px: px)
        var alpha = [UInt8](repeating: 0, count: w * h)
        for y in 0 ..< h { for x in 0 ..< 30 { alpha[y * w + x] = 255 } }
        var keepOut = Gray(w: w, h: h)
        for y in 0 ..< h { for x in 0 ..< 10 { keepOut.v[y * w + x] = 1 } }
        let mask = SkinMask.make(photo: photo, alpha: alpha, model: model, exclusion: keepOut)
        XCTAssertEqual(mask[10 * w + 3], 0, "excluded")
        XCTAssertGreaterThan(mask[10 * w + 20], 230, "skin inside the subject")
        XCTAssertEqual(mask[10 * w + 35], 0, "outside the subject")
    }
}
