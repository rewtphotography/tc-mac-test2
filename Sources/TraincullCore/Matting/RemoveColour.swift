import Foundation

/// Remove Colour (masking spec v7, section 3; v7.2, section 4): a box for where the mask
/// really takes in some background (an orange wall round a rose). The colours to take out are
/// guessed from the box (automatic) or picked with the eyedropper; pixels that hold them lose
/// as much coverage as is theirs.
public struct RemoveColourSettings: Equatable {
    /// How far from the mask's outline the box may act, either side, in photo pixels. The
    /// deeper interior is never touched.
    public var reach: Float = 40
    /// The change in alpha is softened over this radius (Gaussian σ = half of it).
    public var smooth: Float = 1.5
    /// Pieces cut loose, and holes opened, smaller than this many pixels are tidied away.
    public var tidy = 50
    /// The automatic guess (spec v7.2, 4.1): up to this many colours each side; a colour is
    /// ignored as noise under `noise` of its side; an outside colour is removable when it is
    /// `apart` × the tolerance from every inside colour, or the inside pixels within the
    /// tolerance of it are under `share` of the inside.
    public var clusters = 4
    public var noise: Float = 0.02
    public var apart: Float = 2
    public var share: Float = 0.15
    /// Automatic mode: partly matching pixels are taken also within this many pixels of a
    /// removed one, beyond `reach`.
    public var nearRemoved: Float = 3

    public init() {}
}

extension Refine {
    /// How far a pixel is in the hair zone round the faces, as the edge engine places it
    /// (alpha 16's box, 2.6 × 3.0 face sizes less the face's oval; with no face, everywhere).
    static func hairZone(_ x: Int, _ y: Int, faces: [PixelRect]) -> Float {
        if faces.isEmpty { return 1 }
        var most: Float = 0
        let px = Float(x) + 0.5, py = Float(y) + 0.5
        for f in faces {
            let fw = Float(f.w), fh = Float(f.h)
            let cx = Float(f.x) + fw / 2, cy = Float(f.y) + fh / 2 - 0.25 * fh
            let x0 = cx - 1.3 * fw, y0 = cy - 1.5 * fh, x1 = x0 + 2.6 * fw, y1 = y0 + 3.0 * fh
            if px < x0 || px > x1 || py < y0 || py > y1 { continue }
            let ovalY = Float(f.y) + 0.325 * fh, a = fw / 2, b = 1.35 * fh / 2
            let dx = (px - cx) / a, dy = (py - ovalY) / b
            let outsideOval = min(max(((dx * dx + dy * dy).squareRoot() - 1) / 0.2, 0), 1)
            let fromEdge = min(min(px - x0, x1 - px), min(py - y0, y1 - py))
            most = max(most, outsideOval * min(max(fromEdge / max(0.15 * fw, 8), 0), 1))
        }
        return most
    }

    /// The distance in Oklab from a colour to the segment between two others.
    @inline(__always)
    static func toSegment(_ p: SIMD3<Float>, _ a: SIMD3<Float>, _ b: SIMD3<Float>) -> Float {
        let d = b - a
        let dd = (d * d).sum()
        let t = dd > 1e-12 ? min(max(((p - a) * d).sum() / dd, 0), 1) : 0
        let e = p - (a + d * t)
        return (e * e).sum().squareRoot()
    }


    /// One colour of a palette: its Oklab and linear centre, and its share of its side.
    public struct PaletteColour: Equatable {
        public var lab: SIMD3<Float>
        public var linear: SIMD3<Float>
        public var share: Float
        /// The display value (the engine's 2.2 curve), as the eyedropper gives colours.
        public var shown: SIMD3<Float> { SIMD3(pow(max(linear.x, 0), 1 / 2.2), pow(max(linear.y, 0), 1 / 2.2), pow(max(linear.z, 0), 1 / 2.2)) }
    }

