import Foundation

/// Remove Colour (masking spec v7, section 3): a box for where the mask really takes in some
/// background (an orange wall round a rose). The user samples the colour to remove with an
/// eyedropper; inside the box, near the mask's outline, pixels that are a mix of the inside
/// colour and a sampled colour lose as much coverage as is the sampled colour's.
public struct RemoveColourSettings: Equatable {
    /// How far from the mask's outline the box may act, either side, in photo pixels. The
    /// deeper interior is never touched.
    public var reach: Float = 40
    /// The change in alpha is softened over this radius (Gaussian σ = half of it).
    public var smooth: Float = 1.5
    /// Pieces cut loose, and holes opened, smaller than this many pixels are tidied away.
    public var tidy = 50

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

    /// Remove Colour. `samples` are the eyedropper's colours (display values, 0 to 1),
    /// `tolerance` an Oklab distance; `repaint` the mask's repaint map (`Repaint`), if it has
    /// one. Returns the patch to lay in through the box's soft edge, like Refine Edges, with
    /// the repaint worked out again inside the box (spec v7.1, 1.2).
    ///
    /// Spec v7.1, 3 and 4: a pixel's match with a sample is soft (`weight` 1 within the
    /// tolerance, falling to 0 at twice it); a pixel that matches is taken out anywhere in the
    /// box, and partly matching pixels on the line between the inside colour and the sample
    /// only within `reach` of the outline. The inside colour is taken only from subject that
    /// doesn't match. Holes the box opens are never refilled where a pixel matched, and
    /// matching pixels get no rim-light protection.
    public static func removeColour(box: PixelRect, samples: [SIMD3<Float>], tolerance: Float, alpha: [UInt8], shares: [UInt8], repaint: [UInt8]? = nil,
                                    context c: RefineContext, settings rs: RemoveColourSettings = RemoveColourSettings()) -> RefineResult {
        let W = c.photo.w, H = c.photo.h
        let s = c.settings.inside
        let patch = Refine.patch(around: box, margin: max(margin(W, H), Int(rs.reach + s.reach + s.solidDepth) + 8), w: W, h: H)
        let pw = patch.w, ph = patch.h, n = pw * ph
        let photo = c.photo.cropped(patch)
        var before = [UInt8](repeating: 0, count: n), share = [UInt8](repeating: 0, count: n * 4)
        var map = Repaint.blank(count: n)
        for y in 0 ..< ph {
            for x in 0 ..< pw {
                let o = (patch.y + y) * W + patch.x + x, i = y * pw + x
                before[i] = alpha[o]
                for ch in 0 ..< 4 {
                    share[i * 4 + ch] = shares[o * 4 + ch]
                    if let r = repaint { map[i * 4 + ch] = r[o * 4 + ch] }
                }
            }
        }
        let inBox = weight(box: box, in: patch, feather: 6)
        let lin = Matte.toLinear.p
        let removed = samples.map { c3 -> (lin: SIMD3<Float>, lab: SIMD3<Float>) in
            let l = SIMD3<Float>(lin[Int(min(max(c3.x, 0), 1) * 255)], lin[Int(min(max(c3.y, 0), 1) * 255)], lin[Int(min(max(c3.z, 0), 1) * 255)])
            return (l, Oklab.from(linear: l))
        }
        if removed.isEmpty {
            var out = MatteOutput(w: pw, h: ph, alpha: before, shares: share, trimap: [], trimapW: 0, trimapH: 0,
                                  band: PixelRect(x: 0, y: 0, w: 0, h: 0), unknownPixels: 0, log: [])
            out.repaint = repaint == nil ? nil : map
            return RefineResult(patch: patch, weight: inBox, output: out, log: ["remove colour: nothing sampled, nothing done"])
        }
        let tol = max(tolerance, 1e-4)
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
        // 1. How much of each pixel goes.
        var change = [Float](repeating: 0, count: n)
        var matched = [Bool](repeating: false, count: n)
        for y in 0 ..< ph {
            for x in 0 ..< pw {
                let i = y * pw + x
                if inBox.v[i] <= 0 || before[i] == 0 { continue }
                var remove = 1 - smoothstep(tol, 2 * tol, nearest[i])
                if remove > 0 { matched[i] = true }
                if abs(field0.depth[i]) <= rs.reach && field0.source[i] >= 0 {
                    let src = Int(field0.source[i])
                    let F = InsideColour.median3(photo, src % pw, src / pw)
                    let I = InsideColour.linear(photo, x, y), B = removed[which[i]]
                    let along = 1 - smoothstep(tol, 2 * tol, toSegment(Oklab.from(linear: I), Oklab.from(linear: F), B.lab))
                    if along > 0 {
                        let d = B.lin - F
                        let t = min(max(((I - F) * d).sum() / max((d * d).sum(), 1e-12), 0), 1)
                        remove = max(remove, along * t)
                    }
                }
                let a = Float(before[i]) / 255
                change[i] = a - min(a, 1 - remove)
            }
        }
        // 2. The change softened (not the alpha), inside the box only, averaged over the pixels
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
        // 3. Tidy: pieces the box cut loose go; holes it opened close, but never over a pixel
        // that matched a sample (an enclosed patch of wall stays open).
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
        // 4. Shares: where coverage was taken, scaled down with it, all three together; then
        // the repaint is worked out again inside the box (and 4 px round it) from the new mask.
        var changed = 0
        var removedSum = 0.0
        for i in 0 ..< n where after[i] != before[i] {
            changed += 1
            removedSum += Double(Int(before[i]) - Int(after[i])) / 255
            let k = Float(after[i]) / max(Float(before[i]), 1)
            for ch in 0 ..< 3 { share[i * 4 + ch] = UInt8((Float(share[i * 4 + ch]) * k).rounded()) }
        }
        var stats: RepaintStats?
        if c.settings.insideColour {
            let region = PixelRect(x: box.x - patch.x - 4, y: box.y - patch.y - 4, w: box.w + 8, h: box.h + 8).clamped(w: pw, h: ph)
            for y in region.y ..< region.maxY {
                for x in region.x ..< region.maxX {
                    let o = (y * pw + x) * 4
                    map[o] = 128; map[o + 1] = 128; map[o + 2] = 0; map[o + 3] = 255
                }
            }
            let faces = c.faces, skin = c.skin
            stats = after.withUnsafeBufferPointer { ap in
                share.withUnsafeMutableBufferPointer { sp in
                    map.withUnsafeMutableBufferPointer { mp in
                        Repaint.apply(photo: photo, alpha: ap.baseAddress!, shares: sp.baseAddress!, map: mp.baseAddress!, rect: region, settings: s,
                                      skip: { x, y, F in
                                          guard hairZone(patch.x + x, patch.y + y, faces: faces) >= 0.5 else { return false }
                                          guard let skin = skin else { return true }
                                          return skin.value(SIMD3(pow(F.x, 1 / 2.2), pow(F.y, 1 / 2.2), pow(F.z, 1 / 2.2))) < 0.5
                                      },
                                      matched: { x, y in matchesAny[y * pw + x] })
                    }
                }
            }
        }
        let posix = Locale(identifier: "en_US_POSIX")
        var log = ["remove colour: \(changed) px changed, mean alpha removed " + String(format: "%.3f", locale: posix, changed > 0 ? removedSum / Double(changed) : 0)
            + ", samples \(samples.count), tolerance " + String(format: "%.3f", locale: posix, tolerance)
            + " · box \(box.w)×\(box.h) px at \(box.x),\(box.y) · \(loose) px cut loose and taken out, \(closed) px of small holes closed"]
        if let stats = stats { log.append(stats.summary) }
        var out = MatteOutput(w: pw, h: ph, alpha: after, shares: share, trimap: [], trimapW: 0, trimapH: 0,
                              band: PixelRect(x: 0, y: 0, w: pw, h: ph), unknownPixels: 0, log: log)
        out.repaintStats = stats
        out.repaint = c.settings.insideColour || repaint != nil ? map : nil
        return RefineResult(patch: patch, weight: inBox, output: out, log: log)
    }
}
