import Foundation

/// Edge colour from inside (masking spec v7, section 2; since v7.1 a repaint): the background
/// is never looked at. Each edge pixel's subject colour is taken from the solid subject just
/// inside it, and the subject side of the render is given that colour, feathered, where the
/// photo's own colour there is a fringe. Alpha is never changed.
public struct InsideColourSettings: Equatable {
    /// Solid subject: alpha at least this, and at least `solidDepth` pixels inside the
    /// half-way line (distance from pixel centre to the nearest pixel under a half).
    public var solidAlpha: Float = 0.98
    public var solidDepth: Float = 6
    /// Beyond this many pixels from any solid subject the inside colour is unknown (thin
    /// straps, strands), and the pixel is left alone. (30 in v7; v7.1 searches to 60.)
    public var reach: Float = 60
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
    /// Rim-skipped pixels are protected only in connected groups (8-connected) of at least
    /// this many pixels: a real rim runs along the outline; a smaller group is a speck
    /// (spec v7.1, 2), and is repainted.
    public var smallRim = 40
    /// The repaint weight w fades from 1 to 0 over this many pixels round the core, and that
    /// fade is softened with this radius (Gaussian σ = half of it) (spec v7.1, 1.1).
    public var feather: Float = 2
    public var featherBlur: Float = 1.5

    // Spec v7.2.
    /// §2: cut edge pixels that clearly match the background (Debug "Cut background-coloured
    /// edge pixels"). With it off, rim light is judged as in v7.1.
    public var cut = true
    /// §1: solid background is alpha at most `backgroundAlpha` and at least `backgroundDepth`
    /// pixels outside the half-way line; beyond `backgroundReach` of it B̂ is unknown.
    public var backgroundAlpha: Float = 0.02
    public var backgroundDepth: Float = 6
    public var backgroundReach: Float = 30
    /// §2: pixels up to this far inside the half-way line (and all of the soft edge outside it)
    /// are judged; a pixel is background-like when it is at least `cutApart` from F̂ in (a, b)
    /// and at most `cutNone` × that from B̂; it is cut in full at `cutFull` × that or nearer.
    public var cutInside: Float = 6
    public var cutApart: Float = 0.04
    public var cutFull: Float = 0.25
    public var cutNone: Float = 0.5
    /// §2: within this of B̂ in full Oklab a pixel is background showing through: never rim light.
    public var nearBackground: Float = 0.03
    /// §3: the background side's repaint core reaches this many pixels outside the half-way line.
    public var backCore: Float = 3
    public init() {}
}

/// What one repaint pass did, for the log (spec v7.1, 2).
public struct RepaintStats: Equatable {
    /// Pixels given w = 1 (the core), and pixels given a w between 0 and 1 round it.
    public var core = 0
    public var feathered = 0
    /// Rim light kept: pixels, and the runs (groups) they make.
    public var rimKept = 0
    public var rimRuns = 0
    /// Rim-skipped groups too small to be a rim: how many, and their pixels (repainted).
    public var specks = 0
    public var speckPixels = 0
    /// Band pixels with no solid subject within reach.
    public var unknown = 0

    public init() {}

