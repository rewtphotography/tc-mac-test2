import Dispatch
import Foundation

/// Closed-form matting (Levin, Lischinski and Weiss) on one rectangle of a photo.
///
/// The idea: within any 3×3 window of a photograph the colours lie close to a line, so the
/// mask there is close to a straight-line function of colour. Asking for that in every window
/// at once ties each pixel's alpha to its neighbours' and pulls single strands out of the
/// background. It is a large set of linear equations, one per pixel, solved here by
/// conjugate gradients without ever writing the matrix down: `apply` computes what the
/// matrix would do to a vector, window by window.
///
/// Everything is in double precision. In flat areas the windows' colour spread is almost
/// zero and its inverse enormous, and single precision turns that into visible error.
final class ClosedFormTile {
    let w: Int, h: Int
    /// The pixels being solved for. The rest keep the values they start with.
    let acts: [Int]
    /// The windows (by centre pixel) that touch at least one of those pixels.
    let wins: [Int]
    private let img: Buf<Double> // red, green, blue per pixel
    private let mu: Buf<Double> // each window's mean colour
    private let inv: Buf<Double> // each window's inverse colour spread: 6 numbers of a symmetric 3×3
    private let cv: Buf<Double> // scratch: 4 numbers per window
    private let lam: Buf<Double>

    /// - Parameters:
    ///   - rgb: three values per pixel, 0 to 1.
    ///   - lam: how firmly each pixel is held to its starting value.
    ///   - active: the pixels to solve for.
    init(w: Int, h: Int, rgb: [Double], lam: [Double], active: [Bool], epsilon: Double) {
        self.w = w; self.h = h
        img = Buf(rgb)
        self.lam = Buf(lam)
        var a: [Int] = [], k: [Int] = []
        for y in 0 ..< h {
            for x in 0 ..< w {
                let i = y * w + x
                if active[i] { a.append(i) }
                if x == 0 || y == 0 || x == w - 1 || y == h - 1 { continue }
                var touches = false
                for dy in -1 ... 1 where !touches {
                    for dx in -1 ... 1 where active[i + dy * w + dx] { touches = true; break }
                }
                if touches { k.append(i) }
            }
        }
        acts = a
        wins = k
        mu = Buf(w * h * 3, 0)
        inv = Buf(w * h * 6, 0)
        cv = Buf(w * h * 4, 0)
        let I = img.p
        for c in wins {
            var m0 = 0.0, m1 = 0.0, m2 = 0.0
            for dy in -1 ... 1 {
                for dx in -1 ... 1 {
                    let j = (c + dy * w + dx) * 3
                    m0 += I[j]; m1 += I[j + 1]; m2 += I[j + 2]
                }
            }
            m0 /= 9; m1 /= 9; m2 /= 9
            var s00 = 0.0, s01 = 0.0, s02 = 0.0, s11 = 0.0, s12 = 0.0, s22 = 0.0
            for dy in -1 ... 1 {
                for dx in -1 ... 1 {
                    let j = (c + dy * w + dx) * 3
                    let r = I[j] - m0, g = I[j + 1] - m1, b = I[j + 2] - m2
                    s00 += r * r; s01 += r * g; s02 += r * b; s11 += g * g; s12 += g * b; s22 += b * b
                }
            }
            let e = epsilon / 9
            s00 = s00 / 9 + e; s01 /= 9; s02 /= 9; s11 = s11 / 9 + e; s12 /= 9; s22 = s22 / 9 + e
            // The inverse of a symmetric 3×3, by cofactors.
            let c00 = s11 * s22 - s12 * s12, c01 = s02 * s12 - s01 * s22, c02 = s01 * s12 - s02 * s11
            let c11 = s00 * s22 - s02 * s02, c12 = s01 * s02 - s00 * s12, c22 = s00 * s11 - s01 * s01
            let det = s00 * c00 + s01 * c01 + s02 * c02
            let d = det != 0 ? 1 / det : 0
            mu.p[c * 3] = m0; mu.p[c * 3 + 1] = m1; mu.p[c * 3 + 2] = m2
            let o = c * 6
            inv.p[o] = c00 * d; inv.p[o + 1] = c01 * d; inv.p[o + 2] = c02 * d
            inv.p[o + 3] = c11 * d; inv.p[o + 4] = c12 * d; inv.p[o + 5] = c22 * d
        }
    }

    @inline(__always) private func isWindow(_ x: Int, _ y: Int) -> Bool { x >= 1 && y >= 1 && x < w - 1 && y < h - 1 }

