#if os(macOS)
import CoreImage
@testable import TrainCull
import TraincullCore
import XCTest

/// Masking spec v7.1 tests (j), (k) and (o) through the app's own blend, `Masking.apply`:
/// the edge repaint as Core Image draws it. Pictures are made in code. Colours are read back
/// in linear light and measured in Oklab.
final class RepaintRenderTests: XCTestCase {
    private let context = CIContext(options: [.cacheIntermediates: false])

    /// A straight vertical edge, as in the core tests: `subject` left of x0, then the `edge`
    /// columns (colour 0–255, alpha), then `ground`. Shares are the alpha, then the repaint
    /// is worked out by the engine.
    private struct Edge {
        let w = 80, h = 30, x0 = 40
        var picture: CGImage
        var alpha: [UInt8]
        var shares: [UInt8]
        var map: [UInt8]
        var back: [UInt8]
        var stats = RepaintStats()
        var mask: MaskResult
        var extent: CGRect { CGRect(x: 0, y: 0, width: w, height: h) }

        /// `outside`: colours of the pixels just past the edge columns, at alpha 0 (a fringe on
        /// the background side, spec v7.2, 3).
        init(subject: SIMD3<UInt8>, edge: [(SIMD3<UInt8>, Float)], ground: SIMD3<UInt8>, outside: [SIMD3<UInt8>] = []) throws {
            let w = 80, h = 30, x0 = 40
            var px = [UInt8](repeating: 255, count: w * h * 4)
            alpha = [UInt8](repeating: 0, count: w * h)
            for y in 0 ..< h {
                for x in 0 ..< w {
                    var c = ground, a: Float = 0
                    if x < x0 { c = subject; a = 1 } else if x - x0 < edge.count { c = edge[x - x0].0; a = edge[x - x0].1 } else if x - x0 - edge.count < outside.count {
                        c = outside[x - x0 - edge.count]
                    }
                    for ch in 0 ..< 3 { px[(y * w + x) * 4 + ch] = c[ch] }
                    alpha[y * w + x] = UInt8((a * 255).rounded())
                }
            }
            picture = try XCTUnwrap(Masking.picture(rgbx: px, w: w, h: h))
            let photo = try XCTUnwrap(Masking.photo(from: picture))
            shares = [UInt8](repeating: 255, count: w * h * 4)
            for i in 0 ..< w * h { for ch in 0 ..< 3 { shares[i * 4 + ch] = alpha[i] } }
            map = Repaint.blank(count: w * h)
            back = Repaint.blank(count: w * h)
            var a = alpha, s = shares, m = map, b = back
            let made = a.withUnsafeMutableBufferPointer { ap in
                s.withUnsafeMutableBufferPointer { sp in
                    m.withUnsafeMutableBufferPointer { mp in
                        b.withUnsafeMutableBufferPointer { bp in
                            EdgeColour.run(photo: photo, alpha: ap.baseAddress!, shares: sp.baseAddress!, map: mp.baseAddress!, back: bp.baseAddress!,
                                           rect: PixelRect(x: 0, y: 0, w: w, h: h), settings: InsideColourSettings(), skip: { _, _, _ in false })
                        }
                    }
                }
            }
            stats = made.repaint
            alpha = a; shares = s; map = m; back = b
            let alphaPicture = try XCTUnwrap(Masking.picture(gray: alpha, w: w, h: h))
            mask = MaskResult(width: w, height: h, alpha: alphaPicture, shares: try XCTUnwrap(Masking.picture(rgbx: shares, w: w, h: h)), skin: nil,
                              trimap: alphaPicture, coarse: alphaPicture, tier: .off, summary: "",
                              repaint: try XCTUnwrap(Masking.picture(rgbx: map, w: w, h: h)), repaintBack: try XCTUnwrap(Masking.picture(rgbx: back, w: w, h: h)))
        }

        func w(_ x: Int, _ y: Int) -> UInt8 { map[(y * w + x) * 4 + 2] }
        func wb(_ x: Int, _ y: Int) -> UInt8 { back[(y * w + x) * 4 + 2] }
        func a(_ x: Int, _ y: Int) -> Float { Float(alpha[y * w + x]) / 255 }
    }

