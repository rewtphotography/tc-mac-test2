import Foundation

/// How far a mask's edge is refined. Each tier includes the ones before it.
public enum MatteTier: Int, CaseIterable {
    /// One colour for the subject and one for the background near each pixel. Quick; right for
    /// clean edges such as hair on a plain backdrop.
    case fast
    /// Many candidate colours gathered along rays, so several background colours behind one
    /// head of hair are told apart.
    case high
    /// Closed-form matting on top of High: every strand is solved for against its neighbours.
    case max

    public var name: String {
        switch self {
        case .fast: return "Fast"
        case .high: return "High"
        case .max: return "Max"
        }
    }
}

/// A finer mask of one head, from a second look at just that part of the photo.
public struct HeadPatch {
    public var rect: PixelRect
    public var mask: Gray

    public init(rect: PixelRect, mask: Gray) {
        self.rect = rect
        self.mask = mask
    }
}

/// The numbers the plan says to tune. Defaults are the plan's.
public struct MatteSettings {
    public var foregroundThreshold: Float = 0.97
    public var backgroundThreshold: Float = 0.03
    public var contrastLow: Float = 0.02
    public var contrastHigh: Float = 0.10
    public var guidedRadius = 4
    public var guidedEpsilon: Float = 1e-4
    public var rays = 8
    public var raySteps = 24
    public var distanceWeight: Float = 0.5
    public var costFalloff: Float = 50
    public var softPrior = 0.05
    public var hardPrior = 100.0
    public var laplacianEpsilon = 1e-7
    public var maxIterations = 300
    public var tolerance = 1e-4
    public var tileCore = 896
    public var tileApron = 64
    /// The uncertain band's width as fractions of the face's height: how far the certain
    /// subject is pulled in, and how far the certain background is pushed out.
    public var bandIn: Float = 0.02
    public var bandOut: Float = 0.06

    public init() {}
}

/// A finished mask for a whole photo.
public struct MatteOutput {
    public let w: Int
    public let h: Int
    /// How much of each pixel is subject, 0 to 255.
    public var alpha: [UInt8]
    /// For each pixel, four bytes: how much of its red, green and blue light comes from the
    /// subject (then 255). Equal to `alpha` away from edges. Blending with these instead of
    /// `alpha` keeps background colour out of hair when the two are adjusted differently.
    public var shares: [UInt8]
    /// The three-way split the refinement started from, a quarter of the photo's size:
    /// 0 background, 128 unknown, 255 subject.
    public var trimap: [UInt8]
    public let trimapW: Int
    public let trimapH: Int
    /// The part of the photo that holds every uncertain pixel.
    public var band: PixelRect
    public var unknownPixels: Int
    /// What each stage did and how long it took, for the diagnostics log.
    public var log: [String]
    /// Things that look wrong, found by the checks that run on every mask ("SEAM?", "GLOW?").
    public var warnings: [String] = []
}

/// Refines a rough subject mask into a matte with soft, strand-level edges. The rough mask
/// says what the subject is; this works out exactly where its edge lies, and only in the thin
/// band where that is uncertain, so the cost follows the length of the edge, not the size of
/// the photo. Everything here is plain arithmetic on the processor, tested on Linux.
public final class Matte {
    let photo: Photo
    let settings: MatteSettings
    let W: Int, H: Int
    let qw: Int, qh: Int

    // A quarter of the photo's size.
    var qrgb = Buf<Float>(0, 0)
    var m0q: Gray
    var triq = Buf<UInt8>(0, 0) // 0 background, 1 unknown, 2 subject
    var fq = Buf<Float>(0, 0) // subject colour near each pixel
    var bq = Buf<Float>(0, 0) // background colour near each pixel
    var coefA = Buf<Float>(0, 0) // guided upsampling of the rough mask
    var coefB = Buf<Float>(0, 0)
    var rIn: Float = 4
    var rOut: Float = 8

    // The photo's own size, over the band only.
    var band = PixelRect(x: 0, y: 0, w: 0, h: 0)
    var alpha = Buf<Float>(0, 0)
    var conf = Buf<UInt8>(0, 0)
    var fPair: Buf<UInt32>?
    var bPair: Buf<UInt32>?
    var unknownCount = 0
    var log: [String] = []
    var warnings: [String] = []
    /// The rough mask at quarter size, for the guards that keep the result near it.
    var m0qBuf = Buf<Float>(0, 0)
    /// How far each part is in focus, 1 (as sharp as the subject) to 0 (well out of focus), at
    /// quarter size. Colour arithmetic on a blurred edge only adds noise, so it is trusted less there.
    var focusQ: Buf<Float>?
    /// The contrast between subject and background colour at each band pixel, 0 to 255.
    var contrast = Buf<UInt8>(0, 0)
    /// Whether the Fast tier put each band pixel in the subject, to compare with the final answer.
    var fastHalf = Buf<UInt8>(0, 0)

