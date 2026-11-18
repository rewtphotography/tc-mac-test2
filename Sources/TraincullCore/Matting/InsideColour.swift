import Foundation

/// Edge colour from inside (masking spec v7, section 2), as Photoshop's Decontaminate Colors
/// does it: the background is never looked at. Each edge pixel's subject colour is taken
/// from the solid subject just inside it, and the subject's part of the pixel is given that
/// colour: blunt and predictable. Alpha is never changed, only the colour shares.
public struct InsideColourSettings: Equatable {
    /// Solid subject: alpha at least this, and at least `solidDepth` pixels inside the
    /// half-way line (distance from pixel centre to the nearest pixel under a half).
    public var solidAlpha: Float = 0.98
    public var solidDepth: Float = 6
    /// Beyond this many pixels from any solid subject the inside colour is unknown (thin
    /// straps, strands), and the pixel is left alone.
    public var reach: Float = 30
    /// The edge band reaches this far inside, counted as above: the pixel the half-way line
    /// runs beside is 1, so 5 is "4 pixels inside the line".
    public var bandInside: Float = 5
    /// A pixel whose subject colour (its part ÷ alpha) is this much lighter (Oklab L) than
    /// the inside is rim light, and kept. (The spec has 0.03. On the owner's 7451 the teal
    /// pixel (0, 39, 33) at full coverage is 0.034 lighter than its sleeve (29, 26, 25): dark
    /// colours take big steps in Oklab L for a few code values. A real rim, warm and 20%
    /// brighter, is about 0.08 lighter.)
    public var rimLift: Float = 0.05
    /// A part-covered pixel is judged by the nearest fully covered pixel within this many
    /// pixels: its own part still holds some of the background's light, and against a white
    /// wall reads lighter than the subject though it is a fringe.
    public var rimLook = 3
    /// What the hand-made `skip` treats as skin (the skin model's value, 0 to 1).
    public init() {}
}

/// What one pass did, for the log.
public struct InsideColourStats: Equatable {
    public var recoloured = 0
    public var rim = 0
    public var unknown = 0
    public var deltaE = 0.0

    public init() {}

    mutating func add(_ o: InsideColourStats) {
        recoloured += o.recoloured; rim += o.rim; unknown += o.unknown; deltaE += o.deltaE
    }

    public var meanDeltaE: Float { recoloured > 0 ? Float(deltaE / Double(recoloured)) : 0 }

    public var summary: String {
        "edge colour from inside: \(recoloured) pixels recoloured, \(rim) skipped as brighter (rim light), \(unknown) with no inside colour, mean Oklab ΔE "
            + String(format: "%.4f", locale: Locale(identifier: "en_US_POSIX"), meanDeltaE)
    }
}

public enum InsideColour {
    /// Over a crop of a mask: how far each pixel is inside (positive: distance to the nearest
    /// pixel under a half) or outside (negative: distance to the nearest pixel at a half or
    /// more), and the solid-subject pixel whose colour it takes (an index into the crop, −1
    /// for none within reach).
    struct Field {
        let w: Int, h: Int
        var depth: [Float]
        var source: [Int32]
    }

    static func field(alpha: [UInt8], w: Int, h: Int, settings s: InsideColourSettings) -> Field {
        let n = w * h
        let inside = alpha.map { $0 >= 128 }
        let toOutside = PlaneMath.distance(to: inside.map { !$0 }, w: w, h: h)
        let toInside = PlaneMath.distance(to: inside, w: w, h: h)
        var depth = [Float](repeating: 0, count: n)
        for i in 0 ..< n { depth[i] = inside[i] ? toOutside[i] : -toInside[i] }
        let solidByte = UInt8(min(max((s.solidAlpha * 255).rounded(.up), 0), 255))
        var source = [Int32](repeating: -1, count: n)
        var solid = [Bool](repeating: false, count: n)
        for i in 0 ..< n where alpha[i] >= solidByte && depth[i] >= s.solidDepth {
            solid[i] = true
            source[i] = Int32(i)
        }
        // Outward from the solid subject's own edge, each pixel takes the source of the
        // neighbour it was reached from, as long as that source is within reach.
        var queue: [Int32] = []
        queue.reserveCapacity(n / 8)
        for y in 0 ..< h {
            for x in 0 ..< w where solid[y * w + x] {
                var border = false
                for ny in max(y - 1, 0) ... min(y + 1, h - 1) {
                    for nx in max(x - 1, 0) ... min(x + 1, w - 1) where !solid[ny * w + nx] { border = true }
                }
                if border { queue.append(Int32(y * w + x)) }
            }
        }
        let reach2 = s.reach * s.reach
        var head = 0
        while head < queue.count {
            let i = Int(queue[head])
            head += 1
            let src = Int(source[i])
            let sx = src % w, sy = src / w
            let x = i % w, y = i / w
            for ny in max(y - 1, 0) ... min(y + 1, h - 1) {
                for nx in max(x - 1, 0) ... min(x + 1, w - 1) {
                    let j = ny * w + nx
                    if source[j] >= 0 { continue }
                    let dx = Float(nx - sx), dy = Float(ny - sy)
                    if dx * dx + dy * dy > reach2 { continue }
                    source[j] = Int32(src)
                    queue.append(Int32(j))
                }
            }
        }
        return Field(w: w, h: h, depth: depth, source: source)
    }

