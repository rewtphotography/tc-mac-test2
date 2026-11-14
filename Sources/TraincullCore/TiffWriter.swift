import Foundation

/// What a developed TIFF records about the photo besides its pixels. Anything nil is left out.
public struct TiffMeta {
    public var software: String
    public var make: String?
    public var model: String?
    /// "YYYY:MM:DD HH:MM:SS", as cameras write it.
    public var taken: String?
    public var lens: String?
    public var exposureS: Double?
    public var fNumber: Double?
    public var iso: Int?
    public var focalMm: Double?
    /// The ICC profile of the colour space the pixels are in.
    public var icc: [UInt8]?

    public init(software: String, shot: ShotInfo? = nil, icc: [UInt8]? = nil) {
        self.software = software
        make = shot?.make
        model = shot?.model
        taken = shot?.taken
        lens = shot?.lens
        exposureS = shot?.exposureS
        fNumber = shot?.fNumber
        iso = shot?.iso
        focalMm = shot?.focalMm
        self.icc = icc
    }
}

/// Writes a 16-bit RGB TIFF with ZIP compression, the file a developed raw is exported as.
/// The file is little-endian: an 8-byte header, the tables (`head`), then the strips in order.
/// The caller compresses each strip; nothing here needs more than Foundation, so it is tested
/// on Linux.
public enum TiffWriter {
    // MARK: ZIP (zlib) framing

    /// The Adler-32 checksum a zlib stream ends with.
    public static func adler32(_ bytes: UnsafeRawBufferPointer) -> UInt32 {
        var a: UInt32 = 1, b: UInt32 = 0
        var i = 0
        let n = bytes.count
        while i < n {
            // 5552 is the most bytes that can be summed before the sums must be reduced.
            let end = min(i + 5552, n)
            while i < end {
                a &+= UInt32(bytes[i])
                b &+= a
                i += 1
            }
            a %= 65521
            b %= 65521
        }
        return (b << 16) | a
    }

    public static func adler32(_ bytes: [UInt8]) -> UInt32 { bytes.withUnsafeBytes { adler32($0) } }

    /// A zlib stream around raw deflate data: two header bytes, the data, the checksum of the
    /// uncompressed bytes. TIFF's ZIP compression stores exactly this.
    public static func zlibStream(deflated: [UInt8], adler: UInt32) -> [UInt8] {
        var out: [UInt8] = [0x78, 0x9C]
        out.reserveCapacity(deflated.count + 6)
        out.append(contentsOf: deflated)
        out.append(contentsOf: [UInt8(adler >> 24), UInt8((adler >> 16) & 0xFF), UInt8((adler >> 8) & 0xFF), UInt8(adler & 0xFF)])
        return out
    }

    /// Valid deflate data that stores the bytes without compressing them. The fallback when the
    /// system's compressor fails, so an export never produces a broken file.
    public static func storedDeflate(_ bytes: [UInt8]) -> [UInt8] {
        var out: [UInt8] = []
        out.reserveCapacity(bytes.count + (bytes.count / 65535 + 1) * 5)
        var i = 0
        repeat {
            let n = min(65535, bytes.count - i)
            let last = i + n >= bytes.count
            out.append(last ? 1 : 0)
            out.append(UInt8(n & 0xFF))
            out.append(UInt8(n >> 8))
            out.append(UInt8(~n & 0xFF))
            out.append(UInt8((~n >> 8) & 0xFF))
            out.append(contentsOf: bytes[i ..< i + n])
            i += n
        } while i < bytes.count
        return out
    }

    // MARK: Pixels