    /// - Parameters:
    ///   - coarse: the rough mask, any size, covering the whole photo.
    ///   - faces: face rectangles in pixels of the photo, y down.
    ///   - patches: finer masks of each head, if a second look was taken.
    ///   - defocus: how blurred each part of the photo is (`SharpnessMap.dense`), any size.
    ///   - subjectSharpness: the blur of the subject itself, in the same units.
    public init(photo: Photo, coarse: Gray, faces: [PixelRect], patches: [HeadPatch] = [], settings: MatteSettings = MatteSettings(),
                defocus: Gray? = nil, subjectSharpness: Float? = nil) {
        self.photo = photo
        self.settings = settings
        W = photo.w; H = photo.h
        qw = (W + 3) / 4; qh = (H + 3) / 4
        m0q = coarse.resized(w: qw, h: qh)
        if let defocus = defocus, let sharp = subjectSharpness {
            let d = defocus.resized(w: qw, h: qh)
            focusQ = Buf(d.v.map { 1 - smoothstep(sharp + 1.0, sharp + 2.5, $0) })
        }
        let start = Date()
        prepare(faces: faces, patches: patches)
        log.append("setup: band \(band.w)×\(band.h), \(unknownCount) uncertain pixels, edge widths \(Int(rIn))/\(Int(rOut)) px, \(Matte.seconds(start))")
    }

    static func seconds(_ since: Date) -> String {
        String(format: "%.2f s", locale: Locale(identifier: "en_US_POSIX"), Date().timeIntervalSince(since))
    }

    @inline(__always) static func pack(_ c: SIMD3<Float>) -> UInt32 {
        let v = (c.clamped(lowerBound: SIMD3(repeating: 0), upperBound: SIMD3(repeating: 1)) * 255).rounded(.toNearestOrAwayFromZero)
        return UInt32(v.x) | (UInt32(v.y) << 8) | (UInt32(v.z) << 16)
    }

    @inline(__always) static func unpack(_ p: UInt32) -> SIMD3<Float> {
        SIMD3(Float(p & 255), Float((p >> 8) & 255), Float((p >> 16) & 255)) * (1 / 255)
    }

    /// Three channels blended from the four quarter-size pixels around a point of the photo.
    @inline(__always) func sample3(_ p: UnsafeMutablePointer<Float>, _ x: Int, _ y: Int) -> SIMD3<Float> {
        let fx = min(max((Float(x) + 0.5) * 0.25 - 0.5, 0), Float(qw - 1)), fy = min(max((Float(y) + 0.5) * 0.25 - 0.5, 0), Float(qh - 1))
        let x0 = Int(fx), y0 = Int(fy), x1 = min(x0 + 1, qw - 1), y1 = min(y0 + 1, qh - 1)
        let tx = fx - Float(x0), ty = fy - Float(y0)
        let i00 = (y0 * qw + x0) * 3, i10 = (y0 * qw + x1) * 3, i01 = (y1 * qw + x0) * 3, i11 = (y1 * qw + x1) * 3
        let a = SIMD3(p[i00], p[i00 + 1], p[i00 + 2]), b = SIMD3(p[i10], p[i10 + 1], p[i10 + 2])
        let c = SIMD3(p[i01], p[i01 + 1], p[i01 + 2]), d = SIMD3(p[i11], p[i11 + 1], p[i11 + 2])
        let top = a + (b - a) * tx, bottom = c + (d - c) * tx
        return top + (bottom - top) * ty
    }

    @inline(__always) func sample1(_ p: UnsafeMutablePointer<Float>, _ x: Int, _ y: Int) -> Float {
        let fx = min(max((Float(x) + 0.5) * 0.25 - 0.5, 0), Float(qw - 1)), fy = min(max((Float(y) + 0.5) * 0.25 - 0.5, 0), Float(qh - 1))
        let x0 = Int(fx), y0 = Int(fy), x1 = min(x0 + 1, qw - 1), y1 = min(y0 + 1, qh - 1)
        let tx = fx - Float(x0), ty = fy - Float(y0)
        let top = p[y0 * qw + x0] + (p[y0 * qw + x1] - p[y0 * qw + x0]) * tx
        let bottom = p[y1 * qw + x0] + (p[y1 * qw + x1] - p[y1 * qw + x0]) * tx
        return top + (bottom - top) * ty
    }

    // MARK: Setup, at a quarter of the size

