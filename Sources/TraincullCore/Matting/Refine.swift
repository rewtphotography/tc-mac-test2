import Foundation

/// A brush stroke on the photo: the points the pointer passed through, in pixels of the photo
/// with y down, and the brush's radius.
public struct RefineStroke: Equatable {
    public var points: [SIMD2<Float>]
    public var radius: Float

    public init(points: [SIMD2<Float>], radius: Float) {
        self.points = points
        self.radius = radius
    }
}

/// How the Clean Edge brush decides (masking spec v5, 2.4).
public struct CleanSettings: Equatable {
    /// How far the brush may move the mask from where it was, 0 to 1.
    public var strength: Float = 1
    /// Tighter (above 0) pulls the edge in towards the subject; looser (below 0) lets it out. −1 to 1.
    public var tightness: Float = 0
    /// What sharpness and colour each count for in the decision.
    public var sharpnessWeight: Float = 0.25
    public var colourWeight: Float = 0.75
    /// Half the width of the step from background to subject on the score, 0 to 1.
    public var step: Float = 0.15
    /// How far from the edge that is there the brush may decide anything, in pixels at 33
    /// megapixels (it scales with the photo; never under 3). Beyond that the mask stands:
    /// a bokeh highlight the colour of skin, a finger's width from a finger, is not the finger.
    public var reach: Float = 5
    /// How much surer the brush must be to add a pixel to the mask than to take one off, on the score.
    public var growBar: Float = 0.25

    public init() {}
}

/// The three refine tools' arithmetic (masking spec v5, section 2). Every tool works on a
/// patch of the photo: it decides a new mask inside its box or stroke, hands that to the same
/// edge engine the automatic mask uses (so the colour shares and the colour guard apply), and
/// the result is laid back into the photo's mask through the box's or stroke's own soft edge.
public enum Refine {
    // MARK: Where a tool acts

    /// The rectangle a stroke covers, inside a photo `w` by `h`.
    public static func bounds(of stroke: RefineStroke, w: Int, h: Int) -> PixelRect {
        guard let first = stroke.points.first else { return PixelRect(x: 0, y: 0, w: 0, h: 0) }
        var x0 = first.x, x1 = first.x, y0 = first.y, y1 = first.y
        for p in stroke.points {
            x0 = min(x0, p.x); x1 = max(x1, p.x); y0 = min(y0, p.y); y1 = max(y1, p.y)
        }
        let r = stroke.radius + 1
        return PixelRect(x: Int((x0 - r).rounded(.down)), y: Int((y0 - r).rounded(.down)),
                         w: Int((x1 - x0 + 2 * r).rounded(.up)), h: Int((y1 - y0 + 2 * r).rounded(.up))).clamped(w: w, h: h)
    }

    /// The patch a tool works on: its area and some of the photo around it, for the edge
    /// engine to take colours from. Starts on a multiple of four so the engine's quarter-size
    /// working stays in step.
    public static func patch(around area: PixelRect, margin: Int, w: Int, h: Int) -> PixelRect {
        let x0 = max((area.x - margin) / 4 * 4, 0), y0 = max((area.y - margin) / 4 * 4, 0)
        let x1 = min(area.maxX + margin, w), y1 = min(area.maxY + margin, h)
        return PixelRect(x: x0, y: y0, w: max(x1 - x0, 0), h: max(y1 - y0, 0))
    }

    /// 1 inside a box and 0 outside, fading over `feather` pixels inside its border. In the
    /// pixels of `patch`.
    public static func weight(box: PixelRect, in patch: PixelRect, feather: Float) -> Gray {
        var g = Gray(w: patch.w, h: patch.h)
        let f = max(feather, 1)
        for y in max(box.y, patch.y) ..< min(box.maxY, patch.maxY) {
            for x in max(box.x, patch.x) ..< min(box.maxX, patch.maxX) {
                let d = Float(min(min(x - box.x, box.maxX - 1 - x), min(y - box.y, box.maxY - 1 - y))) + 0.5
                g.v[(y - patch.y) * patch.w + (x - patch.x)] = min(d / f, 1)
            }
        }
        return g
    }

    /// 1 under a stroke and 0 away from it, fading over the outer part of the brush. In the
    /// pixels of `patch`.
    public static func weight(stroke: RefineStroke, in patch: PixelRect) -> Gray {
        var g = Gray(w: patch.w, h: patch.h)
        let r = max(stroke.radius, 1), soft = max(min(0.25 * r, 12), 1.5)
        let pts = stroke.points
        if pts.isEmpty { return g }
        g.v.withUnsafeMutableBufferPointer { out in
            for i in 0 ..< max(pts.count - 1, 1) {
                let a = pts[i], b = pts[min(i + 1, pts.count - 1)]
                let x0 = max(Int(min(a.x, b.x) - r) - patch.x, 0), x1 = min(Int(max(a.x, b.x) + r) + 1 - patch.x, patch.w)
                let y0 = max(Int(min(a.y, b.y) - r) - patch.y, 0), y1 = min(Int(max(a.y, b.y) + r) + 1 - patch.y, patch.h)
                if x1 <= x0 || y1 <= y0 { continue }
                let d = b - a
                let len2 = (d * d).sum()
                for y in y0 ..< y1 {
                    for x in x0 ..< x1 {
                        let p = SIMD2(Float(x + patch.x) + 0.5, Float(y + patch.y) + 0.5) - a
                        let t = len2 > 0 ? min(max((p * d).sum() / len2, 0), 1) : 0
                        let e = p - d * t
                        let dist = (e * e).sum().squareRoot()
                        let v = min(max((r - dist) / soft, 0), 1)
                        if v > out[y * patch.w + x] { out[y * patch.w + x] = v }
                    }
                }
            }
        }
        return g
    }