    /// What the matting equations do to `x`, written to `out` for the active pixels:
    /// (L + Λ) x, where L ties each pixel to its windows and Λ holds it to its prior.
    func apply(_ x: UnsafeMutablePointer<Double>, _ out: UnsafeMutablePointer<Double>) {
        let I = img.p, w = self.w
        for c in wins {
            let m0 = mu.p[c * 3], m1 = mu.p[c * 3 + 1], m2 = mu.p[c * 3 + 2]
            var sx = 0.0, u0 = 0.0, u1 = 0.0, u2 = 0.0
            for dy in -1 ... 1 {
                let row = c + dy * w
                for j in (row - 1) ... (row + 1) {
                    let xv = x[j]
                    sx += xv
                    u0 += (I[j * 3] - m0) * xv; u1 += (I[j * 3 + 1] - m1) * xv; u2 += (I[j * 3 + 2] - m2) * xv
                }
            }
            sx /= 9; u0 /= 9; u1 /= 9; u2 /= 9
            let o = c * 6
            let v0 = inv.p[o] * u0 + inv.p[o + 1] * u1 + inv.p[o + 2] * u2
            let v1 = inv.p[o + 1] * u0 + inv.p[o + 3] * u1 + inv.p[o + 4] * u2
            let v2 = inv.p[o + 2] * u0 + inv.p[o + 4] * u1 + inv.p[o + 5] * u2
            cv.p[c * 4] = v0; cv.p[c * 4 + 1] = v1; cv.p[c * 4 + 2] = v2
            cv.p[c * 4 + 3] = sx - (m0 * v0 + m1 * v1 + m2 * v2)
        }
        for i in acts {
            let px = i % w, py = i / w
            var s0 = 0.0, s1 = 0.0, s2 = 0.0, sc = 0.0, n = 0.0
            for dy in -1 ... 1 {
                for dx in -1 ... 1 where isWindow(px + dx, py + dy) {
                    let k = (i + dy * w + dx) * 4
                    s0 += cv.p[k]; s1 += cv.p[k + 1]; s2 += cv.p[k + 2]; sc += cv.p[k + 3]
                    n += 1
                }
            }
            out[i] = n * x[i] - sc - (I[i * 3] * s0 + I[i * 3 + 1] * s1 + I[i * 3 + 2] * s2) + lam.p[i] * x[i]
        }
    }

    /// The matrix's diagonal for the active pixels, used to precondition the solve.
    func diagonal(_ out: UnsafeMutablePointer<Double>) {
        let I = img.p
        for i in acts {
            let px = i % w, py = i / w
            var d = lam.p[i]
            for dy in -1 ... 1 {
                for dx in -1 ... 1 where isWindow(px + dx, py + dy) {
                    let c = i + dy * w + dx
                    let r = I[i * 3] - mu.p[c * 3], g = I[i * 3 + 1] - mu.p[c * 3 + 1], b = I[i * 3 + 2] - mu.p[c * 3 + 2]
                    let o = c * 6
                    let q = r * (inv.p[o] * r + inv.p[o + 1] * g + inv.p[o + 2] * b)
                        + g * (inv.p[o + 1] * r + inv.p[o + 3] * g + inv.p[o + 4] * b)
                        + b * (inv.p[o + 2] * r + inv.p[o + 4] * g + inv.p[o + 5] * b)
                    d += 1 - (1 + q) / 9
                }
            }
            out[i] = d
        }
    }

    /// Solves (L + Λ) x = Λ·prior for the active pixels by preconditioned conjugate gradients,
    /// starting from `x`, which also gives the values of the pixels that are not solved for.
    /// Returns how many steps it took.
    func solve(_ x: inout [Double], prior: [Double], maxIterations: Int, tolerance: Double) -> Int {
        let n = w * h
        if acts.isEmpty { return 0 }
        let r = Buf<Double>(n, 0), z = Buf<Double>(n, 0), p = Buf<Double>(n, 0), ap = Buf<Double>(n, 0), dg = Buf<Double>(n, 1)
        diagonal(dg.p)
        return x.withUnsafeMutableBufferPointer { xb -> Int in
            let xp = xb.baseAddress!
            apply(xp, ap.p)
            var rz = 0.0, rr0 = 0.0
            for i in acts {
                r.p[i] = lam.p[i] * prior[i] - ap.p[i]
                z.p[i] = r.p[i] / dg.p[i]
                p.p[i] = z.p[i]
                rz += r.p[i] * z.p[i]
                rr0 += r.p[i] * r.p[i]
            }
            if rr0 <= 1e-30 { return 0 }
            var done = 0
            for it in 1 ... max(maxIterations, 1) {
                // `p` is zero outside the active pixels and stays so, which is what keeps the
                // other pixels fixed.
                apply(p.p, ap.p)
                var pap = 0.0
                for i in acts { pap += p.p[i] * ap.p[i] }
                if pap <= 0 { break }
                let a = rz / pap
                var rzNew = 0.0, rr = 0.0
                for i in acts {
                    xp[i] += a * p.p[i]
                    r.p[i] -= a * ap.p[i]
                    z.p[i] = r.p[i] / dg.p[i]
                    rzNew += r.p[i] * z.p[i]
                    rr += r.p[i] * r.p[i]
                }
                done = it
                if rr <= tolerance * tolerance * rr0 { break }
                let beta = rzNew / rz
                rz = rzNew
                for i in acts { p.p[i] = z.p[i] + beta * p.p[i] }
            }
            return done
        }
    }
}

