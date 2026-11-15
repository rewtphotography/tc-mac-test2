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

    /// The pictures the large image draws must be finished pixels, not a recipe Core Image
    /// works out when they are first drawn. The timings are printed for the build log.
    func testRenderedPicturesAreFinishedPixels() throws {
        let w = 3000, h = 2000
        let rect = CGRect(x: 0, y: 0, width: w, height: h)
        let image = quarters(CGFloat(w), CGFloat(h)).applyingFilter("CIGaussianBlur", parameters: [kCIInputRadiusKey: 30]).cropped(to: rect)
        let space = try XCTUnwrap(CGColorSpace(name: CGColorSpace.displayP3))
        func seconds(_ work: () -> Void) -> String {
            let start = CFAbsoluteTimeGetCurrent()
            work()
            return String(format: "%.3f s", CFAbsoluteTimeGetCurrent() - start)
        }
        var plain: CGImage?
        let created = seconds { plain = Imaging.ciContext.createCGImage(image, from: rect, format: .RGBA8, colorSpace: space) }
        let read = seconds { _ = plain?.dataProvider?.data }
        var ours: CGImage?
        let made = seconds { ours = Imaging.pixels(image, from: rect) }
        let reread = seconds { _ = ours?.dataProvider?.data }
        print("RENDER-CHECK createCGImage alone: \(created), then first read of its pixels: \(read)")
        print("RENDER-CHECK Imaging.pixels: \(made), then read of its pixels: \(reread)")

        let picture = try XCTUnwrap(ours)
        XCTAssertEqual(picture.width, w)
        XCTAssertEqual(picture.height, h)
        XCTAssertEqual(picture.alphaInfo, .noneSkipLast)
        let data = try XCTUnwrap(picture.dataProvider?.data)
        XCTAssertGreaterThanOrEqual(CFDataGetLength(data), picture.bytesPerRow * h)
        // The same pixels as the picture Core Image hands back: top-left of the red quarter.
        let bytes = try XCTUnwrap(CFDataGetBytePtr(data))
        let reference = try XCTUnwrap(plain?.dataProvider?.data)
        let expected = try XCTUnwrap(CFDataGetBytePtr(reference))
        let p = (h / 4) * picture.bytesPerRow + (w / 4) * 4
        for channel in 0 ..< 3 { XCTAssertEqual(bytes[p + channel], expected[p + channel]) }
        XCTAssertGreaterThan(bytes[p], bytes[p + 2]) // red, not blue
    }

    // MARK: Masks

    /// A flat picture as 8-bit pixels, the form a raw render has.
    private func flat(_ w: Int, _ h: Int, _ paint: (Int, Int) -> (UInt8, UInt8, UInt8)) throws -> CGImage {
        var bytes = [UInt8](repeating: 255, count: w * h * 4)
        for y in 0 ..< h {
            for x in 0 ..< w {
                let c = paint(x, y)
                bytes[(y * w + x) * 4] = c.0; bytes[(y * w + x) * 4 + 1] = c.1; bytes[(y * w + x) * 4 + 2] = c.2
            }
        }
        return try XCTUnwrap(Masking.picture(rgbx: bytes, w: w, h: h))
    }

    private func bytes(of image: CGImage) throws -> (UnsafePointer<UInt8>, CFData) {
        let data = try XCTUnwrap(image.dataProvider?.data)
        return (try XCTUnwrap(CFDataGetBytePtr(data)), data)
    }

    /// Colours blend channel by channel through the mask, and a local adjustment changes its
    /// own area and nothing else. Also proves the small blending programs load on this macOS.
    func testLocalAdjustmentChangesOnlyItsArea() throws {
        XCTAssertTrue(Masking.blendsByChannel, "the per-channel blending program didn't load")
        let w = 64, h = 32
        // The mask: subject on the left half; in the right half the subject owns all of the red
        // light, none of the green and half of the blue.
        var shares = [UInt8](repeating: 255, count: w * h * 4), alpha = [UInt8](repeating: 0, count: w * h)
        for y in 0 ..< h {
            for x in 0 ..< w {
                let left = x < w / 2
                alpha[y * w + x] = left ? 255 : 128
                shares[(y * w + x) * 4] = 255
                shares[(y * w + x) * 4 + 1] = left ? 255 : 0
                shares[(y * w + x) * 4 + 2] = left ? 255 : 128
            }
        }
        let mask = MaskResult(width: w, height: h, alpha: try XCTUnwrap(Masking.picture(gray: alpha, w: w, h: h)),
                              shares: try XCTUnwrap(Masking.picture(rgbx: shares, w: w, h: h)), skin: nil,
                              trimap: try XCTUnwrap(Masking.picture(gray: alpha, w: w, h: h)),
                              coarse: try XCTUnwrap(Masking.picture(gray: alpha, w: w, h: h)), tier: .fast, summary: "")
        let extent = CGRect(x: 0, y: 0, width: w, height: h)
        let grey = CIImage(color: CIColor(red: 0.5, green: 0.5, blue: 0.5)).cropped(to: extent)
        let before = try XCTUnwrap(Imaging.pixels(grey, from: extent))
        var edits = LocalEdits()
        edits.layers[LocalArea.subject.rawValue].exposure = 1 // the subject one stop brighter
        let lit = Masking.apply(LocalRender(mask: mask, edits: edits, view: .photo, area: .subject), to: grey, extent: extent)
        let after = try XCTUnwrap(Imaging.pixels(lit, from: extent))
        let (b, keepB) = try bytes(of: before), (a, keepA) = try bytes(of: after)
        _ = (keepB, keepA)
        let leftPixel = (h / 2) * after.bytesPerRow + (w / 4) * 4, rightPixel = (h / 2) * after.bytesPerRow + (3 * w / 4) * 4
        // Left: all of it brighter. Right: red fully brighter, green untouched, blue in between.
        XCTAssertGreaterThan(Int(a[leftPixel + 1]), Int(b[leftPixel + 1]) + 20)
        XCTAssertEqual(Int(a[rightPixel]), Int(a[leftPixel]), accuracy: 2)
        XCTAssertEqual(Int(a[rightPixel + 1]), Int(b[rightPixel + 1]), accuracy: 2)
        XCTAssertGreaterThan(Int(a[rightPixel + 2]), Int(b[rightPixel + 2]) + 8)
        XCTAssertLessThan(Int(a[rightPixel + 2]), Int(a[leftPixel + 2]) - 8)

        // The views of the mask render too, the right way up: the mask itself is white on the left.
        for view in MaskView.allCases {
            let shown = Masking.apply(LocalRender(mask: mask, edits: LocalEdits(), view: view, area: .subject), to: grey, extent: extent)
            let picture = try XCTUnwrap(Imaging.pixels(shown, from: extent), "\(view.name) view")
            if view == .mask {
                let (m, keep) = try bytes(of: picture)
                _ = keep
                XCTAssertGreaterThan(m[leftPixel], 240)
                XCTAssertEqual(Int(m[rightPixel]), 128, accuracy: 6)
            }
        }
    }

    /// The whole mask pipeline on a made-up picture, without Vision: a dark shape in the top
    /// left of a light picture, a rough mask of it, and out comes a mask the right way up.
    func testMaskPipelineKeepsThePictureTheRightWayUp() throws {
        let w = 400, h = 300
        func inside(_ x: Int, _ y: Int) -> Bool { (x - 110) * (x - 110) + (y - 90) * (y - 90) < 60 * 60 }
        let picture = try flat(w, h) { x, y in inside(x, y) ? (40, 30, 25) : (190, 200, 215) }
        var rough = Gray(w: w / 4, h: h / 4)
        for y in 0 ..< h / 4 { for x in 0 ..< w / 4 { rough.v[y * (w / 4) + x] = inside(x * 4 + 2, y * 4 + 2) ? 1 : 0 } }
        rough = rough.blurred(radius: 3)
        for tier in MatteTier.allCases {
            let mask = try Masking.make(reference: picture, name: "test", tier: tier, faces: DetectedFaces(subjects: [], imageWidth: Double(w)),
                                        coarse: rough, progress: { _ in }, cancelled: { false })
            XCTAssertEqual(mask.width, w)
            let (a, keep) = try bytes(of: mask.alpha)
            _ = keep
            XCTAssertEqual(a[90 * mask.alpha.bytesPerRow + 110], 255, "\(tier.name): the middle of the shape")
            XCTAssertEqual(a[250 * mask.alpha.bytesPerRow + 330], 0, "\(tier.name): far from it")
            // The edge of the shape is where the photo says it is, not where the rough mask put it.
            XCTAssertGreaterThan(a[90 * mask.alpha.bytesPerRow + 110 + 55], 200, "\(tier.name): just inside the edge")
            XCTAssertLessThan(a[90 * mask.alpha.bytesPerRow + 110 + 65], 55, "\(tier.name): just outside the edge")
            print("MASK-CHECK \(mask.summary)")
        }
    }

    /// Apple's first-pass masks run here without failing. A made-up picture has no person in
    /// it, so what they return is only reported.
    func testVisionMasksRun() throws {
        let picture = try flat(640, 480) { x, y in (x - 320) * (x - 320) + (y - 240) * (y - 240) < 150 * 150 ? (200, 150, 120) : (60, 80, 110) }
        let people = Masking.personMask(picture)
        let subject = Masking.subjectMask(picture)
        let features = Masking.featureExclusion(picture)
        print("VISION-CHECK people: \(people.map { "\($0.w)×\($0.h)" } ?? "none"), subject: \(subject.map { "\($0.w)×\($0.h)" } ?? "none"), features: \(features == nil ? "none" : "found")")
        if let people = people { XCTAssertEqual(Double(people.w) / Double(people.h), 640.0 / 480.0, accuracy: 0.05) }
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
