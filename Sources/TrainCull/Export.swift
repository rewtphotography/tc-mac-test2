import CoreGraphics
import CoreImage
import Foundation
import ImageIO
import TraincullCore

/// The two exports: the JPEG the camera embedded in the raw, saved as it is, and the raw
/// developed with its edits as a 16-bit TIFF. Both are saved next to the raw, named after it,
/// and never replace a file that is already there.
enum Export {
    enum Kind {
        case jpeg, tiff

        var noun: String { self == .jpeg ? "JPEG" : "TIFF" }
    }

    struct Failure: Error, CustomStringConvertible {
        let description: String
        init(_ message: String) { description = message }
    }

    /// Writes a file under a free name in `folder`: to a hidden temporary file first, moved
    /// into place only when it is complete, so a crash never leaves half a picture behind.
    private static func save(in folder: URL, base: String, ext: String, _ write: (FileHandle) throws -> Void) throws -> URL {
        let fm = FileManager.default
        let temp = folder.appendingPathComponent(".\(base).\(ext).exporting")
        try? fm.removeItem(at: temp)
        guard fm.createFile(atPath: temp.path, contents: nil) else { throw Failure("the folder can't be written to") }
        do {
            let handle = try FileHandle(forWritingTo: temp)
            defer { try? handle.close() }
            try write(handle)
            try handle.synchronize()
        } catch {
            try? fm.removeItem(at: temp)
            throw error
        }
        // moveItem refuses to replace a file, so a name taken in the meantime means another try.
        for _ in 0 ..< 20 {
            let name = ExportNames.free(base: base, ext: ext) { fm.fileExists(atPath: folder.appendingPathComponent($0).path) }
            let final = folder.appendingPathComponent(name)
            if (try? fm.moveItem(at: temp, to: final)) != nil { return final }
        }
        try? fm.removeItem(at: temp)
        throw Failure("no free file name was found")
    }

    /// Saves the full-size JPEG embedded in a raw file. The picture data is copied byte for
    /// byte; a photo taken on its side gains a note saying which way up it goes.
    static func embeddedJpeg(_ url: URL, _ formats: Formats) throws -> URL {
        let src = try FileByteSource(url: url)
        try src.readHeader(Imaging.firstReadBytes)
        let info = try formats.parse(url.lastPathComponent, src)
        guard let ref = info.full else { throw Failure("there is no embedded JPEG") }
        let bytes = JpegTools.forSaving(try src.read(ref.offset, ref.length), orientation: info.orientation)
        return try save(in: url.deletingLastPathComponent(), base: url.deletingPathExtension().lastPathComponent, ext: "jpg") {
            try $0.write(contentsOf: Data(bytes))
        }
    }

    /// Develops a raw with Apple's decoder and the frame's edits and saves it as a 16-bit TIFF
    /// in ProPhoto RGB with ZIP compression.
    static func developedTiff(_ url: URL, _ values: [String: Float], shot: ShotInfo?, local: LocalRender? = nil) throws -> URL {
        guard let (image, extent) = Imaging.developed(url, values, local: local) else {
            throw Failure("Apple's raw decoder can't open this file on this Mac")
        }
        let folder = url.deletingLastPathComponent()
        return try save(in: folder, base: url.deletingPathExtension().lastPathComponent, ext: "tif") {
            try writeTiff(image, extent, to: $0, shot: shot)
        }
    }

    /// Saves a mask's pictures next to the raw, for looking at or sending on: the mask itself,
    /// the skin mask, the first-pass mask it started from and the three-way split.
    static func maskPictures(_ mask: MaskResult, for url: URL) throws -> [URL] {
        let folder = url.deletingLastPathComponent(), base = url.deletingPathExtension().lastPathComponent
        var saved: [URL] = []
        let pictures: [(String, CGImage?)] = [("mask", mask.alpha), ("skin", mask.skin), ("firstpass", mask.coarse), ("trimap", mask.trimap)]
        for (name, picture) in pictures {
            guard let picture = picture else { continue }
            let data = NSMutableData()
            guard let dest = CGImageDestinationCreateWithData(data, "public.png" as CFString, 1, nil) else { throw Failure("PNG files can't be written") }
            CGImageDestinationAddImage(dest, picture, nil)
            guard CGImageDestinationFinalize(dest) else { throw Failure("the \(name) picture couldn't be encoded") }
            saved.append(try save(in: folder, base: "\(base)-\(name)", ext: "png") { try $0.write(contentsOf: data as Data) })
        }
        return saved
    }