    /// The photo's colour at a pixel in linear light, each channel the median of the 3×3
    /// around it: pores and texture don't count.
    @inline(__always)
    static func median3(_ photo: Photo, _ x: Int, _ y: Int) -> SIMD3<Float> {
        let lin = Matte.toLinear.p
        var r = [Float](repeating: 0, count: 9), g = r, b = r
        var n = 0
        for yy in max(y - 1, 0) ... min(y + 1, photo.h - 1) {
            for xx in max(x - 1, 0) ... min(x + 1, photo.w - 1) {
                let o = yy * photo.rowBytes + xx * 4
                r[n] = lin[Int(photo.p[o])]; g[n] = lin[Int(photo.p[o + 1])]; b[n] = lin[Int(photo.p[o + 2])]
                n += 1
            }
        }
        func mid(_ v: inout [Float]) -> Float {
            let part = v[0 ..< n].sorted()
            return part[n / 2]
        }
        return SIMD3(mid(&r), mid(&g), mid(&b))
    }

    @inline(__always)
    static func linear(_ photo: Photo, _ x: Int, _ y: Int) -> SIMD3<Float> {
        let lin = Matte.toLinear.p
        let o = y * photo.rowBytes + x * 4
        return SIMD3(lin[Int(photo.p[o])], lin[Int(photo.p[o + 1])], lin[Int(photo.p[o + 2])])
    }

    /// The subject's part of a pixel given the inside colour `F` (all linear): k·α·F, with k
    /// the largest single number (at most 1) that keeps every channel within the photo's.
    /// One k for the whole vector: the part keeps F's hue and never passes the photo in any
    /// channel. Shares are that over the photo, 0 where the photo has no light.
    @inline(__always)
    public static func shares(pixel I: SIMD3<Float>, alpha a: Float, inside F: SIMD3<Float>) -> SIMD3<Float> {
        let aF = F * a
        var k: Float = 1
        for c in 0 ..< 3 where aF[c] > 1e-9 { k = min(k, I[c] / aF[c]) }
        let part = aF * max(k, 0)
        var s = SIMD3<Float>(repeating: 0)
        for c in 0 ..< 3 where I[c] > 0 { s[c] = part[c] / I[c] }
        // (Within rounding of 1 at most: the part never passes the photo.)
        return s / max(s.max(), 1)
    }

    /// The colour a pixel's rim-light test goes by: its own part ÷ alpha when it is fully
    /// covered, else the part ÷ alpha of the nearest fully covered pixel within `look`
    /// (alpha at least 250/255), else its own. `alphaAt` reads the mask, nil outside;
    /// `colourAt` gives a covered pixel's part ÷ alpha (linear), from the shares as they were
    /// before this pass. (The photo's own colour there would carry the background light a
    /// lens spills over the edge: alpha 15's pale rim, read as rim light.)
    @inline(__always)
    static func rimColour(x: Int, y: Int, alpha a8: UInt8, part P: SIMD3<Float>, look: Int,
                          alphaAt: (Int, Int) -> UInt8?, colourAt: (Int, Int) -> SIMD3<Float>) -> SIMD3<Float> {
        if a8 >= 250 { return P / max(Float(a8) / 255, 1e-6) }
        var best = Int.max
        var found: (Int, Int)?
        for dy in -look ... look {
            for dx in -look ... look {
                guard let a = alphaAt(x + dx, y + dy), a >= 250 else { continue }
                let d = dx * dx + dy * dy
                if d < best { best = d; found = (x + dx, y + dy) }
            }
        }
        if let (fx, fy) = found { return colourAt(fx, fy) }
        return P / max(Float(a8) / 255, 1e-6)
    }

    /// Whether the subject's part of a pixel is rim light: brighter than the inside by more
    /// than `lift` (Oklab L), at 10% coverage or more. A rim light adds light; every fringe
    /// measured on the owner's photos was as light as the inside, or darker.
    @inline(__always)
    public static func isRim(colour C: SIMD3<Float>, alpha a: Float, inside F: SIMD3<Float>, lift: Float) -> Bool {
        guard a >= 0.1 else { return false }
        return Oklab.from(linear: C).x > Oklab.from(linear: F).x + lift
    }