    private func prepare(faces: [PixelRect], patches: [HeadPatch]) {
        let W = self.W, H = self.H, qw = self.qw, qh = self.qh
        // The photo at a quarter size: each pixel the mean of a 4×4 block.
        let q = Buf<Float>(qw * qh * 3, 0)
        let src = photo.p, rowBytes = photo.rowBytes
        parallelRows(qh) { rows in
            for qy in rows {
                for qx in 0 ..< qw {
                    var s = SIMD3<Float>(repeating: 0)
                    var n: Float = 0
                    for y in (qy * 4) ..< min(qy * 4 + 4, H) {
                        for x in (qx * 4) ..< min(qx * 4 + 4, W) {
                            s += rgbAt(src, rowBytes, x, y)
                            n += 1
                        }
                    }
                    s /= max(n, 1)
                    let i = (qy * qw + qx) * 3
                    q.p[i] = s.x; q.p[i + 1] = s.y; q.p[i + 2] = s.z
                }
            }
        }
        qrgb = q

        // Edge widths follow the size of the largest face; without one, the size of the photo.
        if let faceHeight = faces.map({ Float($0.h) }).max(), faceHeight > 0 {
            rIn = min(max(settings.bandIn * faceHeight, 4), 64)
            rOut = min(max(settings.bandOut * faceHeight, 8), 160)
        } else {
            let unit = 0.3 * Float(max(W, H))
            rIn = min(max(settings.bandIn * unit, 4), 64)
            rOut = min(max(settings.bandOut * unit, 8), 160)
        }

        // The hair zone: around each head, outside the oval of the face. Curly hair masks tend
        // to fill the gaps between curls, so the certain-subject region is pulled in further there.
        // It fades in over a few pixels: a hard edge to the zone would show as a straight line in the mask.
        var hair = [Float](repeating: 0, count: qw * qh)
        for f in faces {
            let fw = Float(f.w), fh = Float(f.h)
            let cx = Float(f.x) + fw / 2, cy = Float(f.y) + fh / 2 - 0.25 * fh
            let head = PixelRect(x: Int(cx - 1.3 * fw), y: Int(cy - 1.5 * fh), w: Int(2.6 * fw), h: Int(3.0 * fh)).clamped(w: W, h: H)
            let ovalY = Float(f.y) + 0.325 * fh, a = fw / 2, b = 1.35 * fh / 2
            if head.isEmpty { continue }
            for qy in (head.y / 4) ..< min((head.maxY + 3) / 4, qh) {
                for qx in (head.x / 4) ..< min((head.maxX + 3) / 4, qw) {
                    let px = Float(qx) * 4 + 2, py = Float(qy) * 4 + 2
                    let dx = (px - (Float(f.x) + fw / 2)) / a, dy = (py - ovalY) / b
                    let outsideOval = min(max(((dx * dx + dy * dy).squareRoot() - 1) / 0.2, 0), 1)
                    let fromEdge = min(min(px - Float(head.x), Float(head.maxX) - px), min(py - Float(head.y), Float(head.maxY) - py))
                    let insideHead = min(max(fromEdge / max(0.15 * fw, 8), 0), 1)
                    hair[qy * qw + qx] = max(hair[qy * qw + qx], outsideOval * insideHead)
                }
            }
        }

        classify(hair)
        if !patches.isEmpty {
            // A second, closer look at each head replaces the rough mask where it was uncertain,
            // fading out towards the edge of the patch.
            for patch in patches where !patch.rect.isEmpty {
                let r = patch.rect
                let feather = max(0.1 * Float(min(r.w, r.h)), 1)
                for qy in max(r.y / 4, 0) ..< min((r.maxY + 3) / 4, qh) {
                    for qx in max(r.x / 4, 0) ..< min((r.maxX + 3) / 4, qw) where triq.p[qy * qw + qx] == 1 {
                        let x = Float(qx) * 4 + 2, y = Float(qy) * 4 + 2
                        let edge = min(min(x - Float(r.x), Float(r.maxX) - x), min(y - Float(r.y), Float(r.maxY) - y))
                        if edge <= 0 { continue }
                        let t = min(edge / feather, 1)
                        let fine = patch.mask.sample((x - Float(r.x)) * Float(patch.mask.w) / Float(r.w), (y - Float(r.y)) * Float(patch.mask.h) / Float(r.h))
                        m0q.v[qy * qw + qx] += (fine - m0q.v[qy * qw + qx]) * t
                    }
                }
            }
            classify(hair)
        }

        // The part of the photo that holds every uncertain pixel.
        var x0 = qw, y0 = qh, x1 = -1, y1 = -1
        unknownCount = 0
        for qy in 0 ..< qh {
            for qx in 0 ..< qw where triq.p[qy * qw + qx] == 1 {
                x0 = min(x0, qx); x1 = max(x1, qx); y0 = min(y0, qy); y1 = max(y1, qy)
                unknownCount += 1
            }
        }
        unknownCount *= 16
        if x1 >= 0 {
            band = PixelRect(x: x0 * 4, y: y0 * 4, w: (x1 - x0 + 1) * 4, h: (y1 - y0 + 1) * 4).clamped(w: W, h: H)
        }

        fq = Buf(pushPull(weightFor: 2))
        bq = Buf(pushPull(weightFor: 0))
        m0qBuf = Buf(m0q.v)

        // The rough mask, sharpened against the photo: within each small neighbourhood the mask
        // is fitted as a straight-line function of brightness, and those two numbers are then
        // applied to the full-size photo. Edges in the photo become edges in the mask.
        let n = qw * qh
        var g = [Float](repeating: 0, count: n), gg = [Float](repeating: 0, count: n), gp = [Float](repeating: 0, count: n)
        var p = m0q.v
        for i in 0 ..< n {
            let l = luma(SIMD3(q.p[i * 3], q.p[i * 3 + 1], q.p[i * 3 + 2]))
            g[i] = l; gg[i] = l * l; gp[i] = l * p[i]
        }
        PlaneMath.boxBlur(&g, w: qw, h: qh, radius: 2)
        PlaneMath.boxBlur(&p, w: qw, h: qh, radius: 2)
        PlaneMath.boxBlur(&gg, w: qw, h: qh, radius: 2)
        PlaneMath.boxBlur(&gp, w: qw, h: qh, radius: 2)
        var ca = [Float](repeating: 0, count: n), cb = [Float](repeating: 0, count: n)
        for i in 0 ..< n {
            let a = (gp[i] - g[i] * p[i]) / (gg[i] - g[i] * g[i] + 1e-3)
            ca[i] = a
            cb[i] = p[i] - a * g[i]
        }
        PlaneMath.boxBlur(&ca, w: qw, h: qh, radius: 2)
        PlaneMath.boxBlur(&cb, w: qw, h: qh, radius: 2)
        coefA = Buf(ca)
        coefB = Buf(cb)
    }