    /// The bytes of one strip, before compression: three little-endian 16-bit samples for each
    /// pixel, each stored as its difference from the pixel to its left (TIFF's horizontal
    /// predictor, which makes photographs compress far better).
    ///
    /// - Parameters:
    ///   - source: rows of 16-bit pixels, `rowBytes` apart.
    ///   - samplesPerPixel: samples each source pixel has (4 for RGBA).
    ///   - firstSample: the index of red within a source pixel (0 for RGBA, 1 for ARGB).
    ///   - littleEndian: the byte order of the source samples.
    public static func strip(_ source: UnsafeRawBufferPointer, rowBytes: Int, rows: Int, width: Int,
                             samplesPerPixel: Int, firstSample: Int, littleEndian: Bool) -> [UInt8] {
        let count = rows * width * 6
        if count <= 0 { return [] }
        return [UInt8](unsafeUninitializedCapacity: count) { out, used in
            let lo = littleEndian ? 0 : 1, hi = littleEndian ? 1 : 0
            var o = 0
            for r in 0 ..< rows {
                var p = r * rowBytes + firstSample * 2
                var pr: UInt16 = 0, pg: UInt16 = 0, pb: UInt16 = 0
                for _ in 0 ..< width {
                    let red = UInt16(source[p + lo]) | (UInt16(source[p + hi]) << 8)
                    let green = UInt16(source[p + 2 + lo]) | (UInt16(source[p + 2 + hi]) << 8)
                    let blue = UInt16(source[p + 4 + lo]) | (UInt16(source[p + 4 + hi]) << 8)
                    let dr = red &- pr, dg = green &- pg, db = blue &- pb
                    pr = red; pg = green; pb = blue
                    out[o] = UInt8(dr & 0xFF); out[o + 1] = UInt8(dr >> 8)
                    out[o + 2] = UInt8(dg & 0xFF); out[o + 3] = UInt8(dg >> 8)
                    out[o + 4] = UInt8(db & 0xFF); out[o + 5] = UInt8(db >> 8)
                    o += 6
                    p += samplesPerPixel * 2
                }
            }
            used = count
        }
    }

    /// Rows in each strip: about four megabytes of pixels, so strips compress side by side.
    public static func rowsPerStrip(width: Int, height: Int) -> Int {
        min(max(1, (4 << 20) / max(width * 6, 1)), max(height, 1))
    }

    // MARK: The tables

    private struct Entry {
        let tag: Int
        let type: Int
        let count: Int
        let data: [UInt8]
    }

    private static func le16(_ v: Int) -> [UInt8] { [UInt8(v & 0xFF), UInt8((v >> 8) & 0xFF)] }
    private static func le32(_ v: Int) -> [UInt8] { (0 ..< 4).map { UInt8((v >> (8 * $0)) & 0xFF) } }

    private static func short(_ tag: Int, _ values: Int...) -> Entry {
        Entry(tag: tag, type: Tiff.typeShort, count: values.count, data: values.flatMap(le16))
    }

    private static func long(_ tag: Int, _ values: [Int]) -> Entry {
        Entry(tag: tag, type: Tiff.typeLong, count: values.count, data: values.flatMap(le32))
    }

    private static func rational(_ tag: Int, _ num: Int, _ den: Int) -> Entry {
        Entry(tag: tag, type: Tiff.typeRational, count: 1, data: le32(num) + le32(den))
    }

    /// ASCII with its closing zero; anything outside printable ASCII becomes "?".
    private static func ascii(_ tag: Int, _ text: String) -> Entry {
        let bytes = text.unicodeScalars.map { (32 ..< 127).contains($0.value) ? UInt8($0.value) : UInt8(ascii: "?") } + [0]
        return Entry(tag: tag, type: Tiff.typeAscii, count: bytes.count, data: bytes)
    }

    /// "1/250" for short exposures, tenths of a second for long ones.
    static func exposure(_ s: Double) -> (Int, Int) {
        if s < 0.3 { return (1, max(1, Int((1 / s).rounded()))) }
        return (Int((s * 10).rounded()), 10)
    }

    private static func blockSize(_ entries: [Entry]) -> Int {
        2 + entries.count * 12 + 4 + entries.reduce(0) { $0 + ($1.data.count > 4 ? ($1.data.count + 1) & ~1 : 0) }
    }