    /// An image's pixels in linear light, top row first.
    private func linear(_ image: CIImage, _ extent: CGRect) throws -> (Int, Int) -> SIMD3<Float> {
        let w = Int(extent.width), h = Int(extent.height)
        var out = [Float](repeating: 0, count: w * h * 4)
        let space = try XCTUnwrap(CGColorSpace(name: CGColorSpace.extendedLinearSRGB))
        out.withUnsafeMutableBytes { p in
            context.render(image, toBitmap: p.baseAddress!, rowBytes: w * 16, bounds: extent, format: .RGBAf, colorSpace: space)
        }
        return { x, y in SIMD3(out[(y * w + x) * 4], out[(y * w + x) * 4 + 1], out[(y * w + x) * 4 + 2]) }
    }

    private func edits(subject: Float, background: Float) -> LocalEdits {
        var e = LocalEdits()
        e.layers[LocalArea.subject.rawValue].exposure = subject
        e.layers[LocalArea.background.rawValue].exposure = background
        return e
    }

    private func render(_ mask: MaskResult, _ source: CIImage, _ edits: LocalEdits, view: MaskView = .photo, area: LocalArea = .subject) -> CIImage {
        Masking.apply(LocalRender(mask: mask, edits: edits, view: view, area: area), to: source, extent: CGRect(x: 0, y: 0, width: mask.width, height: mask.height))
    }

    private static func ab(_ p: SIMD3<Float>, _ q: SIMD3<Float>) -> Float { ((p.y - q.y) * (p.y - q.y) + (p.z - q.z) * (p.z - q.z)).squareRoot() }

    static let sleeveEdge: [(SIMD3<UInt8>, Float)] = [(SIMD3(26, 31, 29), 1), (SIMD3(18, 33, 30), 1), (SIMD3(0, 32, 28), 1), (SIMD3(0, 39, 33), 1),
                                                      (SIMD3(19, 44, 36), 0.84), (SIMD3(41, 51, 46), 0.49)]

    /// (j) The black sleeve with its teal edge, Subject +3 EV and Background −3 EV.
    func testBlackSleeveRendered() throws {
        let e = try Edge(subject: SIMD3(29, 26, 25), edge: Self.sleeveEdge, ground: SIMD3(247, 247, 247))
        let source = CIImage(cgImage: e.picture), y = e.h / 2
        XCTAssertNotNil(Masking.repainted(source, map: e.mask.repaint, extent: e.extent), "the repaint program didn't load")
        for c in 0 ..< 6 { XCTAssertEqual(e.w(e.x0 + c, y), 255, "edge pixel \(c) has w = 1") }
        let out = try linear(render(e.mask, source, edits(subject: 3, background: -3)), e.extent)
        let lab = { (x: Int) in Oklab.from(linear: out(x, y)) }
        let sleeve = lab(e.x0 - 6)
        var darkest: Float = -1
        for c in 0 ..< 6 where e.a(e.x0 + c, y) >= 0.9 { darkest = max(darkest, sleeve.x - lab(e.x0 + c).x) }
        // The subject side: C before the subject's exposure, and after it next to the brightened sleeve.
        let clean = try XCTUnwrap(Masking.repainted(source, map: e.mask.repaint, extent: e.extent))
        let before = try linear(clean, e.extent)
        var lit = LocalLayer()
        lit.exposure = 3
        let after = try linear(Masking.adjust(clean, lit), e.extent)
        let chroma = (0 ..< 6).map { Oklab.chroma(Oklab.from(linear: before(e.x0 + $0, y))) }.max() ?? 1
        let chromaLit = (0 ..< 6).map { Oklab.chroma(Oklab.from(linear: after(e.x0 + $0, y))) }.max() ?? 1
        let sleeveLit = Oklab.chroma(Oklab.from(linear: after(e.x0 - 6, y)))
        let sleeveChroma = Oklab.chroma(Oklab.from(linear: before(e.x0 - 6, y)))
        // Steps between neighbours across the repainted band's inner and outer limits.
        let ws = (0 ..< e.w).map { e.w($0, y) }
        let first = try XCTUnwrap(ws.firstIndex { $0 > 0 }), last = try XCTUnwrap(ws.lastIndex { $0 > 0 })
        var worstL: Float = 0, worstAB: Float = 0
        for (p, q) in [(first - 1, first), (first, first + 1), (last - 1, last), (last, last + 1)] {
            worstL = max(worstL, abs(lab(p).x - lab(q).x)); worstAB = max(worstAB, Self.ab(lab(p), lab(q)))
        }
        // Subject 0, Background −3.
        let plain = try linear(render(e.mask, source, edits(subject: 0, background: -3)), e.extent)
        var plainChroma: Float = 0
        for c in 0 ..< 6 where e.a(e.x0 + c, y) >= 0.9 { plainChroma = max(plainChroma, Oklab.chroma(Oklab.from(linear: plain(e.x0 + c, y)))) }
        print("V7.1-J rendered: darkest edge pixel at α ≥ 0.9 against the brightened sleeve 6 px in \(darkest) (L; negative is lighter) · "
            + "subject side chroma before exposure \(chroma) (sleeve \(sleeveChroma)) · after +3 \(chromaLit) (brightened sleeve \(sleeveLit)) · "
            + "band columns \(first - e.x0)…\(last - e.x0), steps across its limits L \(worstL), (a, b) \(worstAB) · Subject 0: chroma at α ≥ 0.9 \(plainChroma)")
        XCTAssertLessThanOrEqual(darkest, 0.03)
        XCTAssertLessThanOrEqual(chroma, 0.012)
        XCTAssertLessThanOrEqual(worstL, 0.03)
        XCTAssertLessThanOrEqual(worstAB, 0.015)
        XCTAssertLessThanOrEqual(plainChroma, 0.012)
    }