    // MARK: Refine Edges (the box)

    /// A model's raw answer made firm the way the automatic mask's is: nearly-sure taken as
    /// sure, and the enlarged edge steepened.
    public static func firm(_ g: Gray, haze: Float = 0.06, gain: Float = 2) -> Gray {
        var out = g
        for i in 0 ..< out.v.count {
            let v = min(max((g.v[i] - haze) / (1 - 2 * haze), 0), 1)
            out.v[i] = min(max(0.5 + (v - 0.5) * gain, 0), 1)
        }
        return out
    }

    /// Of a closer look's answer, the pieces that belong to the subject already there: those
    /// that touch the present mask, or overlap it by at least `overlap` of their own area. A
    /// box can never pull in a passer-by. `answer` and `current` are the same size.
    public static func keepTouching(_ answer: Gray, current: Gray, overlap: Float = 0.3) -> (kept: Gray, pieces: Int, dropped: Int) {
        precondition(answer.w == current.w && answer.h == current.h)
        let w = answer.w, h = answer.h
        let hard = answer.v.map { $0 >= 0.5 }
        let (lab, count) = SubjectSelect.label(hard, w: w, h: h)
        if count == 0 { return (Gray(w: w, h: h), 0, 0) }
        var area = [Int](repeating: 0, count: count + 1), shared = [Int](repeating: 0, count: count + 1)
        var touches = [Bool](repeating: false, count: count + 1)
        for y in 0 ..< h {
            for x in 0 ..< w {
                let l = Int(lab[y * w + x])
                if l == 0 { continue }
                area[l] += 1
                if current.v[y * w + x] >= 0.5 { shared[l] += 1; touches[l] = true; continue }
                if touches[l] { continue }
                if (x > 0 && current.v[y * w + x - 1] >= 0.5) || (x < w - 1 && current.v[y * w + x + 1] >= 0.5)
                    || (y > 0 && current.v[(y - 1) * w + x] >= 0.5) || (y < h - 1 && current.v[(y + 1) * w + x] >= 0.5) { touches[l] = true }
            }
        }
        var keep = [Bool](repeating: false, count: count + 1)
        var kept = 0
        for l in 1 ... count where touches[l] || Float(shared[l]) >= overlap * Float(area[l]) {
            keep[l] = true
            kept += 1
        }
        // The soft fringe of a kept piece stays; a dropped piece goes entirely.
        let near = PlaneMath.extremum(Gray(w: w, h: h, v: lab.map { keep[Int($0)] ? 1 : 0 }), radius: 3, smallest: false)
        var out = Gray(w: w, h: h)
        for i in 0 ..< w * h where near.v[i] > 0.5 && (lab[i] == 0 || keep[Int(lab[i])]) { out.v[i] = answer.v[i] }
        return (out, kept, count - kept)
    }

    /// Whether a closer look's kept answer runs off a side of its box: left, top, right, bottom.
    public static func touchesBorder(_ kept: Gray, least: Int = 6) -> (left: Bool, top: Bool, right: Bool, bottom: Bool) {
        let w = kept.w, h = kept.h
        var l = 0, t = 0, r = 0, b = 0
        for y in 0 ..< h {
            if kept.v[y * w] >= 0.5 { l += 1 }
            if kept.v[y * w + w - 1] >= 0.5 { r += 1 }
        }
        for x in 0 ..< w {
            if kept.v[x] >= 0.5 { t += 1 }
            if kept.v[(h - 1) * w + x] >= 0.5 { b += 1 }
        }
        return (l >= least, t >= least, r >= least, b >= least)
    }

    // MARK: Colours either side of an edge

    /// The few colours that make up a set of pixels: up to three, found by a short k-means in Oklab.
    static func clusters(_ samples: [SIMD3<Float>], most: Int = 3) -> [SIMD3<Float>] {
        if samples.isEmpty { return [] }
        var centres = [samples[0]]
        // Start from colours far apart.
        while centres.count < min(most, samples.count) {
            var best = 0, far: Float = -1
            for (i, s) in samples.enumerated() {
                var nearest = Float.infinity
                for c in centres { nearest = min(nearest, Oklab.distance(s, c)) }
                if nearest > far { far = nearest; best = i }
            }
            if far < 0.03 { break } // nothing left that is a different colour
            centres.append(samples[best])
        }
        for _ in 0 ..< 6 {
            var sums = [SIMD3<Float>](repeating: SIMD3(repeating: 0), count: centres.count), counts = [Float](repeating: 0, count: centres.count)
            for s in samples {
                var best = 0, near = Float.infinity
                for (i, c) in centres.enumerated() {
                    let d = Oklab.distance(s, c)
                    if d < near { near = d; best = i }
                }
                sums[best] += s
                counts[best] += 1
            }
            for i in 0 ..< centres.count where counts[i] > 0 { centres[i] = sums[i] / counts[i] }
        }
        return centres
    }

    static let toLinear: [Float] = (0 ..< 256).map { pow(Float($0) / 255, 2.2) }

    @inline(__always) static func lab(_ photo: Photo, _ x: Int, _ y: Int) -> SIMD3<Float> {
        let c = photo.rgb(x, y)
        return Oklab.from(linear: SIMD3(toLinear[Int(c.x * 255)], toLinear[Int(c.y * 255)], toLinear[Int(c.z * 255)]))
    }

