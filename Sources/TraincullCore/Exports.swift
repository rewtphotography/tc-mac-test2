import Foundation

/// Helpers for the embedded JPEG a raw file carries.
public enum JpegTools {
    /// Where a new segment can go: after the start marker and a JFIF segment if there is one.
    /// Also reports whether the JPEG already has an Exif segment. Nil if this isn't a JPEG.
    private static func scan(_ b: [UInt8]) -> (insertAt: Int, hasExif: Bool)? {
        if b.count < 4 || b[0] != 0xFF || b[1] != 0xD8 { return nil }
        var i = 2
        var insertAt = 2
        while i + 4 <= b.count && b[i] == 0xFF {
            let marker = Int(b[i + 1])
            let len = (Int(b[i + 2]) << 8) | Int(b[i + 3])
            if marker == 0xE1 && i + 10 <= b.count && Array(b[i + 4 ..< i + 8]) == Array("Exif".utf8) {
                return (insertAt, true)
            }
            if marker == 0xDA || len < 2 { break } // image data starts, or the file is damaged
            if marker == 0xE0 && i == 2 { insertAt = i + 2 + len }
            i += 2 + len
        }
        return (min(insertAt, b.count), false)
    }

    /// The JPEG as it should be saved. A raw file records which way up the photo is in its own
    /// tables, so its embedded JPEG usually doesn't; saved as it is, a portrait would open
    /// sideways. When the JPEG has no Exif of its own and the photo needs turning, a small
    /// Exif segment naming the orientation is added. The image data is never changed.
    public static func forSaving(_ jpeg: [UInt8], orientation: Int) -> [UInt8] {
        guard (2 ... 8).contains(orientation), let found = scan(jpeg), !found.hasExif else { return jpeg }
        // A little-endian TIFF with one entry: Orientation (0x0112), SHORT, 1 value.
        let tiff: [UInt8] = [0x49, 0x49, 42, 0, 8, 0, 0, 0,
                             1, 0,
                             0x12, 0x01, 3, 0, 1, 0, 0, 0, UInt8(orientation), 0, 0, 0,
                             0, 0, 0, 0]
        let length = 2 + 6 + tiff.count
        let segment: [UInt8] = [0xFF, 0xE1, UInt8(length >> 8), UInt8(length & 0xFF)] + Array("Exif".utf8) + [0, 0] + tiff
        return Array(jpeg[..<found.insertAt]) + segment + Array(jpeg[found.insertAt...])
    }
}

/// Names for exported files. An export never replaces a file that is already there.
public enum ExportNames {
    /// "DSC0001.tif", or "DSC0001-2.tif", "DSC0001-3.tif"… when that name is taken.
    public static func free(base: String, ext: String, taken: (String) -> Bool) -> String {
        let first = "\(base).\(ext)"
        if !taken(first) { return first }
        var n = 2
        while taken("\(base)-\(n).\(ext)") { n += 1 }
        return "\(base)-\(n).\(ext)"
    }
}
