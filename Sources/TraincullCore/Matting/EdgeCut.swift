import Foundation

/// Masking spec v7.2 and v7.2.1: the background's own colour B̂ at the edge (v7.2 §1), the
/// bright-background edge rule (v7.2.1: a gate, and a cut decided on a blurred copy of the
/// photo), and the repaint of the background side (v7.2 §3).
public enum EdgeCut {
    /// The background's field over a crop of a mask: solid background is alpha at most
    /// `backgroundAlpha` and at least `backgroundDepth` pixels outside the half-way line; each
    /// pixel takes the nearest solid background within `backgroundReach` (−1: none).
    static func backgroundField(alpha: [UInt8], w: Int, h: Int, settings s: InsideColourSettings) -> InsideColour.Field {
        var b = s
        b.solidAlpha = 1 - s.backgroundAlpha
        b.solidDepth = s.backgroundDepth
        b.reach = s.backgroundReach
        return InsideColour.field(alpha: alpha.map { 255 - $0 }, w: w, h: h, settings: b)
    }

    /// What the rule did, for the log.
    public struct Stats: Equatable {
        /// Pixels with the gate on (over 0), pixels cut, the mean cut (alpha) where cut, the
        /// pixels of holes put back.
        public var gated = 0
        public var cut = 0
        public var removed = 0.0
        public var holesRestored = 0
        public init() {}
    }

    /// A Gaussian blur of a crop's values (σ in pixels), edges clamped.
    static func blurred<T>(_ v: [T], w: Int, h: Int, sigma: Float, zero: T, add: (T, T) -> T, scale: (T, Float) -> T) -> [T] {
        let radius = max(Int((2 * sigma).rounded(.up)), 1)
        let kernel = (-radius ... radius).map { exp(-Float($0 * $0) / (2 * sigma * sigma)) }
        let ksum = kernel.reduce(0, +)
        var tmp = [T](repeating: zero, count: w * h), out = tmp
        for y in 0 ..< h {
            for x in 0 ..< w {
                var acc = zero
                for k in -radius ... radius { acc = add(acc, scale(v[y * w + min(max(x + k, 0), w - 1)], kernel[k + radius] / ksum)) }
                tmp[y * w + x] = acc
            }
        }
        for y in 0 ..< h {
            for x in 0 ..< w {
                var acc = zero
                for k in -radius ... radius { acc = add(acc, scale(tmp[min(max(y + k, 0), h - 1) * w + x], kernel[k + radius] / ksum)) }
                out[y * w + x] = acc
            }
        }
        return out
    }

