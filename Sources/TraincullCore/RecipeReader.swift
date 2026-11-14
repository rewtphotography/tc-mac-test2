import Foundation

/// An embedded JPEG inside the raw file.
public final class JpegRef {
    public let offset: Int64
    public let length: Int
    public let ifdIndex: Int

    public init(offset: Int64, length: Int, ifdIndex: Int) {
        self.offset = offset
        self.length = length
        self.ifdIndex = ifdIndex
    }
}

/// The camera's recorded focus point, in stored (sensor-orientation) coordinates of a frame
/// `frameWidth`×`frameHeight`.
public struct FocusPoint: Equatable {
    public let frameWidth: Int
    public let frameHeight: Int
    public let x: Int
    public let y: Int
}

/// What a recipe found in one raw file.
public struct RawInfo {
    /// EXIF orientation (1 = normal, 6 = rotate 90 CW, 8 = rotate 270 CW, 3 = 180).
    public let orientation: Int
    public let jpegs: [JpegRef]
    public let focus: FocusPoint?
    /// Camera settings from the file's EXIF (focal length, aperture, shutter, ISO, camera).
    public var shot: ShotInfo?

    /// Largest embedded JPEG: the full-size image.
    public var full: JpegRef? { jpegs.max { $0.length < $1.length } }

    /// Grid source: the largest JPEG smaller than `full`. The loader falls back to `full` if
    /// this turns out too small.
    public var preview: JpegRef? {
        let f = full
        return jpegs.filter { $0 !== f }.max { $0.length < $1.length } ?? f
    }

    /// Clockwise rotation needed to display the stored (sensor-oriented) image upright.
    public var rotationDegrees: Int {
        switch orientation {
        case 3: return 180
        case 6: return 90
        case 8: return 270
        default: return 0
        }
    }
}

/// Follows a `Recipe` through one raw file: finds the embedded JPEGs, the orientation and the
/// focus point. Only reads; never touches anything but the bytes the recipe points to.
public enum RecipeReader {
    public static func read(_ recipe: Recipe, _ src: ByteSource) throws -> RawInfo {
        switch recipe.structure {
        case .tiff: return try tiff(recipe, src)
        case .header: return try header(recipe, src)
        }
    }

    // MARK: TIFF structure

    private static func tiff(_ recipe: Recipe, _ src: ByteSource) throws -> RawInfo {
        let tiff = try Tiff(src)
        let maxChain = recipe.tiffPreviews.map { $0.maxIfds }.max() ?? 8
        var chain: [Ifd] = []
        var offset = tiff.firstIfdOffset
        var seen = Set<Int64>()
        while offset != 0 && chain.count < maxChain && seen.insert(offset).inserted {
            let ifd: Ifd
            do {
                ifd = try tiff.readIfd(offset)
            } catch {
                if chain.isEmpty { throw error } else { break } // a broken link late in the chain keeps what was found
            }
            chain.append(ifd)
            offset = ifd.nextOffset
        }
        if chain.isEmpty { throw TiffError("no IFD found") }
        let ifd0 = chain[0]

        var jpegs: [JpegRef] = []
        var found = Set<Int64>()
        for p in recipe.tiffPreviews {
            var sources: [(Int, Ifd)] = []
            if !p.fromSubIfds {
                sources = Array(chain.prefix(p.maxIfds).enumerated().map { ($0.offset, $0.element) })
            } else {
                for ifd in chain {
                    guard let e = ifd.entries[p.subIfdTag] else { continue }
                    for o in tiff.values(e) {
                        if sources.count >= p.maxIfds { break }
                        if let sub = try? tiff.readIfd(o) { sources.append((100 + sources.count, sub)) }
                    }
                }
            }
            for (index, ifd) in sources {
                if let requireTag = p.requireTag {
                    guard let v = tiff.value(ifd, requireTag) else { continue }
                    if !p.requireValues.isEmpty && !p.requireValues.contains(v) { continue }
                }
                let start = tiff.value(ifd, p.offsetTag)
                let length = tiff.value(ifd, p.lengthTag)
                if let start = start, let length = length, start > 0, length > 2,
                   length < Int64(Int32.max), start + length <= src.size, found.insert(start).inserted {
                    jpegs.append(JpegRef(offset: start, length: Int(length), ifdIndex: index))
                }
            }
        }
        if jpegs.isEmpty { throw TiffError("no embedded JPEG found") }
        let largest = jpegs.max { $0.length < $1.length }!

        let orientation: Int
        switch recipe.orientation {
        case let .tag(tag): orientation = tiff.value(ifd0, tag).map { Int($0) } ?? 1
        case .embeddedJpeg: orientation = jpegOrientation(src, largest)
        case .none: orientation = 1
        }
        // The focus point is optional; never fail the frame over it.
        let focusPoint = recipe.focus.flatMap { f in try? focus(f, tiff, src, ifd0) }
        let shot = ShotInfo.fromTiff(tiff, ifd0) ?? jpegExif(src, largest).flatMap { ShotInfo.fromTiff($0.0, $0.1) }
        return RawInfo(orientation: (1 ... 8).contains(orientation) ? orientation : 1, jpegs: jpegs, focus: focusPoint, shot: shot)
    }

