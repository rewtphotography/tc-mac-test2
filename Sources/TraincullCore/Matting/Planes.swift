import Dispatch
import Foundation

/// Runs `body` for every index from 0 to `n`, spread over the processor cores. Each index must
/// only write memory no other index touches.
@inline(__always)
func parallel(_ n: Int, _ body: (Int) -> Void) {
    if n <= 1 {
        if n == 1 { body(0) }
        return
    }
    DispatchQueue.concurrentPerform(iterations: n, execute: body)
}

/// Runs `body` over row ranges that together cover `0 ..< rows`.
func parallelRows(_ rows: Int, _ body: (Range<Int>) -> Void) {
    let chunks = min(max(rows / 32, 1), 64)
    parallel(chunks) { i in
        let lo = rows * i / chunks, hi = rows * (i + 1) / chunks
        if lo < hi { body(lo ..< hi) }
    }
}

/// A rectangle of whole pixels.
public struct PixelRect: Equatable {
    public var x: Int, y: Int, w: Int, h: Int

    public init(x: Int, y: Int, w: Int, h: Int) {
        self.x = x; self.y = y; self.w = w; self.h = h
    }

    public var maxX: Int { x + w }
    public var maxY: Int { y + h }
    public var isEmpty: Bool { w <= 0 || h <= 0 }

    public func contains(_ px: Int, _ py: Int) -> Bool { px >= x && py >= y && px < maxX && py < maxY }

    public func clamped(w cw: Int, h ch: Int) -> PixelRect {
        let x0 = max(x, 0), y0 = max(y, 0), x1 = min(maxX, cw), y1 = min(maxY, ch)
        return PixelRect(x: x0, y: y0, w: max(x1 - x0, 0), h: max(y1 - y0, 0))
    }
}

/// One channel of numbers, usually a mask from 0 to 1, row by row from the top.
public struct Gray {
    public let w: Int
    public let h: Int
    public var v: [Float]

    public init(w: Int, h: Int, fill: Float = 0) {
        self.w = w; self.h = h
        v = [Float](repeating: fill, count: max(w * h, 0))
    }

    public init(w: Int, h: Int, v: [Float]) {
        precondition(v.count == w * h)
        self.w = w; self.h = h; self.v = v
    }

    @inline(__always)
    public func at(_ x: Int, _ y: Int) -> Float {
        v[min(max(y, 0), h - 1) * w + min(max(x, 0), w - 1)]
    }

    /// The value at a point given in pixels of this plane (pixel centres sit at .5), blended
    /// from the four pixels around it.
    @inline(__always)
    public func sample(_ x: Float, _ y: Float) -> Float {
        let fx = min(max(x - 0.5, 0), Float(w - 1)), fy = min(max(y - 0.5, 0), Float(h - 1))
        let x0 = Int(fx), y0 = Int(fy)
        let x1 = min(x0 + 1, w - 1), y1 = min(y0 + 1, h - 1)
        let tx = fx - Float(x0), ty = fy - Float(y0)
        return v.withUnsafeBufferPointer { p in
            let a = p[y0 * w + x0], b = p[y0 * w + x1], c = p[y1 * w + x0], d = p[y1 * w + x1]
            return (a + (b - a) * tx) * (1 - ty) + (c + (d - c) * tx) * ty
        }
    }

    /// This plane stretched or shrunk to another size, blending between pixels.
    public func resized(w nw: Int, h nh: Int) -> Gray {
        if nw == w && nh == h { return self }
        var out = Gray(w: nw, h: nh)
        let kx = Float(w) / Float(nw), ky = Float(h) / Float(nh)
        out.v.withUnsafeMutableBufferPointer { o in
            let dst = o
            parallelRows(nh) { rows in
                for y in rows {
                    for x in 0 ..< nw { dst[y * nw + x] = sample((Float(x) + 0.5) * kx, (Float(y) + 0.5) * ky) }
                }
            }
        }
        return out
    }
}

/// A block of memory with a fixed address, owned by this object. The matting loops read and
/// write these from many threads at once, each thread its own pixels.
public final class Buf<T> {
    public let p: UnsafeMutablePointer<T>
    public let count: Int

    public init(_ count: Int, _ fill: T) {
        self.count = count
        p = UnsafeMutablePointer<T>.allocate(capacity: max(count, 1))
        p.initialize(repeating: fill, count: count)
    }

