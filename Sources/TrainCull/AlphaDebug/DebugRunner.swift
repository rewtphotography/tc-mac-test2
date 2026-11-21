#if TC_ALPHA_DEBUG
import CoreGraphics
import Foundation
import TraincullCore

/// Runs a checked test script, or one manual export, into a new run folder under
/// ~/Pictures/TrainCull Debug. It reads the photos and writes only there: never a sidecar, never
/// the panel's values, never the image on screen.
enum DebugRunner {
    /// For the tests: write somewhere else than ~/Pictures.
    static var rootOverride: URL?

    static var root: URL {
        rootOverride ?? FileManager.default.urls(for: .picturesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("TrainCull Debug", isDirectory: true)
    }

    struct CaseResult {
        let id: String
        let file: String
        let status: String
        let zip: String?
        let zipBytes: Int?
        let estimate: Int
        let renderMs: Double?
    }

    struct RunResult {
        let folder: URL
        let results: [CaseResult]
        /// Baseline file name → checksum.
        let baselines: [String: String]
    }

    /// A new, empty run folder: never an existing one.
    static func newRunFolder(script: Int, at date: Date = Date()) throws -> URL {
        let fm = FileManager.default
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        let base = DebugNames.runFolder(script: script, at: date)
        for n in 1 ... 99 {
            let url = root.appendingPathComponent(n == 1 ? base : "\(base)-\(n)", isDirectory: true)
            if (try? fm.createDirectory(at: url, withIntermediateDirectories: false)) != nil { return url }
        }
        throw DebugRender.Failure(description: "no free run folder name under \(root.path)")
    }

    /// The panel values a case asks for, from Reset All: Apple's defaults plus the case's own.
    /// Returns the reason instead when the case can't run on this file.
    struct Resolved {
        var values: [String: Float] = [:]
        var moved = Set<String>()
        var neutral: (x: Double, y: Double)?
    }

    static func resolve(_ c: DebugCase, facts: RawFacts) -> Result<Resolved, DebugRender.Failure> {
        var r = Resolved()
        for (key, value) in c.set {
            guard let meaning = DebugKey.of(key) else { return .failure(.init(description: "failed: unknown key \(key)")) }
            switch meaning {
            case .highlightRecovery:
                if #available(macOS 27, *) {
                    return .failure(.init(description: "skipped: isHighlightRecoveryEnabled is not yet supported by this build"))
                }
                return .failure(.init(description: "skipped: requires macOS 27"))
            case .neutralLocation:
                if case let .point(x, y) = value { r.neutral = (x, y); r.moved.formUnion(["temperature", "tint"]) }
            case .decoderVersion:
                let wanted: String
                switch value {
                case let .decoder(s): wanted = s
                default: wanted = facts.decoder
                }
                let isDng = facts.decoder.lowercased().contains("dng")
                guard let match = facts.decoders.first(where: { $0 == wanted })
                    ?? facts.decoders.first(where: { RawPanel.major($0) == RawPanel.major(wanted) && $0.lowercased().contains("dng") == isDng }),
                    let major = RawPanel.major(match) else {
                    return .failure(.init(description: "skipped: unsupported (decoderVersion \(wanted))"))
                }
                r.values["decoder"] = Float(major)
                r.moved.insert("decoder")
            case let .control(controlKey):
                guard let control = RawPanel.control(controlKey) else { return .failure(.init(description: "failed: unknown key \(key)")) }
                if !RawPanel.state(control, supported: facts.supported).enabled {
                    return .failure(.init(description: "skipped: unsupported (\(key))"))
                }
                switch value {
                case let .number(n): r.values[controlKey] = Float(n)
                case let .resolved(n, _): r.values[controlKey] = Float(n)
                case let .bool(b): r.values[controlKey] = b ? 1 : 0
                case .appleDefault: r.values[controlKey] = facts.defaults[controlKey] ?? control.neutral
                case .point, .decoder: return .failure(.init(description: "failed: \(key) can't take that value"))
                }
                r.moved.insert(controlKey)
            }
        }
        return .success(r)
    }

