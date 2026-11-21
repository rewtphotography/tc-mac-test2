#if os(macOS)
import CoreGraphics
import CoreImage
@testable import TrainCull
import TraincullCore
import XCTest

/// Spec tests C3a, C3b, C4 and C9 on the large made-up DNG (7008 × 4672, the a7 IV's pixel
/// count): the preview renderer's pictures against the export and against alpha 2's render.
/// Each prints a "SPEC-RESULT C… (DNG)" line. C1, C2, C5–C8 come from the launch check's runs.
final class PreviewTests: XCTestCase {
    static let url: URL = {
        if let path = ProcessInfo.processInfo.environment["TC_BIG_DNG"], FileManager.default.fileExists(atPath: path) {
            return URL(fileURLWithPath: path)
        }
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("tc-big-\(UUID().uuidString).dng")
        try? Data(SyntheticDng.make(width: 7008, height: 4672)).write(to: url)
        return url
    }()

    private var url: URL { PreviewTests.url }
    private let values: [String: Float] = ["exposure": 0.6, "shadowBoost": 1.2, "saturation": 1.2]

    private func decodableOrSkip(_ test: String) throws {
        guard let f = CIRAWFilter(imageURL: url), f.outputImage != nil else {
            print("SPEC-RESULT \(test) (DNG): NOT RUN — Apple's decoder can't open the made-up DNG")
            throw XCTSkip("no decode")
        }
    }

    private func request(_ seq: Int, _ values: [String: Float], _ want: PreviewRenderer.Want, draft: Bool) -> PreviewRenderer.Request {
        PreviewRenderer.Request(seq: seq, values: values, want: want, draft: draft, requested: CFAbsoluteTimeGetCurrent())
    }

