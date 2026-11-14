import Foundation

public struct TiffError: Error, CustomStringConvertible {
    public let description: String
    public init(_ message: String) { description = message }
}

/// One IFD entry. `valuePos` is the absolute file position of the value bytes.
public struct TiffEntry {
    public let tag: Int
    public let type: Int
    public let count: Int64
    public let valuePos: Int64
}

public struct Ifd {
    public let offset: Int64
    public let entries: [Int: TiffEntry]
    public let nextOffset: Int64
}

/// Minimal TIFF/IFD reader. A raw file such as an ARW is a TIFF container whose IFDs list the
/// offset and length of every embedded image, so only the IFD tables and the wanted image
/// bytes are ever read. Entries are looked up by tag, never by position.
public final class Tiff {
    private let src: ByteSource
    public let littleEndian: Bool
    public let firstIfdOffset: Int64

    /// IFDs can't start inside the 8-byte TIFF header; a maker note IFD with no header can start at 0.
    private let minIfdOffset: Int64

    public init(_ src: ByteSource, forcedLittleEndian: Bool? = nil) throws {
        self.src = src
        if let forced = forcedLittleEndian {
            littleEndian = forced
            firstIfdOffset = 0
            minIfdOffset = 0
        } else {
            minIfdOffset = 8
            if src.size < 8 { throw TiffError("file too small") }
            let h = try src.read(0, 8)
            let le: Bool
            if h[0] == 0x49 && h[1] == 0x49 {
                le = true
            } else if h[0] == 0x4D && h[1] == 0x4D {
                le = false
            } else {
                throw TiffError("not a TIFF/ARW file")
            }
            littleEndian = le
            if Tiff.u16(h, 2, le) != 42 { throw TiffError("not a TIFF/ARW file") }
            firstIfdOffset = Tiff.u32(h, 4, le)
        }
    }

    static func u16(_ b: [UInt8], _ i: Int, _ le: Bool) -> Int {
        let a = Int(b[i])
        let c = Int(b[i + 1])
        return le ? a | (c << 8) : (a << 8) | c
    }

    static func u32(_ b: [UInt8], _ i: Int, _ le: Bool) -> Int64 {
        let lo = Int64(u16(b, le ? i : i + 2, le))
        let hi = Int64(u16(b, le ? i + 2 : i, le))
        return (hi << 16) | lo
    }

    public func u16(_ b: [UInt8], _ i: Int) -> Int { Tiff.u16(b, i, littleEndian) }
    public func u32(_ b: [UInt8], _ i: Int) -> Int64 { Tiff.u32(b, i, littleEndian) }

    public func readIfd(_ offset: Int64) throws -> Ifd {
        if offset < minIfdOffset || offset + 2 > src.size { throw TiffError("IFD offset out of range: \(offset)") }
        let n = u16(try src.read(offset, 2), 0)
        if n == 0 || n > 1000 { throw TiffError("implausible IFD entry count \(n) at \(offset)") }
        let buf = try src.read(offset + 2, n * 12 + 4)
        var entries = [Int: TiffEntry](minimumCapacity: n)
        for k in 0 ..< n {
            let p = k * 12
            let tag = u16(buf, p)
            let type = u16(buf, p + 2)
            let count = u32(buf, p + 4)
            let bytes = Int64(Tiff.typeSize(type)) * count
            let valuePos = bytes <= 4 ? offset + 2 + Int64(p) + 8 : u32(buf, p + 8)
            entries[tag] = TiffEntry(tag: tag, type: type, count: count, valuePos: valuePos)
        }
        return Ifd(offset: offset, entries: entries, nextOffset: u32(buf, n * 12))
    }

    /// Integer values of an entry (BYTE, SHORT, LONG, SLONG, IFD types); at most 256 values.
    public func values(_ e: TiffEntry) -> [Int64] {
        let size = Tiff.typeSize(e.type)
        if size == 0 || e.count <= 0 { return [] }
        let count = Int(min(e.count, 256))
        if e.valuePos < 0 || e.valuePos + Int64(count * size) > src.size { return [] }
        guard let b = try? src.read(e.valuePos, count * size) else { return [] }
        return (0 ..< count).map { i in
            switch e.type {
            case Tiff.typeByte, Tiff.typeUndefined: return Int64(b[i])
            case Tiff.typeShort: return Int64(u16(b, i * 2))
            case Tiff.typeLong, Tiff.typeIfd: return u32(b, i * 4)
            case Tiff.typeSLong: return Int64(Int32(truncatingIfNeeded: u32(b, i * 4)))
            case Tiff.typeSShort: return Int64(Int16(truncatingIfNeeded: u16(b, i * 2)))
            default: return 0
            }
        }
    }

    public func value(_ ifd: Ifd, _ tag: Int) -> Int64? {
        guard let e = ifd.entries[tag] else { return nil }
        return values(e).first
    }

    /// First RATIONAL / SRATIONAL value of a tag as a double, or nil.
    public func rational(_ ifd: Ifd, _ tag: Int) -> Double? {
        guard let e = ifd.entries[tag] else { return nil }
        if e.type != Tiff.typeRational && e.type != Tiff.typeSRational {
            return values(e).first.map(Double.init)
        }
        if e.count < 1 || e.valuePos < 0 || e.valuePos + 8 > src.size { return nil }
        guard let b = try? src.read(e.valuePos, 8) else { return nil }
        let num = u32(b, 0)
        let den = u32(b, 4)
        let signed = e.type == Tiff.typeSRational
        let n = signed ? Double(Int32(truncatingIfNeeded: num)) : Double(num)
        let d = signed ? Double(Int32(truncatingIfNeeded: den)) : Double(den)
        return d == 0 ? nil : n / d
    }

    /// ASCII value of a tag, trimmed, or nil.
    public func string(_ ifd: Ifd, _ tag: Int) -> String? {
        guard let e = ifd.entries[tag] else { return nil }
        if e.type != Tiff.typeAscii || e.count < 1 || e.count > 256 || e.valuePos < 0 || e.valuePos + e.count > src.size { return nil }
        guard let b = try? src.read(e.valuePos, Int(e.count)) else { return nil }
        let s = latin1(b)
        let t = s.trimmingCharacters(in: CharacterSet(charactersIn: "\u{0} ")).trimmingCharacters(in: .whitespacesAndNewlines)
        return t.isEmpty ? nil : t
    }

    public static let typeByte = 1
    public static let typeAscii = 2
    public static let typeShort = 3
    public static let typeLong = 4
    public static let typeRational = 5
    public static let typeUndefined = 7
    public static let typeSShort = 8
    public static let typeSLong = 9
    public static let typeSRational = 10
    public static let typeIfd = 13

    public static func typeSize(_ type: Int) -> Int {
        switch type {
        case 1, 2, 6, 7: return 1
        case 3, 8: return 2
        case 4, 9, 11, 13: return 4
        case 5, 10, 12: return 8
        default: return 0
        }
    }
}

/// ISO 8859-1: every byte is the code point of the same value.
func latin1(_ bytes: [UInt8]) -> String {
    var view = String.UnicodeScalarView()
    view.append(contentsOf: bytes.map { Unicode.Scalar($0) })
    return String(view)
}