    /// Splits the quarter-size mask three ways: certainly subject, certainly background, unknown.
    private func classify(_ hair: [Float]) {
        let narrow = max(Int((rIn / 4).rounded()), 1), wide = max(Int((rOut / 4).rounded()), 2)
        let eroded = PlaneMath.extremum(m0q, radius: narrow, smallest: true)
        let erodedMore = PlaneMath.extremum(m0q, radius: narrow * 2, smallest: true)
        let dilated = PlaneMath.extremum(m0q, radius: wide, smallest: false)
        let t = Buf<UInt8>(qw * qh, 1)
        for i in 0 ..< qw * qh {
            if eroded.v[i] + (erodedMore.v[i] - eroded.v[i]) * hair[i] >= settings.foregroundThreshold {
                t.p[i] = 2
            } else if dilated.v[i] <= settings.backgroundThreshold {
                t.p[i] = 0
            }
        }
        triq = t
    }

    /// The colour of the nearest certain pixels of one kind, spread smoothly across the gaps
    /// between them: averaged down level by level, then filled back in from coarse to fine.
    private func pushPull(weightFor kind: UInt8) -> [Float] {
        struct Level { var w: Int, h: Int, c: [Float], wt: [Float] }
        var levels: [Level] = []
        var top = Level(w: qw, h: qh, c: [Float](repeating: 0, count: qw * qh * 3), wt: [Float](repeating: 0, count: qw * qh))
        for i in 0 ..< qw * qh where triq.p[i] == kind {
            top.wt[i] = 1
            top.c[i * 3] = qrgb.p[i * 3]; top.c[i * 3 + 1] = qrgb.p[i * 3 + 1]; top.c[i * 3 + 2] = qrgb.p[i * 3 + 2]
        }
        levels.append(top)
        while max(levels.last!.w, levels.last!.h) > 16 {
            let fine = levels.last!
            let w = (fine.w + 1) / 2, h = (fine.h + 1) / 2
            var coarse = Level(w: w, h: h, c: [Float](repeating: 0, count: w * h * 3), wt: [Float](repeating: 0, count: w * h))
            for y in 0 ..< h {
                for x in 0 ..< w {
                    var s = SIMD3<Float>(repeating: 0)
                    var ws: Float = 0
                    for yy in (y * 2) ..< min(y * 2 + 2, fine.h) {
                        for xx in (x * 2) ..< min(x * 2 + 2, fine.w) {
                            let i = yy * fine.w + xx
                            s += SIMD3(fine.c[i * 3], fine.c[i * 3 + 1], fine.c[i * 3 + 2])
                            ws += fine.wt[i]
                        }
                    }
                    // Colours are stored already multiplied by their weight; keep the weight at most 1.
                    let i = y * w + x
                    let k = ws > 1 ? 1 / ws : 1
                    coarse.c[i * 3] = s.x * k; coarse.c[i * 3 + 1] = s.y * k; coarse.c[i * 3 + 2] = s.z * k
                    coarse.wt[i] = min(ws, 1)
                }
            }
            levels.append(coarse)
        }
        for l in stride(from: levels.count - 2, through: 0, by: -1) {
            let coarse = levels[l + 1]
            let cw = Gray(w: coarse.w, h: coarse.h, v: coarse.wt)
            let planes = (0 ..< 3).map { ch in Gray(w: coarse.w, h: coarse.h, v: (0 ..< coarse.w * coarse.h).map { coarse.c[$0 * 3 + ch] }) }
            let lw = levels[l].w, lh = levels[l].h
            let kx = Float(coarse.w) / Float(lw), ky = Float(coarse.h) / Float(lh)
            var c = levels[l].c, wt = levels[l].wt
            for y in 0 ..< lh {
                for x in 0 ..< lw {
                    let i = y * lw + x
                    let gap = 1 - wt[i]
                    if gap <= 0 { continue }
                    let sx = (Float(x) + 0.5) * kx, sy = (Float(y) + 0.5) * ky
                    for ch in 0 ..< 3 { c[i * 3 + ch] += gap * planes[ch].sample(sx, sy) }
                    wt[i] += gap * cw.sample(sx, sy)
                }
            }
            levels[l].c = c
            levels[l].wt = wt
        }
        var out = levels[0].c
        for i in 0 ..< qw * qh {
            let k = 1 / max(levels[0].wt[i], 1e-4)
            out[i * 3] *= k; out[i * 3 + 1] *= k; out[i * 3 + 2] *= k
        }
        return out
    }

    // MARK: Running the tiers

    /// Runs the refinement up to `tier`. `progress` is told what is being done; `cancelled` is
    /// asked between stages and tiles, and stops the work with what has been done so far.
    public func run(tier: MatteTier, progress: (String) -> Void = { _ in }, cancelled: () -> Bool = { false }) -> MatteOutput {
        if !band.isEmpty {
            var start = Date()
            progress("Fast")
            fast()
            log.append("fast: \(Matte.seconds(start))")
            if tier.rawValue >= MatteTier.high.rawValue && !cancelled() {
                start = Date()
                progress("High")
                high()
                log.append("high: \(Matte.seconds(start))")
            }
            if tier == .max && !cancelled() {
                start = Date()
                progress("Max")
                let note = closedForm(progress: progress, cancelled: cancelled)
                log.append("max: \(note), \(Matte.seconds(start))")
            }
        }
        let start = Date()
        var result = finish()
        log.append("finish: \(Matte.seconds(start))")
        result.log = log
        result.warnings = warnings
        return result
    }

