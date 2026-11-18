import Foundation

/// The Oklab colour space (Björn Ottosson, 2020): distances and angles in it match how
/// different two colours look. Used to check that masking never adds colour, and to compare
/// colours the way the eye does.
public enum Oklab {
    /// Lightness, and two opponent axes (green–red, blue–yellow), from linear-light RGB.
    @inline(__always)
    public static func from(linear c: SIMD3<Float>) -> SIMD3<Float> {
        let l = 0.4122214708 * c.x + 0.5363325363 * c.y + 0.0514459929 * c.z
        let m = 0.2119034982 * c.x + 0.6806995451 * c.y + 0.1073969566 * c.z
        let s = 0.0883024619 * c.x + 0.2817188376 * c.y + 0.6299787005 * c.z
        let l3 = cbrt(max(l, 0)), m3 = cbrt(max(m, 0)), s3 = cbrt(max(s, 0))
        return SIMD3(0.2104542553 * l3 + 0.7936177850 * m3 - 0.0040720468 * s3,
                     1.9779984951 * l3 - 2.4285922050 * m3 + 0.4505937099 * s3,
                     0.0259040371 * l3 + 0.7827717662 * m3 - 0.8086757660 * s3)
    }

    /// Back to linear-light RGB. Out-of-gamut colours come back with channels below 0 or above 1.
    @inline(__always)
    public static func toLinear(_ lab: SIMD3<Float>) -> SIMD3<Float> {
        let l3 = lab.x + 0.3963377774 * lab.y + 0.2158037573 * lab.z
        let m3 = lab.x - 0.1055613458 * lab.y - 0.0638541728 * lab.z
        let s3 = lab.x - 0.0894841775 * lab.y - 1.2914855480 * lab.z
        let l = l3 * l3 * l3, m = m3 * m3 * m3, s = s3 * s3 * s3
        return SIMD3(4.0767416621 * l - 3.3077115913 * m + 0.2309699292 * s,
                     -1.2684380046 * l + 2.6097574011 * m - 0.3413193965 * s,
                     -0.0041960863 * l - 0.7034186147 * m + 1.7076147010 * s)
    }

    /// How colourful: the distance from grey.
    @inline(__always)
    public static func chroma(_ lab: SIMD3<Float>) -> Float { (lab.y * lab.y + lab.z * lab.z).squareRoot() }

    /// The angle between two colours' hues, in degrees, 0 to 180.
    @inline(__always)
    public static func hueApart(_ a: SIMD3<Float>, _ b: SIMD3<Float>) -> Float {
        let ca = chroma(a), cb = chroma(b)
        if ca < 1e-6 || cb < 1e-6 { return 0 }
        let cosine = min(max((a.y * b.y + a.z * b.z) / (ca * cb), -1), 1)
        return acos(cosine) * 180 / Float.pi
    }

    /// The distance between two colours as the eye judges it.
    @inline(__always)
    public static func distance(_ a: SIMD3<Float>, _ b: SIMD3<Float>) -> Float {
        let d = a - b
        return (d * d).sum().squareRoot()
    }
}
