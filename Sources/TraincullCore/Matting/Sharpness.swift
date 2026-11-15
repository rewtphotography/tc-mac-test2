import Foundation

/// How out of focus each part of a picture is, estimated from its edges (Zhuo and Sim, 2011).
///
/// An edge that is already soft changes little when blurred a bit more; a crisp one changes a
/// lot. So the picture is blurred slightly, and at each edge the steepness before is compared
/// with the steepness after: that ratio gives the width of the blur the edge already had.
/// Small numbers are sharp. Widths are in pixels of the picture given.
public struct SharpnessMap {
    public let w: Int
    public let h: Int
    /// The blur width at each edge pixel; meaningless elsewhere.
    public let sigma: [Float]
    public let edge: [Bool]
    /// The blur width everywhere, filled in smoothly between the edges.
    public let dense: Gray

    public static let reblur: Float = 1.0
    public static let most: Float = 8.0

    /// - Parameter luma: brightness from 0 to 1, as displayed.
    public init(luma: Gray) {
        w = luma.w; h = luma.h
        let w = luma.w, h = luma.h, n = w * h
        // The same picture, blurred by one pixel.
        let k: [Float] = [-3, -2, -1, 0, 1, 2, 3].map { exp(-$0 * $0 / (2 * SharpnessMap.reblur * SharpnessMap.reblur)) }
        let ksum = k.reduce(0, +)
        var tmp = [Float](repeating: 0, count: n), blurred = [Float](repeating: 0, count: n)
        luma.v.withUnsafeBufferPointer { src in
            tmp.withUnsafeMutableBufferPointer { t in
                let dst = t
                parallelRows(h) { rows in
                    for y in rows {
                        for x in 0 ..< w {
                            var s: Float = 0
                            for i in 0 ..< 7 { s += k[i] * src[y * w + min(max(x + i - 3, 0), w - 1)] }
                            dst[y * w + x] = s / ksum
                        }
                    }
                }
            }
        }
        tmp.withUnsafeBufferPointer { src in
            blurred.withUnsafeMutableBufferPointer { b in
                let dst = b
                parallelRows(h) { rows in
                    for y in rows {
                        for x in 0 ..< w {
                            var s: Float = 0
                            for i in 0 ..< 7 { s += k[i] * src[min(max(y + i - 3, 0), h - 1) * w + x] }
                            dst[y * w + x] = s / ksum
                        }
                    }
                }
            }
        }
        // Steepness (Sobel), before and after, and the direction of the slope before.
        var g = [Float](repeating: 0, count: n), gb = [Float](repeating: 0, count: n)
        var gx = [Float](repeating: 0, count: n), gy = [Float](repeating: 0, count: n)
        func sobel(_ p: UnsafeBufferPointer<Float>, _ x: Int, _ y: Int) -> (Float, Float) {
            let x0 = max(x - 1, 0), x1 = min(x + 1, w - 1), y0 = max(y - 1, 0), y1 = min(y + 1, h - 1)
            let a = p[y0 * w + x0], b = p[y0 * w + x], c = p[y0 * w + x1]
            let d = p[y * w + x0], f = p[y * w + x1]
            let q = p[y1 * w + x0], r = p[y1 * w + x], s = p[y1 * w + x1]
            return (((c + 2 * f + s) - (a + 2 * d + q)) / 8, ((q + 2 * r + s) - (a + 2 * b + c)) / 8)
        }
        luma.v.withUnsafeBufferPointer { src in
            blurred.withUnsafeBufferPointer { bl in
                g.withUnsafeMutableBufferPointer { go in
                    gb.withUnsafeMutableBufferPointer { gbo in
                        gx.withUnsafeMutableBufferPointer { gxo in
                            gy.withUnsafeMutableBufferPointer { gyo in
                                let gOut = go, gbOut = gbo, gxOut = gxo, gyOut = gyo
                                parallelRows(h) { rows in
                                    for y in rows {
                                        for x in 0 ..< w {
                                            let (ax, ay) = sobel(src, x, y), (bx, by) = sobel(bl, x, y)
                                            let i = y * w + x
                                            gOut[i] = (ax * ax + ay * ay).squareRoot()
                                            gbOut[i] = (bx * bx + by * by).squareRoot()
                                            gxOut[i] = ax; gyOut[i] = ay
                                        }
                                    }
                                }
                            }
                        }
                    }
                }
            }
        }
        // Edges: the steepest 15% of the picture, at least a 2% step. The bar is never set
        // above a 4% step, though: in a photo full of crisp detail the steepest 15% would be
        // crisp edges only, and the soft edges of whatever is out of focus, the very thing
        // being measured, would be left out.
        var sample: [Float] = []
        sample.reserveCapacity(n / 7 + 1)
        for i in stride(from: 0, to: n, by: 7) { sample.append(g[i]) }
        sample.sort()
        let threshold = min(max(sample.isEmpty ? 0 : sample[min(Int(Float(sample.count) * 0.85), sample.count - 1)], 0.02), 0.04)
        var e = [Bool](repeating: false, count: n), s = [Float](repeating: SharpnessMap.most, count: n)
        var weight = [Float](repeating: 0, count: n)
        for y in 1 ..< max(h - 1, 1) {
            for x in 1 ..< max(w - 1, 1) {
                let i = y * w + x
                if g[i] <= threshold { continue }
                // Keep only the crest of each edge: steeper than both neighbours along the slope.
                let horizontal = abs(gx[i]) >= abs(gy[i])
                let sameSign = gx[i] * gy[i] > 0
                let diagonal = min(abs(gx[i]), abs(gy[i])) > 0.41 * max(abs(gx[i]), abs(gy[i]))
                let (dx, dy): (Int, Int) = diagonal ? (1, sameSign ? 1 : -1) : (horizontal ? (1, 0) : (0, 1))
                if g[i] < g[i + dy * w + dx] || g[i] < g[i - dy * w - dx] { continue }
                e[i] = true
                let r = g[i] / max(gb[i], 1e-6)
                s[i] = r > 1.01 ? min(SharpnessMap.reblur / (r * r - 1).squareRoot(), SharpnessMap.most) : SharpnessMap.most
                weight[i] = 1
            }
        }
        edge = e
        sigma = s
        dense = Gray(w: w, h: h, v: PlaneMath.fill(s, weights: weight, w: w, h: h, empty: SharpnessMap.most))
    }