    /// The bright-background edge rule (v7.2.1) within `rect`, in place on `alpha` and
    /// `shares`. Returns the gate g_b over `rect` (for both repaints) and what it did.
    ///
    /// 1. The gate: where F̂ and B̂ are known and the pixel isn't excluded (`skip`: the hair zone
    ///    unless the inside is skin; hair strokes), g_b = smoothstep(0.10, 0.20, L(B̂) − L(F̂)),
    ///    then softened (a Gaussian reaching 3 px).
    /// 2. On a blurred copy of the photo (σ 1.5, linear) and of the mask: t_b, the copy's place
    ///    on the line F̂ → B̂; k, how near the line it lies; the excess e = max(0, t_b − (1 − α_b))
    ///    · k · g_b, background colour the mask still calls subject.
    /// 3. e through a 3×3 median, then a plain 1.5 px feather; α′ = α − e, only under 0.98 alpha
    ///    or within 2 px inside the half-way line. Holes it opens, enclosed and under 20 px, close.
    public static func apply(photo: Photo, alpha: UnsafeMutablePointer<UInt8>, shares: UnsafeMutablePointer<UInt8>, rect: PixelRect,
                             settings s: InsideColourSettings, skip: (Int, Int, SIMD3<Float>) -> Bool) -> (stats: Stats, gate: [Float]) {
        let W = photo.w, H = photo.h
        let r = rect.clamped(w: W, h: H)
        var stats = Stats()
        if r.isEmpty { return (stats, []) }
        let rw = r.w, rh = r.h, rn = rw * rh
        let tiles = Repaint.tiles(r)
        let apron = Int(max(s.reach, s.backgroundReach) + max(s.solidDepth, s.backgroundDepth)) + 4
        // Pass 1: the gate, and each judged pixel's sources (F̂, B̂) as offsets (127: none).
        var gateRaw = [Float](repeating: 0, count: rn)
        var fx = [Int8](repeating: 127, count: rn), fy = fx, bx = fx, by = fx
        var depth = [Float](repeating: 0, count: rn)
        gateRaw.withUnsafeMutableBufferPointer { gp in
            fx.withUnsafeMutableBufferPointer { fxp in fy.withUnsafeMutableBufferPointer { fyp in
            bx.withUnsafeMutableBufferPointer { bxp in by.withUnsafeMutableBufferPointer { byp in
            depth.withUnsafeMutableBufferPointer { dp in
                let g = gp.baseAddress!, fX = fxp.baseAddress!, fY = fyp.baseAddress!, bX = bxp.baseAddress!, bY = byp.baseAddress!, dep = dp.baseAddress!
                parallel(tiles.count) { t in
                    let tile = tiles[t]
                    if !Repaint.holdsEdge(tile, alpha: alpha, W: W) { return }
                    let crop = PixelRect(x: tile.x - apron, y: tile.y - apron, w: tile.w + 2 * apron, h: tile.h + 2 * apron).clamped(w: W, h: H)
                    var local = [UInt8](repeating: 0, count: crop.w * crop.h)
                    for y in 0 ..< crop.h { for x in 0 ..< crop.w { local[y * crop.w + x] = alpha[(crop.y + y) * W + crop.x + x] } }
                    let fS = InsideColour.field(alpha: local, w: crop.w, h: crop.h, settings: s)
                    let fB = backgroundField(alpha: local, w: crop.w, h: crop.h, settings: s)
                    for y in tile.y ..< tile.maxY {
                        for x in tile.x ..< tile.maxX {
                            let li = (y - crop.y) * crop.w + (x - crop.x), ri = (y - r.y) * rw + (x - r.x)
                            let d = fS.depth[li]
                            dep[ri] = d
                            // The band, and the background side the repaint reaches.
                            if d > s.bandInside || d < -(s.backCore + s.feather + 2) { continue }
                            let srcF = Int(fS.source[li]), srcB = Int(fB.source[li])
                            if srcF < 0 || srcB < 0 { continue }
                            let sfx = crop.x + srcF % crop.w, sfy = crop.y + srcF / crop.w
                            let sbx = crop.x + srcB % crop.w, sby = crop.y + srcB / crop.w
                            let F = InsideColour.median3(photo, sfx, sfy)
                            if skip(x, y, F) { continue }
                            let B = InsideColour.median3(photo, sbx, sby)
                            fX[ri] = Int8(min(max(sfx - x, -126), 126)); fY[ri] = Int8(min(max(sfy - y, -126), 126))
                            bX[ri] = Int8(min(max(sbx - x, -126), 126)); bY[ri] = Int8(min(max(sby - y, -126), 126))
                            g[ri] = smoothstep(s.gateLow, s.gateHigh, Oklab.from(linear: B).x - Oklab.from(linear: F).x)
                        }
                    }
                }
            } } } } }
        }
        var anyGate = false
        for v in gateRaw where v > 0 { anyGate = true; break }
        if !anyGate { return (stats, [Float](repeating: 0, count: rn)) }
        // The gate softened, tile by tile.
        let gSigma = max(s.gateBlur / 2, 0.3)
        var gate = [Float](repeating: 0, count: rn)
        let gApron = Int((2 * gSigma).rounded(.up)) + 1
        gate.withUnsafeMutableBufferPointer { gp in
            let out = gp.baseAddress!
            parallel(tiles.count) { t in
                let tile = tiles[t]
                let crop = PixelRect(x: tile.x - gApron, y: tile.y - gApron, w: tile.w + 2 * gApron, h: tile.h + 2 * gApron).clamped(w: r.maxX, h: r.maxY)
                let cx0 = max(crop.x, r.x), cy0 = max(crop.y, r.y), cw = crop.maxX - cx0, ch = crop.maxY - cy0
                if cw <= 0 || ch <= 0 { return }
                var v = [Float](repeating: 0, count: cw * ch), any = false
                for y in 0 ..< ch { for x in 0 ..< cw { let g = gateRaw[(cy0 + y - r.y) * rw + (cx0 + x - r.x)]; v[y * cw + x] = g; if g > 0 { any = true } } }
                if !any { return }
                let b = blurred(v, w: cw, h: ch, sigma: gSigma, zero: Float(0), add: +, scale: *)
                for y in tile.y ..< tile.maxY { for x in tile.x ..< tile.maxX { out[(y - r.y) * rw + (x - r.x)] = b[(y - cy0) * cw + (x - cx0)] } }
            }
        }
        // Pass 2: the excess, on the blurred copy, where the gate is on.
        let bApron = Int((2 * s.blurSigma).rounded(.up)) + 2
        var excess = [Float](repeating: 0, count: rn)
        let lin = Matte.toLinear.p
        excess.withUnsafeMutableBufferPointer { ep in
            let ex = ep.baseAddress!
            parallel(tiles.count) { t in
                let tile = tiles[t]
                var any = false
                for y in tile.y ..< tile.maxY { for x in tile.x ..< tile.maxX where gate[(y - r.y) * rw + (x - r.x)] > 0.001 { any = true; break }; if any { break } }
                if !any { return }
                let crop = PixelRect(x: tile.x - bApron, y: tile.y - bApron, w: tile.w + 2 * bApron, h: tile.h + 2 * bApron).clamped(w: W, h: H)
                var colour = [SIMD3<Float>](repeating: SIMD3(repeating: 0), count: crop.w * crop.h), cover = [Float](repeating: 0, count: crop.w * crop.h)
                for y in 0 ..< crop.h {
                    for x in 0 ..< crop.w {
                        let o = (crop.y + y) * photo.rowBytes + (crop.x + x) * 4
                        colour[y * crop.w + x] = SIMD3(lin[Int(photo.p[o])], lin[Int(photo.p[o + 1])], lin[Int(photo.p[o + 2])])
                        cover[y * crop.w + x] = Float(alpha[(crop.y + y) * W + crop.x + x]) / 255
                    }
                }
                let Ib = blurred(colour, w: crop.w, h: crop.h, sigma: s.blurSigma, zero: SIMD3<Float>(repeating: 0), add: +, scale: { $0 * $1 })
                let ab = blurred(cover, w: crop.w, h: crop.h, sigma: s.blurSigma, zero: Float(0), add: +, scale: *)
                for y in tile.y ..< tile.maxY {
                    for x in tile.x ..< tile.maxX {
                        let ri = (y - r.y) * rw + (x - r.x)
                        let g = gate[ri]
                        if g <= 0.001 || fx[ri] == 127 || bx[ri] == 127 { continue }
                        let F = InsideColour.median3(photo, x + Int(fx[ri]), y + Int(fy[ri]))
                        let B = InsideColour.median3(photo, x + Int(bx[ri]), y + Int(by[ri]))
                        let li = (y - crop.y) * crop.w + (x - crop.x)
                        let I = Ib[li], d = B - F
                        let tb = min(max(((I - F) * d).sum() / max((d * d).sum(), 1e-12), 0), 1)
                        let off = Refine.toSegment(Oklab.from(linear: I), Oklab.from(linear: F), Oklab.from(linear: B))
                        let k = 1 - smoothstep(s.lineNear, s.lineFar, off)
                        let e = max(0, tb - (1 - ab[li])) * k * g
                        if e > 0 { ex[ri] = e }
                    }
                }
            }
        }
        // Pass 3: e through a 3×3 median, then a plain feather, applied within reach.
        let fSigma = max(s.featherBlur / 2, 0.3)
        let opaque = UInt8((s.opaque * 255).rounded())
        var after = [UInt8](repeating: 0, count: rn)
        var touched = [Bool](repeating: false, count: rn)
        let fApron = Int((2 * fSigma).rounded(.up)) + 2
        after.withUnsafeMutableBufferPointer { ap in touched.withUnsafeMutableBufferPointer { tp in
            let aft = ap.baseAddress!, tch = tp.baseAddress!
            parallel(tiles.count) { t in
                let tile = tiles[t]
                let crop = PixelRect(x: tile.x - fApron, y: tile.y - fApron, w: tile.w + 2 * fApron, h: tile.h + 2 * fApron).clamped(w: r.maxX, h: r.maxY)
                let cx0 = max(crop.x, r.x), cy0 = max(crop.y, r.y), cw = crop.maxX - cx0, ch = crop.maxY - cy0
                if cw <= 0 || ch <= 0 { return }
                var v = [Float](repeating: 0, count: cw * ch), any = false
                for y in 0 ..< ch { for x in 0 ..< cw { let e = excess[(cy0 + y - r.y) * rw + (cx0 + x - r.x)]; v[y * cw + x] = e; if e > 0 { any = true } } }
                if !any { return }
                var med = v
                var nine = [Float](repeating: 0, count: 9)
                for y in 0 ..< ch {
                    for x in 0 ..< cw {
                        var n = 0
                        for yy in max(y - 1, 0) ... min(y + 1, ch - 1) { for xx in max(x - 1, 0) ... min(x + 1, cw - 1) { nine[n] = v[yy * cw + xx]; n += 1 } }
                        let part = nine[0 ..< n].sorted()
                        med[y * cw + x] = part[n / 2]
                    }
                }
                let soft = blurred(med, w: cw, h: ch, sigma: fSigma, zero: Float(0), add: +, scale: *)
                for y in tile.y ..< tile.maxY {
                    for x in tile.x ..< tile.maxX {
                        let ri = (y - r.y) * rw + (x - r.x)
                        let a8 = alpha[y * W + x]
                        let change = soft[(y - cy0) * cw + (x - cx0)]
                        if a8 == 0 || change <= 0.5 / 255 { continue }
                        // (Counted as the band is: the pixel the half-way line runs beside is 1.)
                        if a8 >= opaque && depth[ri] > s.cutInside { continue }
                        let a1 = UInt8((max(Float(a8) / 255 - change, 0) * 255).rounded())
                        if a1 == a8 { continue }
                        aft[ri] = a1
                        tch[ri] = true
                    }
                }
            }
        } }
        // Holes the cut opened, enclosed by subject and under `holeArea` pixels, close.
        var opened = [Bool](repeating: false, count: rn)
        for y in r.y ..< r.maxY {
            for x in r.x ..< r.maxX {
                let ri = (y - r.y) * rw + (x - r.x)
                if touched[ri] && alpha[y * W + x] >= 128 && after[ri] < 128 { opened[ri] = true }
            }
        }
        let (labels, count) = SubjectSelect.label(opened, w: rw, h: rh)
        if count > 0 {
            var area = [Int](repeating: 0, count: count + 1), open = [Bool](repeating: false, count: count + 1)
            for y in 0 ..< rh {
                for x in 0 ..< rw {
                    let l = Int(labels[y * rw + x])
                    if l == 0 { continue }
                    area[l] += 1
                    // Open when it meets the background as it was (or the rect's border).
                    if x == 0 || y == 0 || x == rw - 1 || y == rh - 1 { open[l] = true; continue }
                    for ny in y - 1 ... y + 1 {
                        for nx in x - 1 ... x + 1 where alpha[(r.y + ny) * W + r.x + nx] < 128 && !opened[ny * rw + nx] { open[l] = true }
                    }
                }
            }
            for i in 0 ..< rn where labels[i] > 0 {
                let l = Int(labels[i])
                if !open[l] && area[l] < s.holeArea { touched[i] = false; stats.holesRestored += 1 }
            }
        }
        for v in gate where v > 0.001 { stats.gated += 1 }
        for y in r.y ..< r.maxY {
            for x in r.x ..< r.maxX {
                let ri = (y - r.y) * rw + (x - r.x)
                if !touched[ri] { continue }
                let i = y * W + x
                let a0 = alpha[i], a1 = after[ri]
                stats.cut += 1
                stats.removed += Double(Int(a0) - Int(a1)) / 255
                let k = Float(a1) / max(Float(a0), 1)
                alpha[i] = a1
                for ch in 0 ..< 3 { shares[i * 4 + ch] = UInt8((Float(shares[i * 4 + ch]) * k).rounded()) }
            }
        }
        return (stats, gate)
    }
}