    /// The subject's and the background's colours beside an edge: sampled from pixels the
    /// mask is sure of, 4 to 20 pixels in from the edge on each side, where `near` is set.
    static func sideColours(photo: Photo, alpha: Gray, near: Gray) -> (subject: [SIMD3<Float>], background: [SIMD3<Float>]) {
        let w = photo.w, h = photo.h
        let inside = alpha.v.map { $0 >= 0.5 }
        let toOutside = PlaneMath.distance(to: inside.map { !$0 }, w: w, h: h), toInside = PlaneMath.distance(to: inside, w: w, h: h)
        var subject: [SIMD3<Float>] = [], background: [SIMD3<Float>] = []
        var counted = 0
        for y in 0 ..< h {
            for x in 0 ..< w where near.v[y * w + x] > 0 {
                let i = y * w + x
                let a = alpha.v[i]
                if a >= 0.97, toOutside[i] >= 4, toOutside[i] <= 20 {
                    counted += 1
                    if counted % 3 == 0 { subject.append(lab(photo, x, y)) }
                } else if a <= 0.03, toInside[i] >= 4, toInside[i] <= 20 {
                    counted += 1
                    if counted % 3 == 0 { background.append(lab(photo, x, y)) }
                }
            }
        }
        // Enough to find the colours by; more only costs time.
        func thinned(_ s: [SIMD3<Float>]) -> [SIMD3<Float>] {
            if s.count <= 3000 { return s }
            let step = s.count / 3000 + 1
            return stride(from: 0, to: s.count, by: step).map { s[$0] }
        }
        return (clusters(thinned(subject)), clusters(thinned(background)))
    }

    // MARK: Clean Edge (the brush for hard edges)

    /// Decides, pixel by pixel under a stroke, subject or background: by colour (is the pixel
    /// nearer the subject's colours beside the edge or the background's, as the eye judges)
    /// and by focus (a clearly defocused pixel leans background, one as sharp as the subject
    /// leans subject). The answer is nearly a yes or no, with a pixel or two of transition.
    /// Returns the new mask for the patch: `alpha` outside the stroke, the decision inside,
    /// as far as `strength` allows.
    ///
    /// - Parameters:
    ///   - defocus: how blurred each part of the patch is (any size), and `subjectSharpness`
    ///     the blur of the subject itself; without them only colour is used.
    ///   - reachPixels: how far from the present edge the brush may decide, in pixels of this patch.
    public static func cleanEdge(photo: Photo, alpha: Gray, weight: Gray, defocus: Gray?, subjectSharpness: Float?,
                                 settings: CleanSettings = CleanSettings(), reachPixels: Float = 4) -> (alpha: Gray, log: String) {
        let w = photo.w, h = photo.h
        precondition(alpha.w == w && alpha.h == h && weight.w == w && weight.h == h)
        // Colours are taken from around the stroke, not just under it.
        let near = PlaneMath.extremum(weight, radius: 20, smallest: false)
        let sides = sideColours(photo: photo, alpha: alpha, near: near)
        if sides.subject.isEmpty || sides.background.isEmpty {
            return (alpha, "nothing done: no \(sides.subject.isEmpty ? "subject" : "background") the mask is sure of beside the stroke")
        }
        // How far each pixel is from the edge as it stands.
        let inside = alpha.v.map { $0 >= 0.5 }
        let toOutside = PlaneMath.distance(to: inside.map { !$0 }, w: w, h: h), toInside = PlaneMath.distance(to: inside, w: w, h: h)
        let reach = max(reachPixels, 2)
        let blur = defocus.map { $0.w == w && $0.h == h ? $0 : $0.resized(w: w, h: h) }
        let sharp = subjectSharpness ?? 1
        let ws = blur == nil ? 0 : settings.sharpnessWeight, wc = settings.colourWeight
        let total = max(ws + wc, 1e-3)
        let centre = 0.5 + 0.15 * min(max(settings.tightness, -1), 1)
        let lo = centre - settings.step, hi = centre + settings.step
        let growBar = settings.growBar
        var decided = Gray(w: w, h: h)
        var toSubject = 0, toBackground = 0
        for y in 0 ..< h {
            for x in 0 ..< w where weight.v[y * w + x] > 0 {
                let i = y * w + x
                let c = lab(photo, x, y)
                var dS = Float.infinity, dB = Float.infinity
                for s in sides.subject { dS = min(dS, Oklab.distance(c, s)) }
                for b in sides.background { dB = min(dB, Oklab.distance(c, b)) }
                // −1 is the background's colour, +1 the subject's.
                let colour = (dB - dS) / (dB + dS + 1e-4)
                var focus: Float = 0
                if let blur = blur {
                    let d = blur.v[i]
                    // As sharp as the subject leans subject; clearly defocused leans background.
                    focus = 1 - 2 * min(max((d - (sharp + 0.7)) / 1.3, 0), 1)
                }
                let score = 0.5 + 0.5 * (ws * focus + wc * colour) / total
                // Taking a pixel into the mask needs more evidence than trimming one off it: the
                // brush is for a rim that shouldn't be there, and a background can hold the
                // subject's colours (skin-toned bokeh behind a fingertip).
                let bar: Float = alpha.v[i] >= 0.5 ? 0 : growBar
                // Beyond the reach the mask stands, as a yes or a no, so that the two meet
                // in one edge and not in a ghost of the old one beside the new.
                let fromEdge = max(toOutside[i], toInside[i])
                if fromEdge > reach {
                    decided.v[i] = alpha.v[i] >= 0.5 ? 1 : 0
                } else if abs(score - (centre + bar)) < 0.06 {
                    // Too close to call: as it was.
                    decided.v[i] = alpha.v[i]
                } else {
                    decided.v[i] = smoothstep(lo + bar, hi + bar, score)
                }
                if decided.v[i] >= 0.5 { toSubject += 1 } else { toBackground += 1 }
            }
        }
        // A pixel of softening, so the yes-or-no decision has an anti-aliased edge and no
        // ragged single pixels. (A guided filter here, as the spec has it, copied the
        // photo's own texture into the mask as faint lines inside a dark top.)
        for i in 0 ..< w * h where weight.v[i] <= 0 { decided.v[i] = alpha.v[i] >= 0.5 ? 1 : 0 }
        let tidy = decided.blurred(radius: 1)
        var out = alpha
        var changed = 0
        let strength = min(max(settings.strength, 0), 1)
        for i in 0 ..< w * h where weight.v[i] > 0 {
            // Only near the edge that is there.
            if max(toOutside[i], toInside[i]) > reach + 2 { continue }
            let v = alpha.v[i] + (tidy.v[i] - alpha.v[i]) * weight.v[i] * strength
            if abs(v - alpha.v[i]) > 0.02 { changed += 1 }
            out.v[i] = v
        }
        return (out, "colours: subject \(sides.subject.count), background \(sides.background.count) · under the stroke \(toSubject) px judged subject, "
            + "\(toBackground) px background · \(changed) px changed")
    }

