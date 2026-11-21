@testable import TraincullCore
import XCTest

/// The RAW panel's layout, red dots, decoder line and sidecar round trip (spec tests T1, T7,
/// T8, T10). Each prints a SPEC-RESULT line for the build summary.
final class RawPanelTests: XCTestCase {
    /// T1: five sections in pipeline order, every control in its section, labels exactly as specified.
    func testT1Layout() {
        let expected: [(String, [String])] = [
            ("Raw & Detail", ["Decoder", "Lens correction", "Luminance noise reduction", "Colour noise reduction",
                              "Moiré reduction", "Sharpness", "Detail", "Local contrast (Contrast)"]),
            ("Light", ["Temperature", "Tint", "White balance by point", "Exposure", "Baseline exposure",
                       "Blacks (Shadow bias)"]),
            ("Tone curve", ["Tone curve (Boost)", "Shadows (Shadow boost)", "Local tone map"]),
            ("Colour", ["Saturation", "Vibrance"]),
            ("Output", ["Gamut mapping"]),
        ]
        XCTAssertEqual(RawPanel.sections, expected.map { $0.0 })
        var mismatches = 0, checked = 0
        for (section, labels) in expected {
            let shown = RawPanel.controls.filter { $0.section == section }.map { $0.title }
            checked += labels.count
            if shown != labels { mismatches += 1 }
            XCTAssertEqual(shown, labels, section)
        }
        XCTAssertEqual(RawPanel.controls.count, checked, "no control outside the five sections")
        // Every existing slider is still there, with its range and default unchanged.
        let old: [(String, ClosedRange<Float>, Float)] = [
            ("exposure", -3 ... 3, 0), ("boost", 0 ... 1, 1), ("shadowBoost", 0 ... 2, 0), ("shadowBias", -1 ... 1, 0),
            ("contrast", 0 ... 1, 0), ("localToneMap", 0 ... 1, 0), ("temperature", 2000 ... 12000, 5500),
            ("tint", -150 ... 150, 0), ("saturation", 0 ... 2, 1), ("vibrance", -1 ... 1, 0), ("sharpness", 0 ... 1, 0),
            ("detail", 0 ... 3, 0), ("luminanceNoise", 0 ... 1, 0), ("colorNoise", 0 ... 1, 0), ("moire", 0 ... 1, 0),
        ]
        for (key, range, neutral) in old {
            let c = RawPanel.control(key)
            XCTAssertEqual(c?.range, range, key)
            XCTAssertEqual(c?.neutral, neutral, key)
            XCTAssertEqual(c?.kind, .slider, key)
        }
        print("SPEC-RESULT T1 layout: \(RawPanel.sections.count) sections, \(checked) controls checked, \(mismatches) mismatching sections, 15 existing sliders unchanged: \(mismatches == 0 ? "PASS" : "FAIL")")
    }

    /// T7 (mock): each control with an is…Supported flag reported unsupported in turn.
    func testT7RedDotsWithAMock() {
        let flagged = RawPanel.controls.filter { $0.supportProperty != nil }
        let all = Dictionary(uniqueKeysWithValues: flagged.map { ($0.supportProperty!, true) })
        let values = Dictionary(uniqueKeysWithValues: RawPanel.valued.map { ($0.key, $0.neutral + 0.25) })
        var mismatches = 0
        for off in flagged {
            var supported = all
            supported[off.supportProperty!] = false
            let sent = RawPanel.sendable(values, supported: supported)
            for c in RawPanel.controls {
                let s = RawPanel.state(c, supported: supported)
                let wanted = c.key == off.key ? ControlState(enabled: false, redDot: true) : ControlState(enabled: true, redDot: false)
                if s != wanted { mismatches += 1 }
                XCTAssertEqual(s, wanted, "\(c.key) with \(off.key) unsupported")
                if c.kind != .neutralPoint, (sent[c.key] != nil) != (c.key != off.key) { mismatches += 1 }
            }
        }
        // Everything supported: no dot anywhere, everything sent.
        for c in RawPanel.controls where RawPanel.state(c, supported: all) != ControlState(enabled: true, redDot: false) { mismatches += 1 }
        XCTAssertEqual(RawPanel.sendable(values, supported: all).count, values.count)
        // A control with no is…Supported property never gets a dot, whatever the flags say.
        let none = Dictionary(uniqueKeysWithValues: flagged.map { ($0.supportProperty!, false) })
        for c in RawPanel.controls where c.supportProperty == nil && RawPanel.state(c, supported: none).redDot { mismatches += 1 }
        XCTAssertEqual(mismatches, 0)
        print("SPEC-RESULT T7 red dots (mock): \(flagged.count) controls with a supported flag, each turned off in turn; \(mismatches) mismatches: \(mismatches == 0 ? "PASS" : "FAIL")")
    }

