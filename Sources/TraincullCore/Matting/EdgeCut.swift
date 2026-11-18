import Foundation

/// Masking spec v7.2: the background's own colour B̂ at the edge (section 1), the cut of edge
/// pixels that clearly match it (section 2), and the repaint of the background side (section 3).
public enum EdgeCut {
    /// Flags over the rect `apply` worked on, for `Repaint.apply`.
    public static let neverRim: UInt8 = 1
    public static let forceCore: UInt8 = 2

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

    @inline(__always) static func ab(_ p: SIMD3<Float>, _ q: SIMD3<Float>) -> Float {
        let dy = p.y - q.y, dz = p.z - q.z
        return (dy * dy + dz * dz).squareRoot()
    }

    /// What the cut did, for the log.
    public struct Stats: Equatable {
        public var cut = 0
        public var removed = 0.0
        /// Pixels judged background showing through (§2's notch case): repainted, never rim.
        public var through = 0
        public var unknown = 0
        public init() {}
    }

    /// Section 2 within `rect`: every band pixel that is clearly the background's colour
    /// (Oklab (a, b), lightness set aside) loses its coverage, softly, the change feathered
    /// 1.5 px and never weaker than it was; shares go down with alpha, all three together.
    /// `skip` as for `Repaint.apply` (the hair zone unless the inside is skin; hair strokes).
    /// Returns the flags `Repaint.apply` takes, over `rect`.
    public static func apply(photo: Photo, alpha: UnsafeMutablePointer<UInt8>, shares: UnsafeMutablePointer<UInt8>, rect: PixelRect,
                             settings s: InsideColourSettings, skip: (Int, Int, SIMD3<Float>) -> Bool) -> (stats: Stats, flags: [UInt8]) {
        let W = photo.w, H = photo.h
        let r = rect.clamped(w: W, h: H)
        var stats = Stats()
        if r.isEmpty { return (stats, []) }
        let rw = r.w, rn = rw * r.h
        var flags = [UInt8](repeating: 0, count: rn), raw = [UInt8](repeating: 0, count: rn)
        let tiles = Repaint.tiles(r)
        let apron = Int(max(s.reach, s.backgroundReach) + max(s.solidDepth, s.backgroundDepth)) + 4
        let lowest = UInt8((s.backgroundAlpha * 255).rounded())
        let lock = NSLock()
        flags.withUnsafeMutableBufferPointer { fp in
            raw.withUnsafeMutableBufferPointer { rp in
                let fl = fp.baseAddress!, rawp = rp.baseAddress!
                parallel(tiles.count) { t in
                    let tile = tiles[t]
                    if !Repaint.holdsEdge(tile, alpha: alpha, W: W) { return }
                    let crop = PixelRect(x: tile.x - apron, y: tile.y - apron, w: tile.w + 2 * apron, h: tile.h + 2 * apron).clamped(w: W, h: H)
                    var local = [UInt8](repeating: 0, count: crop.w * crop.h)
                    for y in 0 ..< crop.h { for x in 0 ..< crop.w { local[y * crop.w + x] = alpha[(crop.y + y) * W + crop.x + x] } }
                    let fS = InsideColour.field(alpha: local, w: crop.w, h: crop.h, settings: s)
                    let fB = backgroundField(alpha: local, w: crop.w, h: crop.h, settings: s)
                    var through = 0, unknown = 0
                    for y in tile.y ..< tile.maxY {
                        for x in tile.x ..< tile.maxX {
                            let a8 = alpha[y * W + x]
                            if a8 <= lowest { continue }
                            let li = (y - crop.y) * crop.w + (x - crop.x)
                            if fS.depth[li] > s.cutInside { continue }
                            let srcF = Int(fS.source[li]), srcB = Int(fB.source[li])
                            if srcF < 0 || srcB < 0 { unknown += 1; continue }
                            let F = InsideColour.median3(photo, crop.x + srcF % crop.w, crop.y + srcF / crop.w)
                            if skip(x, y, F) { continue }
                            let B = InsideColour.median3(photo, crop.x + srcB % crop.w, crop.y + srcB / crop.w)
                            let P = Oklab.from(linear: InsideColour.linear(photo, x, y))
                            let lF = Oklab.from(linear: F), lB = Oklab.from(linear: B)
                            let ri = (y - r.y) * rw + (x - r.x)
                            let nearB = Oklab.distance(P, lB) < s.nearBackground
                            if ab(lF, lB) < s.cutApart {
                                // Subject and background alike in colour: only a bright pixel that is
                                // the background's own colour is background showing through.
                                if nearB && P.x > lF.x + s.rimLift { fl[ri] = neverRim | forceCore; through += 1 }
                                continue
                            }
                            if nearB { fl[ri] |= neverRim }
                            let dS = ab(P, lF), dB = ab(P, lB)
                            if dS >= s.cutApart && dB <= s.cutNone * dS {
                                fl[ri] |= neverRim
                                let k = 1 - smoothstep(s.cutFull * dS, s.cutNone * dS, dB)
                                // Never below the coverage the pixel's own colour shows (its place on
                                // the line from B̂ to F̂ in (a, b)): a soft edge whose colours fit its
                                // coverage keeps it; a fringe or speck, background-coloured at full
                                // coverage, goes.
                                let a = Float(a8) / 255
                                let fb = SIMD2(lF.y - lB.y, lF.z - lB.z), pb = SIMD2(P.y - lB.y, P.z - lB.z)
                                let shows = min(max((fb * pb).sum() / max((fb * fb).sum(), 1e-9), 0), 1)
                                // Where the colour clearly says less than the coverage (a streak or speck at
                                // full coverage), the cut goes to 0 as specified; where they agree, it keeps it.
                                let apart = smoothstep(0.1, 0.3, a - shows)
                                let kept = max(a * (1 - k), min(a, shows))
                                let target = kept + (a * (1 - k) - kept) * apart
                                let fraction = 1 - target / max(a, 1e-6)
                                if fraction > 0 { rawp[ri] = UInt8((min(max(fraction, 0), 1) * 255).rounded()) }
                            }
                        }
                    }
                    lock.lock()
                    stats.through += through; stats.unknown += unknown
                    lock.unlock()
                }
            }
        }
        // The change, softened over the pixels that have coverage to lose, and never weaker than it was.
        let sigma = max(s.featherBlur / 2, 0.3), radius = Int((2 * sigma).rounded(.up))
        let kernel = (-radius ... radius).map { exp(-Float($0 * $0) / (2 * sigma * sigma)) }
        var after = [UInt8](repeating: 0, count: rn)
        var anyCut = false
        for v in raw where v > 0 { anyCut = true; break }
        if !anyCut { return (stats, flags) }
        let apronB = radius + 1
        parallel(tiles.count) { t in
            let tile = tiles[t]
            var hit = false
            for y in max(tile.y - apronB, r.y) ..< min(tile.maxY + apronB, r.maxY) {
                for x in max(tile.x - apronB, r.x) ..< min(tile.maxX + apronB, r.maxX) where raw[(y - r.y) * rw + (x - r.x)] > 0 { hit = true; break }
                if hit { break }
            }
            if !hit { return }
            for y in tile.y ..< tile.maxY {
                for x in tile.x ..< tile.maxX {
                    let ri = (y - r.y) * rw + (x - r.x)
                    let a8 = alpha[y * W + x]
                    if a8 == 0 { continue }
                    var num: Float = 0, den: Float = 0
                    for dy in -radius ... radius {
                        let yy = y + dy
                        if yy < r.y || yy >= r.maxY { continue }
                        for dx in -radius ... radius {
                            let xx = x + dx
                            if xx < r.x || xx >= r.maxX || alpha[yy * W + xx] == 0 { continue }
                            let k = kernel[dy + radius] * kernel[dx + radius]
                            num += k * Float(raw[(yy - r.y) * rw + (xx - r.x)]) / 255
                            den += k
                        }
                    }
                    let soft = max(den > 0 ? num / den : 0, Float(raw[ri]) / 255)
                    if soft <= 0.002 { continue }
                    after[ri] = UInt8(min(soft * 255, 255).rounded())
                }
            }
        }
        for y in r.y ..< r.maxY {
            for x in r.x ..< r.maxX {
                let ri = (y - r.y) * rw + (x - r.x)
                let k = Float(after[ri]) / 255
                if k <= 0 { continue }
                let i = y * W + x
                let a0 = alpha[i]
                let a1 = UInt8((Float(a0) * (1 - k)).rounded())
                if a1 == a0 { continue }
                stats.cut += 1
                stats.removed += Double(Int(a0) - Int(a1)) / 255
                let scale = Float(a1) / max(Float(a0), 1)
                alpha[i] = a1
                for ch in 0 ..< 3 { shares[i * 4 + ch] = UInt8((Float(shares[i * 4 + ch]) * scale).rounded()) }
            }
        }
        return (stats, flags)
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
    public static func apply(photo: Photo, alpha: UnsafePointer<UInt8>, map: UnsafeMutablePointer<UInt8>, rect: PixelRect,
                             settings s: InsideColourSettings, skip: (Int, Int, SIMD3<Float>) -> Bool) -> BackRepaintStats {
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
        let made = Repaint.feather(rect: r, tiles: tiles, core: core, protected: nil, offX: offX, offY: offY,
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

/// Everything the edge colour step does, in order (spec v7.2): the cut (§2, when on), the
/// subject side's repaint (v7.1 §1, with §2's rim rule) and the background side's (§3).
public enum EdgeColour {
    public struct Stats: Equatable {
        public var repaint = RepaintStats()
        public var cut: EdgeCut.Stats?
        public var back = BackRepaintStats()
        public init() {}

        public var lines: [String] {
            var out: [String] = []
            if let c = cut {
                out.append("background-coloured edge pixels: \(c.cut) cut, mean alpha removed "
                    + String(format: "%.3f", locale: Locale(identifier: "en_US_POSIX"), c.cut > 0 ? c.removed / Double(c.cut) : 0)
                    + ", \(repaint.rimKept) rim-protected, \(c.through) bright pixels of background showing through repainted")
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
        var flags: [UInt8]?
        if s.cut {
            let made = EdgeCut.apply(photo: photo, alpha: alpha, shares: shares, rect: rect, settings: s, skip: skip)
            stats.cut = made.stats
            flags = made.flags.isEmpty ? nil : made.flags
        }
        stats.repaint = Repaint.apply(photo: photo, alpha: UnsafePointer(alpha), shares: shares, map: map, rect: rect, settings: s,
                                      skip: skip, matched: matched, flags: flags, rimOff: rimOff)
        stats.back = RepaintBack.apply(photo: photo, alpha: UnsafePointer(alpha), map: back, rect: rect, settings: s, skip: skip)
        return stats
    }
}