    /// The typical blur width of the edges in a rectangle, or nil with fewer than `atLeast` of them.
    public func median(in rect: PixelRect, atLeast: Int = 50) -> Float? {
        let r = rect.clamped(w: w, h: h)
        if r.isEmpty { return nil }
        var values: [Float] = []
        for y in r.y ..< r.maxY {
            for x in r.x ..< r.maxX where edge[y * w + x] { values.append(sigma[y * w + x]) }
        }
        if values.count < atLeast { return nil }
        values.sort()
        return values[values.count / 2]
    }

    /// How sharp a face is: the typical blur width across its eyes (the band from a quarter to
    /// just over half way down the face).
    public func faceSharp(_ face: PixelRect) -> Float? {
        median(in: PixelRect(x: face.x, y: face.y + face.h / 4, w: face.w, h: max(face.h * 3 / 10, 1)))
    }
}

extension PlaneMath {
    /// Spreads values known at some pixels (weight 1) smoothly across the rest (weight 0):
    /// averaged down level by level, then filled back in from coarse to fine.
    static func fill(_ values: [Float], weights: [Float], w: Int, h: Int, empty: Float) -> [Float] {
        struct Level { var w: Int, h: Int, c: [Float], wt: [Float] }
        var levels = [Level(w: w, h: h, c: zip(values, weights).map { $0 * $1 }, wt: weights)]
        while max(levels.last!.w, levels.last!.h) > 4 {
            let fine = levels.last!
            let cw = (fine.w + 1) / 2, ch = (fine.h + 1) / 2
            var coarse = Level(w: cw, h: ch, c: [Float](repeating: 0, count: cw * ch), wt: [Float](repeating: 0, count: cw * ch))
            for y in 0 ..< ch {
                for x in 0 ..< cw {
                    var s: Float = 0, ws: Float = 0
                    for yy in (y * 2) ..< min(y * 2 + 2, fine.h) {
                        for xx in (x * 2) ..< min(x * 2 + 2, fine.w) {
                            s += fine.c[yy * fine.w + xx]; ws += fine.wt[yy * fine.w + xx]
                        }
                    }
                    let k = ws > 1 ? 1 / ws : 1
                    coarse.c[y * cw + x] = s * k
                    coarse.wt[y * cw + x] = min(ws, 1)
                }
            }
            levels.append(coarse)
        }
        for l in stride(from: levels.count - 2, through: 0, by: -1) {
            let coarse = levels[l + 1]
            let cc = Gray(w: coarse.w, h: coarse.h, v: coarse.c), cw = Gray(w: coarse.w, h: coarse.h, v: coarse.wt)
            let lw = levels[l].w, lh = levels[l].h
            let kx = Float(coarse.w) / Float(lw), ky = Float(coarse.h) / Float(lh)
            var c = levels[l].c, wt = levels[l].wt
            for y in 0 ..< lh {
                for x in 0 ..< lw {
                    let i = y * lw + x
                    let gap = 1 - wt[i]
                    if gap <= 0 { continue }
                    let sx = (Float(x) + 0.5) * kx, sy = (Float(y) + 0.5) * ky
                    c[i] += gap * cc.sample(sx, sy)
                    wt[i] += gap * cw.sample(sx, sy)
                }
            }
            levels[l].c = c
            levels[l].wt = wt
        }
        var out = levels[0].c
        for i in 0 ..< w * h { out[i] = levels[0].wt[i] > 1e-4 ? out[i] / levels[0].wt[i] : empty }
        return out
    }
}