    /// One IFD at `offset` followed by the values that don't fit inside its entries.
    private static func block(_ entries: [Entry], at offset: Int) -> [UInt8] {
        let sorted = entries.sorted { $0.tag < $1.tag }
        var table = le16(sorted.count)
        var extra: [UInt8] = []
        let extraStart = offset + 2 + sorted.count * 12 + 4
        for e in sorted {
            table += le16(e.tag) + le16(e.type) + le32(e.count)
            if e.data.count <= 4 {
                table += e.data + [UInt8](repeating: 0, count: 4 - e.data.count)
            } else {
                table += le32(extraStart + extra.count)
                extra += e.data
                if extra.count % 2 == 1 { extra.append(0) }
            }
        }
        table += le32(0)
        return table + extra
    }

    /// Everything that comes before the strips: the header and the tables that describe the
    /// image, its strips (given their compressed sizes, in order) and the photo.
    public static func head(width: Int, height: Int, rowsPerStrip: Int, stripSizes: [Int], meta: TiffMeta) -> [UInt8] {
        var exif: [Entry] = []
        if let s = meta.exposureS, s > 0 {
            let (n, d) = exposure(s)
            exif.append(rational(0x829A, n, d))
        }
        if let f = meta.fNumber, f > 0 { exif.append(rational(0x829D, Int((f * 10).rounded()), 10)) }
        if let iso = meta.iso, iso > 0 {
            exif.append(iso <= 65535 ? short(0x8827, iso) : long(0x8827, [iso]))
        }
        if let t = meta.taken { exif.append(ascii(0x9003, t)) }
        if let mm = meta.focalMm, mm > 0 { exif.append(rational(0x920A, Int((mm * 10).rounded()), 10)) }
        if let lens = meta.lens { exif.append(ascii(0xA434, lens)) }
        if !exif.isEmpty { exif.append(Entry(tag: 0x9000, type: Tiff.typeUndefined, count: 4, data: Array("0232".utf8))) }

        func main(_ offsets: [Int], exifAt: Int) -> [Entry] {
            var e: [Entry] = [
                long(0x100, [width]),
                long(0x101, [height]),
                short(0x102, 16, 16, 16),
                short(0x103, 8), // ZIP
                short(0x106, 2), // RGB
                long(0x111, offsets),
                short(0x112, 1), // the pixels are already upright
                short(0x115, 3),
                long(0x116, [rowsPerStrip]),
                long(0x117, stripSizes),
                rational(0x11A, 300, 1),
                rational(0x11B, 300, 1),
                short(0x11C, 1),
                short(0x128, 2),
                ascii(0x131, meta.software),
                short(0x13D, 2), // horizontal differencing
            ]
            if let make = meta.make { e.append(ascii(0x10F, make)) }
            if let model = meta.model { e.append(ascii(0x110, model)) }
            if let t = meta.taken { e.append(ascii(0x132, t)) }
            if !exif.isEmpty { e.append(long(0x8769, [exifAt])) }
            if let icc = meta.icc, !icc.isEmpty {
                e.append(Entry(tag: 0x8773, type: Tiff.typeUndefined, count: icc.count, data: icc))
            }
            return e
        }

        // Sizes don't depend on the values, so lay the file out once with placeholders.
        let blank = [Int](repeating: 0, count: stripSizes.count)
        let exifAt = 8 + blockSize(main(blank, exifAt: 0))
        var length = exifAt + (exif.isEmpty ? 0 : blockSize(exif))
        if length % 2 == 1 { length += 1 }
        var offsets: [Int] = []
        var at = length
        for size in stripSizes {
            offsets.append(at)
            at += size
        }
        var out: [UInt8] = [0x49, 0x49, 42, 0] + le32(8)
        out += block(main(offsets, exifAt: exifAt), at: 8)
        if !exif.isEmpty { out += block(exif, at: exifAt) }
        if out.count < length { out.append(0) }
        return out
    }
}
