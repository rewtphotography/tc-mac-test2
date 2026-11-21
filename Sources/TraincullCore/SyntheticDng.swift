import Foundation

/// A made-up DNG for tests: a 16-bit Bayer (RGGB) raw that Apple's decoder can develop, so the
/// raw controls can be tested without keeping a photo in the repository. Its picture, upright:
/// - a smooth colour gradient over the whole frame (for the transparency and exposure tests);
/// - a neutral grey patch at the top left (for white balance by point);
/// - at the top right, a block clipped in red and green, and below it one clipped in red only
///   (for highlight recovery);
/// - a little noise everywhere (so the noise reduction controls have something to act on).
/// The camera's colours are linear sRGB, and the white balance as shot is deliberately off
/// (`asShotNeutral`), so the grey patch comes out tinted until white balance is set on it.
public enum SyntheticDng {
    public struct Layout {
        /// The upright picture's size in pixels.
        public let width: Int
        public let height: Int
        /// In pixels of the upright picture, origin at the top left.
        public let greyPatch: Rect
        public let clippedTwo: Rect
        public let clippedOne: Rect

        public struct Rect {
            public let x: Int, y: Int, w: Int, h: Int
            public var centreX: Int { x + w / 2 }
            public var centreY: Int { y + h / 2 }
        }
    }

    public static let whiteLevel = 16383
    public static let asShotNeutral: [Double] = [0.75, 1, 0.55]

    /// The picture's layout for an upright size.
    public static func layout(width: Int, height: Int) -> Layout {
        func rect(_ u0: Double, _ v0: Double, _ u1: Double, _ v1: Double) -> Layout.Rect {
            let x = Int(u0 * Double(width)), y = Int(v0 * Double(height))
            return Layout.Rect(x: x, y: y, w: Int(u1 * Double(width)) - x, h: Int(v1 * Double(height)) - y)
        }
        return Layout(width: width, height: height, greyPatch: rect(0.08, 0.10, 0.28, 0.30),
                      clippedTwo: rect(0.70, 0.08, 0.95, 0.30), clippedOne: rect(0.70, 0.33, 0.95, 0.45))
    }

    /// The scene's linear camera values at an upright point (0…1, 1 being the white level).
    static func scene(_ x: Int, _ y: Int, _ layout: Layout) -> (Double, Double, Double) {
        func inside(_ r: Layout.Rect) -> Bool { x >= r.x && x < r.x + r.w && y >= r.y && y < r.y + r.h }
        if inside(layout.greyPatch) { return (0.16, 0.16, 0.16) }
        if inside(layout.clippedTwo) { return (1.2, 1.2, 0.45) }
        if inside(layout.clippedOne) { return (1.2, 0.55, 0.35) }
        let u = Double(x) / Double(layout.width), v = Double(y) / Double(layout.height)
        return (0.03 + 0.45 * u, 0.04 + 0.22 * u + 0.12 * v, 0.10 + 0.25 * (1 - u))
    }

    /// The file's bytes. `orientation` is the TIFF orientation: 1 is upright as stored, 6 is a
    /// portrait frame stored on its side (turned 90° clockwise to view). `width` and `height`
    /// are the upright picture's; both must be even.
    public static func make(width: Int = 1536, height: Int = 1024, orientation: Int = 1, noise: Double = 0.012) -> [UInt8] {
        precondition(width % 2 == 0 && height % 2 == 0 && (orientation == 1 || orientation == 6))
        let layout = self.layout(width: width, height: height)
        // Stored size: on its side for orientation 6.
        let sw = orientation == 6 ? height : width, sh = orientation == 6 ? width : height
        var seed: UInt64 = 0x5EED_1234_ABCD
        func uniform() -> Double {
            seed = seed &* 6364136223846793005 &+ 1442695040888963407
            return Double(seed >> 11) / Double(1 << 53)
        }
        var pixels = [UInt8](repeating: 0, count: sw * sh * 2)
        for r in 0 ..< sh {
            for c in 0 ..< sw {
                // Orientation 6: stored row r is the upright column (width - 1 - r), stored column c the upright row c.
                let (x, y) = orientation == 6 ? (width - 1 - r, c) : (c, r)
                let rgb = scene(x, y, layout)
                let channel = (r % 2 == 0) ? (c % 2 == 0 ? rgb.0 : rgb.1) : (c % 2 == 0 ? rgb.1 : rgb.2)
                // Roughly Gaussian noise: the sum of three uniforms.
                let n = (uniform() + uniform() + uniform() - 1.5) * noise * 2
                let v = min(max(channel + (channel >= 1 ? 0 : n), 0), 1)
                let sample = Int((v * Double(whiteLevel)).rounded())
                let at = (r * sw + c) * 2
                pixels[at] = UInt8(sample & 0xFF)
                pixels[at + 1] = UInt8(sample >> 8)
            }
        }
        return tiff(width: sw, height: sh, orientation: orientation, pixels: pixels)
    }