/// What the background side's repaint did (spec v7.2, 3).
public struct BackRepaintStats: Equatable {
    public var core = 0
    public var feathered = 0
    public var unknown = 0
    public init() {}
}

/// The background side's repaint (spec v7.2, 3): the mirror of `Repaint`. Its map, the same
/// four bytes a pixel, points to the solid background whose colour B̂ the background side of
/// the render takes, by wb: Cb = mix(photo, B̂, wb).
public enum RepaintBack {
    /// `gate` (over `rect`, v7.2.1): the core is weighted by it, and is nothing where it is 0.
    public static func apply(photo: Photo, alpha: UnsafePointer<UInt8>, map: UnsafeMutablePointer<UInt8>, rect: PixelRect,
                             settings s: InsideColourSettings, skip: (Int, Int, SIMD3<Float>) -> Bool, gate: [Float]) -> BackRepaintStats {
        let W = photo.w, H = photo.h
        let r = rect.clamped(w: W, h: H)
        var stats = BackRepaintStats()
        if r.isEmpty { return stats }
        let rw = r.w, rn = rw * r.h
        var core = [Bool](repeating: false, count: rn)
        var offX = [Int8](repeating: 0, count: rn), offY = [Int8](repeating: 0, count: rn)
        let tiles = Repaint.tiles(r)
        let apron = Int(max(s.reach, s.backgroundReach) + max(s.solidDepth, s.backgroundDepth)) + 4
        let lock = NSLock()
        core.withUnsafeMutableBufferPointer { cp in
            offX.withUnsafeMutableBufferPointer { xp in
                offY.withUnsafeMutableBufferPointer { yp in
                    let cores = cp.baseAddress!, xs = xp.baseAddress!, ys = yp.baseAddress!
                    parallel(tiles.count) { t in
                        let tile = tiles[t]
                        if !Repaint.holdsEdge(tile, alpha: alpha, W: W) { return }
                        var gated = false
                        for y in tile.y ..< tile.maxY { for x in tile.x ..< tile.maxX where gate[(y - r.y) * rw + (x - r.x)] > 0.001 { gated = true; break }; if gated { break } }
                        if !gated { return }
                        let crop = PixelRect(x: tile.x - apron, y: tile.y - apron, w: tile.w + 2 * apron, h: tile.h + 2 * apron).clamped(w: W, h: H)
                        var local = [UInt8](repeating: 0, count: crop.w * crop.h)
                        for y in 0 ..< crop.h { for x in 0 ..< crop.w { local[y * crop.w + x] = alpha[(crop.y + y) * W + crop.x + x] } }
                        let fS = InsideColour.field(alpha: local, w: crop.w, h: crop.h, settings: s)
                        let fB = EdgeCut.backgroundField(alpha: local, w: crop.w, h: crop.h, settings: s)
                        var unknown = 0
                        for y in tile.y ..< tile.maxY {
                            for x in tile.x ..< tile.maxX {
                                let li = (y - crop.y) * crop.w + (x - crop.x)
                                let d = fS.depth[li]
                                if d >= 0 || d < -s.backCore { continue }
                                let srcB = Int(fB.source[li]), srcF = Int(fS.source[li])
                                if srcB < 0 || srcF < 0 { unknown += 1; continue }
                                let F = InsideColour.median3(photo, crop.x + srcF % crop.w, crop.y + srcF / crop.w)
                                if skip(x, y, F) { continue }
                                let ri = (y - r.y) * rw + (x - r.x)
                                if gate[ri] <= 0.001 { continue }
                                cores[ri] = true
                                let bx = crop.x + srcB % crop.w, by = crop.y + srcB / crop.w
                                xs[ri] = Int8(min(max(bx - x, -127), 127)); ys[ri] = Int8(min(max(by - y, -127), 127))
                            }
                        }
                        lock.lock()
                        stats.unknown += unknown
                        lock.unlock()
                    }
                }
            }
        }
        // The feather borrows each core pixel's offset: a feathered pixel takes its nearest core's.
        spreadOffsets(core: core, offX: &offX, offY: &offY, w: rw, h: r.h, reach: Int(s.feather.rounded(.up)) + Int(s.featherBlur.rounded(.up)) + 2)
        let weights = (0 ..< rn).map { core[$0] ? gate[$0] : 0 }
        let made = Repaint.feather(rect: r, tiles: tiles, core: weights, protected: nil, offX: offX, offY: offY,
                                   alpha: alpha, shares: nil, map: map, W: W, settings: s)
        stats.core = made.core
        stats.feathered = made.feathered
        return stats
    }

