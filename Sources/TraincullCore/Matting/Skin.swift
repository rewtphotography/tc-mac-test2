import Foundation

/// What skin looks like in one photo, learned from a few samples of it: the average colour
/// (leaving brightness aside), how far and in which directions it strays, and how light and
/// dark it gets. Colour is measured in CIE Lab, where equal distances look about equally
/// different.
public struct SkinModel {
    public let mean: SIMD2<Float>
    /// The inverse of the colour spread: three numbers of a symmetric 2×2.
    public let inverse: SIMD3<Float>
    public let lightness: ClosedRange<Float>
    public var tolerance: ClosedRange<Float> = 2.0 ... 3.5
    public var lightnessMargin: Float = 12

    /// - Parameter samples: skin pixels, red, green and blue from 0 to 1 as displayed.
    public init?(samples: [SIMD3<Float>]) {
        if samples.count < 8 { return nil }
        let labs = samples.map(SkinModel.lab)
        let n = Float(labs.count)
        let m = labs.reduce(SIMD3<Float>(repeating: 0), +) / n
        var caa: Float = 0, cab: Float = 0, cbb: Float = 0
        for l in labs {
            let da = l.y - m.y, db = l.z - m.z
            caa += da * da; cab += da * db; cbb += db * db
        }
        // A floor on the spread, so a very even patch doesn't give a hair-thin tolerance.
        caa = caa / n + 4; cab /= n; cbb = cbb / n + 4
        let det = caa * cbb - cab * cab
        if det <= 0 { return nil }
        mean = SIMD2(m.y, m.z)
        inverse = SIMD3(cbb / det, -cab / det, caa / det)
        let ls = labs.map { $0.x }.sorted()
        lightness = ls[ls.count / 20] ... ls[ls.count - 1 - ls.count / 20]
    }

    @inline(__always) static func f(_ t: Float) -> Float { t > 0.008856 ? cbrtf(t) : 7.787 * t + 16.0 / 116.0 }

    /// Displayed red, green and blue to Lab (lightness, green-red, blue-yellow).
    @inline(__always) public static func lab(_ c: SIMD3<Float>) -> SIMD3<Float> {
        let lin = Matte.toLinear.p
        let r = lin[Int(min(max(c.x, 0), 1) * 255)], g = lin[Int(min(max(c.y, 0), 1) * 255)], b = lin[Int(min(max(c.z, 0), 1) * 255)]
        let x = 0.4124 * r + 0.3576 * g + 0.1805 * b, y = 0.2126 * r + 0.7152 * g + 0.0722 * b, z = 0.0193 * r + 0.1192 * g + 0.9505 * b
        let fx = f(x / 0.95047), fy = f(y), fz = f(z / 1.08883)
        return SIMD3(116 * fy - 16, 500 * (fx - fy), 200 * (fy - fz))
    }

    /// How skin-like a colour is, 0 to 1.
    @inline(__always) public func value(_ c: SIMD3<Float>) -> Float {
        let l = SkinModel.lab(c)
        let da = l.y - mean.x, db = l.z - mean.y
        let m2 = da * (inverse.x * da + inverse.y * db) + db * (inverse.y * da + inverse.z * db)
        let chroma = 1 - smoothstep(tolerance.lowerBound, tolerance.upperBound, max(m2, 0).squareRoot())
        let lum = smoothstep(lightness.lowerBound - lightnessMargin, lightness.lowerBound, l.x)
            * (1 - smoothstep(lightness.upperBound, lightness.upperBound + lightnessMargin, l.x))
        return chroma * lum
    }
}

public enum SkinMask {
    /// A skin mask for the whole photo, 0 to 255: skin-coloured pixels, inside the subject,
    /// outside the eyes, brows and lips.
    ///
    /// - Parameters:
    ///   - alpha: the subject mask, one byte per pixel.
    ///   - exclusion: where skin must not be selected (1 = keep out), any size, covering the photo.
    public static func make(photo: Photo, alpha: [UInt8], model: SkinModel, exclusion: Gray?) -> [UInt8] {
        let W = photo.w, H = photo.h
        let raw = Buf<Float>(W * H, 0)
        let a = Buf(alpha)
        let src = photo.p, rowBytes = photo.rowBytes
        parallelRows(H) { rows in
            for y in rows {
                for x in 0 ..< W where a.p[y * W + x] > 0 {
                    raw.p[y * W + x] = model.value(rgbAt(src, rowBytes, x, y))
                }
            }
        }
        // Grain makes single pixels flicker in and out of the colour range; average it away.
        var smooth = raw.array
        PlaneMath.boxBlur(&smooth, w: W, h: H, radius: 3)
        var out = [UInt8](repeating: 0, count: W * H)
        let kx = exclusion.map { Float($0.w) / Float(W) } ?? 0, ky = exclusion.map { Float($0.h) / Float(H) } ?? 0
        smooth.withUnsafeBufferPointer { s in
            out.withUnsafeMutableBufferPointer { o in
                let dst = o
                parallelRows(H) { rows in
                    for y in rows {
                        for x in 0 ..< W where a.p[y * W + x] > 0 {
                            var v = s[y * W + x] * Float(a.p[y * W + x]) / 255
                            if let e = exclusion { v *= 1 - min(max(e.sample((Float(x) + 0.5) * kx, (Float(y) + 0.5) * ky), 0), 1) }
                            dst[y * W + x] = UInt8((min(max(v, 0), 1) * 255).rounded())
                        }
                    }
                }
            }
        }
        return out
    }
}