    /// Up to `k` colours of a set of pixels (linear), by k-means in Oklab: started from the
    /// mean and the pixels farthest from the centres so far, ten rounds. Colours under
    /// `noise` of the pixels are dropped. Deterministic.
    static func palette(_ linear: [SIMD3<Float>], k: Int, noise: Float) -> [PaletteColour] {
        guard !linear.isEmpty else { return [] }
        let step = max(linear.count / 40_000, 1)
        let lin = stride(from: 0, to: linear.count, by: step).map { linear[$0] }
        let labs = lin.map { Oklab.from(linear: $0) }
        var centres = [labs.reduce(SIMD3<Float>(repeating: 0), +) / Float(labs.count)]
        while centres.count < k {
            var far: Float = 0, at = -1
            for (i, p) in labs.enumerated() {
                let d = centres.map { Oklab.distance(p, $0) }.min() ?? 0
                if d > far { far = d; at = i }
            }
            if at < 0 || far < 0.01 { break }
            centres.append(labs[at])
        }
        var owner = [Int](repeating: 0, count: labs.count)
        for _ in 0 ..< 10 {
            for (i, p) in labs.enumerated() {
                var best = Float.infinity
                for (c, q) in centres.enumerated() {
                    let d = Oklab.distance(p, q)
                    if d < best { best = d; owner[i] = c }
                }
            }
            var sum = [SIMD3<Float>](repeating: SIMD3(repeating: 0), count: centres.count), n = [Int](repeating: 0, count: centres.count)
            for (i, p) in labs.enumerated() { sum[owner[i]] += p; n[owner[i]] += 1 }
            for c in centres.indices where n[c] > 0 { centres[c] = sum[c] / Float(n[c]) }
        }
        var sumLin = [SIMD3<Float>](repeating: SIMD3(repeating: 0), count: centres.count), n = [Int](repeating: 0, count: centres.count)
        for (i, p) in lin.enumerated() { sumLin[owner[i]] += p; n[owner[i]] += 1 }
        var out: [PaletteColour] = []
        for c in centres.indices where n[c] > 0 {
            let share = Float(n[c]) / Float(lin.count)
            if share < noise { continue }
            let l = sumLin[c] / Float(n[c])
            out.append(PaletteColour(lab: Oklab.from(linear: l), linear: l, share: share))
        }
        return out.sorted { $0.share > $1.share }
    }

    /// The automatic guess (spec v7.2, 4.1): the outside and inside palettes of the box, and
    /// which outside colours are removable and why.
    public struct Guess {
        public var outside: [PaletteColour] = []
        public var inside: [PaletteColour] = []
        /// For each outside colour: removable, and why (or why not).
        public var verdicts: [(removable: Bool, why: String)] = []
        public var removable: [PaletteColour] { zip(outside, verdicts).filter { $0.1.removable }.map { $0.0 } }

        public var summary: String {
            let posix = Locale(identifier: "en_US_POSIX")
            func show(_ c: PaletteColour) -> String {
                let v = c.shown * 255
                return String(format: "(%.0f, %.0f, %.0f) %.0f%%", locale: posix, v.x, v.y, v.z, c.share * 100)
            }
            let o = zip(outside, verdicts).map { "\(show($0.0)) \($0.1.removable ? "removable" : "kept"): \($0.1.why)" }
            return "automatic guess · outside: " + (o.isEmpty ? "none" : o.joined(separator: "; ")) + " · inside: "
                + (inside.isEmpty ? "none" : inside.map(show).joined(separator: ", "))
        }
    }