    private static let stamp: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    /// What the run keeps from one file's Reset All render, for the next case on the same file.
    private struct Baseline {
        let key: String
        let name: String
        let checksum: String
        let pixels: CGImage
    }

    /// One case's pictures go in one zip; with `screen` (a manual export) the preview's own
    /// picture goes in too.
    struct Extra {
        /// The preview's own picture of what was on screen.
        var screen: CGImage?
        /// The part of the picture on screen, in its pixels (origin top left).
        var visible: CGRect?
    }

    /// The mean difference, in 8-bit levels over the colour channels, between two pictures of the same size.
    static func meanDifference(_ a: CGImage, _ b: CGImage) -> Double? {
        guard a.width == b.width, a.height == b.height, a.bitsPerPixel == 32, b.bitsPerPixel == 32,
              let da = a.dataProvider?.data, let db = b.dataProvider?.data,
              let pa = CFDataGetBytePtr(da), let pb = CFDataGetBytePtr(db) else { return nil }
        var total = 0
        for y in 0 ..< a.height {
            for x in 0 ..< a.width {
                for c in 0 ..< 3 { total += abs(Int(pa[y * a.bytesPerRow + x * 4 + c]) - Int(pb[y * b.bytesPerRow + x * 4 + c])) }
            }
        }
        return Double(total) / Double(a.width * a.height * 3)
    }

    /// Runs every case into a new run folder. `cancelled` is asked between cases; `progress`
    /// gets (cases done, cases in all, what is happening).
    static func run(_ script: DebugScript, photos folder: URL, extras: [Int: Extra] = [:], estimates: [Int: Int] = [:],
                    cancelled: () -> Bool = { false }, progress: (Int, Int, String) -> Void = { _, _, _ in }) throws -> RunResult {
        let runFolder = try newRunFolder(script: script.scriptNumber)
        Log.note("debug", "script \(String(format: "%02d", script.scriptNumber)) \(script.name): \(script.cases.count) case(s) → \(runFolder.path)",
                 fields: ["script": script.scriptNumber, "folder": runFolder.path])
        var results: [CaseResult] = []
        var baselines: [String: String] = [:]
        var lastBaseline: Baseline?
        var factsCache: [String: RawFacts?] = [:]

        func writeManifest() {
            let manifest: [String: Any] = [
                "script": (try? JSONSerialization.jsonObject(with: Data(script.text.utf8))) ?? script.text,
                "scriptNumber": script.scriptNumber, "name": script.name, "folder": runFolder.path,
                "baselines": baselines.sorted { $0.key < $1.key }.map { ["file": $0.key, "sha256": $0.value] },
                "cases": results.map { r -> [String: Any] in
                    ["id": r.id, "file": r.file, "status": r.status, "zip": r.zip ?? NSNull(), "zipBytes": r.zipBytes ?? NSNull(),
                     "estimatedBytes": r.estimate, "renderMs": r.renderMs ?? NSNull()]
                },
                "app": appVersion,
            ]
            if let data = try? JSONSerialization.data(withJSONObject: manifest, options: [.prettyPrinted, .sortedKeys]) {
                try? data.write(to: runFolder.appendingPathComponent("run-manifest.json"), options: .atomic)
            }
        }

        for (n, c) in script.cases.enumerated() {
            let id = DebugScript.testId(script.scriptNumber, c.number)
            let estimate = estimates[c.number] ?? 0
            func finish(_ status: String, zip: String? = nil, bytes: Int? = nil, ms: Double? = nil) {
                results.append(CaseResult(id: id, file: c.file, status: status, zip: zip, zipBytes: bytes, estimate: estimate, renderMs: ms))
                var fields: [String: Any] = ["id": id, "file": c.file, "status": status, "zip": zip.map { runFolder.appendingPathComponent($0).path } ?? NSNull(),
                                             "zipSize": bytes ?? NSNull(), "renderMs": ms ?? NSNull()]
                if estimate > 0 { fields["estimatedSize"] = estimate }
                Log.note("debug", "test \(id) \(c.file): \(status)\(bytes.map { " · \(DebugEstimate.plain($0))" } ?? "")\(ms.map { String(format: " · render %.0f ms", $0) } ?? "")",
                         fields: fields)
                writeManifest()
            }
            if cancelled() {
                finish("skipped: cancelled")
                continue
            }
            progress(n, script.cases.count, "\(id): \(c.file)")
            let url = folder.appendingPathComponent(c.file)
            if factsCache[c.file] == nil { factsCache[c.file] = .some(Adjust.facts(url)) }
            guard let facts = factsCache[c.file] ?? nil else {
                finish("failed: Apple's decoder can't open \(c.file)")
                continue
            }
            let resolved: Resolved
            switch resolve(c, facts: facts) {
            case let .success(r): resolved = r
            case let .failure(reason):
                finish(reason.description)
                continue
            }
            do {
                let result = try autoreleasepool { () -> (String, Int, Double) in
                    try runCase(c, id: id, url: url, facts: facts, resolved: resolved, script: script, runFolder: runFolder,
                                extra: extras[c.number], baseline: &lastBaseline, baselines: &baselines)
                }
                finish("done", zip: result.0, bytes: result.1, ms: result.2)
            } catch {
                finish("failed: \(error)")
            }
        }
        progress(script.cases.count, script.cases.count, "done")
        writeManifest()
        let done = results.filter { $0.status == "done" }.count
        Log.note("debug", "script \(String(format: "%02d", script.scriptNumber)) finished: \(done) of \(results.count) done · \(runFolder.path)")
        return RunResult(folder: runFolder, results: results, baselines: baselines)
    }

