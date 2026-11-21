#if os(macOS) && TC_ALPHA_DEBUG
import CoreGraphics
import CoreImage
import CryptoKit
import ImageIO
@testable import TrainCull
import TraincullCore
import XCTest

/// The alpha-only debug tools (B2, B4–B11, and B3's sidecar half) on the made-up DNG. Each
/// prints a "SPEC-RESULT B… (DNG)" line. Delete this file with the AlphaDebug folder.
final class AlphaDebugTests: XCTestCase {
    static let photos: URL = {
        let f = FileManager.default.temporaryDirectory.appendingPathComponent("tc-debug-photos-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: f, withIntermediateDirectories: true)
        let dng = SyntheticDng.make()
        try? Data(dng).write(to: f.appendingPathComponent("SYNTHETIC.dng"))
        try? Data(dng.prefix(4096)).write(to: f.appendingPathComponent("CORRUPT.dng")) // cut short on purpose
        let sidecar = Xmp.newSidecar(2)
        let edited = Xmp.withField(Xmp.withField(sidecar, .cameraRaw, "Exposure2012", "+0.70") ?? sidecar, .trainCull, "ShadowBoost", "1.300") ?? sidecar
        try? Data(edited.utf8).write(to: f.appendingPathComponent("SYNTHETIC.xmp"))
        return f
    }()

    static let script = """
    {
      "scriptNumber": 7,
      "name": "self-test",
      "index": ["0701: exposure +0.5 with a crop", "0702: Shadow bias min, Boost 0, saturation, gamut mapping off",
                "0703: out of range on purpose", "0704: white balance on the grey patch", "0705: defaults, decoder, TIFF, crop",
                "0706: Local tone map (unsupported on the DNG)", "0707: a corrupted file", "0708: highlight recovery (macOS 27)"],
      "cases": [
        { "case": 1, "file": "SYNTHETIC.dng", "set": { "exposure": 0.5 }, "crop": [0.1, 0.1, 0.25, 0.25] },
        { "case": 2, "file": "SYNTHETIC.dng", "set": { "shadowBias": "min", "boostAmount": 0, "tc.saturation": 1.3, "isGamutMappingEnabled": false } },
        { "case": 3, "file": "SYNTHETIC.dng", "set": { "shadowBias": 5, "boostShadowAmount": 2.5 }, "allowOutOfRange": true, "crop": [0.6, 0.05, 0.3, 0.3] },
        { "case": 4, "file": "SYNTHETIC.dng", "set": { "neutralLocation": [0.18, 0.2] } },
        { "case": 5, "file": "SYNTHETIC.dng", "set": { "baselineExposure": "default", "decoderVersion": "8.dng", "tc.vibrance": 0.4 },
          "fullResTIFF": true, "crop": [0.4, 0.4, 0.2, 0.2] },
        { "case": 6, "file": "SYNTHETIC.dng", "set": { "localToneMapAmount": 0.5 } },
        { "case": 7, "file": "CORRUPT.dng", "set": { "exposure": 0.2 } },
        { "case": 8, "file": "SYNTHETIC.dng", "set": { "isHighlightRecoveryEnabled": true } }
      ]
    }
    """

    static let root: URL = FileManager.default.temporaryDirectory.appendingPathComponent("tc-debug-root-\(UUID().uuidString)", isDirectory: true)

    /// The script run twice, as B4 asks; the other tests read the first run.
    static let runs: (DebugRunner.RunResult, DebugRunner.RunResult, [Int: Int], String, String)? = {
        guard let filter = CIRAWFilter(imageURL: photos.appendingPathComponent("SYNTHETIC.dng")), filter.outputImage != nil else { return nil }
        DebugRunner.rootOverride = root
        let sidecar = photos.appendingPathComponent("SYNTHETIC.xmp")
        let before = (try? Data(contentsOf: sidecar)).map { SHA256.hash(data: $0).description } ?? ""
        let (validation, estimates, _) = DebugTools.check(script, folder: photos)
        guard let s = validation.script,
              let first = try? DebugRunner.run(s, photos: photos, estimates: estimates),
              let second = try? DebugRunner.run(s, photos: photos, estimates: estimates) else { return nil }
        let after = (try? Data(contentsOf: sidecar)).map { SHA256.hash(data: $0).description } ?? ""
        return (first, second, estimates, before, after)
    }()

    private func runsOrSkip(_ test: String) throws -> (DebugRunner.RunResult, DebugRunner.RunResult, [Int: Int], String, String) {
        guard let r = AlphaDebugTests.runs else {
            print("SPEC-RESULT \(test) (DNG): NOT RUN — Apple's decoder can't open the made-up DNG, or the run couldn't start")
            throw XCTSkip("no run")
        }
        return r
    }

    // MARK: Pixels

    private struct Samples {
        let w: Int, h: Int, channels: Int, bits: Int
        let values: [Int] // w × h × 3 colour samples
        func at(_ x: Int, _ y: Int, _ c: Int) -> Int { values[(y * w + x) * 3 + c] }
    }

    private func decode(_ data: Data) throws -> CGImage {
        let source = try XCTUnwrap(CGImageSourceCreateWithData(data as CFData, nil))
        return try XCTUnwrap(CGImageSourceCreateImageAtIndex(source, 0, nil))
    }

    /// The colour samples as the file holds them (8 or 16 bits), whatever the byte order.
    private func samples(_ image: CGImage) throws -> Samples {
        let data = try XCTUnwrap(image.dataProvider?.data)
        let p = try XCTUnwrap(CFDataGetBytePtr(data))
        let bytesPerSample = image.bitsPerComponent / 8
        let perPixel = image.bitsPerPixel / image.bitsPerComponent
        let alpha = image.alphaInfo
        let first = (alpha == .premultipliedFirst || alpha == .first || alpha == .noneSkipFirst) ? 1 : 0
        let order = image.bitmapInfo.intersection(.byteOrderMask)
        let little = order == .byteOrder16Little || order == .byteOrder32Little
        var out = [Int](repeating: 0, count: image.width * image.height * 3)
        for y in 0 ..< image.height {
            for x in 0 ..< image.width {
                for c in 0 ..< 3 {
                    let i = y * image.bytesPerRow + (x * perPixel + first + c) * bytesPerSample
                    let v = bytesPerSample == 1 ? Int(p[i]) : (little ? Int(p[i]) | Int(p[i + 1]) << 8 : Int(p[i]) << 8 | Int(p[i + 1]))
                    out[(y * image.width + x) * 3 + c] = v
                }
            }
        }
        return Samples(w: image.width, h: image.height, channels: perPixel, bits: image.bitsPerComponent, values: out)
    }

    private func maxDiff(_ a: Samples, _ b: Samples, offsetX: Int = 0, offsetY: Int = 0) -> Int {
        var worst = 0
        for y in 0 ..< a.h {
            for x in 0 ..< a.w {
                for c in 0 ..< 3 { worst = max(worst, abs(a.at(x, y, c) - b.at(x + offsetX, y + offsetY, c))) }
            }
        }
        return worst
    }

    private func zips(_ run: DebugRunner.RunResult) -> [(DebugRunner.CaseResult, URL)] {
        run.results.compactMap { r in r.zip.map { (r, run.folder.appendingPathComponent($0)) } }
    }

    private func report(_ zip: URL) throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: try ZipWriter.entry("report.json", in: zip)) as? [String: Any])
    }

    private func scriptCase(_ number: Int) throws -> DebugCase {
        let s = try XCTUnwrap(DebugScriptReader.validate(AlphaDebugTests.script) { _ in true }.script)
        return try XCTUnwrap(s.cases.first { $0.number == number })
    }

    // MARK: The tests

    /// B2: seven bad scripts, each refused with its own error, and nothing written.
    func testB2Validation() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("tc-debug-b2-\(UUID().uuidString)", isDirectory: true)
        DebugRunner.rootOverride = root
        defer { DebugRunner.rootOverride = AlphaDebugTests.root }
        func one(_ cases: String, number: String = "7") -> String { "{\"scriptNumber\": \(number), \"name\": \"bad\", \"cases\": [\(cases)]}" }
        let bad: [(String, String, String)] = [
            ("malformed JSON", "{ \"scriptNumber\": 7, \"name\": ", "malformed JSON"),
            ("unknown key", one("{\"case\": 1, \"file\": \"SYNTHETIC.dng\", \"set\": {\"sharpenAmount\": 1}}"), "unknown key \"sharpenAmount\""),
            ("duplicate case", one("{\"case\": 1, \"file\": \"SYNTHETIC.dng\"}, {\"case\": 1, \"file\": \"SYNTHETIC.dng\"}"), "duplicate case 1"),
            ("scriptNumber 0", one("{\"case\": 1, \"file\": \"SYNTHETIC.dng\"}", number: "0"), "scriptNumber 0 is out of range"),
            ("scriptNumber 100", one("{\"case\": 1, \"file\": \"SYNTHETIC.dng\"}", number: "100"), "scriptNumber 100 is out of range"),
            ("missing file", one("{\"case\": 1, \"file\": \"NOT-THERE.ARW\"}"), "missing file NOT-THERE.ARW"),
            ("two files in one case", one("{\"case\": 1, \"file\": [\"SYNTHETIC.dng\", \"CORRUPT.dng\"]}"), "more than one file in one case"),
            ("out of range without allowOutOfRange", one("{\"case\": 1, \"file\": \"SYNTHETIC.dng\", \"set\": {\"shadowBias\": 5}}"), "shadowBias = 5.0 is out of range"),
        ]
        var rejected = 0
        for (what, text, expected) in bad {
            let (v, _, _) = DebugTools.check(text, folder: AlphaDebugTests.photos)
            let hit = !v.canRun && v.errors.contains { $0.contains(expected) }
            if hit { rejected += 1 }
            XCTAssertTrue(hit, "\(what): \(v.errors)")
            print("SPEC-RESULT B2 \(what) (DNG): \(hit ? "rejected" : "NOT REJECTED") — \(v.errors.first ?? "no error")")
        }
        let written = (try? FileManager.default.contentsOfDirectory(atPath: root.path))?.count ?? 0
        XCTAssertEqual(written, 0)
        print("SPEC-RESULT B2 validation (DNG): \(rejected) of \(bad.count) bad scripts rejected with the specific error (the spec's 7, with scriptNumber 0 and 100 counted apart); \(written) files written — \(rejected == bad.count && written == 0 ? "PASS" : "FAIL")")
    }

    /// B3 (sidecar half): the DNG's sidecar is byte-identical after two runs. The panel half is
    /// checked by the launch check.
    func testB3SidecarUntouched() throws {
        let (_, _, _, before, after) = try runsOrSkip("B3")
        XCTAssertEqual(before, after)
        print("SPEC-RESULT B3 sidecar (DNG): SHA-256 before \(before.suffix(12)), after \(after.suffix(12)) — \(before == after ? "identical" : "CHANGED")")
    }

    /// B4: the same script twice: two run folders, identical pictures, equal baseline checksums.
    func testB4Determinism() throws {
        let (a, b, _, _, _) = try runsOrSkip("B4")
        XCTAssertNotEqual(a.folder, b.folder)
        var worst = 0, compared = 0
        for ((_, za), (_, zb)) in zip(zips(a), zips(b)) {
            for name in try ZipWriter.names(za) where name.hasSuffix(".png") {
                let pa = try samples(try decode(try ZipWriter.entry(name, in: za))), pb = try samples(try decode(try ZipWriter.entry(name, in: zb)))
                worst = max(worst, maxDiff(pa, pb))
                compared += 1
            }
        }
        let same = a.baselines.values.sorted() == b.baselines.values.sorted()
        XCTAssertEqual(worst, 0)
        XCTAssertTrue(same)
        print("SPEC-RESULT B4 determinism (DNG): folders \(a.folder.lastPathComponent) and \(b.folder.lastPathComponent); \(compared) PNGs compared, max difference \(worst); baseline checksums \(same ? "equal" : "DIFFERENT") (\(a.baselines.values.joined(separator: ", "))) — \(worst == 0 && same && a.folder != b.folder ? "PASS" : "FAIL")")
    }

    /// B5: the baseline is the Reset All export through the existing TIFF path, and every report
    /// names the baseline's real checksum.
    func testB5Baseline() throws {
        let (run, _, _, _, _) = try runsOrSkip("B5")
        let url = AlphaDebugTests.photos.appendingPathComponent("SYNTHETIC.dng")
        let tiff = try Export.developedTiff(url, [:], shot: nil)
        defer { try? FileManager.default.removeItem(at: tiff) }
        let fromExport = try samples(try DebugRender.frame(try decode(try Data(contentsOf: tiff))))
        var worst = 0, checked = 0, matches = 0
        for (name, sum) in run.baselines {
            let file = run.folder.appendingPathComponent(name)
            let data = try Data(contentsOf: file)
            XCTAssertEqual(DebugRender.checksum(data), sum)
            if name.contains("raw8dng") { worst = max(worst, maxDiff(try samples(try decode(data)), fromExport)) }
        }
        for (_, zip) in zips(run) {
            let r = try report(zip)
            let base = try XCTUnwrap(r["baseline"] as? [String: Any])
            let name = try XCTUnwrap(base["file"] as? String), sum = try XCTUnwrap(base["sha256"] as? String)
            let actual = DebugRender.checksum(try Data(contentsOf: run.folder.appendingPathComponent(name)))
            checked += 1
            if actual == sum { matches += 1 }
        }
        XCTAssertEqual(worst, 0)
        XCTAssertEqual(matches, checked)
        print("SPEC-RESULT B5 baseline (DNG): baseline vs Reset All export through the TIFF path: max difference \(worst); report checksums matching the baseline file: \(matches) of \(checked) — \(worst == 0 && matches == checked ? "PASS" : "FAIL")")
    }

    /// B6: frame 8-bit Display P3, long edge 3000 (or native); crop 16-bit, tagged, the right size.
    func testB6Formats() throws {
        let (run, _, _, _, _) = try runsOrSkip("B6")
        let p3 = CGColorSpace(name: CGColorSpace.displayP3)?.copyICCData() as Data?
        let pro = CGColorSpace(name: CGColorSpace.rommrgb)?.copyICCData() as Data?
        func tagged(_ image: CGImage, _ icc: Data?, _ name: CFString) -> Bool {
            image.colorSpace?.name == name || (image.colorSpace?.copyICCData() as Data?) == icc
        }
        var failures: [String] = [], lines: [String] = []
        for (result, zip) in zips(run) {
            let frame = try decode(try ZipWriter.entry("frame.png", in: zip))
            let native = 1536 // the made-up DNG is smaller than 3000 px
            if frame.bitsPerComponent != 8 || !tagged(frame, p3, CGColorSpace.displayP3) || abs(max(frame.width, frame.height) - native) > 1 {
                failures.append("\(result.id) frame \(frame.width)×\(frame.height) \(frame.bitsPerComponent)-bit")
            }
            lines.append("\(result.id) frame \(frame.width)×\(frame.height) \(frame.bitsPerComponent)-bit P3")
            if let fractions = try scriptCase(Int(result.id.suffix(2))!).crop {
                for name in ["crop.png", "crop-default.png"] {
                    let crop = try decode(try ZipWriter.entry(name, in: zip))
                    let w = Int((fractions[2] * 1536).rounded()), h = Int((fractions[3] * 1024).rounded())
                    if crop.bitsPerComponent != 16 || !tagged(crop, pro, CGColorSpace.rommrgb) || abs(crop.width - w) > 1 || abs(crop.height - h) > 1 {
                        failures.append("\(result.id) \(name) \(crop.width)×\(crop.height) \(crop.bitsPerComponent)-bit, wanted \(w)×\(h)")
                    }
                }
                lines.append("\(result.id) crop \(Int((fractions[2] * 1536).rounded()))×\(Int((fractions[3] * 1024).rounded())) 16-bit ProPhoto")
            }
        }
        XCTAssertTrue(failures.isEmpty, failures.joined(separator: "; "))
        print("SPEC-RESULT B6 formats (DNG): \(lines.joined(separator: " · ")); problems: \(failures.isEmpty ? "none" : failures.joined(separator: "; ")) — \(failures.isEmpty ? "PASS" : "FAIL")")
    }

    /// B7: crop.png against the same region of a 16-bit TIFF export with the same settings.
    func testB7ExportMatch() throws {
        let (run, _, _, _, _) = try runsOrSkip("B7")
        let url = AlphaDebugTests.photos.appendingPathComponent("SYNTHETIC.dng")
        let facts = try XCTUnwrap(Adjust.facts(url))
        var lines: [String] = [], worstAll = 0
        for (result, zip) in zips(run) {
            let c = try scriptCase(Int(result.id.suffix(2))!)
            guard let fractions = c.crop else { continue }
            guard case let .success(resolved) = DebugRunner.resolve(c, facts: facts) else { continue }
            let tiff = try Export.developedTiff(url, resolved.values, shot: nil)
            defer { try? FileManager.default.removeItem(at: tiff) }
            let full = try samples(try decode(try Data(contentsOf: tiff)))
            let crop = try samples(try decode(try ZipWriter.entry("crop.png", in: zip)))
            let rect = DebugRender.cropRect(fractions, full.w, full.h)
            let worst = maxDiff(crop, full, offsetX: Int(rect.minX), offsetY: Int(rect.minY))
            worstAll = max(worstAll, worst)
            lines.append("\(result.id): max \(worst) (16-bit code values)")
        }
        XCTAssertLessThanOrEqual(worstAll, 1)
        print("SPEC-RESULT B7 export match (DNG): \(lines.joined(separator: "; ")) — \(worstAll <= 1 ? "PASS" : "FAIL")")
    }

    /// B8: every moved control reads back what was sent, or the report lists the difference.
    func testB8ReadBack() throws {
        let (run, _, _, _, _) = try runsOrSkip("B8")
        var unexplained: [String] = [], explained: [String] = [], checked = 0
        for (result, zip) in zips(run) {
            let r = try report(zip)
            let listed = (r["readBackDiffers"] as? [String]) ?? []
            explained += listed.map { "\(result.id) \($0)" }
            for control in (r["controls"] as? [[String: Any]]) ?? [] where control["moved"] as? Bool == true {
                checked += 1
                guard let used = control["valueUsed"] as? Double, let back = control["readBack"] as? Double else { continue }
                let property = control["appleProperty"] as? String ?? "?"
                if abs(used - back) > 0.001 && !listed.contains(where: { $0.hasPrefix(property) }) {
                    unexplained.append("\(result.id) \(property): \(used) → \(back)")
                }
            }
        }
        XCTAssertTrue(unexplained.isEmpty, unexplained.joined(separator: "; "))
        print("SPEC-RESULT B8 read-back (DNG): \(checked) moved controls checked; differences reported by Apple: \(explained.isEmpty ? "none" : explained.joined(separator: "; ")); unexplained: \(unexplained.count) — \(unexplained.isEmpty ? "PASS" : "FAIL")")
    }

    /// B9: every zip holds exactly its files, and its report the case as written.
    func testB9ZipContents() throws {
        let (run, _, _, _, _) = try runsOrSkip("B9")
        var good = 0, all = 0, problems: [String] = []
        for (result, zip) in zips(run) {
            all += 1
            let c = try scriptCase(Int(result.id.suffix(2))!)
            var expected = ["frame.png"]
            if c.crop != nil { expected += ["crop.png", "crop-default.png"] }
            if c.fullResTIFF { expected.append("frame.tif") }
            expected.append("report.json")
            let names = try ZipWriter.names(zip)
            let text = String(decoding: try ZipWriter.entry("report.json", in: zip), as: UTF8.self)
            let verbatim = text.contains(c.raw)
            if Set(names) == Set(expected) && names.count == expected.count && verbatim { good += 1 } else { problems.append("\(result.id): \(names), verbatim \(verbatim)") }
        }
        XCTAssertEqual(good, all)
        print("SPEC-RESULT B9 zip contents (DNG): \(good) of \(all) zips exactly right, each report holding its case verbatim\(problems.isEmpty ? "" : "; " + problems.joined(separator: "; ")) — \(good == all ? "PASS" : "FAIL")")
    }

    /// B10: estimated against actual zip sizes.
    func testB10SizeEstimate() throws {
        let (run, _, estimates, _, _) = try runsOrSkip("B10")
        var lines: [String] = [], outside = 0
        for (result, _) in zips(run) {
            let estimate = estimates[Int(result.id.suffix(2))!] ?? 0
            let actual = result.zipBytes ?? 0
            let off = estimate > 0 ? Double(actual - estimate) / Double(estimate) * 100 : 100
            if abs(off) > 25 { outside += 1 }
            lines.append("\(result.id) estimated \(DebugEstimate.plain(estimate)), actual \(DebugEstimate.plain(actual)) (\(String(format: "%+.0f", off))%)")
        }
        XCTAssertEqual(outside, 0)
        print("SPEC-RESULT B10 size estimate (DNG): \(lines.joined(separator: "; ")) — \(outside == 0 ? "PASS" : "FAIL")")
    }

    /// B11: an unsupported control and a corrupted file don't stop the run.
    func testB11ContinuePastProblems() throws {
        let (run, _, _, _, _) = try runsOrSkip("B11")
        let manifest = try XCTUnwrap(JSONSerialization.jsonObject(with: try Data(contentsOf: run.folder.appendingPathComponent("run-manifest.json"))) as? [String: Any])
        let cases = try XCTUnwrap(manifest["cases"] as? [[String: Any]])
        let status = Dictionary(uniqueKeysWithValues: cases.map { ($0["id"] as? String ?? "", $0["status"] as? String ?? "") })
        let unsupported = status["0706"] == "skipped: unsupported (localToneMapAmount)"
        let failed = status["0707"]?.hasPrefix("failed: ") == true
        let macOS27 = status["0708"] == "skipped: requires macOS 27"
        let others = ["0701", "0702", "0703", "0704", "0705"].allSatisfy { status[$0] == "done" }
        XCTAssertTrue(unsupported && failed && macOS27 && others)
        print("SPEC-RESULT B11 continue past problems (DNG): " + status.sorted { $0.key < $1.key }.map { "\($0.key) \($0.value)" }.joined(separator: " · ") + " — \(unsupported && failed && macOS27 && others ? "PASS" : "FAIL")")
    }
}
#endif