    public static func guess(box: PixelRect, photo: Photo, alpha: [UInt8], tolerance: Float, settings rs: RemoveColourSettings = RemoveColourSettings()) -> Guess {
        let W = photo.w
        let b = box.clamped(w: photo.w, h: photo.h)
        var outside: [SIMD3<Float>] = [], inside: [SIMD3<Float>] = []
        for y in b.y ..< b.maxY {
            for x in b.x ..< b.maxX {
                let a = alpha[y * W + x]
                if a <= 5 { outside.append(InsideColour.linear(photo, x, y)) } else if a >= 250 { inside.append(InsideColour.linear(photo, x, y)) }
            }
        }
        var g = Guess()
        g.outside = palette(outside, k: rs.clusters, noise: rs.noise)
        g.inside = palette(inside, k: rs.clusters, noise: rs.noise)
        let step = max(inside.count / 40_000, 1)
        let insideLabs = stride(from: 0, to: inside.count, by: step).map { Oklab.from(linear: inside[$0]) }
        let posix = Locale(identifier: "en_US_POSIX")
        for o in g.outside {
            if g.inside.isEmpty { g.verdicts.append((true, "no subject colour in the box")); continue }
            let nearest = g.inside.map { Oklab.distance(o.lab, $0.lab) }.min() ?? .infinity
            if nearest >= rs.apart * tolerance {
                g.verdicts.append((true, "distance " + String(format: "%.3f", locale: posix, nearest) + " from every inside colour"))
                continue
            }
            let within = insideLabs.filter { Oklab.distance($0, o.lab) <= tolerance }.count
            let share = Float(within) / Float(max(insideLabs.count, 1))
            if share < rs.share {
                g.verdicts.append((true, "share " + String(format: "%.0f%%", locale: posix, share * 100) + " of the inside"))
            } else {
                g.verdicts.append((false, "distance " + String(format: "%.3f", locale: posix, nearest) + ", share "
                    + String(format: "%.0f%%", locale: posix, share * 100) + " of the inside"))
            }
        }
        return g
    }