    /// A small guided filter over the pixels `only` marks: the mask refitted to the photo's
    /// brightness in windows of `radius`.
    static func guided(_ p: Gray, photo: Photo, radius r: Int, only: Gray) -> Gray {
        let w = p.w, h = p.h, n = w * h
        var g = [Float](repeating: 0, count: n), gg = [Float](repeating: 0, count: n), gp = [Float](repeating: 0, count: n)
        var mean = p.v
        for y in 0 ..< h {
            for x in 0 ..< w {
                let l = luma(photo.rgb(x, y)), i = y * w + x
                g[i] = l; gg[i] = l * l; gp[i] = l * p.v[i]
            }
        }
        let brightness = g
        PlaneMath.boxBlur(&g, w: w, h: h, radius: r)
        PlaneMath.boxBlur(&mean, w: w, h: h, radius: r)
        PlaneMath.boxBlur(&gg, w: w, h: h, radius: r)
        PlaneMath.boxBlur(&gp, w: w, h: h, radius: r)
        var slope = [Float](repeating: 0, count: n), offset = [Float](repeating: 0, count: n)
        for i in 0 ..< n {
            let k = (gp[i] - g[i] * mean[i]) / (gg[i] - g[i] * g[i] + 1e-4)
            slope[i] = k
            offset[i] = mean[i] - k * g[i]
        }
        PlaneMath.boxBlur(&slope, w: w, h: h, radius: r)
        PlaneMath.boxBlur(&offset, w: w, h: h, radius: r)
        var out = p
        for i in 0 ..< n where only.v[i] > 0 { out.v[i] = min(max(slope[i] * brightness[i] + offset[i], 0), 1) }
        return out
    }

    // MARK: Gaps inside a box

    /// Pockets of background inside the mask, within a user's box (masking spec v5, 2.2):
    /// connected areas the mask calls subject whose colour is the background's and not the
    /// subject's, enclosed by subject, and neither tiny nor most of the box. Only ever run
    /// inside a box the user drew: across a whole photo the same test cuts into costumes.
    /// Returns the mask with those pockets opened, and how many there were.
    public static func openGaps(photo: Photo, alpha: Gray, box weight: Gray) -> (alpha: Gray, opened: Int, log: [String]) {
        let w = photo.w, h = photo.h
        let near = PlaneMath.extremum(weight, radius: 20, smallest: false)
        let sides = sideColours(photo: photo, alpha: alpha, near: near)
        if sides.subject.isEmpty || sides.background.isEmpty { return (alpha, 0, []) }
        var candidate = [Bool](repeating: false, count: w * h)
        var boxArea = 0
        for y in 0 ..< h {
            for x in 0 ..< w where weight.v[y * w + x] > 0.5 {
                boxArea += 1
                let i = y * w + x
                if alpha.v[i] < 0.5 { continue }
                let c = lab(photo, x, y)
                var dS = Float.infinity, dB = Float.infinity
                for s in sides.subject { dS = min(dS, Oklab.distance(c, s)) }
                for b in sides.background { dB = min(dB, Oklab.distance(c, b)) }
                // The background's colour outright, and plainly not any of the subject's. (A navy
                // sleeve against a dark room is near both; it is not a gap.)
                candidate[i] = dB < 0.05 && dS > 0.2 && dB < 0.25 * dS && weight.v[i] >= 0.999
            }
        }
        let (lab, count) = SubjectSelect.label(candidate, w: w, h: h)
        if count == 0 { return (alpha, 0, []) }
        var area = [Int](repeating: 0, count: count + 1), rim = [Int](repeating: 0, count: count + 1), rimInside = [Int](repeating: 0, count: count + 1)
        var cx = [Int](repeating: 0, count: count + 1), cy = [Int](repeating: 0, count: count + 1)
        for y in 0 ..< h {
            for x in 0 ..< w {
                let l = Int(lab[y * w + x])
                if l == 0 { continue }
                area[l] += 1; cx[l] += x; cy[l] += y
                for (dx, dy) in [(-1, 0), (1, 0), (0, -1), (0, 1)] {
                    let nx = x + dx, ny = y + dy
                    if nx < 0 || ny < 0 || nx >= w || ny >= h { continue }
                    if lab[ny * w + nx] == Int32(l) { continue }
                    rim[l] += 1
                    if alpha.v[ny * w + nx] >= 0.5 { rimInside[l] += 1 }
                }
            }
        }
        let least = max(12, boxArea / 4000), most = boxArea / 8
        var open = [Bool](repeating: false, count: count + 1)
        var opened = 0
        var log: [String] = []
        for l in 1 ... count where area[l] >= least {
            let enclosed = rim[l] > 0 ? Float(rimInside[l]) / Float(rim[l]) : 0
            let at = "\(area[l]) px at \(cx[l] / area[l]),\(cy[l] / area[l])"
            if area[l] > most {
                log.append("gap \(at): left, too large a part of the box")
            } else if enclosed < 0.9 {
                log.append("gap \(at): left, not enclosed by subject (\(Int(enclosed * 100))%)")
            } else {
                open[l] = true
                opened += 1
                log.append("gap \(at): opened")
            }
        }
        if opened == 0 { return (alpha, 0, log) }
        var out = alpha
        for i in 0 ..< w * h where lab[i] > 0 && open[Int(lab[i])] { out.v[i] = 0 }
        // A soft pixel or two at each opened pocket's edge.
        let soft = out.blurred(radius: 1)
        let touched = PlaneMath.extremum(Gray(w: w, h: h, v: lab.map { $0 > 0 && open[Int($0)] ? 1 : 0 }), radius: 2, smallest: false)
        for i in 0 ..< w * h where touched.v[i] > 0.5 { out.v[i] = soft.v[i] }
        return (out, opened, log)
    }