    /// Gives pixels near a core the offset of a core pixel beside them (breadth first), so a
    /// feathered pixel points at background as its core neighbour does.
    static func spreadOffsets(core: [Bool], offX: inout [Int8], offY: inout [Int8], w: Int, h: Int, reach: Int) {
        var have = core
        var frontier: [Int] = []
        for i in 0 ..< w * h where core[i] { frontier.append(i) }
        for _ in 0 ..< reach {
            var next: [Int] = []
            for i in frontier {
                let x = i % w, y = i / w
                for ny in max(y - 1, 0) ... min(y + 1, h - 1) {
                    for nx in max(x - 1, 0) ... min(x + 1, w - 1) {
                        let j = ny * w + nx
                        if have[j] { continue }
                        have[j] = true
                        // The same background pixel, seen from here.
                        offX[j] = Int8(min(max(Int(offX[i]) + x - nx, -127), 127))
                        offY[j] = Int8(min(max(Int(offY[i]) + y - ny, -127), 127))
                        next.append(j)
                    }
                }
            }
            frontier = next
            if frontier.isEmpty { break }
        }
    }
}

/// Everything the edge colour step does, in order: the bright-background rule's gate and cut
/// (v7.2.1, when on), the subject side's repaint (v7.1 §1; gated pixels core to the gate) and,
/// where gated, the background side's (v7.2 §3).
public enum EdgeColour {
    public struct Stats: Equatable {
        public var repaint = RepaintStats()
        public var cut: EdgeCut.Stats?
        public var back = BackRepaintStats()
        public init() {}