    public init(_ values: [T]) {
        count = values.count
        p = UnsafeMutablePointer<T>.allocate(capacity: max(count, 1))
        values.withUnsafeBufferPointer { if count > 0 { p.initialize(from: $0.baseAddress!, count: count) } }
    }

    deinit {
        p.deinitialize(count: count)
        p.deallocate()
    }

    public var array: [T] { Array(UnsafeBufferPointer(start: p, count: count)) }
}

/// A photograph as 8-bit pixels with red, green and blue first in each group of four bytes,
/// in the encoding it is shown in (not linear light). Matting works on this directly.
public final class Photo {
    public let w: Int
    public let h: Int
    public let rowBytes: Int
    let buf: Buf<UInt8>

    public init(w: Int, h: Int, rowBytes: Int, px: [UInt8]) {
        precondition(px.count >= (h - 1) * rowBytes + w * 4)
        self.w = w; self.h = h; self.rowBytes = rowBytes
        buf = Buf(px)
    }

    /// Copies the pixels from memory someone else owns.
    public init(w: Int, h: Int, rowBytes: Int, bytes: UnsafeRawBufferPointer) {
        precondition(bytes.count >= (h - 1) * rowBytes + w * 4)
        self.w = w; self.h = h; self.rowBytes = rowBytes
        buf = Buf(bytes.count, UInt8(0))
        UnsafeMutableRawBufferPointer(start: buf.p, count: bytes.count).copyMemory(from: bytes)
    }

    var p: UnsafePointer<UInt8> { UnsafePointer(buf.p) }

    @inline(__always)
    public func rgb(_ x: Int, _ y: Int) -> SIMD3<Float> { rgbAt(buf.p, rowBytes, x, y) }
}

@inline(__always)
func rgbAt(_ p: UnsafePointer<UInt8>, _ rowBytes: Int, _ x: Int, _ y: Int) -> SIMD3<Float> {
    let i = y * rowBytes + x * 4
    return SIMD3(Float(p[i]), Float(p[i + 1]), Float(p[i + 2])) * (1 / 255)
}

@inline(__always)
func luma(_ c: SIMD3<Float>) -> Float { 0.2126 * c.x + 0.7152 * c.y + 0.0722 * c.z }

@inline(__always)
func dot3(_ a: SIMD3<Float>, _ b: SIMD3<Float>) -> Float { (a * b).sum() }

@inline(__always)
func smoothstep(_ e0: Float, _ e1: Float, _ x: Float) -> Float {
    let t = min(max((x - e0) / (e1 - e0), 0), 1)
    return t * t * (3 - 2 * t)
}

enum PlaneMath {
    /// The smallest (or largest) value within `radius` pixels in a square around each pixel.
    static func extremum(_ g: Gray, radius: Int, smallest: Bool) -> Gray {
        if radius <= 0 { return g }
        let w = g.w, h = g.h
        var tmp = Gray(w: w, h: h), out = Gray(w: w, h: h)
        g.v.withUnsafeBufferPointer { src in
            tmp.v.withUnsafeMutableBufferPointer { t in
                let dst = t
                parallelRows(h) { rows in
                    for y in rows {
                        let row = y * w
                        for x in 0 ..< w {
                            var m = src[row + x]
                            let lo = max(x - radius, 0), hi = min(x + radius, w - 1)
                            if smallest { for k in lo ... hi { m = min(m, src[row + k]) } } else { for k in lo ... hi { m = max(m, src[row + k]) } }
                            dst[row + x] = m
                        }
                    }
                }
            }
        }
        tmp.v.withUnsafeBufferPointer { src in
            out.v.withUnsafeMutableBufferPointer { o in
                let dst = o
                parallelRows(h) { rows in
                    for y in rows {
                        let lo = max(y - radius, 0), hi = min(y + radius, h - 1)
                        for x in 0 ..< w {
                            var m = src[y * w + x]
                            if smallest { for k in lo ... hi { m = min(m, src[k * w + x]) } } else { for k in lo ... hi { m = max(m, src[k * w + x]) } }
                            dst[y * w + x] = m
                        }
                    }
                }
            }
        }
        return out
    }