    // MARK: Refine Hair (the brush for hair)

    /// Which way the hair brush should work under a stroke (masking spec v5, 2.3).
    public struct HairChoice: Equatable {
        /// How easily the subject's colour and the background's are told apart, 0 to 1.
        public var contrast: Float
        /// How busy the background is, 0 (plain) upwards.
        public var texture: Float
        /// True: colour matting (a clean backdrop). False: the matting model (a busy one).
        public var colour: Bool
        public var why: String
    }

    /// Colour matting needs a backdrop that is unlike the hair and plain. This measures both
    /// around a stroke: the contrast between the subject's and the background's colours
    /// there, and how much the background's brightness varies from pixel to pixel.
    public static func hairMethod(photo: Photo, alpha: Gray, weight: Gray, contrastNeeded: Float = 0.5, textureAllowed: Float = 0.03) -> HairChoice {
        let w = photo.w, h = photo.h
        let near = PlaneMath.extremum(weight, radius: 24, smallest: false)
        var fs = SIMD3<Float>(repeating: 0), bs = SIMD3<Float>(repeating: 0)
        var fn: Float = 0, bn: Float = 0
        var lum = [Float](repeating: 0, count: w * h), isBack = [Float](repeating: 0, count: w * h)
        for y in 0 ..< h {
            for x in 0 ..< w {
                let i = y * w + x
                let c = photo.rgb(x, y)
                lum[i] = luma(c)
                if near.v[i] <= 0 { continue }
                if alpha.v[i] >= 0.97 { fs += c; fn += 1 } else if alpha.v[i] <= 0.03 { bs += c; bn += 1; isBack[i] = 1 }
            }
        }
        if fn < 50 || bn < 50 {
            return HairChoice(contrast: 0, texture: 1, colour: false, why: "too little sure subject or background beside the stroke to judge the backdrop")
        }
        let f = fs / fn, b = bs / bn
        // How far apart the two average colours are as the eye judges it (Oklab), where 0.6
        // or more counts as 1: black against white is 1.0, skin against a mid-green wall
        // about 0.25, dark hair against a dark brown room 0.1. (Until the final round this
        // was a proportional measure that reached 1 at a tenth of that; it read 1.00 on
        // every stroke.)
        let apart = Oklab.distance(Oklab.from(linear: SIMD3(pow(f.x, 2.2), pow(f.y, 2.2), pow(f.z, 2.2))),
                                   Oklab.from(linear: SIMD3(pow(b.x, 2.2), pow(b.y, 2.2), pow(b.z, 2.2))))
        let contrast = min(apart / 0.6, 1)
        // How busy: the background's brightness against its own local average, taken over the
        // sure background alone (so the subject's edge in the window doesn't count as busyness).
        var count = isBack, sum = [Float](repeating: 0, count: w * h), squares = [Float](repeating: 0, count: w * h)
        for i in 0 ..< w * h where isBack[i] > 0 { sum[i] = lum[i]; squares[i] = lum[i] * lum[i] }
        PlaneMath.boxBlur(&count, w: w, h: h, radius: 6)
        PlaneMath.boxBlur(&sum, w: w, h: h, radius: 6)
        PlaneMath.boxBlur(&squares, w: w, h: h, radius: 6)
        var spread: Float = 0
        for i in 0 ..< w * h where isBack[i] > 0 && count[i] > 0.05 {
            let mean = sum[i] / count[i]
            spread += max(squares[i] / count[i] - mean * mean, 0).squareRoot()
        }
        let texture = (spread / bn) / 0.04 // 1 is a backdrop whose brightness wanders by 4% from pixel to pixel
        let colour = contrast >= contrastNeeded && texture <= textureAllowed
        let numbers = String(format: "contrast %.2f (needs %.2f), backdrop busyness %.2f (allows %.2f)", locale: Locale(identifier: "en_US_POSIX"),
                             contrast, contrastNeeded, texture, textureAllowed)
        return HairChoice(contrast: contrast, texture: texture, colour: colour,
                          why: (colour ? "colour matting: a plain, contrasting backdrop" : "the matting model: the backdrop is busy or like the hair") + " · " + numbers)
    }

    // MARK: Laying a result back