    /// Whether each row of the band holds any uncertain pixel.
    func rowsWithUnknown() -> [Bool] {
        var qrow = [Bool](repeating: false, count: qh)
        for qy in 0 ..< qh {
            for qx in 0 ..< qw where triq.p[qy * qw + qx] == 1 {
                qrow[qy] = true
                break
            }
        }
        return (0 ..< band.h).map { qrow[(band.y + $0) >> 2] }
    }

    // MARK: Fast

    /// For each uncertain pixel: where its colour sits on the line between the nearby subject
    /// colour and the nearby background colour. Where those two colours are too alike to tell
    /// apart, the rough mask is kept instead.
    private func fast() {
        let band = self.band, bw = band.w, bh = band.h, qw = self.qw
        let a = Buf<Float>(bw * bh, 0), cf = Buf<UInt8>(bw * bh, 0), ct = Buf<UInt8>(bw * bh, 0)
        let c0 = settings.contrastLow, c1 = settings.contrastHigh
        let src = photo.p, rowBytes = photo.rowBytes, tq = triq.p
        let fp = fq.p, bp = bq.p, ca = coefA.p, cb = coefB.p, focus = focusQ?.p
        parallelRows(bh) { rows in
            for by in rows {
                let y = band.y + by
                for bx in 0 ..< bw {
                    let x = band.x + bx
                    let t = tq[(y >> 2) * qw + (x >> 2)]
                    if t != 1 {
                        a.p[by * bw + bx] = t == 2 ? 1 : 0
                        continue
                    }
                    let I = rgbAt(src, rowBytes, x, y)
                    let F = sample3(fp, x, y), B = sample3(bp, x, y)
                    let base = min(max(sample1(ca, x, y) * luma(I) + sample1(cb, x, y), 0), 1)
                    let d = F - B
                    let dd = dot3(d, d)
                    let al = min(max(dot3(I - B, d) / (dd + 1e-6), 0), 1)
                    // Contrast between the two colours, whatever the exposure.
                    let cn = dd / (dot3(F, F) + dot3(B, B) + 1e-6)
                    var c = smoothstep(c0, c1, cn)
                    // Blown highlights have lost their colour; trust them less.
                    if max(I.max(), B.max()) >= 0.985 { c *= 0.5 }
                    ct.p[by * bw + bx] = UInt8(c * 255)
                    // Out of focus, the true edge is a blur; stay with the rough mask there.
                    if let focus = focus { c *= sample1(focus, x, y) }
                    a.p[by * bw + bx] = base + (al - base) * c
                    cf.p[by * bw + bx] = UInt8(c * 255)
                }
            }
        }
        alpha = a
        conf = cf
        contrast = ct
        guidedCleanup(alpha)
        let half = Buf<UInt8>(bw * bh, 0)
        for i in 0 ..< bw * bh where a.p[i] >= 0.5 { half.p[i] = 1 }
        fastHalf = half
    }

    /// Smooths a mask along the photo's own edges and free of its grain: within each small
    /// window the mask is refitted as a straight-line function of brightness (the guided
    /// filter). Only uncertain pixels are changed.
    func guidedCleanup(_ a: Buf<Float>) {
        let band = self.band, bw = band.w, bh = band.h, qw = self.qw
        let r = settings.guidedRadius, eps = settings.guidedEpsilon
        let has = rowsWithUnknown()
        let stripRows = 128, apron = 2 * r
        let strips = (bh + stripRows - 1) / stripRows
        let source = Buf(a.array)
        let src = photo.p, rowBytes = photo.rowBytes, tq = triq.p
        parallel(strips) { s in
            let y0 = s * stripRows, y1 = min(y0 + stripRows, bh)
            if !has[y0 ..< y1].contains(true) { return }
            let ey0 = max(y0 - apron, 0), ey1 = min(y1 + apron, bh)
            let eh = ey1 - ey0, n = bw * eh
            var g = [Float](repeating: 0, count: n), p = [Float](repeating: 0, count: n)
            var gg = [Float](repeating: 0, count: n), gp = [Float](repeating: 0, count: n)
            for yy in 0 ..< eh {
                for x in 0 ..< bw {
                    let l = luma(rgbAt(src, rowBytes, band.x + x, band.y + ey0 + yy))
                    let v = source.p[(ey0 + yy) * bw + x]
                    let i = yy * bw + x
                    g[i] = l; p[i] = v; gg[i] = l * l; gp[i] = l * v
                }
            }
            let lumaKept = g
            PlaneMath.boxBlur(&g, w: bw, h: eh, radius: r)
            PlaneMath.boxBlur(&p, w: bw, h: eh, radius: r)
            PlaneMath.boxBlur(&gg, w: bw, h: eh, radius: r)
            PlaneMath.boxBlur(&gp, w: bw, h: eh, radius: r)
            for i in 0 ..< n {
                let k = (gp[i] - g[i] * p[i]) / (gg[i] - g[i] * g[i] + eps)
                gp[i] = p[i] - k * g[i] // the offset
                gg[i] = k // the slope
            }
            PlaneMath.boxBlur(&gg, w: bw, h: eh, radius: r)
            PlaneMath.boxBlur(&gp, w: bw, h: eh, radius: r)
            for y in y0 ..< y1 {
                for x in 0 ..< bw where tq[((band.y + y) >> 2) * qw + ((band.x + x) >> 2)] == 1 {
                    let i = (y - ey0) * bw + x
                    a.p[y * bw + x] = min(max(gg[i] * lumaKept[i] + gp[i], 0), 1)
                }
            }
        }
    }