    /// (k) A strong green fringe on skin at alpha 1, Subject +1.5 EV.
    func testStrongGreenOnSkinRendered() throws {
        let skin = SIMD3<UInt8>(155, 113, 85)
        let e = try Edge(subject: skin, edge: [(SIMD3(88, 118, 70), 1), (skin, 0.5)], ground: SIMD3(247, 247, 247))
        let out = try linear(render(e.mask, CIImage(cgImage: e.picture), edits(subject: 1.5, background: 0)), e.extent)
        let y = e.h / 2
        let fringe = Oklab.from(linear: out(e.x0, y)), lit = Oklab.from(linear: out(e.x0 - 8, y))
        let dL = abs(fringe.x - lit.x), dAB = Self.ab(fringe, lit)
        print("V7.1-K rendered: fringe against the brightened skin L \(dL), (a, b) \(dAB)")
        XCTAssertLessThanOrEqual(dL, 0.03)
        XCTAssertLessThanOrEqual(dAB, 0.015)
    }

    /// (s) Spec v7.2: the black sleeve against white with a 2-px teal fringe on the background
    /// side, Subject +3 EV and Background −3 EV, through `Masking.apply`: no background pixel
    /// within 3 px outside the edge is darker than the darkened wall 6 px out by more than
    /// 0.03 L, and none of those pixels is darker than its own coverage's mix of brightened
    /// sleeve and darkened wall by more than that.
    func testBackgroundSideRendered() throws {
        let e = try Edge(subject: SIMD3(29, 26, 25), edge: Self.sleeveEdge, ground: SIMD3(247, 247, 247), outside: [SIMD3(0, 39, 33), SIMD3(0, 39, 33)])
        let source = CIImage(cgImage: e.picture), y = e.h / 2
        let out = try linear(render(e.mask, source, edits(subject: 3, background: -3)), e.extent)
        var edgeX = e.x0
        for x in 0 ..< e.w where e.alpha[y * e.w + x] < 128 { edgeX = x; break }
        let wallLin = out(edgeX + 5 + 6, y), sleeveLin = out(e.x0 - 6, y)
        let wall = Oklab.from(linear: wallLin)
        var darkWall: Float = -1, darkMix: Float = -1
        for x in edgeX ..< edgeX + 3 {
            let a = e.a(x, y), here = Oklab.from(linear: out(x, y))
            darkMix = max(darkMix, Oklab.from(linear: sleeveLin * a + wallLin * (1 - a)).x - here.x)
            if a <= 0.02 { darkWall = max(darkWall, wall.x - here.x) }
        }
        let noBack = MaskResult(width: e.w, height: e.h, alpha: e.mask.alpha, shares: e.mask.shares, skin: nil, trimap: e.mask.alpha, coarse: e.mask.alpha,
                                tier: .off, summary: "", repaint: e.mask.repaint)
        let before = try linear(render(noBack, source, edits(subject: 3, background: -3)), e.extent)
        var darkBefore: Float = -1
        for x in edgeX ..< edgeX + 3 where e.a(x, y) <= 0.02 { darkBefore = max(darkBefore, wall.x - Oklab.from(linear: before(x, y)).x) }
        print("V7.2-S rendered: background pixels within 3 px outside the edge at most \(darkWall) L darker than the darkened wall 6 px out "
            + "(without the background repaint \(darkBefore)) · every pixel there at most \(darkMix) L darker than its coverage's mix · "
            + "wb on the fringe \((edgeX ..< edgeX + 3).map { e.wb($0, y) })")
        XCTAssertLessThanOrEqual(darkWall, 0.03)
        XCTAssertLessThanOrEqual(darkMix, 0.03)
    }