    /// Recolours the edge band of a whole mask in place, within `rect` (pixels of the photo).
    /// `alpha` is the photo's size, one byte a pixel; `shares` four bytes a pixel. `skip`
    /// says, for a pixel and its inside colour (linear), to leave it alone (the hair zone,
    /// a hair stroke). Worked in tiles with an apron, so memory stays small.
    public static func apply(photo: Photo, alpha: UnsafePointer<UInt8>, shares: UnsafeMutablePointer<UInt8>, rect: PixelRect,
                             settings s: InsideColourSettings = InsideColourSettings(),
                             skip: (Int, Int, SIMD3<Float>) -> Bool = { _, _, _ in false }) -> InsideColourStats {
        let W = photo.w, H = photo.h
        let r = rect.clamped(w: W, h: H)
        if r.isEmpty { return InsideColourStats() }
        let tile = 256, apron = Int(s.reach + s.solidDepth) + 4
        var tiles: [PixelRect] = []
        for ty in stride(from: r.y, to: r.maxY, by: tile) {
            for tx in stride(from: r.x, to: r.maxX, by: tile) {
                tiles.append(PixelRect(x: tx, y: ty, w: min(tile, r.maxX - tx), h: min(tile, r.maxY - ty)))
            }
        }
        let lock = NSLock()
        var total = InsideColourStats()
        var allWrites: [[(Int, UInt8, UInt8, UInt8)]] = []
        parallel(tiles.count) { t in
            let core = tiles[t]
            // Nothing to do where the tile is all one thing.
            var low = false, high = false, partial = false
            for y in core.y ..< core.maxY {
                for x in core.x ..< core.maxX {
                    let a = alpha[y * W + x]
                    if a < 128 { low = true } else { high = true }
                    if a > 1 && a < 255 { partial = true }
                }
            }
            if !(partial || (low && high)) { return }
            let crop = PixelRect(x: core.x - apron, y: core.y - apron, w: core.w + 2 * apron, h: core.h + 2 * apron).clamped(w: W, h: H)
            var local = [UInt8](repeating: 0, count: crop.w * crop.h)
            for y in 0 ..< crop.h { for x in 0 ..< crop.w { local[y * crop.w + x] = alpha[(crop.y + y) * W + crop.x + x] } }
            let f = field(alpha: local, w: crop.w, h: crop.h, settings: s)
            var stats = InsideColourStats()
            var writes: [(Int, UInt8, UInt8, UInt8)] = []
            for y in core.y ..< core.maxY {
                for x in core.x ..< core.maxX {
                    let a8 = alpha[y * W + x]
                    if a8 <= 1 { continue }
                    let li = (y - crop.y) * crop.w + (x - crop.x)
                    if f.depth[li] > s.bandInside { continue }
                    let src = Int(f.source[li])
                    if src < 0 { stats.unknown += 1; continue }
                    let F = median3(photo, crop.x + src % crop.w, crop.y + src / crop.w)
                    if skip(x, y, F) { continue }
                    let o = (y * W + x) * 4
                    let I = linear(photo, x, y)
                    let a = Float(a8) / 255
                    let now = SIMD3<Float>(Float(shares[o]), Float(shares[o + 1]), Float(shares[o + 2])) / 255
                    let P = I * now
                    let C = rimColour(x: x, y: y, alpha: a8, part: P, look: s.rimLook,
                                      alphaAt: { xx, yy in xx >= 0 && yy >= 0 && xx < W && yy < H ? alpha[yy * W + xx] : nil },
                                      colourAt: { xx, yy in
                                          let q = (yy * W + xx) * 4
                                          let sh = SIMD3<Float>(Float(shares[q]), Float(shares[q + 1]), Float(shares[q + 2])) / 255
                                          return linear(photo, xx, yy) * sh / max(Float(alpha[yy * W + xx]) / 255, 1e-6)
                                      })
                    if isRim(colour: C, alpha: a, inside: F, lift: s.rimLift) { stats.rim += 1; continue }
                    let next = InsideColour.shares(pixel: I, alpha: a, inside: F)
                    let bytes = (next * 255).rounded(.toNearestOrAwayFromZero)
                    writes.append((o, UInt8(bytes.x), UInt8(bytes.y), UInt8(bytes.z)))
                    stats.recoloured += 1
                    stats.deltaE += Double(Oklab.distance(Oklab.from(linear: P), Oklab.from(linear: I * next)))
                }
            }
            lock.lock()
            total.add(stats)
            allWrites.append(writes)
            lock.unlock()
        }
        // Written only once every tile has read the shares as they were.
        for list in allWrites {
            for (o, r, g, b) in list { shares[o] = r; shares[o + 1] = g; shares[o + 2] = b }
        }
        return total
    }
}