        public var lines: [String] {
            var out: [String] = []
            if let c = cut {
                out.append("bright-background edges: \(c.gated) px gated, \(c.cut) px cut, mean alpha removed "
                    + String(format: "%.3f", locale: Locale(identifier: "en_US_POSIX"), c.cut > 0 ? c.removed / Double(c.cut) : 0)
                    + ", \(c.holesRestored) px of holes restored")
            }
            out.append(repaint.summary)
            out.append("background side: \(back.core) pixels repainted (core), \(back.feathered) feathered, \(back.unknown) with no background colour within reach")
            return out
        }
    }

    public static func run(photo: Photo, alpha: UnsafeMutablePointer<UInt8>, shares: UnsafeMutablePointer<UInt8>, map: UnsafeMutablePointer<UInt8>,
                           back: UnsafeMutablePointer<UInt8>, rect: PixelRect, settings s: InsideColourSettings,
                           skip: @escaping (Int, Int, SIMD3<Float>) -> Bool, matched: ((Int, Int) -> Bool)? = nil, rimOff: Bool = false) -> Stats {
        var stats = Stats()
        var gate: [Float]?
        if s.cut {
            let made = EdgeCut.apply(photo: photo, alpha: alpha, shares: shares, rect: rect, settings: s, skip: skip)
            stats.cut = made.stats
            if made.gate.contains(where: { $0 > 0.001 }) { gate = made.gate }
        }
        stats.repaint = Repaint.apply(photo: photo, alpha: UnsafePointer(alpha), shares: shares, map: map, rect: rect, settings: s,
                                      skip: skip, matched: matched, gate: gate, rimOff: rimOff)
        if let gate = gate {
            stats.back = RepaintBack.apply(photo: photo, alpha: UnsafePointer(alpha), map: back, rect: rect, settings: s, skip: skip, gate: gate)
        }
        return stats
    }
}