    /// IFD0 → Exif IFD → maker note → focus tag.
    private static func focus(_ f: Recipe.FocusRule, _ tiff: Tiff, _ src: ByteSource, _ ifd0: Ifd) throws -> FocusPoint? {
        guard let exifOffset = tiff.value(ifd0, f.exifTag) else { return nil }
        let exif = try tiff.readIfd(exifOffset)
        guard let note = exif.entries[f.makerNoteTag] else { return nil }
        if note.count < 14 { return nil }
        var skip = f.skip
        if let prefix = f.prefix, f.skip > 0 {
            let head = try src.read(note.valuePos, min(prefix.utf16.count, 32))
            skip = latin1(head) == prefix ? f.skip : 0 // some models omit the header
        }
        let ifd: Ifd
        let reader: Tiff
        switch f.offsets {
        case .file:
            reader = tiff
            ifd = try tiff.readIfd(note.valuePos + Int64(skip))
        case .makernote:
            reader = try Tiff(SubByteSource(src, note.valuePos), forcedLittleEndian: tiff.littleEndian)
            ifd = try reader.readIfd(Int64(skip))
        case .embeddedTiff:
            reader = try Tiff(SubByteSource(src, note.valuePos + Int64(skip)))
            ifd = try reader.readIfd(reader.firstIfdOffset)
        }
        guard let e = ifd.entries[f.tag] else { return nil }
        let v = reader.values(e)
        if v.count < f.values.count { return nil }
        func pick(_ name: String) -> Int? { f.values.firstIndex(of: name).map { Int(v[$0]) } }
        let w = pick("width") ?? f.frameWidth
        let h = pick("height") ?? f.frameHeight
        guard let x = pick("x"), let y = pick("y") else { return nil }
        if w <= 0 || h <= 0 || !(0 ..< w).contains(x) || !(0 ..< h).contains(y) { return nil }
        return FocusPoint(frameWidth: w, frameHeight: h, x: x, y: y)
    }

    // MARK: Fixed-header structure

    private static func header(_ recipe: Recipe, _ src: ByteSource) throws -> RawInfo {
        if let m = recipe.magic {
            let b = try? src.read(0, m.utf16.count)
            if b.map(latin1) != m { throw TiffError("not a \(recipe.name) file (no \"\(m)\" at the start)") }
        }
        var jpegs: [JpegRef] = []
        for (i, p) in recipe.headerPreviews.enumerated() {
            let start = try u32(src, p.offsetAt, recipe.bigEndian)
            let length = try u32(src, p.lengthAt, recipe.bigEndian)
            if start > 0 && length > 2 && length < Int64(Int32.max) && start + length <= src.size {
                jpegs.append(JpegRef(offset: start, length: Int(length), ifdIndex: i))
            }
        }
        if jpegs.isEmpty { throw TiffError("no embedded JPEG found") }
        var orientation = 1
        if recipe.orientation == .embeddedJpeg {
            orientation = jpegOrientation(src, jpegs.max { $0.length < $1.length }!)
        }
        let shot = jpegExif(src, jpegs.max { $0.length < $1.length }!).flatMap { ShotInfo.fromTiff($0.0, $0.1) }
        return RawInfo(orientation: (1 ... 8).contains(orientation) ? orientation : 1, jpegs: jpegs, focus: nil, shot: shot)
    }