    /// Lays a patch's finished mask and colour shares into the photo's, through `weight`
    /// (the box's or stroke's soft edge, the size of the patch). Returns how many pixels changed.
    @discardableResult
    public static func paste(_ out: MatteOutput, at patch: PixelRect, weight: Gray, alpha: inout [UInt8], shares: inout [UInt8], width W: Int) -> Int {
        precondition(out.w == patch.w && out.h == patch.h && weight.w == patch.w && weight.h == patch.h)
        var changed = 0
        for y in 0 ..< patch.h {
            for x in 0 ..< patch.w {
                let k = weight.v[y * patch.w + x]
                if k <= 0 { continue }
                let i = y * patch.w + x, o = (patch.y + y) * W + patch.x + x
                let before = alpha[o]
                let a = Float(before) + (Float(out.alpha[i]) - Float(before)) * k
                alpha[o] = UInt8(min(max(a.rounded(), 0), 255))
                if alpha[o] != before { changed += 1 }
                for c in 0 ..< 3 {
                    let s = Float(shares[o * 4 + c]) + (Float(out.shares[i * 4 + c]) - Float(shares[o * 4 + c])) * k
                    shares[o * 4 + c] = UInt8(min(max(s.rounded(), 0), 255))
                }
            }
        }
        return changed
    }

    /// The engine's settings for a patch whose first-pass mask is a mask that is already
    /// finished (or already made firm): nothing is stretched or steepened a second time.
    public static func patchSettings(from base: MatteSettings = MatteSettings()) -> MatteSettings {
        var s = base
        s.haze = 0
        s.steepen = 1
        return s
    }
}

// MARK: - The tools, whole

/// What the tools need to know about the photo a mask belongs to.
public struct RefineContext {
    public var photo: Photo
    /// Faces in pixels of the photo, y down.
    public var faces: [PixelRect]
    /// How blurred each part of the photo is (any size, covering the whole photo), and the
    /// blur of the subject itself.
    public var defocus: Gray?
    public var subjectSharpness: Float?
    public var settings: MatteSettings

    public init(photo: Photo, faces: [PixelRect], defocus: Gray? = nil, subjectSharpness: Float? = nil, settings: MatteSettings = MatteSettings()) {
        self.photo = photo; self.faces = faces; self.defocus = defocus; self.subjectSharpness = subjectSharpness; self.settings = settings
    }
}

/// What a tool worked out: a patch of finished mask and colour shares, and the soft-edged
/// area of it that belongs in the photo's mask. Lay it in with `Refine.paste`.
public struct RefineResult {
    public var patch: PixelRect
    public var weight: Gray
    public var output: MatteOutput
    public var log: [String]
    /// Refine Edges: the sides of the looked-at area the subject runs off, where the area
    /// could be grown to follow it (a staff, a sword). Left, top, right, bottom.
    public var runsOff: (left: Bool, top: Bool, right: Bool, bottom: Bool) = (false, false, false, false)
}

extension Refine {
    /// A part of the photo's mask (0 to 255, the photo's width `W`) as a plane from 0 to 1.
    static func plane(_ alpha: [UInt8], width W: Int, _ r: PixelRect) -> Gray {
        var g = Gray(w: r.w, h: r.h)
        for y in 0 ..< r.h {
            for x in 0 ..< r.w { g.v[y * r.w + x] = Float(alpha[(r.y + y) * W + r.x + x]) / 255 }
        }
        return g
    }

    /// The part of a whole-photo plane (any size) that lies over a patch, a quarter of the patch's size.
    static func region(_ whole: Gray?, photoW: Int, photoH: Int, _ r: PixelRect) -> Gray? {
        guard let whole = whole else { return nil }
        let w = max(r.w / 4, 1), h = max(r.h / 4, 1)
        var g = Gray(w: w, h: h)
        let kx = Float(whole.w) / Float(photoW), ky = Float(whole.h) / Float(photoH)
        for y in 0 ..< h {
            for x in 0 ..< w {
                g.v[y * w + x] = whole.sample((Float(r.x) + (Float(x) + 0.5) * 4) * kx, (Float(r.y) + (Float(y) + 0.5) * 4) * ky)
            }
        }
        return g
    }

    /// How much of the photo round a tool's area the edge engine is given. It takes the
    /// subject's and background's colours from areas the mask is sure of, and in a narrow
    /// gap there is no sure background for some way: with too little around it the engine
    /// had no background colour at all, and left a light rim.
    static func margin(_ w: Int, _ h: Int) -> Int { max(96, max(w, h) / 16) }

    static func moved(_ faces: [PixelRect], by r: PixelRect) -> [PixelRect] {
        faces.map { PixelRect(x: $0.x - r.x, y: $0.y - r.y, w: $0.w, h: $0.h) }
    }

    /// The area a box's closer look should cover: the box and 15% more each side.
    public static func lookArea(box: PixelRect, w: Int, h: Int) -> PixelRect {
        let dx = Int((Float(box.w) * 0.15).rounded(.up)), dy = Int((Float(box.h) * 0.15).rounded(.up))
        return PixelRect(x: box.x - dx, y: box.y - dy, w: box.w + 2 * dx, h: box.h + 2 * dy).clamped(w: w, h: h)
    }

    /// The area the matting model should be shown for a hair stroke: its bounds and 20% more each side.
    public static func lookArea(stroke: RefineStroke, w: Int, h: Int) -> PixelRect {
        let b = bounds(of: stroke, w: w, h: h)
        let dx = Int((Float(b.w) * 0.2).rounded(.up)), dy = Int((Float(b.h) * 0.2).rounded(.up))
        return PixelRect(x: b.x - dx, y: b.y - dy, w: b.w + 2 * dx, h: b.h + 2 * dy).clamped(w: w, h: h)
    }

