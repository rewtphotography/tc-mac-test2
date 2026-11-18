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
    /// `tolerance` an Oklab distance. Returns the patch to lay in through the box's soft edge,
    /// like Refine Edges.
    public static func removeColour(box: PixelRect, samples: [SIMD3<Float>], tolerance: Float, alpha: [UInt8], shares: [UInt8],
                                    context c: RefineContext, settings rs: RemoveColourSettings = RemoveColourSettings()) -> RefineResult {
        let W = c.photo.w, H = c.photo.h
        let s = c.settings.inside
        let patch = Refine.patch(around: box, margin: max(margin(W, H), Int(rs.reach + s.reach + s.solidDepth) + 8), w: W, h: H)
        let pw = patch.w, ph = patch.h, n = pw * ph
        let photo = c.photo.cropped(patch)
        var before = [UInt8](repeating: 0, count: n), share = [UInt8](repeating: 0, count: n * 4)
        for y in 0 ..< ph {
            for x in 0 ..< pw {
                let o = (patch.y + y) * W + patch.x + x
                before[y * pw + x] = alpha[o]
                for ch in 0 ..< 4 { share[(y * pw + x) * 4 + ch] = shares[o * 4 + ch] }
            }
        }
        let inBox = weight(box: box, in: patch, feather: 6)
        let lin = Matte.toLinear.p
        let removed = samples.map { c3 -> (lin: SIMD3<Float>, lab: SIMD3<Float>) in
            let l = SIMD3<Float>(lin[Int(min(max(c3.x, 0), 1) * 255)], lin[Int(min(max(c3.y, 0), 1) * 255)], lin[Int(min(max(c3.z, 0), 1) * 255)])
            return (l, Oklab.from(linear: l))
        }
        var log: [String] = []
        if removed.isEmpty {
            let out = MatteOutput(w: pw, h: ph, alpha: before, shares: share, trimap: [], trimapW: 0, trimapH: 0,
                                  band: PixelRect(x: 0, y: 0, w: 0, h: 0), unknownPixels: 0, log: [])
            return RefineResult(patch: patch, weight: inBox, output: out, log: ["remove colour: nothing sampled, nothing done"])
        }
        let field0 = InsideColour.field(alpha: before, w: pw, h: ph, settings: s)
        // 1. How much of each pixel is the sampled colour.
        var change = [Float](repeating: 0, count: n)
        for y in 0 ..< ph {
            for x in 0 ..< pw {
                let i = y * pw + x
                if inBox.v[i] <= 0 || before[i] == 0 || abs(field0.depth[i]) > rs.reach { continue }
                let I = InsideColour.linear(photo, x, y), Ilab = Oklab.from(linear: I)
                var B = removed[0], dB = Float.infinity
                for r in removed {
                    let d = Oklab.distance(Ilab, r.lab)
                    if d < dB { dB = d; B = r }
                }
                var t: Float = -1
                if dB <= tolerance {
                    t = 1
                } else if field0.source[i] >= 0 {
                    let src = Int(field0.source[i])
                    let F = InsideColour.median3(photo, src % pw, src / pw)
                    if toSegment(Ilab, Oklab.from(linear: F), B.lab) <= tolerance {
                        let d = B.lin - F
                        t = min(max(((I - F) * d).sum() / max((d * d).sum(), 1e-12), 0), 1)
                    }
                }
                if t < 0 { continue }
                let a = Float(before[i]) / 255
                change[i] = a - min(a, 1 - t)
            }
        }
        // 2. The change softened (not the alpha), inside the box only, averaged over the pixels
        // that have coverage to lose: next to bare background (nothing to take) it isn't diluted.
        var inPlay = [Float](repeating: 0, count: n)
        for i in 0 ..< n where before[i] > 0 { inPlay[i] = 1 }
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
        var weighted = change
        for i in 0 ..< n { weighted[i] *= inPlay[i] }
        let num = blur(weighted), den = blur(inPlay)
        var soft = [Float](repeating: 0, count: n)
        for i in 0 ..< n where inBox.v[i] > 0 && inPlay[i] > 0 && den[i] > 1e-6 { soft[i] = num[i] / den[i] }
        var after = before
        for i in 0 ..< n where soft[i] > 0 {
            let a = Float(before[i]) / 255
            after[i] = UInt8((min(max(a - soft[i], 0), a) * 255).rounded())
        }
        // 3. Tidy: pieces the box cut loose from the subject go; holes it opened inside it close.
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
                if areaA[l] < rs.tidy && wasBigger[l] && labB[i] > 0 && areaB[Int(labB[i])] > areaA[l] {
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
                if area[l] < rs.tidy && !open[l] && opened[l] && after[i] != before[i] {
                    after[i] = before[i]
                    closed += 1
                }
            }
        }
        // 4. Colour: where coverage was taken, the subject's part is the inside colour at the
        // new coverage; elsewhere in the box the edge gets its colour from inside as usual.
        let field1 = InsideColour.field(alpha: after, w: pw, h: ph, settings: s)
        let share0 = share
        var changed = 0
        var removedSum = 0.0
        var inside = InsideColourStats()
        for y in 0 ..< ph {
            for x in 0 ..< pw {
                let i = y * pw + x
                if inBox.v[i] <= 0 { continue }
                let o = i * 4
                let I = InsideColour.linear(photo, x, y)
                let src = Int(field1.source[i])
                if after[i] != before[i] {
                    changed += 1
                    removedSum += Double(Int(before[i]) - Int(after[i])) / 255
                    let a = Float(after[i]) / 255
                    var next = SIMD3<Float>(repeating: 0)
                    if a > 0 {
                        if src >= 0 {
                            next = InsideColour.shares(pixel: I, alpha: a, inside: InsideColour.median3(photo, src % pw, src / pw))
                        } else {
                            // No inside colour to go by: the shares scaled down with the coverage, all three together.
                            let k = a / max(Float(before[i]) / 255, 1e-6)
                            next = SIMD3(Float(share[o]), Float(share[o + 1]), Float(share[o + 2])) / 255 * k
                        }
                    }
                    let bytes = (next * 255).rounded(.toNearestOrAwayFromZero)
                    share[o] = UInt8(bytes.x); share[o + 1] = UInt8(bytes.y); share[o + 2] = UInt8(bytes.z)
                    continue
                }
                // Unchanged: edge colour from inside, with its usual limits.
                guard c.settings.insideColour, after[i] > 1, field1.depth[i] <= s.bandInside else { continue }
                if src < 0 { inside.unknown += 1; continue }
                let F = InsideColour.median3(photo, src % pw, src / pw)
                if hairZone(patch.x + x, patch.y + y, faces: c.faces) >= 0.5 {
                    guard let skin = c.skin, skin.value(SIMD3(pow(F.x, 1 / 2.2), pow(F.y, 1 / 2.2), pow(F.z, 1 / 2.2))) >= 0.5 else { continue }
                }
                let a = Float(after[i]) / 255
                let now = SIMD3<Float>(Float(share[o]), Float(share[o + 1]), Float(share[o + 2])) / 255
                let C = InsideColour.rimColour(x: x, y: y, alpha: after[i], part: I * now, look: s.rimLook,
                                               alphaAt: { xx, yy in xx >= 0 && yy >= 0 && xx < pw && yy < ph ? after[yy * pw + xx] : nil },
                                               colourAt: { xx, yy in
                                                   let q = (yy * pw + xx) * 4
                                                   let sh = SIMD3<Float>(Float(share0[q]), Float(share0[q + 1]), Float(share0[q + 2])) / 255
                                                   return InsideColour.linear(photo, xx, yy) * sh / max(Float(after[yy * pw + xx]) / 255, 1e-6)
                                               })
                if InsideColour.isRim(colour: C, alpha: a, inside: F, lift: s.rimLift) { inside.rim += 1; continue }
                let next = InsideColour.shares(pixel: I, alpha: a, inside: F)
                let bytes = (next * 255).rounded(.toNearestOrAwayFromZero)
                share[o] = UInt8(bytes.x); share[o + 1] = UInt8(bytes.y); share[o + 2] = UInt8(bytes.z)
                inside.recoloured += 1
                inside.deltaE += Double(Oklab.distance(Oklab.from(linear: I * now), Oklab.from(linear: I * next)))
            }
        }
        let posix = Locale(identifier: "en_US_POSIX")
        log.append("remove colour: \(changed) px changed, mean alpha removed " + String(format: "%.3f", locale: posix, changed > 0 ? removedSum / Double(changed) : 0)
            + ", samples \(samples.count), tolerance " + String(format: "%.3f", locale: posix, tolerance)
            + " · box \(box.w)×\(box.h) px at \(box.x),\(box.y) · \(loose) px cut loose and taken out, \(closed) px of small holes closed")
        if c.settings.insideColour { log.append(inside.summary) }
        var out = MatteOutput(w: pw, h: ph, alpha: after, shares: share, trimap: [], trimapW: 0, trimapH: 0,
                              band: PixelRect(x: 0, y: 0, w: pw, h: ph), unknownPixels: 0, log: log)
        out.insideColourStats = c.settings.insideColour ? inside : nil
        return RefineResult(patch: patch, weight: inBox, output: out, log: log)
    }
}