    /// Remove Colour (spec v7.2, 4). `samples` are colours (display values, 0 to 1): with
    /// `automatic` and none, they are guessed from the box (`guess`); with `automatic` and some,
    /// a guess is being done again exactly (Remake); without `automatic` they were picked with
    /// the eyedropper, and nothing is judged: every pixel in the box near one of them goes.
    /// `tolerance` is an Oklab distance. `repaint` and `repaintBack` are the mask's repaint
    /// maps, if it has them. Returns the patch to lay in through the box's soft edge, with the
    /// samples used.
    public static func removeColour(box: PixelRect, samples: [SIMD3<Float>], automatic: Bool = false, tolerance: Float, alpha: [UInt8], shares: [UInt8],
                                    repaint: [UInt8]? = nil, repaintBack: [UInt8]? = nil,
                                    context c: RefineContext, settings rs: RemoveColourSettings = RemoveColourSettings()) -> RefineResult {
        let W = c.photo.w, H = c.photo.h
        let s = c.settings.inside
        let patch = Refine.patch(around: box, margin: max(margin(W, H), Int(rs.reach + s.reach + s.solidDepth) + 8), w: W, h: H)
        let pw = patch.w, ph = patch.h, n = pw * ph
        let photo = c.photo.cropped(patch)
        var before = [UInt8](repeating: 0, count: n), share = [UInt8](repeating: 0, count: n * 4)
        var map = Repaint.blank(count: n), back = Repaint.blank(count: n)
        for y in 0 ..< ph {
            for x in 0 ..< pw {
                let o = (patch.y + y) * W + patch.x + x, i = y * pw + x
                before[i] = alpha[o]
                for ch in 0 ..< 4 {
                    share[i * 4 + ch] = shares[o * 4 + ch]
                    if let r = repaint { map[i * 4 + ch] = r[o * 4 + ch] }
                    if let r = repaintBack { back[i * 4 + ch] = r[o * 4 + ch] }
                }
            }
        }
        let inBox = weight(box: box, in: patch, feather: 6)
        let tol = max(tolerance, 1e-4)
        let posix = Locale(identifier: "en_US_POSIX")
        var log: [String] = []
        var used = samples
        if automatic && samples.isEmpty {
            let g = guess(box: box, photo: c.photo, alpha: alpha, tolerance: tol, settings: rs)
            log.append(g.summary)
            used = g.removable.map { $0.shown }
        }
        func unchanged(_ why: String, message: String?) -> RefineResult {
            var out = MatteOutput(w: pw, h: ph, alpha: before, shares: share, trimap: [], trimapW: 0, trimapH: 0,
                                  band: PixelRect(x: 0, y: 0, w: 0, h: 0), unknownPixels: 0, log: [])
            out.repaint = repaint == nil ? nil : map
            out.repaintBack = repaintBack == nil ? nil : back
            var result = RefineResult(patch: patch, weight: inBox, output: out, log: log + ["remove colour: \(why)"])
            result.samples = used
            result.message = message
            return result
        }
        if used.isEmpty {
            return automatic ? unchanged("no clear background colour in the box, nothing done",
                                         message: "No clear background colour in the box — click one with the eyedropper.")
                : unchanged("nothing picked, nothing done", message: nil)
        }
        let lin = Matte.toLinear.p
        let removed = used.map { c3 -> (lin: SIMD3<Float>, lab: SIMD3<Float>) in
            let l = SIMD3<Float>(lin[Int((min(max(c3.x, 0), 1) * 255).rounded())], lin[Int((min(max(c3.y, 0), 1) * 255).rounded())],
                                 lin[Int((min(max(c3.z, 0), 1) * 255).rounded())])
            return (l, Oklab.from(linear: l))
        }
        // How near each pixel is to a sample, and which sample.
        var nearest = [Float](repeating: .infinity, count: n), which = [Int](repeating: 0, count: n)
        for y in 0 ..< ph {
            for x in 0 ..< pw {
                let i = y * pw + x
                let Ilab = Oklab.from(linear: InsideColour.linear(photo, x, y))
                for (k, r) in removed.enumerated() {
                    let d = Oklab.distance(Ilab, r.lab)
                    if d < nearest[i] { nearest[i] = d; which[i] = k }
                }
            }
        }
        let matchesAny = nearest.map { $0 < 2 * tol }
        let field0 = InsideColour.field(alpha: before, w: pw, h: ph, settings: s, solidOK: matchesAny.map { !$0 })
        /// How much of a pixel's light is the sample's: its place on the line from the inside
        /// colour to the sample (linear light), 1 where there's no inside colour to go by.
        func mix(_ i: Int, _ x: Int, _ y: Int) -> (t: Float, F: SIMD3<Float>?) {
            guard field0.source[i] >= 0 else { return (1, nil) }
            let src = Int(field0.source[i])
            let F = InsideColour.median3(photo, src % pw, src / pw)
            let B = removed[which[i]]
            if Oklab.distance(Oklab.from(linear: F), B.lab) < 2 * tol { return (1, F) }
            let I = InsideColour.linear(photo, x, y), d = B.lin - F
            return (min(max(((I - F) * d).sum() / max((d * d).sum(), 1e-12), 0), 1), F)
        }
        // 1. Pixels that match a sample, anywhere in the box, by how much of them is the sample
        // (owner, v7.2: the cut follows the mix, so a part-pink, part-orange pixel keeps its pink part).
        var change = [Float](repeating: 0, count: n), remove = [Float](repeating: 0, count: n)
        var matched = [Bool](repeating: false, count: n)
        for y in 0 ..< ph {
            for x in 0 ..< pw {
                let i = y * pw + x
                if inBox.v[i] <= 0 || before[i] == 0 { continue }
                let ws = 1 - smoothstep(tol, 2 * tol, nearest[i])
                if ws <= 0 { continue }
                matched[i] = true
                remove[i] = ws * mix(i, x, y).t
            }
        }
        // 2. Partly matching pixels on the line between the inside colour and a sample: in the
        // eyedropper's box anywhere, else near the outline or beside a removed pixel.
        var nearRemoved = [Float](repeating: .infinity, count: n)
        if automatic { nearRemoved = PlaneMath.distance(to: remove.map { $0 >= 0.5 }, w: pw, h: ph) }
        for y in 0 ..< ph {
            for x in 0 ..< pw {
                let i = y * pw + x
                if inBox.v[i] <= 0 || before[i] == 0 { continue }
                if automatic && abs(field0.depth[i]) > rs.reach && nearRemoved[i] > rs.nearRemoved { continue }
                let (t, F) = mix(i, x, y)
                guard let inside = F else { continue }
                let I = InsideColour.linear(photo, x, y), B = removed[which[i]]
                let along = 1 - smoothstep(tol, 2 * tol, toSegment(Oklab.from(linear: I), Oklab.from(linear: inside), B.lab))
                if along > 0 { remove[i] = max(remove[i], along * t) }
            }
        }
        for i in 0 ..< n where remove[i] > 0 {
            let a = Float(before[i]) / 255
            change[i] = a - min(a, 1 - remove[i])
        }
        // 3. The change softened (not the alpha), inside the box only, averaged over the pixels
        // that have coverage to lose, and never weaker than it was: a 3×3 speck still goes.
        let sigma = max(rs.smooth / 2, 0.3), radius = Int((2 * sigma).rounded(.up))
        let kernel = (-radius ... radius).map { exp(-Float($0 * $0) / (2 * sigma * sigma)) }
        let ksum = kernel.reduce(0, +)
        func blur(_ f: [Float]) -> [Float] {
            var tmp = [Float](repeating: 0, count: n), out = [Float](repeating: 0, count: n)
            for y in 0 ..< ph {
                for x in 0 ..< pw {
                    var v: Float = 0
                    for k in -radius ... radius { v += f[y * pw + min(max(x + k, 0), pw - 1)] * kernel[k + radius] }
                    tmp[y * pw + x] = v / ksum
                }
            }
            for y in 0 ..< ph {
                for x in 0 ..< pw {
                    var v: Float = 0
                    for k in -radius ... radius { v += tmp[min(max(y + k, 0), ph - 1) * pw + x] * kernel[k + radius] }
                    out[y * pw + x] = v / ksum
                }
            }
            return out
        }
        var inPlay = [Float](repeating: 0, count: n)
        for i in 0 ..< n where before[i] > 0 { inPlay[i] = 1 }
        var weighted = change
        for i in 0 ..< n { weighted[i] *= inPlay[i] }
        let num = blur(weighted), den = blur(inPlay)
        var after = before
        for i in 0 ..< n where inBox.v[i] > 0 && inPlay[i] > 0 {
            let soft = den[i] > 1e-6 ? max(num[i] / den[i], change[i]) : change[i]
            if soft <= 0 { continue }
            let a = Float(before[i]) / 255
            after[i] = UInt8((min(max(a - soft, 0), a) * 255).rounded())
        }
        // 4. Tidy: pieces the box cut loose go; in automatic mode holes it opened close, but
        // never over a pixel that matched (an enclosed patch of wall stays open). The
        // eyedropper's box never refills.
        let hardBefore = before.map { $0 >= 128 }, hardAfter = after.map { $0 >= 128 }
        let (labB, countB) = SubjectSelect.label(hardBefore, w: pw, h: ph)
        var areaB = [Int](repeating: 0, count: countB + 1)
        for l in labB where l > 0 { areaB[Int(l)] += 1 }
        let (labA, countA) = SubjectSelect.label(hardAfter, w: pw, h: ph)
        var loose = 0, closed = 0
        if countA > 0 {
            var areaA = [Int](repeating: 0, count: countA + 1), wasBigger = [Bool](repeating: false, count: countA + 1)
            for i in 0 ..< n where labA[i] > 0 {
                areaA[Int(labA[i])] += 1
                if labB[i] > 0 { wasBigger[Int(labA[i])] = true }
            }
            for i in 0 ..< n where labA[i] > 0 {
                let l = Int(labA[i])
                if areaA[l] < rs.tidy && wasBigger[l] && labB[i] > 0 && areaB[Int(labB[i])] > areaA[l] && inBox.v[i] > 0 {
                    after[i] = 0
                    loose += 1
                }
            }
        }
        if automatic {
            let (holes, holeCount) = SubjectSelect.label(after.map { $0 < 128 }, w: pw, h: ph)
            if holeCount > 0 {
                var area = [Int](repeating: 0, count: holeCount + 1), open = [Bool](repeating: false, count: holeCount + 1)
                var opened = [Bool](repeating: false, count: holeCount + 1)
                for i in 0 ..< n where holes[i] > 0 {
                    let l = Int(holes[i])
                    area[l] += 1
                    let x = i % pw, y = i / pw
                    if x == 0 || y == 0 || x == pw - 1 || y == ph - 1 { open[l] = true }
                    if hardBefore[i] { opened[l] = true }
                }
                for i in 0 ..< n where holes[i] > 0 {
                    let l = Int(holes[i])
                    if area[l] < rs.tidy && !open[l] && opened[l] && after[i] != before[i] && !matched[i] {
                        after[i] = before[i]
                        closed += 1
                    }
                }
            }
        }
        // 5. Shares: where coverage was taken, scaled down with it, all three together.
        var changed = 0
        var removedSum = 0.0
        for i in 0 ..< n where after[i] != before[i] {
            changed += 1
            removedSum += Double(Int(before[i]) - Int(after[i])) / 255
            let k = Float(after[i]) / max(Float(before[i]), 1)
            for ch in 0 ..< 3 { share[i * 4 + ch] = UInt8((Float(share[i * 4 + ch]) * k).rounded()) }
        }
        log.append("remove colour (\(automatic ? "automatic" : "eyedropper")): \(changed) px changed, mean alpha removed "
            + String(format: "%.3f", locale: posix, changed > 0 ? removedSum / Double(changed) : 0)
            + ", samples \(used.count), tolerance " + String(format: "%.3f", locale: posix, tolerance)
            + " · box \(box.w)×\(box.h) px at \(box.x),\(box.y) · \(loose) px cut loose and taken out, \(closed) px of small holes closed")
        // 6. Then the edge colour step inside the box (and 4 px round it): the cut of leftover
        // background-coloured bits, and both repaints, from the new mask.
        var stats: EdgeColour.Stats?
        if c.settings.insideColour {
            let region = PixelRect(x: box.x - patch.x - 4, y: box.y - patch.y - 4, w: box.w + 8, h: box.h + 8).clamped(w: pw, h: ph)
            for y in region.y ..< region.maxY {
                for x in region.x ..< region.maxX {
                    let o = (y * pw + x) * 4
                    map[o] = 128; map[o + 1] = 128; map[o + 2] = 0; map[o + 3] = 255
                    back[o] = 128; back[o + 1] = 128; back[o + 2] = 0; back[o + 3] = 255
                }
            }
            let faces = c.faces, skin = c.skin
            stats = after.withUnsafeMutableBufferPointer { ap in
                share.withUnsafeMutableBufferPointer { sp in
                    map.withUnsafeMutableBufferPointer { mp in
                        back.withUnsafeMutableBufferPointer { bp in
                            EdgeColour.run(photo: photo, alpha: ap.baseAddress!, shares: sp.baseAddress!, map: mp.baseAddress!, back: bp.baseAddress!,
                                           rect: region, settings: s,
                                           skip: { x, y, F in hairSkip(patch.x + x, patch.y + y, F, faces: faces, skin: skin) },
                                           matched: { x, y in matchesAny[y * pw + x] }, rimOff: !automatic)
                        }
                    }
                }
            }
            if let st = stats { log += st.lines }
        }
        var out = MatteOutput(w: pw, h: ph, alpha: after, shares: share, trimap: [], trimapW: 0, trimapH: 0,
                              band: PixelRect(x: 0, y: 0, w: pw, h: ph), unknownPixels: 0, log: log)
        out.repaintStats = stats?.repaint
        out.edgeColourStats = stats
        out.repaint = c.settings.insideColour || repaint != nil ? map : nil
        out.repaintBack = c.settings.insideColour || repaintBack != nil ? back : nil
        var result = RefineResult(patch: patch, weight: inBox, output: out, log: log)
        result.samples = used
        return result
    }