    /// 8-bit Display P3 RGB bytes of a picture, drawn (and resized if asked) by Core Graphics.
    private func p3(_ image: CGImage, width: Int? = nil, height: Int? = nil) throws -> (w: Int, h: Int, bytes: [UInt8]) {
        let w = width ?? image.width, h = height ?? image.height
        let space = try XCTUnwrap(CGColorSpace(name: CGColorSpace.displayP3))
        let ctx = try XCTUnwrap(CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4, space: space,
                                          bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue))
        ctx.interpolationQuality = .high
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        let data = try XCTUnwrap(ctx.data)
        return (w, h, Array(UnsafeBufferPointer(start: data.assumingMemoryBound(to: UInt8.self), count: w * h * 4)))
    }

    /// The export's 16-bit ProPhoto pixels turned into 8-bit Display P3 by Core Image, the way the
    /// preview's own pixels are made.
    private func p3ci(_ image: CGImage) throws -> (w: Int, h: Int, bytes: [UInt8]) {
        let space = try XCTUnwrap(CGColorSpace(name: CGColorSpace.displayP3))
        let ci = CIImage(cgImage: image)
        let out = try XCTUnwrap(Imaging.ciContext.createCGImage(ci, from: ci.extent, format: .RGBA8, colorSpace: space))
        return try raw8(out)
    }

    /// The bytes of an 8-bit picture as it is (no redraw).
    private func raw8(_ image: CGImage) throws -> (w: Int, h: Int, bytes: [UInt8]) {
        let data = try XCTUnwrap(image.dataProvider?.data)
        let p = try XCTUnwrap(CFDataGetBytePtr(data))
        var out = [UInt8](repeating: 0, count: image.width * image.height * 4)
        for y in 0 ..< image.height { for x in 0 ..< image.width * 4 { out[y * image.width * 4 + x] = p[y * image.bytesPerRow + x] } }
        return (image.width, image.height, out)
    }

    private func diff(_ a: (w: Int, h: Int, bytes: [UInt8]), _ b: (w: Int, h: Int, bytes: [UInt8])) -> (max: Int, mean: Double) {
        guard a.w == b.w, a.h == b.h else { return (255, 255) }
        var worst = 0, total = 0
        for i in stride(from: 0, to: a.bytes.count, by: 4) {
            for c in 0 ..< 3 {
                let d = abs(Int(a.bytes[i + c]) - Int(b.bytes[i + c]))
                worst = max(worst, d)
                total += d
            }
        }
        return (worst, Double(total) / Double(a.w * a.h * 3))
    }

    private func exportRender(_ values: [String: Float]) throws -> CGImage {
        let developed = try XCTUnwrap(Imaging.developed(url, values))
        return try Export.render16(developed.image, developed.extent)
    }

    /// A drag's worth of draft frames on the renderer, then its settled render.
    private func dragThenSettle(_ r: PreviewRenderer, _ want: PreviewRenderer.Want, _ settledWant: PreviewRenderer.Want) throws -> PreviewRenderer.Frame {
        var seq = 0
        for v: Float in [0.1, 0.3, 0.5, 0.6] {
            var dragged = values
            dragged["exposure"] = v
            seq += 1
            XCTAssertNotNil(r.renderNow(request(seq, dragged, want, draft: true)))
        }
        return try XCTUnwrap(r.renderNow(request(seq + 1, values, settledWant, draft: false)))
    }

    private let region = PreviewRenderer.Want.region(CGRect(x: 0.4, y: 0.35, width: 0.2, height: 0.2), screenPixelsPerPixel: 1)

    /// C3a: the settled visible region at 100% against the same region of the export.
    func testC3aSettledMatchesExportAt100() throws {
        try decodableOrSkip("C3a")
        let r = PreviewRenderer(url: url, legacy: false)
        let settled = try dragThenSettle(r, region, region)
        let export = try exportRender(values)
        let part = try XCTUnwrap(export.cropping(to: settled.rect.integral))
        let d = diff(try raw8(settled.image), try p3ci(part))
        let cg = diff(try raw8(settled.image), try p3(part))
        XCTAssertLessThanOrEqual(d.max, 1)
        print("SPEC-RESULT C3a settled = export at 100% (DNG): region \(settled.image.width)×\(settled.image.height) after 4 draft frames; max \(d.max), mean \(String(format: "%.4f", d.mean)) levels (export turned into 8-bit Display P3 by Core Image; by Core Graphics: max \(cg.max)) — \(d.max <= 1 ? "PASS" : "FAIL")")
    }

    /// C3b: at fit, the view-size settled render against the full-resolution export made the same size.
    func testC3bSettledMatchesExportAtFit() throws {
        try decodableOrSkip("C3b")
        let r = PreviewRenderer(url: url, legacy: false)
        let fit = PreviewRenderer.Want.whole(viewLongEdge: 1800)
        let export = try exportRender(values)
        let small = try dragThenSettle(r, fit, fit)
        let a = try raw8(small.image)
        let on = diff(a, try p3(export, width: a.w, height: a.h))
        let passOn = on.mean <= 0.5 && on.max <= 4
        print("SPEC-RESULT C3b settled = export at fit, view-size settle ON (DNG): \(a.w)×\(a.h) (scale \(String(format: "%.3f", small.scale))); mean \(String(format: "%.3f", on.mean)), max \(on.max) levels — \(passOn ? "PASS" : "FAIL")")
        let full = try XCTUnwrap(r.renderNow(request(99, values, .whole(viewLongEdge: nil), draft: false)))
        let exportP3 = try p3ci(export)
        let off = diff(try raw8(full.image), exportP3)
        // For reference: alpha 2's own settled render against the same export, compared the same way.
        let alpha2 = diff(try raw8(try XCTUnwrap(Imaging.renderRaw(url, values))), exportP3)
        let sameAsAlpha2 = diff(try raw8(full.image), try raw8(try XCTUnwrap(Imaging.renderRaw(url, values))))
        print("SPEC-RESULT C3b settled = export at fit, view-size settle OFF (DNG): \(full.image.width)×\(full.image.height); mean \(String(format: "%.4f", off.mean)), max \(off.max) levels (alpha 2's render vs the same export: max \(alpha2.max); this build vs alpha 2: max \(sameAsAlpha2.max)) — \(off.max <= 1 ? "PASS" : "FAIL")")
        XCTAssertLessThanOrEqual(off.max, 1)
        if PreviewTuning.viewSizeSettleDefault { XCTAssertTrue(passOn, "view-size settle is on by default but fails C3b") }
    }

    /// C4: a TIFF export and a debug export made while drag frames are rendering equal the same
    /// exports made at rest.
    func testC4NoDraftLeak() throws {
        try decodableOrSkip("C4")
        let atRest = try p3(try exportRender(values))
        let r = PreviewRenderer(url: url, legacy: false)
        var dragging = true
        let dragger = Thread {
            var seq = 0
            while dragging {
                seq += 1
                var v = self.values
                v["exposure"] = Float(seq % 10) / 10
                _ = r.renderNow(self.request(seq, v, .whole(viewLongEdge: 1500), draft: true))
            }
        }
        dragger.start()
        let midDrag = try p3(try exportRender(values))
        #if TC_ALPHA_DEBUG
        let debugMid = try DebugRender.render(url, values)
        let draftReported = DebugRender.pipeline(url)["draftMode"] as? Bool
        #endif
        dragging = false
        let tiff = diff(atRest, midDrag)
        XCTAssertEqual(tiff.max, 0)
        #if TC_ALPHA_DEBUG
        let debugRest = try DebugRender.render(url, values)
        let dbg = diff(try p3(debugRest.pixels), try p3(debugMid.pixels))
        XCTAssertEqual(dbg.max, 0)
        XCTAssertEqual(draftReported, false)
        print("SPEC-RESULT C4 no draft leak (DNG): TIFF-export render mid-drag vs at rest max \(tiff.max); debug-export render mid-drag vs at rest max \(dbg.max); report.json draftMode \(draftReported.map { "\($0)" } ?? "?") — \(tiff.max == 0 && dbg.max == 0 && draftReported == false ? "PASS" : "FAIL")")
        #else
        print("SPEC-RESULT C4 no draft leak (DNG): TIFF-export render mid-drag vs at rest max \(tiff.max); debug export NOT RUN (built without the debug tools)")
        #endif
    }

    /// C9: a file with no edits settles exactly as alpha 2 rendered it.
    func testC9NoLookChange() throws {
        try decodableOrSkip("C9")
        let alpha2 = try XCTUnwrap(Imaging.renderRaw(url, [:])) // alpha 2's settled render: a fresh filter, full resolution
        let r = PreviewRenderer(url: url, legacy: false)
        // At fit, the settled render as the default tuning makes it.
        let fitWant = PreviewRenderer.Want.whole(viewLongEdge: PreviewTuning.viewSizeSettleDefault ? 1800 : nil)
        let fit = try XCTUnwrap(r.renderNow(request(1, [:], fitWant, draft: false)))
        let zoomed = try XCTUnwrap(r.renderNow(request(2, [:], region, draft: false)))
        let part = try XCTUnwrap(alpha2.cropping(to: zoomed.rect.integral))
        let at100 = diff(try raw8(zoomed.image), try raw8(part))
        let a = try raw8(fit.image)
        let atFit = PreviewTuning.viewSizeSettleDefault ? diff(a, try p3(alpha2, width: a.w, height: a.h)) : diff(a, try raw8(alpha2))
        XCTAssertEqual(at100.max, 0)
        let fitPass = PreviewTuning.viewSizeSettleDefault ? (atFit.mean <= 0.5 && atFit.max <= 4) : atFit.max == 0
        XCTAssertTrue(fitPass)
        print("SPEC-RESULT C9 no look change (DNG): at 100% vs alpha 2's render max \(at100.max) — \(at100.max == 0 ? "PASS" : "FAIL"); at fit (view-size settle \(PreviewTuning.viewSizeSettleDefault ? "on" : "off, full resolution")) \(a.w)×\(a.h): mean \(String(format: "%.3f", atFit.mean)), max \(atFit.max) — \(fitPass ? "PASS" : "FAIL")")
    }
}
#endif
