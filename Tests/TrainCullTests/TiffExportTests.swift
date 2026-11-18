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

    /// Spec v7, test (f): in Photo view with no adjustments the rendered image is the photo,
    /// pixel for pixel, whatever the mask's colour shares: the same with edge colour from
    /// inside on and off (whose shares differ), and the same as the photo drawn alone. (In the
    /// app that view doesn't even hand the mask to the render; this checks the blend itself.)
    func testPhotoViewIsTheSameWhateverTheShares() throws {
        let w = 200, h = 200
        func distance(_ x: Int, _ y: Int) -> Double { ((Double(x) - 100) * (Double(x) - 100) + (Double(y) - 100) * (Double(y) - 100)).squareRoot() }
        // 7451's black sleeve with its teal fringe, on white.
        let picture = try flat(w, h) { x, y in
            let r = distance(x, y)
            if r > 58.6 && r <= 59.6 { return (0, 32, 28) }
            return r < 60 ? (29, 26, 25) : (247, 247, 247)
        }
        let photo = try XCTUnwrap(Masking.photo(from: picture))
        var rough = Gray(w: w, h: h)
        for y in 0 ..< h { for x in 0 ..< w { rough.v[y * w + x] = min(max(Float(60.5 - distance(x, y)), 0), 1) } }
        rough = rough.blurred(radius: 2)
        func mask(_ settings: MatteSettings) throws -> (MaskResult, Data) {
            let out = Matte(photo: photo, coarse: rough, faces: [PixelRect(x: 2, y: 2, w: 8, h: 8)], settings: settings).run(tier: .off)
            let alpha = try XCTUnwrap(Masking.picture(gray: out.alpha, w: w, h: h))
            let made = MaskResult(width: w, height: h, alpha: alpha, shares: try XCTUnwrap(Masking.picture(rgbx: out.shares, w: w, h: h)), skin: nil,
                                  trimap: alpha, coarse: alpha, tier: .off, summary: "")
            return (made, Data(out.shares))
        }
        var on = MatteSettings()
        on.insideColour = true
        let (plain, plainShares) = try mask(MatteSettings())
        let (inside, insideShares) = try mask(on)
        XCTAssertNotEqual(plainShares, insideShares, "edge colour from inside changed the shares")
        let extent = CGRect(x: 0, y: 0, width: w, height: h)
        let source = CIImage(cgImage: picture)
        let alone = try XCTUnwrap(Imaging.pixels(source, from: extent))
        let aloneData = try XCTUnwrap(alone.dataProvider?.data) as Data
        for (name, m) in [("switch off", plain), ("edge colour from inside", inside)] {
            let shown = Masking.apply(LocalRender(mask: m, edits: LocalEdits(), view: .photo, area: .subject), to: source, extent: extent)
            let picture = try XCTUnwrap(Imaging.pixels(shown, from: extent))
            let data = try XCTUnwrap(picture.dataProvider?.data) as Data
            XCTAssertEqual(data, aloneData, "\(name): Photo view with no adjustments is the photo, pixel for pixel")
        }
        print("PHOTO-VIEW-CHECK: identical with the switch off and on (\(aloneData.count) bytes each); shares differ in "
            + "\(zip(plainShares, insideShares).filter { $0 != $1 }.count) bytes")
    }

    /// Colours blend channel by channel through the mask, and a local adjustment changes its
    /// own area and nothing else. Also proves the small blending programs load on this macOS.
    func testLocalAdjustmentChangesOnlyItsArea() throws {
        XCTAssertTrue(Masking.blendsByChannel, "the per-channel blending program didn't load")
        let w = 96, h = 32
        // Three bands. Left: all subject. Middle: the subject owns all of the red light and
        // none of the green or blue. Right: half of everything.
        var shares = [UInt8](repeating: 255, count: w * h * 4), alpha = [UInt8](repeating: 0, count: w * h)
        for y in 0 ..< h {
            for x in 0 ..< w {
                let band = x * 3 / w
                alpha[y * w + x] = band == 0 ? 255 : 128
                shares[(y * w + x) * 4] = band == 2 ? 128 : 255
                shares[(y * w + x) * 4 + 1] = band == 0 ? 255 : (band == 1 ? 0 : 128)
                shares[(y * w + x) * 4 + 2] = band == 0 ? 255 : (band == 1 ? 0 : 128)
            }
        }
        let mask = MaskResult(width: w, height: h, alpha: try XCTUnwrap(Masking.picture(gray: alpha, w: w, h: h)),
                              shares: try XCTUnwrap(Masking.picture(rgbx: shares, w: w, h: h)), skin: nil,
                              trimap: try XCTUnwrap(Masking.picture(gray: alpha, w: w, h: h)),
                              coarse: try XCTUnwrap(Masking.picture(gray: alpha, w: w, h: h)), tier: .fast, summary: "")
        let extent = CGRect(x: 0, y: 0, width: w, height: h)
        let linear = try XCTUnwrap(CGColorSpace(name: CGColorSpace.extendedLinearSRGB))
        func plain(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat) throws -> CIImage {
            CIImage(color: try XCTUnwrap(CIColor(red: r, green: g, blue: b, colorSpace: linear))).cropped(to: extent)
        }
        // A mid grey, in linear light, and the same one stop brighter.
        let v: CGFloat = 0.2
        var edits = LocalEdits()
        edits.layers[LocalArea.subject.rawValue].exposure = 1
        let lit = Masking.apply(LocalRender(mask: mask, edits: edits, view: .photo, area: .subject), to: try plain(v, v, v), extent: extent)
        let after = try XCTUnwrap(Imaging.pixels(lit, from: extent))
        let (a, keepA) = try bytes(of: after)
        _ = keepA
        // What each band should be, rendered the same way so the comparison is like for like.
        let wanted = [try plain(2 * v, 2 * v, 2 * v), try plain(2 * v, v, v), try plain(1.5 * v, 1.5 * v, 1.5 * v)]
        for (band, image) in wanted.enumerated() {
            let reference = try XCTUnwrap(Imaging.pixels(image, from: extent))
            let (r, keep) = try bytes(of: reference)
            _ = keep
            let p = (h / 2) * after.bytesPerRow + (band * w / 3 + w / 6) * 4
            for channel in 0 ..< 3 {
                XCTAssertEqual(Int(a[p + channel]), Int(r[p + channel]), accuracy: 2, "band \(band), channel \(channel)")
            }
        }

        // The views of the mask render too. The mask itself shows its numbers as they are:
        // white where the subject is, mid grey where it is half.
        for view in MaskView.allCases {
            let shown = Masking.apply(LocalRender(mask: mask, edits: LocalEdits(), view: view, area: .subject), to: try plain(v, v, v), extent: extent)
            let picture = try XCTUnwrap(Imaging.pixels(shown, from: extent), "\(view.name) view")
            if view == .mask {
                let (m, keep) = try bytes(of: picture)
                _ = keep
                XCTAssertGreaterThan(m[(h / 2) * picture.bytesPerRow + (w / 6) * 4], 240)
                XCTAssertEqual(Int(m[(h / 2) * picture.bytesPerRow + (5 * w / 6) * 4]), 128, accuracy: 6)
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
        // About as soft as a model's edge is once enlarged.
        rough = rough.blurred(radius: 1)
        for tier in MatteTier.allCases {
            let mask = try Masking.make(reference: picture, name: "test", tier: tier, faces: DetectedFaces(subjects: [], imageWidth: Double(w)),
                                        coarse: rough, progress: { _ in }, cancelled: { false })
            XCTAssertEqual(mask.width, w)
            let (a, keep) = try bytes(of: mask.alpha)
            _ = keep
            XCTAssertEqual(a[90 * mask.alpha.bytesPerRow + 110], 255, "\(tier.name): the middle of the shape")
            XCTAssertEqual(a[250 * mask.alpha.bytesPerRow + 330], 0, "\(tier.name): far from it")
            // The edge of the shape is where the photo says it is, not where the rough mask put it.
            // Off only snaps the rough mask's own edge, so it is allowed to be a little softer here.
            let inside: UInt8 = tier == .off ? 170 : 200, outside: UInt8 = tier == .off ? 85 : 55
            XCTAssertGreaterThan(a[90 * mask.alpha.bytesPerRow + 110 + 55], inside, "\(tier.name): just inside the edge")
            XCTAssertLessThan(a[90 * mask.alpha.bytesPerRow + 110 + 65], outside, "\(tier.name): just outside the edge")
            XCTAssertEqual(mask.tier, tier)
            XCTAssertNotNil(mask.debug, "\(tier.name): the debug overlay")
            print("MASK-CHECK \(mask.summary) · \(mask.edge.summary)")
        }
    }

    /// Choosing the subject and measuring a job both run on a Mac: the sharper of two made-up
    /// "faces" ranks first, and a measured job reports its memory and processor use.
    func testSubjectRankingAndJobMeasurement() throws {
        // Crisp stripes on the left, the same stripes smeared on the right.
        let picture = try flat(480, 240) { x, _ in
            if x < 240 { return (x / 6) % 2 == 0 ? (30, 30, 30) : (220, 220, 220) }
            let t = 0.5 + 0.5 * sin(Double(x) / 12 * Double.pi)
            let v = UInt8(30 + 190 * t)
            return (v, v, v)
        }
        let meter = JobMeter()
        let left = PixelRect(x: 40, y: 20, w: 160, h: 200), right = PixelRect(x: 280, y: 20, w: 160, h: 200)
        let ranking = Masking.rank(proxy: picture, faces: [right, left])
        XCTAssertEqual(ranking.primary?.face, left)
        XCTAssertEqual(ranking.candidates.count, 2)
        let measured = meter.finish()
        XCTAssertTrue(measured.memory.contains("peak"))
        XCTAssertTrue(measured.load.contains("core-s"))
        print("METER-CHECK \(measured.memory) | \(measured.load)")
    }

    /// BiRefNet, converted for Core ML, still finds the thing in a picture.
    func testBiRefNetFindsTheSubject() throws {
        try XCTSkipUnless(BundledModels.hasBiRefNet, "no BiRefNet model in this build")
        let w = 900, h = 600
        func inside(_ x: Int, _ y: Int) -> Bool { (x - 500) * (x - 500) + (y - 270) * (y - 270) < 160 * 160 }
        let picture = try flat(w, h) { x, y in
            inside(x, y) ? (UInt8(200 + (x % 24 < 12 ? 20 : 0)), 120, 50) : (UInt8(50 + x / 9), UInt8(80 + y / 10), 120)
        }
        let start = CFAbsoluteTimeGetCurrent()
        let answer = try BiRefNetModel.shared.segment(picture, what: "test disc")
        XCTAssertEqual(answer.w, BiRefNetModel.shared.inputSide)
        let mask = answer.resized(w: w, h: h)
        var both = 0, either = 0
        for y in 0 ..< h {
            for x in 0 ..< w {
                let a = mask.v[y * w + x] >= 0.5, b = inside(x, y)
                if a && b { both += 1 }
                if a || b { either += 1 }
            }
        }
        print("BIREFNET-CHECK disc IoU \(Double(both) / Double(max(either, 1))) at \(BiRefNetModel.shared.inputSide)² in \(CFAbsoluteTimeGetCurrent() - start) s (the first call, loading included)")
        XCTAssertGreaterThan(Double(both) / Double(max(either, 1)), 0.8)
        let warm = CFAbsoluteTimeGetCurrent()
        _ = try BiRefNetModel.shared.segment(picture, what: "test disc, warm")
        print("BIREFNET-CHECK warm call \(CFAbsoluteTimeGetCurrent() - warm) s · memory now \(MemoryStats.plain(MemoryMonitor.footprint()))")
    }

    /// The whole BiRefNet pipeline on a made-up picture, when the model is in the build: the
    /// whole frame, selection without a face, a close-up cut from the picture, the snapped
    /// edge, the hair tier, the debug bundle. Then again from what was kept, without the model.
    func testBiRefNetPipelineEndToEnd() throws {
        try XCTSkipUnless(BundledModels.hasBiRefNet, "no BiRefNet model in this build")
        let w = 1800, h = 1200
        func inside(_ x: Int, _ y: Int) -> Bool { (x - 1000) * (x - 1000) + (y - 540) * (y - 540) < 300 * 300 }
        let picture = try flat(w, h) { x, y in
            inside(x, y) ? (UInt8(200 + (x % 24 < 12 ? 20 : 0)), 120, 50) : (UInt8(50 + x / 18), UInt8(80 + y / 20), 120)
        }
        let none = DetectedFaces(subjects: [], imageWidth: Double(w))
        let key = "test|\(UUID().uuidString)"
        let before = BiRefNetModel.shared.calls
        var firsts = 0
        let mask = try Masking.make(reference: picture, name: "pipeline", key: key, tier: .high, faces: none, subject: .birefnet,
                                    progress: { _ in }, partial: { _ in firsts += 1 }, cancelled: { false })
        let calls = BiRefNetModel.shared.calls - before
        XCTAssertGreaterThanOrEqual(calls, 2, "the whole frame and at least one close-up")
        XCTAssertEqual(firsts, 1, "the Off mask is handed over first")
        let (a, keep) = try bytes(of: mask.alpha)
        _ = keep
        let row = 540 * mask.alpha.bytesPerRow
        XCTAssertEqual(a[row + 1000], 255, "the middle of the disc")
        XCTAssertEqual(a[100 * mask.alpha.bytesPerRow + 100], 0, "far from it")
        XCTAssertGreaterThan(a[row + 1000 + 290], 200, "just inside the disc's edge")
        XCTAssertLessThan(a[row + 1000 + 310], 55, "just outside it")
        XCTAssertNotNil(mask.debug)
        print("PIPELINE-CHECK \(mask.summary) · model calls \(calls) · \(mask.edge.summary) · α across the edge "
            + "\(stride(from: -6, through: 6, by: 2).map { Int(a[row + 1300 + $0]) })")

        // Another tier: from what is kept, the model is not run again.
        let again = BiRefNetModel.shared.calls
        let off = try Masking.make(reference: picture, name: "pipeline", key: key, tier: .off, faces: none, subject: .birefnet,
                                   progress: { _ in }, cancelled: { false })
        XCTAssertEqual(BiRefNetModel.shared.calls, again, "changing the tier doesn't run the model")
        XCTAssertEqual(off.tier, .off)

        // The debug bundle, from the same kept base.
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("traincull-bundle-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        try Masking.writeBundle(reference: picture, name: "pipeline", key: key, into: folder, faces: none, subject: .birefnet, mask: off)
        for file in ["proxy.png", "faces.json", "m0_birefnet.png", "m0_final.png", "final_alpha.png", "sharpness.png", "pose.json", "regions.json", "README.txt"] {
            XCTAssertTrue(FileManager.default.fileExists(atPath: folder.appendingPathComponent(file).path), file)
        }
        XCTAssertEqual(BiRefNetModel.shared.calls, again, "nor does the bundle")
        Masking.forgetAll("test")
        BiRefNetModel.shared.unload("test")
        XCTAssertFalse(BiRefNetModel.shared.isLoaded)
    }

    /// The hair-matting model, when it is in the build: one look at an area of a picture,
    /// and the same in tiles, both find the thing in it. Then a tool's whole path on a made-up
    /// mask: a box, laid back into the mask, and Option-restore putting the first mask back.
    func testMattingModelLooksAndToolsLayBack() throws {
        let w = 2400, h = 1600
        func inside(_ x: Int, _ y: Int) -> Bool { (x - 1200) * (x - 1200) + (y - 800) * (y - 800) < 500 * 500 }
        let picture = try flat(w, h) { x, y in
            inside(x, y) ? (UInt8(60 + (x % 24 < 12 ? 20 : 0)), 40, 30) : (UInt8(150 + x / 60), UInt8(170 + y / 50), 190)
        }
        let area = PixelRect(x: 100, y: 0, w: 2200, h: 1600)
        if BiRefNetModel.matting.isAvailable {
            for tiled in [false, true] {
                let start = CFAbsoluteTimeGetCurrent()
                let answer = try Masking.look(.matting, reference: picture, area: area, tiled: tiled, what: "test")
                var both = 0, either = 0
                for y in stride(from: 0, to: area.h, by: 4) {
                    for x in stride(from: 0, to: area.w, by: 4) {
                        let a = answer.sample((Float(x) + 0.5) * Float(answer.w) / Float(area.w), (Float(y) + 0.5) * Float(answer.h) / Float(area.h)) >= 0.5
                        let b = inside(area.x + x, area.y + y)
                        if a && b { both += 1 }
                        if a || b { either += 1 }
                    }
                }
                print("MATTING-CHECK \(tiled ? "tiled" : "one pass") IoU \(Double(both) / Double(max(either, 1))) · answer \(answer.w)×\(answer.h) in \(CFAbsoluteTimeGetCurrent() - start) s")
                XCTAssertGreaterThan(Double(both) / Double(max(either, 1)), 0.8)
            }
            BiRefNetModel.matting.unload("test")
        } else {
            print("MATTING-CHECK no matting model in this build")
        }
        XCTAssertTrue(Masking.wantsTiles(area))
        XCTAssertFalse(Masking.wantsTiles(PixelRect(x: 0, y: 0, w: 900, h: 1200)))

        // A box through the engine (the "closer look" is the truth, standing in for a model).
        let photo = try XCTUnwrap(Masking.photo(from: picture))
        var alpha = [UInt8](repeating: 0, count: w * h), shares = [UInt8](repeating: 255, count: w * h * 4)
        for y in 0 ..< h { for x in 0 ..< w where (x - 1200) * (x - 1200) + (y - 800) * (y - 800) < 520 * 520 { alpha[y * w + x] = 255 } } // 20 px too wide
        for i in 0 ..< w * h { shares[i * 4] = alpha[i]; shares[i * 4 + 1] = alpha[i]; shares[i * 4 + 2] = alpha[i] }
        let first = alpha, firstShares = shares
        let box = PixelRect(x: 1500, y: 600, w: 400, h: 400)
        let look = Refine.lookArea(box: box, w: w, h: h)
        var answer = Gray(w: look.w / 2, h: look.h / 2)
        for y in 0 ..< answer.h { for x in 0 ..< answer.w where inside(look.x + x * 2, look.y + y * 2) { answer.v[y * answer.w + x] = 1 } }
        let context = RefineContext(photo: photo, faces: [])
        let result = Refine.edges(box: box, look: look, answer: answer, alpha: alpha, context: context)
        let changed = Refine.paste(result.output, at: result.patch, weight: result.weight, alpha: &alpha, shares: &shares, width: w)
        XCTAssertGreaterThan(changed, 1000)
        XCTAssertLessThan(alpha[800 * w + 1200 + 510], 40, "the 20 pixels of ground the mask had taken, inside the box")
        XCTAssertEqual(alpha[800 * w + 1200 - 510], 255, "outside the box nothing moved")
        print("TOOL-CHECK box: \(changed) px changed · \(result.log.joined(separator: " | "))")
        // Option: the first mask back, exactly, inside the box.
        let weight = Refine.weight(box: box, in: box, feather: 1)
        Refine.restore(weight: weight, at: box, baseAlpha: first, baseShares: firstShares, alpha: &alpha, shares: &shares, width: w)
        XCTAssertEqual(alpha[800 * w + 1200 + 510], 255)
        XCTAssertEqual(alpha[(box.y + 200) * w + box.x + 200], first[(box.y + 200) * w + box.x + 200])
    }

    /// Apple's body-pose detector runs here without failing. A made-up picture has no person
    /// in it, so what it returns is only reported.
    func testBodyPoseRuns() throws {
        let picture = try flat(640, 480) { x, y in (x - 320) * (x - 320) + (y - 240) * (y - 240) < 150 * 150 ? (200, 150, 120) : (60, 80, 110) }
        let poses = Masking.bodyPoses(picture)
        print("POSE-CHECK \(poses.count) pose(s) in a picture with no person")
        XCTAssertLessThanOrEqual(poses.count, 1)
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