    /// Refine Edges: a closer look by the model (`answer`, any size, covering `look`) takes
    /// the mask's place inside the box, as far as it belongs to the subject already there;
    /// pockets of background inside the box are opened; then the edge is snapped, given its
    /// colour shares and checked by the colour guard like any other.
    public static func edges(box: PixelRect, look: PixelRect, answer: Gray, alpha: [UInt8], context c: RefineContext) -> RefineResult {
        let W = c.photo.w, H = c.photo.h
        let patch = Refine.patch(around: look, margin: margin(W, H), w: W, h: H)
        let current = plane(alpha, width: W, patch)
        let inBox = weight(box: box, in: patch, feather: 6)
        // The model's answer, at the photo's size over the area it was shown.
        let full = answer.fitted(w: look.w, h: look.h)
        let was = current.cropped(PixelRect(x: look.x - patch.x, y: look.y - patch.y, w: look.w, h: look.h))
        let (kept, pieces, dropped) = keepTouching(full, current: was)
        // With re-centring on, the engine steepens the new edge itself, by as much as the
        // photo's own edge says; here only the haze is taken off.
        let firmed = firm(kept, haze: c.settings.haze, gain: c.settings.recentre ? 1 : c.settings.steepen)
        var next = current
        for y in 0 ..< look.h {
            for x in 0 ..< look.w {
                let i = (look.y - patch.y + y) * patch.w + (look.x - patch.x + x)
                let k = inBox.v[i]
                if k > 0 { next.v[i] += (firmed.v[y * look.w + x] - next.v[i]) * k }
            }
        }
        let photo = c.photo.cropped(patch)
        let gaps = openGaps(photo: photo, alpha: next, box: inBox)
        var settings = patchSettings(from: c.settings)
        // How many photo pixels one pixel of the model's answer covered: the scale of what it can get wrong.
        let modelPixel = max(Float(max(look.w, look.h)) / Float(max(max(answer.w, answer.h), 1)), 1)
        // Where the photo can't say how wide an edge is, a much-enlarged answer is steepened
        // as the automatic mask's is; one the model gave at about the photo's own size is left.
        if c.settings.recentre && modelPixel > 1.5 { settings.steepen = c.settings.steepen }
        let out = Matte(photo: photo, coarse: gaps.alpha, faces: moved(c.faces, by: patch), settings: settings,
                        defocus: region(c.defocus, photoW: W, photoH: H, patch), subjectSharpness: c.subjectSharpness,
                        firstPassPixel: modelPixel).run(tier: .off)
        var log = ["box \(box.w)×\(box.h) px at \(box.x),\(box.y) · the model's pieces: \(pieces) kept, \(dropped) dropped (not part of the subject) · gaps opened \(gaps.opened)"]
        log += gaps.log
        log += out.log.filter { $0.hasPrefix("snap") || $0.hasPrefix("colour guard") || $0.hasPrefix("decontaminated") || $0.hasPrefix("edge placement") }
        var result = RefineResult(patch: patch, weight: inBox, output: out, log: log)
        // Only what is new counts as running off: the subject that was already there always does.
        var added = kept
        for i in 0 ..< added.v.count where was.v[i] >= 0.5 { added.v[i] = 0 }
        let off = touchesBorder(added)
        result.runsOff = (off.left && look.x > 0, off.top && look.y > 0, off.right && look.maxX < W, off.bottom && look.maxY < H)
        return result
    }

    /// Clean Edge: the near yes-or-no decision under the stroke, then colour shares and the guard.
    public static func clean(stroke: RefineStroke, alpha: [UInt8], context c: RefineContext, clean: CleanSettings = CleanSettings()) -> RefineResult {
        let W = c.photo.w, H = c.photo.h
        let patch = Refine.patch(around: bounds(of: stroke, w: W, h: H), margin: margin(W, H), w: W, h: H)
        let current = plane(alpha, width: W, patch)
        let under = weight(stroke: stroke, in: patch)
        let photo = c.photo.cropped(patch)
        let blur = region(c.defocus, photoW: W, photoH: H, patch)
        let megapixels = Float(W) * Float(H) / 1_000_000
        let reach = max(clean.reach * (megapixels / 33).squareRoot(), 3)
        let (decided, note) = cleanEdge(photo: photo, alpha: current, weight: under, defocus: blur, subjectSharpness: c.subjectSharpness,
                                        settings: clean, reachPixels: reach)
        var settings = patchSettings(from: c.settings)
        settings.colourSnap = false // the brush has already said where the edge is
        let out = Matte(photo: photo, coarse: decided, faces: moved(c.faces, by: patch), settings: settings,
                        defocus: blur, subjectSharpness: c.subjectSharpness).run(tier: .off)
        var log = ["stroke of \(stroke.points.count) points, brush \(Int(stroke.radius)) px · \(note)"]
        log += out.log.filter { $0.hasPrefix("colour guard") || $0.hasPrefix("decontaminated") }
        return RefineResult(patch: patch, weight: under, output: out, log: log)
    }

    /// Which way a hair stroke should be worked, from the photo and mask under it.
    public static func hairChoice(stroke: RefineStroke, alpha: [UInt8], context c: RefineContext,
                                  contrastNeeded: Float = 0.5, textureAllowed: Float = 0.03) -> HairChoice {
        let W = c.photo.w, H = c.photo.h
        let patch = Refine.patch(around: bounds(of: stroke, w: W, h: H), margin: margin(W, H), w: W, h: H)
        return hairMethod(photo: c.photo.cropped(patch), alpha: plane(alpha, width: W, patch), weight: weight(stroke: stroke, in: patch),
                          contrastNeeded: contrastNeeded, textureAllowed: textureAllowed)
    }