/// Which person a photo is of, when it has several faces: the one that is large and in focus.
public enum SubjectChoice {
    public struct Candidate: Equatable {
        public let face: PixelRect
        /// The blur width across the eyes; nil when too few edges were found to tell.
        public let sharp: Float?
        public let score: Float
    }

    /// The faces worth considering, best first: at least 1.5% of the picture's long edge wide,
    /// ranked by size over blur. Faces whose sharpness couldn't be measured come last.
    public static func rank(_ faces: [PixelRect], sharpness: SharpnessMap) -> [Candidate] {
        let least = 0.015 * Float(max(sharpness.w, sharpness.h))
        return faces.filter { Float($0.w) >= least }.map { f -> Candidate in
            let sharp = sharpness.faceSharp(f)
            let size = (Float(f.w) * Float(f.h)).squareRoot()
            return Candidate(face: f, sharp: sharp, score: sharp.map { size / ($0 + 0.25) } ?? 0)
        }.sorted { a, b in
            if (a.sharp == nil) != (b.sharp == nil) { return a.sharp != nil }
            return a.score != b.score ? a.score > b.score : a.face.w * a.face.h > b.face.w * b.face.h
        }
    }

    /// The box a person's body is expected to fall in, from their face: two face-widths either
    /// side, from a little above the head to six and a half face-heights below the chin.
    public static func bodyBox(face f: PixelRect, w: Int, h: Int) -> PixelRect {
        let cx = Float(f.x) + Float(f.w) / 2
        let x0 = Int((cx - 2 * Float(f.w)).rounded(.down)), x1 = Int((cx + 2 * Float(f.w)).rounded(.up))
        let y0 = Int((Float(f.y) - 0.8 * Float(f.h)).rounded(.down)), y1 = Int((Float(f.maxY) + 6.5 * Float(f.h)).rounded(.up))
        return PixelRect(x: x0, y: y0, w: x1 - x0, h: y1 - y0).clamped(w: w, h: h)
    }
}