    // MARK: High

    /// Gathers candidate subject and background colours along rays from each uncertain pixel
    /// and keeps the pair that best explains the pixel. Rays in different directions reach
    /// different things, so a backdrop and a decoration in front of it are both found, and
    /// each strand is matched with the one actually behind it.
    private func high() {
        let band = self.band, bw = band.w, bh = band.h, qw = self.qw, qh = self.qh, W = self.W, H = self.H
        var isF = [Bool](repeating: false, count: qw * qh), isB = [Bool](repeating: false, count: qw * qh)
        for i in 0 ..< qw * qh {
            isF[i] = triq.p[i] == 2
            isB[i] = triq.p[i] == 0
        }
        let distF = Buf(PlaneMath.distance(to: isF, w: qw, h: qh)), distB = Buf(PlaneMath.distance(to: isB, w: qw, h: qh))
        let f1 = Buf<UInt32>(bw * bh, 0), b1 = Buf<UInt32>(bw * bh, 0)
        let K = min(max(settings.rays, 1), 8), raySteps = settings.raySteps
        let maxLen = 2.5 * rOut
        let wd = settings.distanceWeight
        // Sixteen rotations of the ray pattern, so neighbouring pixels probe different directions.
        let dirs = Buf<SIMD2<Float>>((0 ..< 16 * K).map { i in
            let rot = Float(i / K) / 16 * (2 * Float.pi / Float(K))
            let th = rot + Float(i % K) * 2 * Float.pi / Float(K)
            return SIMD2(cos(th), sin(th))
        })
        let src = photo.p, rowBytes = photo.rowBytes, tq = triq.p, fp = fq.p, bp = bq.p

        /// Walks from `origin` along `dir` to the first certain pixel of one kind. Each step is
        /// the distance to the nearest such pixel, which can never jump over one; distances
        /// are in quarter-size pixels, so a block's worth is held back.
        @inline(__always) func trace(_ origin: SIMD2<Float>, _ dir: SIMD2<Float>, _ kind: UInt8, _ dist: UnsafeMutablePointer<Float>) -> (SIMD3<Float>, Float)? {
            var t: Float = 0
            var steps = 0
            while steps < raySteps && t < maxLen {
                let q = origin + dir * t
                if q.x < 0 || q.y < 0 { return nil }
                let qx = Int(q.x), qy = Int(q.y)
                if qx >= W || qy >= H { return nil }
                let cell = (qy >> 2) * qw + (qx >> 2)
                if tq[cell] == kind { return (rgbAt(src, rowBytes, qx, qy), t) }
                t += max(4 * (dist[cell] - 1.5), 1)
                steps += 1
            }
            return nil
        }

        parallelRows(bh) { rows in
            var Fc = [SIMD3<Float>](repeating: SIMD3(repeating: 0), count: 8), Bc = Fc
            var dF = [Float](repeating: 0, count: 8), dB = dF
            for by in rows {
                let y = band.y + by
                for bx in 0 ..< bw {
                    let x = band.x + bx
                    if tq[(y >> 2) * qw + (x >> 2)] != 1 { continue }
                    let Ip = rgbAt(src, rowBytes, x, y)
                    let origin = SIMD2(Float(x) + 0.5, Float(y) + 0.5)
                    var nF = 0, nB = 0
                    let first = ((x & 3) + 4 * (y & 3)) * K
                    for k in 0 ..< K {
                        let dir = dirs.p[first + k]
                        if let (c, t) = trace(origin, dir, 2, distF.p) { Fc[nF] = c; dF[nF] = t; nF += 1 }
                        if let (c, t) = trace(origin, dir, 0, distB.p) { Bc[nB] = c; dB[nB] = t; nB += 1 }
                    }
                    // No certain pixel in reach: fall back on the smooth local colours.
                    if nF == 0 { Fc[0] = sample3(fp, x, y); dF[0] = maxLen; nF = 1 }
                    if nB == 0 { Bc[0] = sample3(bp, x, y); dB[0] = maxLen; nB = 1 }
                    var best = Float.infinity
                    var bestF = Fc[0], bestB = Bc[0]
                    for i in 0 ..< nF {
                        for j in 0 ..< nB {
                            let c = Matte.pairCost(Ip, Fc[i], Bc[j]).cost * (1 + wd * (dF[i] + dB[j]) / maxLen)
                            if c < best { best = c; bestF = Fc[i]; bestB = Bc[j] }
                        }
                    }
                    f1.p[by * bw + bx] = Matte.pack(bestF)
                    b1.p[by * bw + bx] = Matte.pack(bestB)
                }
            }
        }

        // Each pixel then tries its neighbours' pairs against its own colour and averages the
        // best three, which removes the speckle of pixel-by-pixel choices.
        let alphaHigh = Buf(alpha.array)
        let confHigh = Buf<UInt8>(bw * bh, 0)
        let f2 = Buf<UInt32>(bw * bh, 0), b2 = Buf<UInt32>(bw * bh, 0)
        let c0 = settings.contrastLow, c1 = settings.contrastHigh, falloff = settings.costFalloff
        let focus = focusQ?.p
        parallelRows(bh) { rows in
            for by in rows {
                let y = band.y + by
                for bx in 0 ..< bw {
                    let x = band.x + bx
                    if tq[(y >> 2) * qw + (x >> 2)] != 1 { continue }
                    let Ip = rgbAt(src, rowBytes, x, y)
                    var c0b = Float.infinity, c1b = Float.infinity, c2b = Float.infinity
                    var j0 = -1, j1 = -1, j2 = -1
                    for ny in max(by - 2, 0) ... min(by + 2, bh - 1) {
                        for nx in max(bx - 2, 0) ... min(bx + 2, bw - 1) {
                            if tq[((band.y + ny) >> 2) * qw + ((band.x + nx) >> 2)] != 1 { continue }
                            let j = ny * bw + nx
                            let c = Matte.pairCost(Ip, Matte.unpack(f1.p[j]), Matte.unpack(b1.p[j])).cost
                            if c < c0b {
                                c2b = c1b; j2 = j1; c1b = c0b; j1 = j0; c0b = c; j0 = j
                            } else if c < c1b {
                                c2b = c1b; j2 = j1; c1b = c; j1 = j
                            } else if c < c2b {
                                c2b = c; j2 = j
                            }
                        }
                    }
                    var F = SIMD3<Float>(repeating: 0), B = F
                    var n: Float = 0
                    if j0 >= 0 { F += Matte.unpack(f1.p[j0]); B += Matte.unpack(b1.p[j0]); n += 1 }
                    if j1 >= 0 { F += Matte.unpack(f1.p[j1]); B += Matte.unpack(b1.p[j1]); n += 1 }
                    if j2 >= 0 { F += Matte.unpack(f1.p[j2]); B += Matte.unpack(b1.p[j2]); n += 1 }
                    F /= max(n, 1); B /= max(n, 1)
                    let fit = Matte.pairCost(Ip, F, B)
                    let d = F - B
                    let cn = dot3(d, d) / (dot3(F, F) + dot3(B, B) + 1e-6)
                    let i = by * bw + bx
                    alphaHigh.p[i] = fit.alpha
                    var trust = exp(-falloff * fit.cost) * smoothstep(c0, c1, cn)
                    if let focus = focus { trust *= sample1(focus, x, y) }
                    confHigh.p[i] = UInt8(min(max(trust, 0), 1) * 255)
                    f2.p[i] = Matte.pack(F)
                    b2.p[i] = Matte.pack(B)
                }
            }
        }
        fPair = f2
        bPair = b2
        guidedCleanup(alphaHigh)
        // Take the new answer as far as it can be trusted; elsewhere keep the Fast one.
        let a = alpha.p, cf = conf.p
        var buckets = [Int](repeating: 0, count: 5), counted = 0
        for by in 0 ..< bh {
            for bx in 0 ..< bw where tq[((band.y + by) >> 2) * qw + ((band.x + bx) >> 2)] == 1 {
                let i = by * bw + bx
                buckets[min(Int(confHigh.p[i]) * 5 / 256, 4)] += 1
                counted += 1
                if confHigh.p[i] > 0 {
                    a[i] += (alphaHigh.p[i] - a[i]) * (Float(confHigh.p[i]) / 255)
                    cf[i] = max(cf[i], confHigh.p[i])
                }
            }
        }
        let names = ["0–.2", ".2–.4", ".4–.6", ".6–.8", ".8–1"]
        log.append("high trust " + zip(names, buckets).map { "\($0):\(Matte.percent($1, counted))" }.joined(separator: " "))
    }

