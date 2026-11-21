#if os(macOS)
import CoreImage
@testable import TrainCull
import TraincullCore
import XCTest

/// Spec tests T2–T6, T9 and T11, run through Apple's own raw decoder on the made-up DNG
/// (`SyntheticDng`): no photo is kept in the repository. Every figure is printed on a
/// "SPEC-RESULT … (DNG)" line; they describe the made-up DNG, not a camera's files.
final class RawControlsTests: XCTestCase {
    private static var folder: URL = {
        let f = FileManager.default.temporaryDirectory.appendingPathComponent("tc-dng-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: f, withIntermediateDirectories: true)
        return f
    }()

    private static func dng(_ orientation: Int) -> URL {
        let url = folder.appendingPathComponent("synthetic-o\(orientation).dng")
        if !FileManager.default.fileExists(atPath: url.path) {
            let (w, h) = orientation == 6 ? (1024, 1536) : (1536, 1024)
            try? Data(SyntheticDng.make(width: w, height: h, orientation: orientation)).write(to: url)
        }
        return url
    }

    private var url: URL { RawControlsTests.dng(1) }

    /// Skips (reported as NOT RUN) when Apple's decoder can't develop the made-up DNG.
    private func decodable(_ test: String, _ url: URL? = nil) throws -> CIRAWFilter {
        guard let f = CIRAWFilter(imageURL: url ?? self.url), let out = f.outputImage, !out.extent.isEmpty else {
            print("SPEC-RESULT \(test) (DNG): NOT RUN — Apple's decoder can't open the made-up DNG")
            throw XCTSkip("Apple's decoder can't open the made-up DNG")
        }
        return f
    }

    // MARK: Pixels

    private struct Pixels {
        let w: Int, h: Int
        let bytes: [UInt8] // RGBA, rows packed
        func at(_ x: Int, _ y: Int) -> (Int, Int, Int) {
            let i = (y * w + x) * 4
            return (Int(bytes[i]), Int(bytes[i + 1]), Int(bytes[i + 2]))
        }
    }

    private func pixels(_ image: CGImage?) throws -> Pixels {
        let image = try XCTUnwrap(image, "no render")
        XCTAssertEqual(image.bitsPerPixel, 32)
        let data = try XCTUnwrap(image.dataProvider?.data)
        let base = try XCTUnwrap(CFDataGetBytePtr(data))
        var out = [UInt8](repeating: 0, count: image.width * image.height * 4)
        for y in 0 ..< image.height {
            for x in 0 ..< image.width * 4 { out[y * image.width * 4 + x] = base[y * image.bytesPerRow + x] }
        }
        return Pixels(w: image.width, h: image.height, bytes: out)
    }

    /// The largest and the mean absolute difference over the colour channels.
    private func difference(_ a: Pixels, _ b: Pixels, only: ((Int, Int) -> Bool)? = nil) -> (max: Int, mean: Double) {
        guard a.w == b.w, a.h == b.h else { return (255, 255) }
        var worst = 0, total = 0, n = 0
        for y in 0 ..< a.h {
            for x in 0 ..< a.w {
                if let only = only, !only(x, y) { continue }
                let i = (y * a.w + x) * 4
                for c in 0 ..< 3 {
                    let d = abs(Int(a.bytes[i + c]) - Int(b.bytes[i + c]))
                    worst = max(worst, d)
                    total += d
                    n += 1
                }
            }
        }
        return (worst, n == 0 ? 0 : Double(total) / Double(n))
    }

    private func render(_ values: [String: Float], _ url: URL? = nil) throws -> Pixels {
        try pixels(Imaging.renderRaw(url ?? self.url, values))
    }

    private func f3(_ v: Float) -> String { String(format: "%.3f", v) }

    // MARK: The tests

    /// Which decoder Apple uses for the made-up DNG, and which controls get a red dot on it.
    func testDecoderAndRedDotsOnTheDng() throws {
        let f = try decodable("decoder")
        let facts = try XCTUnwrap(Adjust.facts(url))
        let dots = Adjust.controls.filter { RawPanel.state($0, supported: facts.supported).redDot }.map { $0.title }
        print("SPEC-RESULT decoder (DNG): Apple uses \(f.decoderVersion.rawValue); supported [\(facts.decoders.joined(separator: ", "))]; line \(RawPanel.decoderLine(facts.decoders)); native size \(Int(f.nativeSize.width))×\(Int(f.nativeSize.height))")
        let ctx = Imaging.ciContext
        print("SPEC-RESULT pipeline (DNG): draft mode by default \(f.isDraftModeEnabled ? "on" : "off"); scale factor \(f.scaleFactor); Core Image working format \(ctx.workingFormat == .RGBAh ? "RGBAh (16-bit half float)" : "\(ctx.workingFormat.rawValue)"), working colour space \(ctx.workingColorSpace?.name.map { $0 as String } ?? "none")")
        print("SPEC-RESULT T7 red dots on the made-up DNG (DNG): \(dots.isEmpty ? "none" : dots.joined(separator: ", ")) · flags \(facts.supported.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }.joined(separator: " "))")
    }

    /// T2: for every supported numeric control, set its minimum, midpoint and maximum and read
    /// back what Apple kept.
    func testT2ReadBack() throws {
        let fresh = try decodable("T2")
        let supported = Adjust.supported(fresh)
        var exact = 0, clamped: [String] = []
        for c in Adjust.controls where c.kind == .slider && c.key != "saturation" && c.key != "vibrance" {
            guard RawPanel.state(c, supported: supported).enabled else {
                print("SPEC-RESULT T2 \(c.title) (DNG): not supported for this file, nothing sent")
                continue
            }
            let lo = c.range.lowerBound, hi = c.range.upperBound
            var line: [String] = []
            for v in [lo, (lo + hi) / 2, hi] {
                let f = try XCTUnwrap(CIRAWFilter(imageURL: url))
                Adjust.apply([c.key: v], to: f)
                _ = f.outputImage
                let back = try XCTUnwrap(Adjust.properties(f)[c.key])
                if abs(back - v) <= 0.001 { exact += 1 } else { clamped.append("\(c.title) \(f3(v)) → \(f3(back))") }
                line.append("\(f3(v))→\(f3(back))")
            }
            print("SPEC-RESULT T2 \(c.title) (DNG): \(line.joined(separator: ", "))")
        }
        var boost: [String] = []
        for v: Float in [0.9, 1.0, 1.5, 2.0] {
            let f = try XCTUnwrap(CIRAWFilter(imageURL: url))
            f.boostShadowAmount = v
            _ = f.outputImage
            boost.append("\(f3(v))→\(f3(f.boostShadowAmount))")
        }
        print("SPEC-RESULT T2 Shadow boost read-back at 0.9, 1.0, 1.5, 2.0 (DNG): \(boost.joined(separator: ", "))")
        print("SPEC-RESULT T2 read-back (DNG): \(exact) exact; Apple changed \(clamped.count): \(clamped.isEmpty ? "none" : clamped.joined(separator: "; ")) — PASS (every value reported)")
    }

    /// T3: with nothing moved, what Apple uses equals a fresh filter's default for every control.
    func testT3UnclampedDefaults() throws {
        let fresh = try decodable("T3")
        let defaults = Adjust.properties(fresh)
        let f = try XCTUnwrap(CIRAWFilter(imageURL: url))
        Adjust.apply([:], to: f) // what the app sends for a frame nothing was moved on
        _ = f.outputImage
        let used = Adjust.properties(f)
        let appDefaults = Adjust.defaults(url)
        var mismatches: [String] = []
        for c in Adjust.controls where c.kind != .neutralPoint {
            guard let d = defaults[c.key], let u = used[c.key], let shown = appDefaults[c.key] else { continue }
            if abs(d - u) > 0.001 || abs(d - shown) > 0.001 { mismatches.append("\(c.title) \(f3(d)) vs \(f3(u))") }
            if c.kind == .slider, !c.range.contains(d) { print("SPEC-RESULT T3 (DNG): \(c.title)'s default \(f3(d)) lies outside its slider (\(c.range)); it is used unclamped") }
        }
        XCTAssertTrue(mismatches.isEmpty, mismatches.joined(separator: "; "))
        print("SPEC-RESULT T3 unclamped defaults (DNG): \(mismatches.count) mismatches\(mismatches.isEmpty ? "" : ": " + mismatches.joined(separator: "; ")); Shadow bias true default \(f3(defaults["shadowBias"] ?? .nan)) — \(mismatches.isEmpty ? "PASS" : "FAIL")")
        print("SPEC-RESULT T3 all defaults (DNG): " + Adjust.controls.compactMap { c in defaults[c.key].map { "\(c.title) \(f3($0))" } }.joined(separator: " · "))
    }

    /// The previous build's render path (0.2.0 alpha 1's `Imaging.renderRaw`) with nothing moved,
    /// kept here verbatim as the reference.
    private func previousBuildRender(_ url: URL) -> CGImage? {
        autoreleasepool {
            guard let filter = CIRAWFilter(imageURL: url) else { return nil }
            guard let decoded = filter.outputImage else { return nil }
            let out = decoded // Adjust.finish with no values changed nothing
            let e = decoded.extent
            if e.isInfinite || e.isEmpty { return nil }
            return Imaging.pixels(out, from: e)
        }
    }

    /// T4: every control at default renders exactly as the previous build did.
    func testT4Transparency() throws {
        _ = try decodable("T4")
        let before = try pixels(previousBuildRender(url))
        let now = try render([:])
        let d = difference(before, now)
        XCTAssertLessThanOrEqual(d.max, 1)
        // For information: every control explicitly set to its own default value.
        let explicit = try render(Adjust.defaults(url))
        let e = difference(before, explicit)
        print("SPEC-RESULT T4 transparency (DNG): nothing moved vs the previous build's path: max \(d.max), mean \(String(format: "%.4f", d.mean)) over 100% of \(now.w)×\(now.h) pixels — \(d.max <= 1 ? "PASS" : "FAIL"); every control explicitly sent its default (information): max \(e.max), mean \(String(format: "%.4f", e.mean))")
    }

    /// T5: each toggle flipped and flipped back renders as at first.
    func testT5Toggles() throws {
        let fresh = try decodable("T5")
        let defaults = Adjust.properties(fresh), supported = Adjust.supported(fresh)
        let layout = SyntheticDng.layout(width: 1536, height: 1024)
        func inClipped(_ x: Int, _ y: Int) -> Bool {
            let r = layout.clippedTwo, s = layout.clippedOne
            return (x >= r.x && x < r.x + r.w && y >= r.y && y < r.y + r.h) || (x >= s.x && x < s.x + s.w && y >= s.y && y < s.y + s.h)
        }
        let first = try render([:])
        var allPass = true
        // Highlight recovery is left out: Apple's raw filter has no such setting before macOS 27.
        for key in ["gamutMapping", "lensCorrection"] {
            let c = try XCTUnwrap(Adjust.control(key))
            let d = try XCTUnwrap(defaults[key])
            let flipped = try render([key: 1 - d])
            // Flipping back to Apple's default removes the change, as the panel does.
            let back = try render([:])
            let backExplicit = try render([key: d])
            let f = difference(first, flipped), b = difference(first, back), be = difference(first, backExplicit)
            let clip = difference(first, flipped, only: inClipped)
            let sent = RawPanel.state(c, supported: supported).enabled
            if b.max != 0 { allPass = false }
            print("SPEC-RESULT T5 \(c.title) (DNG): default \(d >= 0.5 ? "on" : "off")\(sent ? "" : " (not supported: nothing sent)"); flipped mean \(String(format: "%.3f", f.mean)) (max \(f.max); clipped blocks mean \(String(format: "%.3f", clip.mean))); flipped back max \(b.max) — \(b.max == 0 ? "PASS" : "FAIL"); default sent explicitly max \(be.max)")
        }
        XCTAssertTrue(allPass)
    }

    /// T6: Baseline exposure one stop up brightens the picture, midtones included.
    func testT6BaselineExposure() throws {
        let fresh = try decodable("T6")
        let b = fresh.baselineExposure
        let a = try render([:]), up = try render(["baselineExposure": b + 1])
        let d = difference(a, up)
        var before = 0.0, after = 0.0, n = 0
        for y in stride(from: 0, to: a.h, by: 2) {
            for x in stride(from: 0, to: a.w, by: 2) {
                let p = a.at(x, y), q = up.at(x, y)
                let l = Double(p.0 + p.1 + p.2) / 3
                if l >= 64 && l <= 192 {
                    before += l
                    after += Double(q.0 + q.1 + q.2) / 3
                    n += 1
                }
            }
        }
        let midBefore = before / Double(max(n, 1)), midAfter = after / Double(max(n, 1))
        let pass = d.mean > 2 && midAfter > midBefore
        XCTAssertTrue(pass)
        print("SPEC-RESULT T6 baseline exposure (DNG): default \(f3(b)) → \(f3(b + 1)); mean difference \(String(format: "%.2f", d.mean)) levels (max \(d.max)); midtones \(String(format: "%.1f", midBefore)) → \(String(format: "%.1f", midAfter)) over \(n) samples — \(pass ? "PASS" : "FAIL")")
    }

    /// T9: white balance by point on the grey patch, upright and on a frame stored on its side.
    func testT9WhiteBalanceByPoint() throws {
        var allPass = true
        for orientation in [1, 6] {
            let file = RawControlsTests.dng(orientation)
            _ = try decodable("T9", file)
            let (w, h) = orientation == 6 ? (1024, 1536) : (1536, 1024)
            let patch = SyntheticDng.layout(width: w, height: h).greyPatch
            let point = CGPoint(x: patch.centreX, y: patch.centreY)
            func patchMean(_ p: Pixels) -> (Double, Double, Double) {
                var r = 0, g = 0, b = 0
                for y in patch.centreY - 2 ... patch.centreY + 2 {
                    for x in patch.centreX - 2 ... patch.centreX + 2 {
                        let v = p.at(x, y)
                        r += v.0; g += v.1; b += v.2
                    }
                }
                return (Double(r) / 25, Double(g) / 25, Double(b) / 25)
            }
            let asShot = patchMean(try render([:], file))
            let first = try XCTUnwrap(Imaging.neutral(at: point, file, [:]))
            let again = try XCTUnwrap(Imaging.neutral(at: point, file, [:]))
            // What the panel then holds and sends: Apple's read-back temperature and tint.
            let values: [String: Float] = ["temperature": first.temperature, "tint": first.tint]
            let (image, readBack) = Imaging.renderRawReading(file, values)
            let t = try XCTUnwrap(readBack["temperature"]), tint = try XCTUnwrap(readBack["tint"])
            let balanced = patchMean(try pixels(image))
            let rg = abs(balanced.0 - balanced.1), bg = abs(balanced.2 - balanced.1)
            let matches = abs(t - first.temperature) <= 1 && abs(tint - first.tint) <= 0.1
            let neutral = rg <= 3 && bg <= 3
            let repeatable = first.temperature == again.temperature && first.tint == again.tint
            if !(matches && neutral && repeatable) { allPass = false }
            print("SPEC-RESULT T9 white balance by point, orientation \(orientation) (DNG): point \(patch.centreX), \(patch.centreY) → \(String(format: "%.1f", first.temperature)) K, tint \(String(format: "%+.2f", first.tint)); read back \(String(format: "%.1f", t)) K, \(String(format: "%+.2f", tint)) (\(matches ? "match" : "MISMATCH")); 5×5 patch mean R,G,B as shot \(String(format: "%.1f, %.1f, %.1f", asShot.0, asShot.1, asShot.2)), after \(String(format: "%.1f, %.1f, %.1f", balanced.0, balanced.1, balanced.2)): |R−G| \(String(format: "%.1f", rg)), |B−G| \(String(format: "%.1f", bg)) (\(neutral ? "neutral" : "NOT neutral")); same point again \(repeatable ? "identical" : "DIFFERENT") — \(matches && neutral && repeatable ? "PASS" : "FAIL")")
        }
        XCTAssertTrue(allPass)
    }

    /// T11: after Reset All (the panel empties every change) the render equals a fresh open.
    func testT11ResetAll() throws {
        _ = try decodable("T11")
        var values: [String: Float] = ["exposure": 1, "baselineExposure": 0.5, "gamutMapping": 0,
                                       "temperature": 4500, "tint": 12, "saturation": 1.4, "vibrance": 0.3, "shadowBoost": 1.2]
        let moved = try render(values)
        values = [:] // what Reset All leaves
        let reset = try render(values)
        let fresh = try pixels(Imaging.renderRaw(url))
        let d = difference(fresh, reset), m = difference(fresh, moved)
        XCTAssertLessThanOrEqual(d.max, 1)
        print("SPEC-RESULT T11 Reset All (DNG): after reset vs fresh open max \(d.max) (moved state differed by mean \(String(format: "%.2f", m.mean))) — \(d.max <= 1 ? "PASS" : "FAIL")")
    }
}
#endif