    private static func u32(_ src: ByteSource, _ at: Int64, _ big: Bool) throws -> Int64 {
        let b = try src.read(at, 4).map { Int64($0) }
        return big ? (b[0] << 24) | (b[1] << 16) | (b[2] << 8) | b[3]
            : (b[3] << 24) | (b[2] << 16) | (b[1] << 8) | b[0]
    }

    /// EXIF orientation from the APP1 segment at the start of an embedded JPEG; 1 if there is none.
    public static func jpegOrientation(_ src: ByteSource, _ ref: JpegRef) -> Int {
        guard let (t, ifd0) = jpegExif(src, ref), let v = t.value(ifd0, 0x0112) else { return 1 }
        return Int(v)
    }

    /// The EXIF (TIFF) block inside an embedded JPEG's APP1 segment and its IFD0, or nil.
    public static func jpegExif(_ src: ByteSource, _ ref: JpegRef) -> (Tiff, Ifd)? {
        let n = min(ref.length, 64 * 1024)
        guard let b = try? src.read(ref.offset, n) else { return nil }
        if n < 4 || b[0] != 0xFF || b[1] != 0xD8 { return nil }
        var i = 2
        while i + 4 <= n && b[i] == 0xFF {
            let marker = Int(b[i + 1])
            let len = (Int(b[i + 2]) << 8) | Int(b[i + 3])
            if marker == 0xE1 && i + 10 <= n && latin1(Array(b[i + 4 ..< i + 8])) == "Exif" {
                guard let t = try? Tiff(SubByteSource(src, ref.offset + Int64(i) + 10)),
                      let ifd = try? t.readIfd(t.firstIfdOffset) else { return nil }
                return (t, ifd)
            }
            if marker == 0xDA { break } // image data starts; no EXIF before it
            i += 2 + len
        }
        return nil
    }
}

/// The raw formats TrainCull reads: the built-in recipes plus imported ones. The file whitelist
/// follows this list: only these extensions are ever opened.
public final class Formats {
    public private(set) var recipes: [Recipe] = BuiltInRecipes.all

    public init() {}

    /// Replaces the imported recipes. A recipe whose id or extension is already taken is skipped and reported.
    @discardableResult
    public func setImported(_ imported: [Recipe]) -> [String] {
        var out = BuiltInRecipes.all
        var problems: [String] = []
        for r in imported {
            if let clash = out.first(where: { o in o.id == r.id || o.extensions.contains { r.extensions.contains($0) } }) {
                problems.append("\(r.name): clashes with \(clash.name)")
            } else {
                out.append(r)
            }
        }
        recipes = out
        return problems
    }

    private static func ext(_ name: String) -> String? {
        guard let dot = name.lastIndex(of: "."), dot != name.startIndex, name.index(after: dot) != name.endIndex else { return nil }
        return name[name.index(after: dot)...].lowercased()
    }

    public func forName(_ fileName: String) -> Recipe? {
        guard let e = Formats.ext(fileName) else { return nil }
        return recipes.first { $0.extensions.contains(e) }
    }

    /// Hidden files (e.g. "._DSC0001.ARW" left by macOS) are never photos.
    public func isRaw(_ name: String) -> Bool { !name.hasPrefix(".") && forName(name) != nil }

    /// Bytes to read at once before parsing: enough for every enabled recipe.
    public var headerBytes: Int { recipes.map { $0.headerBytes }.max() ?? 65536 }

    public func parse(_ fileName: String, _ src: ByteSource) throws -> RawInfo {
        guard let r = forName(fileName) else { throw TiffError("no recipe for \(fileName)") }
        return try RecipeReader.read(r, src)
    }
}