    static func percent(_ part: Int, _ whole: Int) -> String { "\(whole > 0 ? Int((100 * Double(part) / Double(whole)).rounded()) : 0)%" }

    /// How well a subject colour and a background colour explain a pixel: the mix of the two
    /// that comes closest, and how far off even that is, relative to how different they are.
    @inline(__always) static func pairCost(_ I: SIMD3<Float>, _ F: SIMD3<Float>, _ B: SIMD3<Float>) -> (alpha: Float, cost: Float) {
        let d = F - B
        let dd = dot3(d, d)
        let a = min(max(dot3(I - B, d) / (dd + 1e-6), 0), 1)
        let r = I - (F * a + B * (1 - a))
        return (a, dot3(r, r) / (dd + 1e-6))
    }

    // MARK: Finish

    /// 8-bit display values to linear light, near enough for a ratio.
    static let toLinear = Buf<Float>((0 ..< 256).map { pow(Float($0) / 255, 2.2) })

    /// What the checks on a finished mask count, over the uncertain band.
    struct BandStats {
        var n = 0, zero = 0, low = 0, mid = 0, high = 0, one = 0
        var background = 0, backgroundMid = 0
        var heldUp = 0, heldDown = 0, blurred = 0
        var both = 0, either = 0

        mutating func add(_ o: BandStats) {
            n += o.n; zero += o.zero; low += o.low; mid += o.mid; high += o.high; one += o.one
            background += o.background; backgroundMid += o.backgroundMid
            heldUp += o.heldUp; heldDown += o.heldDown; blurred += o.blurred
            both += o.both; either += o.either
        }
    }