    // MARK: The TIFF container

    private enum Value {
        case short([Int])
        case long([Int])
        case byte([Int])
        case ascii(String)
        case rational([Double])
        case srational([Double])
    }

    private static func tiff(width: Int, height: Int, orientation: Int, pixels: [UInt8]) -> [UInt8] {
        // XYZ (D65) to the camera's colours, which are linear sRGB.
        let xyzToCamera: [Double] = [3.2406, -1.5372, -0.4986, -0.9689, 1.8758, 0.0415, 0.0557, -0.2040, 1.0570]
        var entries: [(Int, Value)] = [
            (254, .long([0])),
            (256, .long([width])),
            (257, .long([height])),
            (258, .short([16])),
            (259, .short([1])),
            (262, .short([32803])), // colour filter array
            (271, .ascii("TrainCull")),
            (272, .ascii("Synthetic DNG")),
            (273, .long([0])), // strip offset, filled in below
            (274, .short([orientation])),
            (277, .short([1])),
            (278, .long([height])),
            (279, .long([pixels.count])),
            (284, .short([1])),
            (305, .ascii("TrainCull tests")),
            (33421, .short([2, 2])), // CFA repeat pattern
            (33422, .byte([0, 1, 1, 2])), // RGGB
            (50706, .byte([1, 4, 0, 0])), // DNG version
            (50707, .byte([1, 1, 0, 0])),
            (50708, .ascii("TrainCull Synthetic")),
            (50710, .byte([0, 1, 2])), // CFA plane colours
            (50711, .short([1])), // CFA layout
            (50714, .long([0])), // black level
            (50717, .long([whiteLevel])),
            (50721, .srational(xyzToCamera)), // colour matrix 1
            (50728, .rational(asShotNeutral)),
            (50778, .short([21])), // calibration illuminant 1: D65
        ]
        let ifdStart = 8
        let ifdSize = 2 + entries.count * 12 + 4
        // Values longer than four bytes go after the table; the pixels after them.
        var extra: [UInt8] = []
        var extraStart = ifdStart + ifdSize
        func bytes(_ v: Value) -> (type: Int, count: Int, data: [UInt8]) {
            func le16(_ x: Int) -> [UInt8] { [UInt8(x & 0xFF), UInt8((x >> 8) & 0xFF)] }
            func le32(_ x: Int) -> [UInt8] { (0 ..< 4).map { UInt8((x >> (8 * $0)) & 0xFF) } }
            switch v {
            case let .short(xs): return (3, xs.count, xs.flatMap(le16))
            case let .long(xs): return (4, xs.count, xs.flatMap(le32))
            case let .byte(xs): return (1, xs.count, xs.map { UInt8($0) })
            case let .ascii(s): let d = Array(s.utf8) + [0]; return (2, d.count, d)
            case let .rational(xs): return (5, xs.count, xs.flatMap { le32(Int(($0 * 10000).rounded())) + le32(10000) })
            case let .srational(xs):
                return (10, xs.count, xs.flatMap { x -> [UInt8] in
                    let n = Int32((x * 10000).rounded())
                    return le32(Int(UInt32(bitPattern: n))) + le32(10000)
                })
            }
        }
        // First pass for sizes, to know where the pixels start.
        var extraSize = 0
        for entry in entries {
            let n = bytes(entry.1).data.count
            if n > 4 { extraSize += (n + 1) & ~1 }
        }
        let pixelStart = (extraStart + extraSize + 15) & ~15
        if let i = entries.firstIndex(where: { $0.0 == 273 }) { entries[i].1 = .long([pixelStart]) }

        func le32(_ x: Int) -> [UInt8] { (0 ..< 4).map { UInt8((x >> (8 * $0)) & 0xFF) } }
        var table: [UInt8] = [UInt8(entries.count & 0xFF), UInt8(entries.count >> 8)]
        for (tag, value) in entries {
            let b = bytes(value)
            var entry: [UInt8] = [UInt8(tag & 0xFF), UInt8(tag >> 8), UInt8(b.type), 0]
            entry += le32(b.count)
            if b.data.count <= 4 {
                entry += b.data
                entry += [UInt8](repeating: 0, count: 4 - b.data.count)
            } else {
                entry += le32(extraStart)
                extra += b.data
                if b.data.count % 2 == 1 { extra.append(0) }
                extraStart += (b.data.count + 1) & ~1
            }
            table += entry
        }
        table += [0, 0, 0, 0] // no next IFD
        var out: [UInt8] = [0x49, 0x49, 42, 0, 8, 0, 0, 0]
        out += table
        out += extra
        out += [UInt8](repeating: 0, count: pixelStart - out.count)
        out += pixels
        return out
    }
}
