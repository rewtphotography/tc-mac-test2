#if TC_ALPHA_DEBUG
import Foundation

/// Writes a plain zip archive: every entry stored as it is (PNGs are compressed already), with
/// a CRC-32 per entry so any unzip tool checks it. Large entries are read from disk in pieces.
enum ZipWriter {
    enum Source {
        case data(Data)
        case file(URL)
    }

    struct Failure: Error, CustomStringConvertible {
        let description: String
    }

    private static let table: [UInt32] = (0 ..< 256).map { n -> UInt32 in
        var c = UInt32(n)
        for _ in 0 ..< 8 { c = (c & 1) != 0 ? 0xEDB8_8320 ^ (c >> 1) : c >> 1 }
        return c
    }

    static func crc32<S: Sequence>(_ bytes: S, start: UInt32 = 0) -> UInt32 where S.Element == UInt8 {
        var c = ~start
        for b in bytes { c = table[Int((c ^ UInt32(b)) & 0xFF)] ^ (c >> 8) }
        return ~c
    }

    private static func chunks(_ source: Source, _ body: (Data) throws -> Void) throws {
        switch source {
        case let .data(d):
            try body(d)
        case let .file(url):
            let handle = try FileHandle(forReadingFrom: url)
            defer { try? handle.close() }
            while let piece = try handle.read(upToCount: 8 << 20), !piece.isEmpty { try body(piece) }
        }
    }

    /// Writes the entries, in order, to `url`, which must not exist yet. Returns the zip's size.
    @discardableResult
    static func write(_ entries: [(name: String, source: Source)], to url: URL, date: Date = Date()) throws -> Int {
        let fm = FileManager.default
        guard !fm.fileExists(atPath: url.path) else { throw Failure(description: "\(url.lastPathComponent) already exists") }
        guard fm.createFile(atPath: url.path, contents: nil) else { throw Failure(description: "\(url.lastPathComponent) can't be created") }
        let out = try FileHandle(forWritingTo: url)
        defer { try? out.close() }

        let c = Calendar(identifier: .gregorian).dateComponents(in: TimeZone.current, from: date)
        let hour: Int = c.hour ?? 0, minute: Int = c.minute ?? 0, second: Int = c.second ?? 0
        let year: Int = max((c.year ?? 1980) - 1980, 0), month: Int = c.month ?? 1, day: Int = c.day ?? 1
        let dosTime: Int = (hour << 11) | (minute << 5) | (second / 2)
        let dosDate: Int = (year << 9) | (month << 5) | day
        func le16(_ v: Int) -> [UInt8] { [UInt8(v & 0xFF), UInt8((v >> 8) & 0xFF)] }
        func le32(_ v: Int) -> [UInt8] { (0 ..< 4).map { UInt8((v >> (8 * $0)) & 0xFF) } }

        var central: [UInt8] = []
        var offset = 0
        for entry in entries {
            var crc: UInt32 = 0
            var size = 0
            try chunks(entry.source) { piece in
                crc = crc32(piece, start: crc)
                size += piece.count
            }
            guard size < Int(UInt32.max), offset < Int(UInt32.max) else { throw Failure(description: "\(entry.name) is too large for a zip") }
            let name = Array(entry.name.utf8)
            var common: [UInt8] = le16(20) + le16(0x0800) + le16(0) // version, UTF-8 names, stored
            common += le16(dosTime) + le16(dosDate)
            common += le32(Int(crc)) + le32(size) + le32(size) + le16(name.count) + le16(0)
            let local: [UInt8] = [0x50, 0x4B, 0x03, 0x04] + common + name
            try out.write(contentsOf: Data(local))
            try chunks(entry.source) { try out.write(contentsOf: $0) }
            var record: [UInt8] = [0x50, 0x4B, 0x01, 0x02] + le16(20) + common
            record += le16(0) + le16(0) + le16(0) + le32(0) + le32(offset) + name
            central += record
            offset += local.count + size
        }
        var end: [UInt8] = [0x50, 0x4B, 0x05, 0x06] + le16(0) + le16(0) + le16(entries.count) + le16(entries.count)
        end += le32(central.count) + le32(offset) + le16(0)
        try out.write(contentsOf: Data(central + end))
        return offset + central.count + end.count
    }

    /// The names of the entries in a zip this writer made (for the tests and the manifest).
    static func names(_ url: URL) throws -> [String] {
        let data = try Data(contentsOf: url)
        let b = [UInt8](data)
        guard b.count >= 22 else { return [] }
        func u16(_ i: Int) -> Int { Int(b[i]) | (Int(b[i + 1]) << 8) }
        func u32(_ i: Int) -> Int { u16(i) | (u16(i + 2) << 16) }
        let e = b.count - 22
        guard u32(e) == 0x0605_4B50 else { throw Failure(description: "not a zip this writer made") }
        var p = u32(e + 16), out: [String] = []
        for _ in 0 ..< u16(e + 10) {
            let n = u16(p + 28)
            out.append(String(decoding: b[p + 46 ..< p + 46 + n], as: UTF8.self))
            p += 46 + n + u16(p + 30) + u16(p + 32)
        }
        return out
    }

    /// One stored entry's bytes, read back.
    static func entry(_ name: String, in url: URL) throws -> Data {
        let b = [UInt8](try Data(contentsOf: url))
        func u16(_ i: Int) -> Int { Int(b[i]) | (Int(b[i + 1]) << 8) }
        func u32(_ i: Int) -> Int { u16(i) | (u16(i + 2) << 16) }
        var p = 0
        while p + 30 <= b.count, u32(p) == 0x0403_4B50 {
            let size = u32(p + 18), n = u16(p + 26), extra = u16(p + 28)
            let entryName = String(decoding: b[p + 30 ..< p + 30 + n], as: UTF8.self)
            let start = p + 30 + n + extra
            if entryName == name { return Data(b[start ..< start + size]) }
            p = start + size
        }
        throw Failure(description: "\(name) is not in \(url.lastPathComponent)")
    }
}
#endif