    /// Refine Hair. With `answer` (the matting model's reading of `look`, any size) that
    /// takes the mask's place under the stroke. Without it, colour matting runs under the
    /// stroke: High, and the closed-form solve on top when the stroke is small enough.
    /// Either way the guards are off under the stroke, and the colour shares and colour
    /// guard follow.
    public static func hair(stroke: RefineStroke, look: PixelRect?, answer: Gray?, alpha: [UInt8], context c: RefineContext,
                            progress: (String) -> Void = { _ in }, cancelled: () -> Bool = { false }) -> RefineResult {
        let W = c.photo.w, H = c.photo.h
        let patch = Refine.patch(around: bounds(of: stroke, w: W, h: H), margin: margin(W, H), w: W, h: H)
        let current = plane(alpha, width: W, patch)
        let under = weight(stroke: stroke, in: patch)
        let photo = c.photo.cropped(patch)
        var settings = patchSettings(from: c.settings)
        settings.relaxGuards = true
        let blur = region(c.defocus, photoW: W, photoH: H, patch)
        var log: [String] = []
        let out: MatteOutput
        if let answer = answer, let look = look {
            // The model's matte, at the photo's size, laid in under the stroke.
            var next = current
            // (Made the photo's size properly first: a small stroke's area is shown to the
            // model enlarged several times, and read back pixel for pixel its edge came out ragged.)
            let full = answer.fitted(w: look.w, h: look.h)
            for y in 0 ..< patch.h {
                for x in 0 ..< patch.w where under.v[y * patch.w + x] > 0 {
                    let px = patch.x + x - look.x, py = patch.y + y - look.y
                    if px < 0 || py < 0 || px >= look.w || py >= look.h { continue }
                    let v = full.v[py * look.w + px]
                    let i = y * patch.w + x
                    next.v[i] += (v - next.v[i]) * under.v[i]
                }
            }
            out = Matte(photo: photo, coarse: next, faces: moved(c.faces, by: patch), settings: settings,
                        defocus: blur, subjectSharpness: c.subjectSharpness, forced: under).run(tier: .off)
            log.append("stroke of \(stroke.points.count) points, brush \(Int(stroke.radius)) px · the matting model's matte laid in under the stroke")
        } else {
            // Colour matting is for the edge, and for blobs and strands near it. Deep inside
            // the mask it has nothing to go by but colour, and a sleeve the colour of nothing
            // near it would be eaten: so the stroke counts only within reach of the edge on
            // the subject's side (any distance on the background's, where strands fly).
            let megapixels = Float(W) * Float(H) / 1_000_000
            let reach = max(80 * (megapixels / 33).squareRoot(), 16)
            let inside = current.v.map { $0 >= 0.5 }
            let depth = PlaneMath.distance(to: inside.map { !$0 }, w: patch.w, h: patch.h)
            var edgeOnly = under
            for i in 0 ..< edgeOnly.v.count where depth[i] > reach * 0.6 {
                edgeOnly.v[i] *= min(max((reach - depth[i]) / (reach * 0.4), 0), 1)
            }
            let matte = Matte(photo: photo, coarse: current, faces: moved(c.faces, by: patch), settings: settings,
                              defocus: blur, subjectSharpness: c.subjectSharpness, forced: edgeOnly)
            // The closed-form solve is slow; it is for strokes of up to about a megapixel and a half.
            let tier: MatteTier = matte.mattedCount <= 1_500_000 ? .max : .high
            out = matte.run(tier: tier, progress: progress, cancelled: cancelled)
            log.append("stroke of \(stroke.points.count) points, brush \(Int(stroke.radius)) px · colour matting (\(tier.name)) over \(matte.mattedCount) px")
            log += out.log.filter { $0.hasPrefix("max") || $0.hasPrefix("high trust") }
        }
        log += out.log.filter { $0.hasPrefix("colour guard") || $0.hasPrefix("decontaminated") }
        return RefineResult(patch: patch, weight: under, output: out, log: log)
    }

    /// ⌥ with any tool: the automatic mask put back inside a box or under a stroke.
    /// `base` are the automatic mask's alpha and shares. Returns how many pixels changed.
    @discardableResult
    public static func restore(weight: Gray, at patch: PixelRect, baseAlpha: [UInt8], baseShares: [UInt8],
                               alpha: inout [UInt8], shares: inout [UInt8], width W: Int) -> Int {
        var changed = 0
        for y in 0 ..< patch.h {
            for x in 0 ..< patch.w {
                let k = weight.v[y * patch.w + x]
                if k <= 0 { continue }
                let o = (patch.y + y) * W + patch.x + x
                let before = alpha[o]
                // Fully under the tool the base comes back exactly.
                if k >= 0.999 {
                    alpha[o] = baseAlpha[o]
                    for ch in 0 ..< 3 { shares[o * 4 + ch] = baseShares[o * 4 + ch] }
                } else {
                    alpha[o] = UInt8((Float(before) + (Float(baseAlpha[o]) - Float(before)) * k).rounded())
                    for ch in 0 ..< 3 {
                        let s = Float(shares[o * 4 + ch])
                        shares[o * 4 + ch] = UInt8((s + (Float(baseShares[o * 4 + ch]) - s) * k).rounded())
                    }
                }
                if alpha[o] != before { changed += 1 }
            }
        }
        return changed
    }
}