    /// Renders `image` to 16-bit ProPhoto RGB and writes it as a TIFF. The strips are
    /// compressed side by side on every processor core.
    static func writeTiff(_ image: CIImage, _ extent: CGRect, to handle: FileHandle, shot: ShotInfo?) throws {
        guard let space = CGColorSpace(name: CGColorSpace.rommrgb) else { throw Failure("ProPhoto RGB isn't available") }
        let start = CFAbsoluteTimeGetCurrent()
        guard let pixels = Imaging.ciContext.createCGImage(image, from: extent, format: .RGBA16, colorSpace: space) else {
            throw Failure("the photo couldn't be rendered")
        }
        let w = pixels.width, h = pixels.height, rowBytes = pixels.bytesPerRow
        guard pixels.bitsPerComponent == 16, pixels.bitsPerPixel == 64, w > 0, h > 0,
              let data = pixels.dataProvider?.data, let base = CFDataGetBytePtr(data),
              CFDataGetLength(data) >= (h - 1) * rowBytes + w * 8 else {
            throw Failure("the rendered photo isn't in the expected 16-bit form (\(pixels.bitsPerComponent) bits, \(pixels.bitsPerPixel) per pixel)")
        }
        // Core Graphics stores 16-bit samples big-endian unless the image says little-endian.
        let little = pixels.bitmapInfo.intersection(.byteOrderMask) == .byteOrder16Little
        let alpha = pixels.alphaInfo
        let firstSample = (alpha == .premultipliedFirst || alpha == .first || alpha == .noneSkipFirst) ? 1 : 0
        Log.note("export", "rendered \(w)×\(h) in \(Log.seconds(since: start)) (\(little ? "little" : "big")-endian, alpha \(alpha.rawValue))")
        MemoryMonitor.mark("rendering 16-bit pixels for a TIFF")

        let rows = TiffWriter.rowsPerStrip(width: w, height: h)
        let count = (h + rows - 1) / rows
        var strips = [[UInt8]](repeating: [], count: count)
        let packing = CFAbsoluteTimeGetCurrent()
        strips.withUnsafeMutableBufferPointer { buffer in
            let out = buffer // each strip writes only its own element
            DispatchQueue.concurrentPerform(iterations: count) { i in
                let y = i * rows, n = min(rows, h - y)
                let source = UnsafeRawBufferPointer(start: base + y * rowBytes, count: (n - 1) * rowBytes + w * 8)
                let raw = TiffWriter.strip(source, rowBytes: rowBytes, rows: n, width: w, samplesPerPixel: 4,
                                           firstSample: firstSample, littleEndian: little)
                let deflated: [UInt8]
                if let packed = try? (Data(raw) as NSData).compressed(using: .zlib) {
                    deflated = [UInt8](packed as Data)
                } else {
                    deflated = TiffWriter.storedDeflate(raw)
                }
                out[i] = TiffWriter.zlibStream(deflated: deflated, adler: TiffWriter.adler32(raw))
            }
        }
        let icc = space.copyICCData().map { [UInt8]($0 as Data) }
        let meta = TiffMeta(software: appVersion, shot: shot, icc: icc)
        let sizes = strips.map { $0.count }
        try handle.write(contentsOf: Data(TiffWriter.head(width: w, height: h, rowsPerStrip: rows, stripSizes: sizes, meta: meta)))
        for strip in strips { try handle.write(contentsOf: Data(strip)) }
        Log.note("export", "compressed \(count) strips to \(MemoryStats.plain(UInt64(sizes.reduce(0, +)))) in \(Log.seconds(since: packing))")
        MemoryMonitor.mark("writing a TIFF")
    }
}