    /// Writes the mask out for the whole photo, with the per-colour shares.
    private func finish() -> MatteOutput {
        let W = self.W, H = self.H, qw = self.qw, band = self.band, bw = band.w
        let alpha8 = Buf<UInt8>(W * H, 0)
        let shares = Buf<UInt8>(W * H * 4, 255)
        let haveBand = !band.isEmpty && alpha.count > 0
        let src = photo.p, rowBytes = photo.rowBytes, tq = triq.p, fp = fq.p, bp = bq.p
        let a = alpha.p, f = fPair?.p, b = bPair?.p, lin = Matte.toLinear.p
        let m0 = m0qBuf.p, ct = contrast.p, focus = focusQ?.p, fastHalf = self.fastHalf.p
        let lock = NSLock()
        var stats = BandStats()
        parallelRows(H) { rows in
            var local = BandStats()
            for y in rows {
                for x in 0 ..< W {
                    let t = tq[(y >> 2) * qw + (x >> 2)]
                    var a8: UInt8 = t == 2 ? 255 : 0
                    var s = SIMD3<Float>(repeating: t == 2 ? 1 : 0)
                    if t == 1 && haveBand && band.contains(x, y) {
                        let i = (y - band.y) * bw + (x - band.x)
                        // Written so that a value that isn't a number at all comes out as 0.
                        var al: Float = a[i] >= 0 ? min(a[i], 1) : 0
                        // The guards. Where the rough mask was sure, the answer may only stray
                        // from it as far as the colours there can be told apart; and out of
                        // focus, the background may not turn into subject at all.
                        let rough = sample1(m0, x, y)
                        let reach = 0.3 + 0.7 * Float(ct[i]) / 255
                        let sharp = focus.map { sample1($0, x, y) } ?? 1
                        if rough >= 0.9, al < rough - reach {
                            al = rough - reach
                            local.heldUp += 1
                        } else if rough <= 0.1, al > rough + reach * sharp {
                            al = rough + reach * sharp
                            local.heldDown += 1
                        }
                        local.n += 1
                        if sharp < 0.5 { local.blurred += 1 }
                        if al <= 0.002 { local.zero += 1 } else if al < 0.2 { local.low += 1 } else if al <= 0.8 { local.mid += 1 }
                        else if al < 0.998 { local.high += 1 } else { local.one += 1 }
                        if rough <= 0.1 {
                            local.background += 1
                            if al >= 0.2 && al <= 0.8 { local.backgroundMid += 1 }
                        }
                        let now = al >= 0.5, before = fastHalf[i] == 1
                        if now && before { local.both += 1 }
                        if now || before { local.either += 1 }
                        a8 = UInt8((al * 255).rounded())
                        s = SIMD3(repeating: al)
                        if al > 0.004 && al < 0.996 {
                            // The subject and background colours behind this pixel, nudged so that
                            // mixed by its alpha they give exactly the pixel's colour.
                            let I = rgbAt(src, rowBytes, x, y)
                            var F = f != nil ? Matte.unpack(f![i]) : sample3(fp, x, y)
                            var B = b != nil ? Matte.unpack(b![i]) : sample3(bp, x, y)
                            let e = (I - (F * al + B * (1 - al))) / (al * al + (1 - al) * (1 - al) + 0.05)
                            F = (F + e * al).clamped(lowerBound: SIMD3(repeating: 0), upperBound: SIMD3(repeating: 1))
                            B = (B + e * (1 - al)).clamped(lowerBound: SIMD3(repeating: 0), upperBound: SIMD3(repeating: 1))
                            // In linear light, the fraction of each colour that is the subject's.
                            for ch in 0 ..< 3 {
                                let fl = al * lin[Int(F[ch] * 255)], bl = (1 - al) * lin[Int(B[ch] * 255)]
                                s[ch] = fl + bl > 1e-5 ? fl / (fl + bl) : al
                            }
                        }
                    }
                    alpha8.p[y * W + x] = a8
                    let o = (y * W + x) * 4
                    shares.p[o] = UInt8((s.x * 255).rounded())
                    shares.p[o + 1] = UInt8((s.y * 255).rounded())
                    shares.p[o + 2] = UInt8((s.z * 255).rounded())
                }
            }
            lock.lock()
            stats.add(local)
            lock.unlock()
        }
        if stats.n > 0 {
            let p = { (v: Int) in Matte.percent(v, stats.n) }
            let glow = stats.background > 0 ? 100 * Double(stats.backgroundMid) / Double(stats.background) : 0
            let flagged = glow > 5
            if flagged { warnings.append("GLOW?") }
            log.append("band α 0:\(p(stats.zero)) · low:\(p(stats.low)) · mid:\(p(stats.mid)) · high:\(p(stats.high)) · 1:\(p(stats.one))"
                + " · mid-in-confident-bg \(String(format: "%.1f", locale: Locale(identifier: "en_US_POSIX"), glow))%\(flagged ? " GLOW?" : "")")
            let agreement = stats.either > 0 ? Double(stats.both) / Double(stats.either) : 1
            log.append("guards: subject \(stats.heldUp) px · background \(stats.heldDown) px · out-of-focus \(p(stats.blurred)) of band"
                + " · fast↔final IoU \(String(format: "%.3f", locale: Locale(identifier: "en_US_POSIX"), agreement))")
        }
        var tri8 = [UInt8](repeating: 0, count: qw * qh)
        for i in 0 ..< qw * qh { tri8[i] = tq[i] == 2 ? 255 : (tq[i] == 1 ? 128 : 0) }
        return MatteOutput(w: W, h: H, alpha: alpha8.array, shares: shares.array, trimap: tri8,
                           trimapW: qw, trimapH: qh, band: band, unknownPixels: unknownCount, log: [], warnings: warnings)
    }
}