    /// (o) Every pixel with w = 0 renders exactly as alpha 16's path does, under Subject +3 and
    /// Background −3, on a soft hair-like edge whose shares differ by channel; the background
    /// side never reads C; and the views render with a repaint.
    func testRepaintLeavesEverythingElseAsAlpha16() throws {
        let w = 120, h = 60
        var px = [UInt8](repeating: 0, count: w * h * 4), alpha = [UInt8](repeating: 0, count: w * h)
        var shares = [UInt8](repeating: 0, count: w * h * 4), map = Repaint.blank(count: w * h), back = Repaint.blank(count: w * h)
        for y in 0 ..< h {
            for x in 0 ..< w {
                let i = y * w + x
                // Hair: strands every 3 px fading out from x = 40 to 100, over a blue-grey ground.
                let strand = (y % 3 == 0) ? 1.0 : 0.35
                let a: Double = x < 40 ? 1 : max(0, 1 - Double(x - 40) / 60) * strand
                let hair = SIMD3<Double>(120, 80, 50), ground = SIMD3<Double>(90, 110, 140)
                let c = hair * a + ground * (1 - a)
                for ch in 0 ..< 3 { px[i * 4 + ch] = UInt8(c[ch].rounded()) }
                px[i * 4 + 3] = 255
                alpha[i] = UInt8((a * 255).rounded())
                // Shares that differ by channel, as matting leaves them in hair.
                shares[i * 4] = UInt8((min(a * 1.2, 1) * 255).rounded())
                shares[i * 4 + 1] = UInt8((a * 255).rounded())
                shares[i * 4 + 2] = UInt8((a * 0.7 * 255).rounded())
                // A repainted strip (columns 10–19, feathered out by 25), pointing 8 px left.
                if x >= 10 && x < 25 {
                    map[i * 4] = 128 - 8
                    map[i * 4 + 2] = x < 20 ? 255 : UInt8(255 * (25 - x) / 6)
                }
                // And a background-side strip (columns 60–69, feathered out by 74), pointing 30 px right.
                if x >= 60 && x < 75 {
                    back[i * 4] = 128 + 30
                    back[i * 4 + 2] = x < 70 ? 255 : UInt8(255 * (75 - x) / 6)
                }
            }
        }
        let picture = try XCTUnwrap(Masking.picture(rgbx: px, w: w, h: h))
        let a = try XCTUnwrap(Masking.picture(gray: alpha, w: w, h: h)), s = try XCTUnwrap(Masking.picture(rgbx: shares, w: w, h: h))
        let plainMask = MaskResult(width: w, height: h, alpha: a, shares: s, skin: nil, trimap: a, coarse: a, tier: .off, summary: "")
        let repaintMask = MaskResult(width: w, height: h, alpha: a, shares: s, skin: nil, trimap: a, coarse: a, tier: .off, summary: "",
                                     repaint: try XCTUnwrap(Masking.picture(rgbx: map, w: w, h: h)), repaintBack: try XCTUnwrap(Masking.picture(rgbx: back, w: w, h: h)))
        let source = CIImage(cgImage: picture), extent = CGRect(x: 0, y: 0, width: w, height: h)
        func bytes(_ image: CIImage) throws -> [UInt8] {
            let p = try XCTUnwrap(Imaging.pixels(image, from: extent))
            let data = try XCTUnwrap(p.dataProvider?.data) as Data
            return [UInt8](data).enumerated().filter { $0.offset % p.bytesPerRow < w * 4 }.map { $0.element }
        }
        let edited = edits(subject: 3, background: -3)
        let alpha16 = try bytes(render(plainMask, source, edited)), now = try bytes(render(repaintMask, source, edited))
        var same = 0, differ = 0, repaintedDiffer = 0, largest = 0
        var columns: [Int: Int] = [:]
        for y in 0 ..< h {
            for x in 0 ..< w {
                let i = (y * w + x) * 4
                let equal = alpha16[i ..< i + 3] == now[i ..< i + 3]
                if map[i + 2] == 0 && back[i + 2] == 0 {
                    if equal { same += 1 } else {
                        differ += 1
                        columns[x, default: 0] += 1
                        for ch in 0 ..< 3 { largest = max(largest, abs(Int(alpha16[i + ch]) - Int(now[i + ch]))) }
                    }
                } else if !equal { repaintedDiffer += 1 }
            }
        }
        print("V7.2-V w = wb = 0 under Subject +3 / Background −3 on a soft hair edge: \(same) px identical to alpha 16, \(differ) different "
            + "(largest \(largest)/255; by column \(columns.sorted { $0.key < $1.key }.map { "\($0.key):\($0.value)" }.joined(separator: " "))) · "
            + "\(repaintedDiffer) repainted px changed")
        // Diagnosis: the same two renders with float intermediates.
        let floats = CIContext(options: [.cacheIntermediates: false, .workingFormat: CIFormat.RGBAf])
        func floatBytes(_ image: CIImage) throws -> [UInt8] {
            let space = CGColorSpace(name: CGColorSpace.displayP3) ?? CGColorSpaceCreateDeviceRGB()
            let p = try XCTUnwrap(floats.createCGImage(image, from: extent, format: .RGBA8, colorSpace: space))
            let data = try XCTUnwrap(p.dataProvider?.data) as Data
            return [UInt8](data).enumerated().filter { $0.offset % p.bytesPerRow < w * 4 }.map { $0.element }
        }
        let f16 = try floatBytes(render(plainMask, source, edited)), fNow = try floatBytes(render(repaintMask, source, edited))
        var floatDiffer = 0
        for i in stride(from: 0, to: w * h * 4, by: 4) where map[i + 2] == 0 && back[i + 2] == 0 && f16[i ..< i + 3] != fNow[i ..< i + 3] { floatDiffer += 1 }
        print("V7.2-V with float intermediates: \(floatDiffer) px with w = wb = 0 differ")
        // Owner (spec v7.1, answer to default 4, then the rounding question): w = 0 renders as
        // alpha 16 does, to Core Image's rounding of its in-between pictures, at most 1/255.
        XCTAssertLessThanOrEqual(largest, 1, "pixels with w = 0 render as alpha 16 does, to 1/255")
        XCTAssertEqual(floatDiffer, 0, "with float intermediates, pixels with w = 0 render exactly as alpha 16 does")
        XCTAssertGreaterThan(repaintedDiffer, 0, "the repaint did something where w > 0")

        // No local edits: the photo, pixel for pixel, repaint or not.
        let photo = try bytes(source)
        XCTAssertEqual(try bytes(render(repaintMask, source, LocalEdits())), photo, "no local edits: the render is the photo")

        // The background side never reads C: with no subject anywhere (shares 0) and w = 1
        // everywhere, the render is the background's edit of the photo.
        var full = Repaint.blank(count: w * h)
        for i in 0 ..< w * h { full[i * 4] = 128 - 8; full[i * 4 + 2] = 255 }
        let none = try XCTUnwrap(Masking.picture(rgbx: [UInt8](repeating: 0, count: w * h * 4), w: w, h: h))
        let zeroA = try XCTUnwrap(Masking.picture(gray: [UInt8](repeating: 0, count: w * h), w: w, h: h))
        let ground = MaskResult(width: w, height: h, alpha: zeroA, shares: none, skin: nil, trimap: zeroA, coarse: zeroA, tier: .off, summary: "",
                                repaint: try XCTUnwrap(Masking.picture(rgbx: full, w: w, h: h)))
        var dark = LocalLayer()
        dark.exposure = -3
        let backgroundOnly = try bytes(Masking.adjust(source, dark))
        let groundRender = try bytes(render(ground, source, edited))
        let worst = zip(backgroundOnly, groundRender).map { abs(Int($0) - Int($1)) }.max() ?? 0
        print("V7.1-O background side with w = 1 everywhere and no subject: largest difference from the background's edit of the photo \(worst)/255")
        XCTAssertLessThanOrEqual(worst, 1, "the background side reads the photo, never C")

        // Every view renders with a repaint.
        for view in MaskView.allCases {
            for area in LocalArea.allCases {
                XCTAssertNotNil(Imaging.pixels(render(repaintMask, source, edited, view: view, area: area), from: extent), "\(view.name) view, \(area)")
            }
        }
    }
}
#endif