    /// The edge colour step's exclusion in a tool's patch: the hair zone, unless the inside
    /// colour is skin.
    static func hairSkip(_ x: Int, _ y: Int, _ F: SIMD3<Float>, faces: [PixelRect], skin: SkinModel?) -> Bool {
        guard hairZone(x, y, faces: faces) >= 0.5 else { return false }
        guard let skin = skin else { return true }
        return skin.value(SIMD3(pow(F.x, 1 / 2.2), pow(F.y, 1 / 2.2), pow(F.z, 1 / 2.2))) < 0.5
    }

    /// The Edge Colour box (spec v7.2, 5): inside the box nothing is rim light; every band
    /// pixel with an inside colour joins the repaint's core, and the cut runs.
    public static func edgeColour(box: PixelRect, alpha: [UInt8], shares: [UInt8], repaint: [UInt8]?, repaintBack: [UInt8]?,
                                  context c: RefineContext) -> RefineResult {
        let W = c.photo.w, H = c.photo.h
        let s = c.settings.inside
        let patch = Refine.patch(around: box, margin: max(margin(W, H), Int(s.reach + s.solidDepth) + 8), w: W, h: H)
        let pw = patch.w, ph = patch.h, n = pw * ph
        let photo = c.photo.cropped(patch)
        var a = [UInt8](repeating: 0, count: n), share = [UInt8](repeating: 0, count: n * 4)
        var map = Repaint.blank(count: n), back = Repaint.blank(count: n)
        for y in 0 ..< ph {
            for x in 0 ..< pw {
                let o = (patch.y + y) * W + patch.x + x, i = y * pw + x
                a[i] = alpha[o]
                for ch in 0 ..< 4 {
                    share[i * 4 + ch] = shares[o * 4 + ch]
                    if let r = repaint { map[i * 4 + ch] = r[o * 4 + ch] }
                    if let r = repaintBack { back[i * 4 + ch] = r[o * 4 + ch] }
                }
            }
        }
        let before = a
        let region = PixelRect(x: box.x - patch.x - 4, y: box.y - patch.y - 4, w: box.w + 8, h: box.h + 8).clamped(w: pw, h: ph)
        for y in region.y ..< region.maxY {
            for x in region.x ..< region.maxX {
                let o = (y * pw + x) * 4
                map[o] = 128; map[o + 1] = 128; map[o + 2] = 0; map[o + 3] = 255
                back[o] = 128; back[o + 1] = 128; back[o + 2] = 0; back[o + 3] = 255
            }
        }
        let faces = c.faces, skin = c.skin
        var settings = s
        settings.cut = true
        let stats = a.withUnsafeMutableBufferPointer { ap in
            share.withUnsafeMutableBufferPointer { sp in
                map.withUnsafeMutableBufferPointer { mp in
                    back.withUnsafeMutableBufferPointer { bp in
                        EdgeColour.run(photo: photo, alpha: ap.baseAddress!, shares: sp.baseAddress!, map: mp.baseAddress!, back: bp.baseAddress!,
                                       rect: region, settings: settings,
                                       skip: { x, y, F in hairSkip(patch.x + x, patch.y + y, F, faces: faces, skin: skin) }, rimOff: true)
                    }
                }
            }
        }
        var changed = 0
        for i in 0 ..< n where a[i] != before[i] { changed += 1 }
        let log = ["edge colour box \(box.w)×\(box.h) px at \(box.x),\(box.y): \(stats.repaint.core) px repainted (core), \(stats.cut?.cut ?? 0) px cut"] + stats.lines
        var out = MatteOutput(w: pw, h: ph, alpha: a, shares: share, trimap: [], trimapW: 0, trimapH: 0,
                              band: PixelRect(x: 0, y: 0, w: pw, h: ph), unknownPixels: 0, log: log)
        out.repaintStats = stats.repaint
        out.edgeColourStats = stats
        out.repaint = map
        out.repaintBack = back
        return RefineResult(patch: patch, weight: weight(box: box, in: patch, feather: 1), output: out, log: log)
    }
}
