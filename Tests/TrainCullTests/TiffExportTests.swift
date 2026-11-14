#if os(macOS)
import CoreImage
import ImageIO
@testable import TrainCull
import TraincullCore
import XCTest

/// The TIFF export, end to end on a Mac: a picture with known colours goes through the same
/// rendering and writing code an exported raw does, and the file is then opened with Apple's
/// own TIFF reader. This catches a wrong byte order, wrong channel order, upside-down rows, a
/// bad strip or a broken colour profile, none of which the Linux tests can see.
final class TiffExportTests: XCTestCase {
    /// One flat colour in each quarter. Core Image counts y upwards, so the first two are the top row.
    private let colours: [[CGFloat]] = [[0.8, 0.2, 0.1], [0.1, 0.7, 0.2], [0.2, 0.3, 0.9], [0.9, 0.9, 0.5]]

    private func quarters(_ w: CGFloat, _ h: CGFloat) -> CIImage {
        let rects = [CGRect(x: 0, y: h / 2, width: w / 2, height: h / 2), CGRect(x: w / 2, y: h / 2, width: w / 2, height: h / 2),
                     CGRect(x: 0, y: 0, width: w / 2, height: h / 2), CGRect(x: w / 2, y: 0, width: w / 2, height: h / 2)]
        var image = CIImage.empty()
        for (c, rect) in zip(colours, rects) {
            image = CIImage(color: CIColor(red: c[0], green: c[1], blue: c[2])).cropped(to: rect).composited(over: image)
        }
        return image
    }

    func testExportedTiffOpensInApplesReaderWithTheRightPixels() throws {
        let w = 2000, h = 1000 // wide enough to need several strips
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("traincull-test-\(UUID().uuidString).tif")
        defer { try? FileManager.default.removeItem(at: url) }
        XCTAssertTrue(FileManager.default.createFile(atPath: url.path, contents: nil))
        let handle = try FileHandle(forWritingTo: url)
        var shot = ShotInfo(focalMm: 85, fNumber: 1.6, exposureS: 1 / 125.0, iso: 100, model: "ILCE-7M4")
        shot.make = "SONY"
        try Export.writeTiff(quarters(CGFloat(w), CGFloat(h)), CGRect(x: 0, y: 0, width: w, height: h), to: handle, shot: shot)
        try handle.close()

        // Our own reader: ZIP, several strips, a colour profile, smaller than the bare pixels.
        let bytes = [UInt8](try Data(contentsOf: url))
        let tiff = try Tiff(ArrayByteSource(bytes))
        let ifd = try tiff.readIfd(tiff.firstIfdOffset)
        XCTAssertEqual(tiff.value(ifd, 0x103), 8)
        XCTAssertGreaterThan(tiff.values(ifd.entries[0x111]!).count, 1)
        XCTAssertGreaterThan(try XCTUnwrap(ifd.entries[0x8773]).count, 100)
        XCTAssertLessThan(bytes.count, w * h * 6 / 10)

        // Apple's reader.
        let source = try XCTUnwrap(CGImageSourceCreateWithURL(url as CFURL, nil))
        let props = try XCTUnwrap(CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any])
        XCTAssertEqual(props[kCGImagePropertyPixelWidth] as? Int, w)
        XCTAssertEqual(props[kCGImagePropertyPixelHeight] as? Int, h)
        XCTAssertEqual(props[kCGImagePropertyDepth] as? Int, 16)
        let tiffProps = props[kCGImagePropertyTIFFDictionary] as? [CFString: Any]
        XCTAssertEqual(tiffProps?[kCGImagePropertyTIFFModel] as? String, "ILCE-7M4")
        let decoded = try XCTUnwrap(CGImageSourceCreateImageAtIndex(source, 0, nil))
        XCTAssertEqual(decoded.bitsPerComponent, 16)
        XCTAssertNotNil(decoded.colorSpace)

        // Drawn into plain 8-bit sRGB, the middle of each quarter has the colour it started with.
        let srgb = try XCTUnwrap(CGColorSpace(name: CGColorSpace.sRGB))
        let ctx = try XCTUnwrap(CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                                          space: srgb, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue))
        ctx.draw(decoded, in: CGRect(x: 0, y: 0, width: w, height: h))
        let data = try XCTUnwrap(ctx.data).assumingMemoryBound(to: UInt8.self)
        // The first row in memory is the top of the picture.
        let middles = [(w / 4, h / 4), (3 * w / 4, h / 4), (w / 4, 3 * h / 4), (3 * w / 4, 3 * h / 4)]
        for (c, (x, y)) in zip(colours, middles) {
            let p = (y * w + x) * 4
            for channel in 0 ..< 3 {
                XCTAssertEqual(Double(data[p + channel]), Double(c[channel]) * 255, accuracy: 4,
                               "channel \(channel) at \(x),\(y) of the quarter coloured \(c)")
            }
        }
    }
}
#endif