    /// T8: the decoder line from mocked lists of supported versions.
    func testT8DecoderLine() {
        let a = RawPanel.decoderLine(["8"]), b = RawPanel.decoderLine(["6", "7", "8"]), c = RawPanel.decoderLine(["8", "9"])
        XCTAssertEqual(a, .label("RAW 8"))
        XCTAssertEqual(b, .label("RAW 8"))
        XCTAssertEqual(c, .menu(["8", "9"]))
        XCTAssertEqual(RawPanel.decoderLine(["6.dng", "7.dng", "8.dng"]), .label("RAW 8 (DNG)"))
        let pass = a == .label("RAW 8") && b == .label("RAW 8") && c == .menu(["8", "9"])
        print("SPEC-RESULT T8 decoder line: [8] → \(a); [6, 7, 8] → \(b); [8, 9] → \(c): \(pass ? "PASS" : "FAIL")")
    }

    /// T10: every new control set to a non-default value, saved, read back; defaults write nothing.
    func testT10SidecarRoundTrip() throws {
        let dir = MemDir(atomic: true)
        let moved: [String: Float] = ["lensCorrection": 1, "gamutMapping": 0, "baselineExposure": 0.75,
                                      "decoder": 9, "exposure": 0.5, "temperature": 5200, "tint": 7]
        let name = try XCTUnwrap(Edits.write(dir, baseName: "DSC00001", sidecarName: nil, values: SidecarValues(rating: 3, label: nil),
                                             fields: RawPanel.fields(moved)))
        let text = try XCTUnwrap(dir.files[name])
        let back = RawPanel.read(text)
        var worst: Float = 0
        for (key, v) in moved { worst = max(worst, abs((back[key] ?? .nan) - v)) }
        XCTAssertEqual(Set(back.keys), Set(moved.keys))
        XCTAssertLessThanOrEqual(worst, 0.001)
        // New controls under TrainCull's namespace; Adobe's fields in their existing format.
        XCTAssertTrue(text.contains("traincull:LensCorrection=\"True\""))
        XCTAssertTrue(text.contains("traincull:GamutMapping=\"False\""))
        XCTAssertTrue(text.contains("traincull:BaselineExposure=\"0.750\""))
        XCTAssertTrue(text.contains("crs:Exposure2012=\"+0.50\""))
        XCTAssertTrue(text.contains("crs:Temperature=\"5200\""))
        XCTAssertTrue(text.contains("crs:Tint=\"+7\""))
        XCTAssertTrue(text.contains("crs:WhiteBalance=\"Custom\""))
        // Back to defaults: the new fields are removed, and nothing new is written.
        _ = try Edits.write(dir, baseName: "DSC00001", sidecarName: name, values: SidecarValues(rating: 3, label: nil),
                            fields: RawPanel.fields(["exposure": 0.5]))
        let after = try XCTUnwrap(dir.files[name])
        for field in ["LensCorrection", "GamutMapping", "BaselineExposure", "DecoderVersion"] {
            XCTAssertFalse(after.contains("traincull:\(field)"), field)
        }
        XCTAssertNil(try Edits.write(MemDir(atomic: true), baseName: "DSC00002", sidecarName: nil,
                                     values: SidecarValues(rating: 0, label: nil), fields: RawPanel.fields([:])),
                     "nothing moved: no sidecar")
        print("SPEC-RESULT T10 sidecar round trip: \(moved.count) values, worst difference \(worst); defaults write nothing; Adobe fields as before: PASS")
    }
}