    public var summary: String {
        "edge colour from inside: \(core) pixels repainted (core), \(feathered) feathered, \(rimKept) kept as rim light in \(rimRuns) run(s), "
            + "\(specks) small rim group(s) of \(speckPixels) px repainted as specks, \(unknown) left with no inside colour within reach"
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

    /// `solidOK`: where solid subject may be taken from (Remove Colour leaves out the colours
    /// it removes), nil for everywhere.
    static func field(alpha: [UInt8], w: Int, h: Int, settings s: InsideColourSettings, solidOK: [Bool]? = nil) -> Field {
        let n = w * h
        let inside = alpha.map { $0 >= 128 }
        let toOutside = PlaneMath.distance(to: inside.map { !$0 }, w: w, h: h)
        let toInside = PlaneMath.distance(to: inside, w: w, h: h)
        var depth = [Float](repeating: 0, count: n)
        for i in 0 ..< n { depth[i] = inside[i] ? toOutside[i] : -toInside[i] }
        let solidByte = UInt8(min(max((s.solidAlpha * 255).rounded(.up), 0), 255))
        var source = [Int32](repeating: -1, count: n)
        var solid = [Bool](repeating: false, count: n)
        for i in 0 ..< n where alpha[i] >= solidByte && depth[i] >= s.solidDepth && (solidOK?[i] ?? true) {
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

}

/// The repaint (spec v7.1, 1): for each pixel, a weight w and the offset to the solid-subject
/// pixel whose colour it takes. The clean colour image C = mix(photo, F̂, w) is made where it
/// is used (the render), from the photo as it is then, so that global edits follow.
///
/// The map is four bytes a pixel: x offset + 128, y offset + 128 (photo pixels, y down), w ×
/// 255, and 255. Where w = 0, C is the photo.
public enum Repaint {
    /// A map with w = 0 everywhere.
    public static func blank(count: Int) -> [UInt8] {
        var m = [UInt8](repeating: 128, count: count * 4)
        for i in 0 ..< count { m[i * 4 + 2] = 0; m[i * 4 + 3] = 255 }
        return m
    }

    /// The clean colour of one pixel (linear): the photo mixed with the median colour at its
    /// source by w. For the tests and anything else that renders outside Core Image.
    public static func clean(_ photo: Photo, map: [UInt8], x: Int, y: Int) -> SIMD3<Float> {
        let o = (y * photo.w + x) * 4
        let w = Float(map[o + 2]) / 255
        let I = InsideColour.linear(photo, x, y)
        if w <= 0 { return I }
        let sx = min(max(x + Int(map[o]) - 128, 0), photo.w - 1), sy = min(max(y + Int(map[o + 1]) - 128, 0), photo.h - 1)
        return I + (InsideColour.median3(photo, sx, sy) - I) * w
    }

    /// Works out the repaint within `rect` (pixels of the photo) of a mask the photo's size,
    /// writing `map` and setting shares to alpha (one value for all three channels) wherever
    /// w > 0. `skip` says, for a pixel and its inside colour (linear), that it is excluded
    /// (the hair zone unless the inside is skin; a hair stroke): no core of its own.
    /// `matched` (Remove Colour) marks pixels that match a sampled colour: never rim light,
    /// and never a source of the inside colour. `flags` (spec v7.2, 2: `EdgeCut`), over `rect`:
    /// `EdgeCut.neverRim` pixels are never rim light, `EdgeCut.forceCore` ones join the core.
    /// `rimOff` (the Edge Colour box, an eyedropper Remove Colour box): nothing is rim light.
    public static func apply(photo: Photo, alpha: UnsafePointer<UInt8>, shares: UnsafeMutablePointer<UInt8>, map: UnsafeMutablePointer<UInt8>,
                             rect: PixelRect, settings s: InsideColourSettings = InsideColourSettings(),
                             skip: (Int, Int, SIMD3<Float>) -> Bool = { _, _, _ in false },
                             matched: ((Int, Int) -> Bool)? = nil, flags: [UInt8]? = nil, rimOff: Bool = false) -> RepaintStats {
        let W = photo.w, H = photo.h
        let r = rect.clamped(w: W, h: H)
        var stats = RepaintStats()
        if r.isEmpty { return stats }
        let rw = r.w, rh = r.h, rn = rw * rh
        // What each pixel of the band is: 0 nothing, 1 core, 2 rim light, 3 no inside colour,
        // 4 excluded; and the offset to its source.
        var kind = [UInt8](repeating: 0, count: rn)
        var offX = [Int8](repeating: 0, count: rn), offY = [Int8](repeating: 0, count: rn)
        let tile = 256, apron = Int(s.reach + s.solidDepth) + 4
        var tiles: [PixelRect] = []
        for ty in stride(from: r.y, to: r.maxY, by: tile) {
            for tx in stride(from: r.x, to: r.maxX, by: tile) {
                tiles.append(PixelRect(x: tx, y: ty, w: min(tile, r.maxX - tx), h: min(tile, r.maxY - ty)))
            }
        }
        kind.withUnsafeMutableBufferPointer { kp in
            offX.withUnsafeMutableBufferPointer { xp in
                offY.withUnsafeMutableBufferPointer { yp in
                    let kinds = kp.baseAddress!, xs = xp.baseAddress!, ys = yp.baseAddress!
                    parallel(tiles.count) { t in
                        let core = tiles[t]
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
                        var solidOK: [Bool]?
                        if matched != nil { solidOK = [Bool](repeating: true, count: crop.w * crop.h) }
                        for y in 0 ..< crop.h {
                            for x in 0 ..< crop.w {
                                local[y * crop.w + x] = alpha[(crop.y + y) * W + crop.x + x]
                                if let m = matched, m(crop.x + x, crop.y + y) { solidOK![y * crop.w + x] = false }
                            }
                        }
                        let f = InsideColour.field(alpha: local, w: crop.w, h: crop.h, settings: s, solidOK: solidOK)
                        for y in core.y ..< core.maxY {
                            for x in core.x ..< core.maxX {
                                let a8 = alpha[y * W + x]
                                if a8 <= 1 { continue }
                                let li = (y - crop.y) * crop.w + (x - crop.x)
                                if f.depth[li] > s.bandInside { continue }
                                let ri = (y - r.y) * rw + (x - r.x)
                                let src = Int(f.source[li])
                                if src < 0 { kinds[ri] = 3; continue }
                                let sx = crop.x + src % crop.w, sy = crop.y + src / crop.w
                                xs[ri] = Int8(min(max(sx - x, -127), 127)); ys[ri] = Int8(min(max(sy - y, -127), 127))
                                let F = InsideColour.median3(photo, sx, sy)
                                if skip(x, y, F) { kinds[ri] = 4; continue }
                                let flag = flags?[ri] ?? 0
                                if flag & EdgeCut.forceCore != 0 { kinds[ri] = 1; continue }
                                if !rimOff && flag & EdgeCut.neverRim == 0 && matched?(x, y) != true {
                                    let o = (y * W + x) * 4
                                    let now = SIMD3<Float>(Float(shares[o]), Float(shares[o + 1]), Float(shares[o + 2])) / 255
                                    let C = InsideColour.rimColour(x: x, y: y, alpha: a8, part: InsideColour.linear(photo, x, y) * now, look: s.rimLook,
                                                                   alphaAt: { xx, yy in xx >= 0 && yy >= 0 && xx < W && yy < H ? alpha[yy * W + xx] : nil },
                                                                   colourAt: { xx, yy in
                                                                       let q = (yy * W + xx) * 4
                                                                       let sh = SIMD3<Float>(Float(shares[q]), Float(shares[q + 1]), Float(shares[q + 2])) / 255
                                                                       return InsideColour.linear(photo, xx, yy) * sh / max(Float(alpha[yy * W + xx]) / 255, 1e-6)
                                                                   })
                                    if InsideColour.isRim(colour: C, alpha: Float(a8) / 255, inside: F, lift: s.rimLift) { kinds[ri] = 2; continue }
                                }
                                kinds[ri] = 1
                            }
                        }
                    }
                }
            }
        }
        // Rim light only in runs along the outline: smaller groups are specks, and are repainted.
        let (labels, count) = SubjectSelect.label(kind.map { $0 == 2 }, w: rw, h: rh)
        var protected = [Bool](repeating: false, count: rn)
        if count > 0 {
            var area = [Int](repeating: 0, count: count + 1)
            for l in labels where l > 0 { area[Int(l)] += 1 }
            for l in 1 ... count {
                if area[l] < s.smallRim { stats.specks += 1; stats.speckPixels += area[l] } else { stats.rimRuns += 1; stats.rimKept += area[l] }
            }
            for i in 0 ..< rn where labels[i] > 0 {
                if area[Int(labels[i])] < s.smallRim { kind[i] = 1 } else { protected[i] = true }
            }
        }
        for k in kind where k == 3 { stats.unknown += 1 }
        let made = feather(rect: r, tiles: tiles, core: kind.map { $0 == 1 }, protected: protected, offX: offX, offY: offY,
                           alpha: alpha, shares: shares, map: map, W: W, settings: s)
        let coreCount = made.core, feathered = made.feathered
        stats.core = coreCount
        stats.feathered = feathered
        return stats
    }

    /// Tiles of 256 pixels covering `r`.
    static func tiles(_ r: PixelRect, size tile: Int = 256) -> [PixelRect] {
        var tiles: [PixelRect] = []
        for ty in stride(from: r.y, to: r.maxY, by: tile) {
            for tx in stride(from: r.x, to: r.maxX, by: tile) {
                tiles.append(PixelRect(x: tx, y: ty, w: min(tile, r.maxX - tx), h: min(tile, r.maxY - ty)))
            }
        }
        return tiles
    }

    /// Whether a tile of the mask holds any edge (a part-covered pixel, or both sides).
    static func holdsEdge(_ t: PixelRect, alpha: UnsafePointer<UInt8>, W: Int) -> Bool {
        var low = false, high = false
        for y in t.y ..< t.maxY {
            for x in t.x ..< t.maxX {
                let a = alpha[y * W + x]
                if a > 1 && a < 255 { return true }
                if a < 128 { low = true } else { high = true }
                if low && high { return true }
            }
        }
        return false
    }

    /// The weight round a core (spec v7.1, 1.1): 1 on the core, fading over `feather` pixels
    /// round it, softened, never under 1 on the core; 0 on `protected` pixels. Written into
    /// `map` (with each pixel's offset) wherever it is over 0, and, with `shares`, shares set
    /// to alpha there. `core`, `protected` and the offsets are over `rect`.
    static func feather(rect r: PixelRect, tiles: [PixelRect], core: [Bool], protected: [Bool]?, offX: [Int8], offY: [Int8],
                        alpha: UnsafePointer<UInt8>, shares: UnsafeMutablePointer<UInt8>?, map: UnsafeMutablePointer<UInt8>,
                        W: Int, settings s: InsideColourSettings) -> (core: Int, feathered: Int) {
        let rw = r.w
        let sigma = max(s.featherBlur / 2, 0.3), radius = Int((2 * sigma).rounded(.up))
        let kernel = (-radius ... radius).map { exp(-Float($0 * $0) / (2 * sigma * sigma)) }
        let ksum = kernel.reduce(0, +)
        let apronB = Int(s.feather.rounded(.up)) + radius + 2
        let lock = NSLock()
        var feathered = 0, coreCount = 0
        parallel(tiles.count) { t in
            let tile = tiles[t]
            let crop = PixelRect(x: tile.x - apronB, y: tile.y - apronB, w: tile.w + 2 * apronB, h: tile.h + 2 * apronB).clamped(w: r.maxX, h: r.maxY)
            let cx0 = max(crop.x, r.x), cy0 = max(crop.y, r.y)
            let cw = crop.maxX - cx0, ch = crop.maxY - cy0
            if cw <= 0 || ch <= 0 { return }
            var isCore = [Bool](repeating: false, count: cw * ch)
            var any = false
            for y in 0 ..< ch {
                for x in 0 ..< cw where core[(cy0 + y - r.y) * rw + (cx0 + x - r.x)] { isCore[y * cw + x] = true; any = true }
            }
            if !any { return }
            let d = PlaneMath.distance(to: isCore, w: cw, h: ch)
            var wf = d.map { 1 - smoothstep(0, s.feather, $0) }
            var tmp = wf
            for y in 0 ..< ch {
                for x in 0 ..< cw {
                    var v: Float = 0
                    for k in -radius ... radius { v += wf[y * cw + min(max(x + k, 0), cw - 1)] * kernel[k + radius] }
                    tmp[y * cw + x] = v / ksum
                }
            }
            for y in 0 ..< ch {
                for x in 0 ..< cw {
                    var v: Float = 0
                    for k in -radius ... radius { v += tmp[min(max(y + k, 0), ch - 1) * cw + x] * kernel[k + radius] }
                    wf[y * cw + x] = v / ksum
                }
            }
            var nF = 0, nC = 0
            for y in tile.y ..< tile.maxY {
                for x in tile.x ..< tile.maxX {
                    let li = (y - cy0) * cw + (x - cx0), ri = (y - r.y) * rw + (x - r.x)
                    var w = max(wf[li], isCore[li] ? 1 : 0)
                    if protected?[ri] == true { w = 0 }
                    let w8 = UInt8((min(max(w, 0), 1) * 255).rounded())
                    if w8 == 0 { continue }
                    let o = (y * W + x) * 4
                    map[o] = UInt8(Int(offX[ri]) + 128); map[o + 1] = UInt8(Int(offY[ri]) + 128); map[o + 2] = w8; map[o + 3] = 255
                    if let shares = shares {
                        let a = alpha[y * W + x]
                        shares[o] = a; shares[o + 1] = a; shares[o + 2] = a
                    }
                    if w8 == 255 { nC += 1 } else { nF += 1 }
                }
            }
            lock.lock()
            feathered += nF; coreCount += nC
            lock.unlock()
        }
        return (coreCount, feathered)
    }
}