    /// The mean of the square of pixels within `radius` of each pixel, in place. Near an edge
    /// the mean is of the pixels that exist.
    static func boxBlur(_ a: inout [Float], w: Int, h: Int, radius r: Int) {
        if r <= 0 || w == 0 || h == 0 { return }
        var tmp = [Float](repeating: 0, count: w * h)
        a.withUnsafeBufferPointer { src in
            tmp.withUnsafeMutableBufferPointer { t in
                let dst = t
                parallelRows(h) { rows in
                    for y in rows {
                        let row = y * w
                        var sum: Float = 0
                        var lo = 0, hi = -1 // the window currently summed, inclusive
                        for x in 0 ..< w {
                            let wantLo = max(x - r, 0), wantHi = min(x + r, w - 1)
                            while hi < wantHi { hi += 1; sum += src[row + hi] }
                            while lo < wantLo { sum -= src[row + lo]; lo += 1 }
                            dst[row + x] = sum / Float(hi - lo + 1)
                        }
                    }
                }
            }
        }
        tmp.withUnsafeBufferPointer { src in
            a.withUnsafeMutableBufferPointer { o in
                let dst = o
                let chunks = min(max(w / 64, 1), 64)
                parallel(chunks) { c in
                    for x in (w * c / chunks) ..< (w * (c + 1) / chunks) {
                        var sum: Float = 0
                        var lo = 0, hi = -1
                        for y in 0 ..< h {
                            let wantLo = max(y - r, 0), wantHi = min(y + r, h - 1)
                            while hi < wantHi { hi += 1; sum += src[hi * w + x] }
                            while lo < wantLo { sum -= src[lo * w + x]; lo += 1 }
                            dst[y * w + x] = sum / Float(hi - lo + 1)
                        }
                    }
                }
            }
        }
    }

    /// For every pixel, the distance in pixels to the nearest pixel where `inside` is true
    /// (0 on those pixels). Exact, by the lower-envelope method of Felzenszwalb and
    /// Huttenlocher, one row or column at a time.
    static func distance(to inside: [Bool], w: Int, h: Int) -> [Float] {
        let far: Float = 1e18
        var d = [Float](repeating: 0, count: w * h)
        // Columns first: squared distance along y.
        d.withUnsafeMutableBufferPointer { o in
            let dst = o
            let chunks = min(max(w / 64, 1), 64)
            parallel(chunks) { c in
                var f = [Float](repeating: 0, count: h), out = [Float](repeating: 0, count: h)
                var v = [Int](repeating: 0, count: h), z = [Float](repeating: 0, count: h + 1)
                for x in (w * c / chunks) ..< (w * (c + 1) / chunks) {
                    for y in 0 ..< h { f[y] = inside[y * w + x] ? 0 : far }
                    envelope(&f, h, &out, &v, &z)
                    for y in 0 ..< h { dst[y * w + x] = out[y] }
                }
            }
            parallelRows(h) { rows in
                var f = [Float](repeating: 0, count: w), out = [Float](repeating: 0, count: w)
                var v = [Int](repeating: 0, count: w), z = [Float](repeating: 0, count: w + 1)
                for y in rows {
                    for x in 0 ..< w { f[x] = dst[y * w + x] }
                    envelope(&f, w, &out, &v, &z)
                    for x in 0 ..< w { dst[y * w + x] = out[x].squareRoot() }
                }
            }
        }
        return d
    }

    /// One dimension of the distance transform: out[q] = min over p of (q - p)² + f[p].
    private static func envelope(_ f: inout [Float], _ n: Int, _ out: inout [Float], _ v: inout [Int], _ z: inout [Float]) {
        var k = 0
        v[0] = 0
        z[0] = -Float.infinity
        z[1] = Float.infinity
        if n > 1 {
            for q in 1 ..< n {
                var s: Float = 0
                while true {
                    let p = v[k]
                    s = ((f[q] + Float(q * q)) - (f[p] + Float(p * p))) / Float(2 * q - 2 * p)
                    if s <= z[k] && k > 0 { k -= 1 } else { break }
                }
                k += 1
                v[k] = q
                z[k] = s
                z[k + 1] = Float.infinity
            }
        }
        k = 0
        for q in 0 ..< n {
            while z[k + 1] < Float(q) { k += 1 }
            let p = v[k]
            out[q] = Float((q - p) * (q - p)) + f[p]
        }
    }
}