    private static func runCase(_ c: DebugCase, id: String, url: URL, facts: RawFacts, resolved: Resolved, script: DebugScript,
                                runFolder: URL, extra: Extra?, baseline lastBaseline: inout Baseline?, baselines: inout [String: String]) throws -> (String, Int, Double) {
        var values = resolved.values
        // The size Apple renders, for neutralLocation's point and the crop.
        var neutralInfo: Any = NSNull()
        if let point = resolved.neutral {
            guard let size = Imaging.rawSize(url) else { throw DebugRender.Failure(description: "the picture's size can't be read") }
            let at = CGPoint(x: point.x * Double(size.width), y: point.y * Double(size.height))
            guard let found = Imaging.neutral(at: at, url, values) else { throw DebugRender.Failure(description: "white balance by point failed") }
            values["temperature"] = found.temperature
            values["tint"] = found.tint
            neutralInfo = ["requested": [point.x, point.y], "pixels": [Double(at.x), Double(at.y)],
                           "coreImagePoint": [Double(found.location.x), Double(found.location.y)],
                           "temperature": Double(found.temperature), "tint": Double(found.tint)]
        }

        // The Reset All render for this file and decoder: the baseline, outside the zip.
        let decoderValues: [String: Float] = values["decoder"].map { ["decoder": $0] } ?? [:]
        let decoderName: String = {
            guard let v = values["decoder"] else { return facts.decoder }
            return facts.decoders.first { RawPanel.major($0) == Int(v) && $0.lowercased().contains("dng") == facts.decoder.lowercased().contains("dng") } ?? facts.decoder
        }()
        let stem = url.deletingPathExtension().lastPathComponent
        let baselineKey = "\(c.file)|\(decoderName)"
        let base: Baseline
        if let kept = lastBaseline, kept.key == baselineKey {
            base = kept
        } else {
            let rendered = try DebugRender.render(url, decoderValues)
            let png = try DebugRender.png(try DebugRender.frame(rendered.pixels))
            let name = DebugNames.baseline(stem: stem, decoder: decoderName, script: script.scriptNumber)
            let file = runFolder.appendingPathComponent(name)
            if !FileManager.default.fileExists(atPath: file.path) { try png.write(to: file, options: .withoutOverwriting) }
            base = Baseline(key: baselineKey, name: name, checksum: DebugRender.checksum((try? Data(contentsOf: file)) ?? png), pixels: rendered.pixels)
            baselines[name] = base.checksum
            lastBaseline = base
        }

        // The case itself, through the same render.
        let rendered = try DebugRender.render(url, values)
        let full = rendered.pixels
        var entries: [(name: String, source: ZipWriter.Source)] = []
        let frame = try DebugRender.frame(full)
        entries.append(("frame.png", .data(try DebugRender.png(frame))))
        var cropInfo: Any = NSNull()
        var output: [String: Any] = ["frame": [frame.width, frame.height]]
        if let fractions = c.crop {
            let rect = DebugRender.cropRect(fractions, full.width, full.height)
            let crop = try DebugRender.crop(full, rect)
            entries.append(("crop.png", .data(try DebugRender.png(crop))))
            entries.append(("crop-default.png", .data(try DebugRender.png(try DebugRender.crop(base.pixels, rect)))))
            cropInfo = ["fractions": fractions, "pixels": [Int(rect.minX), Int(rect.minY), Int(rect.width), Int(rect.height)]]
            output["crop"] = [crop.width, crop.height]
        }
        var screenVsFrame: Double?
        if let screen = extra?.screen {
            entries.append(("screen.png", .data(try DebugRender.png(screen))))
            output["screen"] = [screen.width, screen.height]
            // The preview-vs-export gap: the export's render of the same part, at the same size.
            let reference = try DebugRender.redraw(full, from: extra?.visible, width: screen.width, height: screen.height)
            screenVsFrame = meanDifference(screen, reference)
            Log.note("debug", "test \(id): screen.png vs the export's render at \(screen.width)×\(screen.height): mean difference \(screenVsFrame.map { String(format: "%.3f", $0) } ?? "?") levels",
                     fields: ["id": id, "screenVsFrameMeanDifference": screenVsFrame ?? NSNull(), "screenSize": [screen.width, screen.height]])
        }
        var tiffURL: URL?
        if c.fullResTIFF {
            let temp = FileManager.default.temporaryDirectory.appendingPathComponent("tc-debug-\(UUID().uuidString).tif")
            guard FileManager.default.createFile(atPath: temp.path, contents: nil) else { throw DebugRender.Failure(description: "no room for the TIFF") }
            let handle = try FileHandle(forWritingTo: temp)
            try Export.writeTiff(pixels: full, rendered: CFAbsoluteTimeGetCurrent(), to: handle, shot: nil)
            try handle.close()
            entries.append(("frame.tif", .file(temp)))
            tiffURL = temp
        }
        defer { if let t = tiffURL { try? FileManager.default.removeItem(at: t) } }

        // Read-back that differs from what was sent is listed, never hidden.
        var clamps: [String] = []
        for key in resolved.moved.sorted() {
            guard let sent = values[key], let back = rendered.readBack[key], abs(sent - back) > 0.001,
                  let control = RawPanel.control(key) else { continue }
            clamps.append("\(control.appleProperty): sent \(sent), Apple kept \(back)")
        }
        var report: [String: Any] = [
            "testId": id, "scriptNumber": script.scriptNumber, "case": c.number,
            "baseline": ["file": base.name, "sha256": base.checksum],
            "file": DebugRender.fileInfo(url, width: full.width, height: full.height),
            "controls": DebugRender.controls(values: values, moved: resolved.moved, facts: facts, readBack: rendered.readBack),
            "readBackDiffers": clamps,
            "neutralLocation": neutralInfo,
            "decoder": ["used": rendered.decoder, "supportedDecoderVersions": facts.decoders],
            "pipeline": DebugRender.pipeline(url),
            "crop": cropInfo,
            "output": output,
            "renderMs": rendered.milliseconds,
            "app": appVersion,
            "timestamp": stamp.string(from: Date()),
        ]
        if let diff = screenVsFrame { report["screenVsFrameMeanDifference"] = diff }
        entries.append(("report.json", .data(try DebugRender.reportData(report, caseText: c.raw))))
        let zipName = DebugNames.zip(id)
        let bytes = try ZipWriter.write(entries, to: runFolder.appendingPathComponent(zipName))
        return (zipName, bytes, rendered.milliseconds)
    }
}
#endif