extension Matte {
    /// The Max tier: closed-form matting over the band, one tile at a time, each solved from
    /// the High tier's answer and held loosely to it where that answer was trusted.
    func closedForm(progress: (String) -> Void, cancelled: () -> Bool) -> String {
        let band = self.band, bw = band.w, bh = band.h, qw = self.qw
        let core = settings.tileCore, apron = settings.tileApron
        let tq = triq.p
        struct Tile { var x: Int, y: Int, w: Int, h: Int, unknown: Int }
        var tiles: [Tile] = []
        for ty in stride(from: 0, to: bh, by: core) {
            for tx in stride(from: 0, to: bw, by: core) {
                let tw = min(core, bw - tx), th = min(core, bh - ty)
                var unknown = 0
                for qy in ((band.y + ty) >> 2) ... ((band.y + ty + th - 1) >> 2) {
                    for qx in ((band.x + tx) >> 2) ... ((band.x + tx + tw - 1) >> 2) where tq[qy * qw + qx] == 1 { unknown += 16 }
                }
                if unknown * 100 >= tw * th { tiles.append(Tile(x: tx, y: ty, w: tw, h: th, unknown: unknown)) }
            }
        }
        if tiles.isEmpty { return "nothing to solve" }
        tiles.sort { $0.unknown > $1.unknown }

        let before = Buf(alpha.array) // every tile starts from the same picture, whatever order they finish in
        let out = alpha.p, cf = conf.p
        let src = photo.p, rowBytes = photo.rowBytes
        let soft = settings.softPrior, hard = settings.hardPrior
        let total = tiles.count
        let lock = NSLock()
        var finished = 0, iterations = 0, stopped = false
        // Each tile needs a couple of hundred megabytes while it is being solved.
        let gate = DispatchSemaphore(value: max(1, min(ProcessInfo.processInfo.activeProcessorCount / 2, 6)))
        withoutActuallyEscaping(progress) { report in
            withoutActuallyEscaping(cancelled) { isCancelled in
                parallel(total) { t in
                    gate.wait()
                    defer { gate.signal() }
                    lock.lock()
                    if !stopped && isCancelled() { stopped = true }
                    let skip = stopped
                    lock.unlock()
                    if skip { return }
                    let tile = tiles[t]
                    let x0 = max(tile.x - apron, 0), y0 = max(tile.y - apron, 0)
                    let x1 = min(tile.x + tile.w + apron, bw), y1 = min(tile.y + tile.h + apron, bh)
                    let w = x1 - x0, h = y1 - y0, n = w * h
                    var rgb = [Double](repeating: 0, count: n * 3), lam = [Double](repeating: 0, count: n)
                    var x = [Double](repeating: 0, count: n), active = [Bool](repeating: false, count: n)
                    @inline(__always) func kind(_ lx: Int, _ ly: Int) -> UInt8 {
                        let gx = band.x + x0 + min(max(lx, 0), w - 1), gy = band.y + y0 + min(max(ly, 0), h - 1)
                        return tq[(gy >> 2) * qw + (gx >> 2)]
                    }
                    for ly in 0 ..< h {
                        for lx in 0 ..< w {
                            let i = ly * w + lx, b = (y0 + ly) * bw + (x0 + lx)
                            let c = rgbAt(src, rowBytes, band.x + x0 + lx, band.y + y0 + ly)
                            rgb[i * 3] = Double(c.x); rgb[i * 3 + 1] = Double(c.y); rgb[i * 3 + 2] = Double(c.z)
                            x[i] = Double(before.p[b])
                            if kind(lx, ly) == 1 {
                                lam[i] = soft * Double(max(cf[b], 5)) / 255
                                active[i] = true
                            } else {
                                lam[i] = hard
                                // Certain pixels within two of an uncertain one are solved too, so every
                                // window that touches an uncertain pixel is complete.
                                active[i] = kind(lx - 2, ly) == 1 || kind(lx + 2, ly) == 1 || kind(lx, ly - 2) == 1 || kind(lx, ly + 2) == 1
                                    || kind(lx - 2, ly - 2) == 1 || kind(lx + 2, ly - 2) == 1 || kind(lx - 2, ly + 2) == 1 || kind(lx + 2, ly + 2) == 1
                            }
                        }
                    }
                    let prior = x
                    let solver = ClosedFormTile(w: w, h: h, rgb: rgb, lam: lam, active: active, epsilon: settings.laplacianEpsilon)
                    let steps = solver.solve(&x, prior: prior, maxIterations: settings.maxIterations, tolerance: settings.tolerance)
                    // Keep the middle of the tile; its margin was only there to give the edges context.
                    for ly in (tile.y - y0) ..< (tile.y - y0 + tile.h) {
                        for lx in (tile.x - x0) ..< (tile.x - x0 + tile.w) where kind(lx, ly) == 1 {
                            // A solve that went wrong leaves the High tier's answer in place.
                            let v = x[ly * w + lx]
                            if v.isFinite { out[(y0 + ly) * bw + (x0 + lx)] = Float(min(max(v, 0), 1)) }
                        }
                    }
                    lock.lock()
                    finished += 1
                    iterations += steps
                    report("Max \(finished) / \(total)")
                    lock.unlock()
                }
            }
        }
        return "\(finished) of \(total) tiles, \(iterations / max(finished, 1)) steps each on average\(stopped ? ", stopped early" : "")"
    }
}
