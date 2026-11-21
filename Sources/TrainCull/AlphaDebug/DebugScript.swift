#if TC_ALPHA_DEBUG
import Foundation
import TraincullCore

// Alpha-only debug tools: test scripts (Debug ▸ Run Test Script…). This file reads and checks a
// script; nothing here touches the screen or the photos. See README.md in this folder.

// MARK: JSON, with each value's place in the text

/// A JSON value that remembers where it sits in the text, so a script's case can be copied into
/// its report exactly as written, and keys keep their order.
struct DebugJSON {
    indirect enum Kind {
        case object([(key: String, value: DebugJSON)])
        case array([DebugJSON])
        case string(String)
        case number(Double)
        case bool(Bool)
        case null
    }

    let kind: Kind
    /// Byte offsets of the value in the UTF-8 text.
    let start: Int
    let end: Int

    struct Failure: Error, CustomStringConvertible {
        let description: String
    }

    static func parse(_ text: String) throws -> DebugJSON {
        var p = Parser(bytes: Array(text.utf8))
        p.skipSpace()
        let value = try p.value()
        p.skipSpace()
        if p.i != p.bytes.count { throw p.fail("unexpected text after the end") }
        return value
    }

    func raw(in text: String) -> String {
        String(decoding: Array(text.utf8)[start ..< end], as: UTF8.self)
    }

    subscript(key: String) -> DebugJSON? {
        if case let .object(pairs) = kind { return pairs.first { $0.key == key }?.value }
        return nil
    }

    private struct Parser {
        let bytes: [UInt8]
        var i = 0

        func fail(_ what: String) -> Failure {
            var line = 1, column = 1
            for b in bytes[0 ..< min(i, bytes.count)] {
                if b == 0x0A { line += 1; column = 1 } else { column += 1 }
            }
            return Failure(description: "malformed JSON at line \(line), column \(column): \(what)")
        }

        mutating func skipSpace() {
            while i < bytes.count, [0x20, 0x09, 0x0A, 0x0D].contains(bytes[i]) { i += 1 }
        }

        mutating func expect(_ s: String) throws {
            let b = Array(s.utf8)
            guard i + b.count <= bytes.count, Array(bytes[i ..< i + b.count]) == b else { throw fail("expected \(s)") }
            i += b.count
        }

        mutating func value() throws -> DebugJSON {
            guard i < bytes.count else { throw fail("unexpected end") }
            let start = i
            let kind: Kind
            switch bytes[i] {
            case UInt8(ascii: "{"):
                i += 1
                var pairs: [(key: String, value: DebugJSON)] = []
                skipSpace()
                if i < bytes.count, bytes[i] == UInt8(ascii: "}") {
                    i += 1
                } else {
                    while true {
                        skipSpace()
                        guard i < bytes.count, bytes[i] == UInt8(ascii: "\"") else { throw fail("expected a key in quotes") }
                        let key = try string()
                        if pairs.contains(where: { $0.key == key }) { throw fail("the key \"\(key)\" appears twice") }
                        skipSpace()
                        try expect(":")
                        skipSpace()
                        pairs.append((key, try value()))
                        skipSpace()
                        guard i < bytes.count else { throw fail("unexpected end") }
                        if bytes[i] == UInt8(ascii: ",") { i += 1; continue }
                        if bytes[i] == UInt8(ascii: "}") { i += 1; break }
                        throw fail("expected , or }")
                    }
                }
                kind = .object(pairs)
            case UInt8(ascii: "["):
                i += 1
                var items: [DebugJSON] = []
                skipSpace()
                if i < bytes.count, bytes[i] == UInt8(ascii: "]") {
                    i += 1
                } else {
                    while true {
                        skipSpace()
                        items.append(try value())
                        skipSpace()
                        guard i < bytes.count else { throw fail("unexpected end") }
                        if bytes[i] == UInt8(ascii: ",") { i += 1; continue }
                        if bytes[i] == UInt8(ascii: "]") { i += 1; break }
                        throw fail("expected , or ]")
                    }
                }
                kind = .array(items)
            case UInt8(ascii: "\""):
                kind = .string(try string())
            case UInt8(ascii: "t"):
                try expect("true"); kind = .bool(true)
            case UInt8(ascii: "f"):
                try expect("false"); kind = .bool(false)
            case UInt8(ascii: "n"):
                try expect("null"); kind = .null
            default:
                kind = .number(try number())
            }
            return DebugJSON(kind: kind, start: start, end: i)
        }

        mutating func string() throws -> String {
            i += 1 // the opening quote
            var out: [UInt8] = []
            while i < bytes.count {
                let b = bytes[i]
                if b == UInt8(ascii: "\"") {
                    i += 1
                    return String(decoding: out, as: UTF8.self)
                }
                if b == UInt8(ascii: "\\") {
                    i += 1
                    guard i < bytes.count else { break }
                    switch bytes[i] {
                    case UInt8(ascii: "n"): out.append(0x0A)
                    case UInt8(ascii: "t"): out.append(0x09)
                    case UInt8(ascii: "r"): out.append(0x0D)
                    case UInt8(ascii: "b"): out.append(0x08)
                    case UInt8(ascii: "f"): out.append(0x0C)
                    case UInt8(ascii: "u"):
                        guard i + 4 < bytes.count, let code = UInt32(String(decoding: bytes[i + 1 ... i + 4], as: UTF8.self), radix: 16),
                              let scalar = Unicode.Scalar(code) else { throw fail("bad \\u escape") }
                        out += Array(String(Character(scalar)).utf8)
                        i += 4
                    default: out.append(bytes[i])
                    }
                    i += 1
                    continue
                }
                if b < 0x20 { throw fail("a control character inside a string") }
                out.append(b)
                i += 1
            }
            throw fail("a string is not closed")
        }

        mutating func number() throws -> Double {
            let start = i
            while i < bytes.count, "+-0123456789.eE".utf8.contains(bytes[i]) { i += 1 }
            guard i > start, let v = Double(String(decoding: bytes[start ..< i], as: UTF8.self)) else { throw fail("expected a value") }
            return v
        }
    }
}

// MARK: The script

/// One value a case sets.
enum DebugValue: Equatable {
    case number(Double)
    case bool(Bool)
    /// "min" or "max", already turned into the slider's end.
    case resolved(Double, keyword: String)
    /// "default": Apple's own default for the file, found when the case runs.
    case appleDefault
    /// neutralLocation: a point as fractions of the frame.
    case point(Double, Double)
    /// decoderVersion: one of Apple's version strings ("8", "8.dng").
    case decoder(String)
}

struct DebugCase {
    let number: Int
    let file: String
    /// Script key (Apple's property name, or tc.saturation / tc.vibrance) and value, in order.
    let set: [(key: String, value: DebugValue)]
    /// x, y, width, height as fractions of the frame.
    let crop: [Double]?
    let fullResTIFF: Bool
    let allowOutOfRange: Bool
    /// The case exactly as the script wrote it.
    let raw: String
}

struct DebugScript {
    let scriptNumber: Int
    let name: String
    let index: [String]
    let cases: [DebugCase]
    let text: String

    static func testId(_ script: Int, _ number: Int) -> String { String(format: "%02d%02d", script, number) }
}

/// What a script key means.
enum DebugKey {
    /// One of the panel's controls, by its key.
    case control(String)
    case neutralLocation
    case decoderVersion
    /// isHighlightRecoveryEnabled: recognised, but not in Apple's raw filter before macOS 27.
    case highlightRecovery

    static func of(_ key: String) -> DebugKey? {
        switch key {
        case "neutralLocation": return .neutralLocation
        case "decoderVersion": return .decoderVersion
        case "isHighlightRecoveryEnabled": return .highlightRecovery
        case "tc.saturation": return .control("saturation")
        case "tc.vibrance": return .control("vibrance")
        default:
            guard let c = RawPanel.controls.first(where: { $0.appleProperty == key && ($0.kind == .slider || $0.kind == .toggle) }) else { return nil }
            return .control(c.key)
        }
    }

    static let known: [String] = RawPanel.controls.filter { ($0.kind == .slider || $0.kind == .toggle) && !$0.appleProperty.contains(" ") }.map { $0.appleProperty }
        + ["neutralLocation", "decoderVersion", "isHighlightRecoveryEnabled", "tc.saturation", "tc.vibrance"]
}

struct DebugValidation {
    var script: DebugScript?
    var errors: [String] = []
    var warnings: [String] = []
    var canRun: Bool { script != nil && errors.isEmpty }
}

enum DebugScriptReader {
    static let topKeys: Set<String> = ["scriptNumber", "name", "index", "cases"]
    static let caseKeys: Set<String> = ["case", "file", "set", "crop", "fullResTIFF", "allowOutOfRange"]

    /// Checks a script strictly, before anything is rendered. `fileExists` says whether a file
    /// is in the open folder.
    static func validate(_ text: String, fileExists: (String) -> Bool) -> DebugValidation {
        var v = DebugValidation()
        let json: DebugJSON
        do {
            json = try DebugJSON.parse(text)
        } catch {
            v.errors.append("\(error)")
            return v
        }
        guard case let .object(top) = json.kind else {
            v.errors.append("malformed JSON: the script must be one object { … }")
            return v
        }
        for (key, _) in top where !topKeys.contains(key) { v.errors.append("unknown key \"\(key)\" at the top of the script") }

        var scriptNumber = 0
        if case let .number(n)? = json["scriptNumber"]?.kind, n == n.rounded() {
            scriptNumber = Int(n)
            if scriptNumber < 1 || scriptNumber > 99 { v.errors.append("scriptNumber \(scriptNumber) is out of range: use 1–99 (00 is for manual exports)") }
        } else {
            v.errors.append("scriptNumber is missing or not a whole number")
        }
        var name = ""
        if case let .string(s)? = json["name"]?.kind { name = s } else { v.errors.append("name is missing or not text") }
        var index: [String] = []
        if let node = json["index"] {
            if case let .array(items) = node.kind {
                for item in items {
                    if case let .string(s) = item.kind { index.append(s) } else { v.errors.append("index must hold only text lines") }
                }
            } else {
                v.errors.append("index must be a list of text lines")
            }
        }
        guard case let .array(caseNodes)? = json["cases"]?.kind, !caseNodes.isEmpty else {
            v.errors.append("cases is missing, empty or not a list")
            return v
        }

        var cases: [DebugCase] = []
        var seen = Set<Int>()
        for (n, node) in caseNodes.enumerated() {
            let label = "case \(n + 1) in the list"
            guard case let .object(pairs) = node.kind else {
                v.errors.append("\(label) is not an object")
                continue
            }
            var errors: [String] = []
            for (key, _) in pairs where !caseKeys.contains(key) {
                errors.append(key == "files" ? "more than one file in one case (\"files\"): give each file its own case" : "unknown key \"\(key)\"")
            }
            var number = 0
            if case let .number(c)? = node["case"]?.kind, c == c.rounded() {
                number = Int(c)
                if number < 1 || number > 99 { errors.append("case \(number) is out of range: use 1–99") }
                if !seen.insert(number).inserted { errors.append("duplicate case \(number)") }
            } else {
                errors.append("case number missing or not a whole number")
            }
            let id = number > 0 ? "\(DebugScript.testId(scriptNumber, number))" : label
            var file = ""
            switch node["file"]?.kind {
            case let .string(s)?:
                file = s
                if s.contains("/") { errors.append("file must be a name in the open folder, not a path") } else if !fileExists(s) { errors.append("missing file \(s): it isn't in the open folder") }
            case let .array(items)?:
                errors.append(items.count > 1 ? "more than one file in one case: give each file its own case" : "file must be one name, not a list")
            default:
                errors.append("file is missing")
            }
            var allow = false
            if let a = node["allowOutOfRange"] {
                if case let .bool(b) = a.kind { allow = b } else { errors.append("allowOutOfRange must be true or false") }
            }
            var tiff = false
            if let t = node["fullResTIFF"] {
                if case let .bool(b) = t.kind { tiff = b } else { errors.append("fullResTIFF must be true or false") }
            }
            var crop: [Double]?
            if let c = node["crop"] {
                if case let .array(items) = c.kind, items.count == 4,
                   case let numbers = items.compactMap({ item -> Double? in if case let .number(x) = item.kind { return x }; return nil }), numbers.count == 4 {
                    let (x, y, w, h) = (numbers[0], numbers[1], numbers[2], numbers[3])
                    if x < 0 || y < 0 || w <= 0 || h <= 0 || x + w > 1.000001 || y + h > 1.000001 {
                        errors.append("crop [\(numbers.map { String($0) }.joined(separator: ", "))] must lie inside the frame (fractions 0–1, width and height above 0)")
                    } else {
                        crop = numbers
                    }
                } else {
                    errors.append("crop must be [x, y, width, height] as four fractions")
                }
            }
            var set: [(key: String, value: DebugValue)] = []
            if case let .object(setPairs)? = node["set"]?.kind {
                for (key, value) in setPairs {
                    switch parseValue(key, value, allowOutOfRange: allow) {
                    case let .success(parsed):
                        set.append((key, parsed.value))
                        if let warning = parsed.warning { v.warnings.append("\(id): \(warning)") }
                    case let .failure(error):
                        errors.append(error.description)
                    }
                }
                let keys = set.map { $0.key }
                if keys.contains("neutralLocation") && (keys.contains("neutralTemperature") || keys.contains("neutralTint")) {
                    errors.append("neutralLocation sets the temperature and tint itself: don't combine it with neutralTemperature or neutralTint")
                }
                if keys.contains("isHighlightRecoveryEnabled") {
                    v.warnings.append("\(id): isHighlightRecoveryEnabled requires macOS 27; this case will be skipped")
                }
            } else if node["set"] != nil {
                errors.append("set must be an object of Apple property names and values")
            }
            if errors.isEmpty {
                cases.append(DebugCase(number: number, file: file, set: set, crop: crop, fullResTIFF: tiff, allowOutOfRange: allow, raw: node.raw(in: text)))
            }
            v.errors += errors.map { "\(id): \($0)" }
        }
        if v.errors.isEmpty {
            v.script = DebugScript(scriptNumber: scriptNumber, name: name, index: index, cases: cases.sorted { $0.number < $1.number }, text: text)
        }
        return v
    }

    struct ValueError: Error, CustomStringConvertible { let description: String }

    static func parseValue(_ key: String, _ node: DebugJSON, allowOutOfRange: Bool) -> Result<(value: DebugValue, warning: String?), ValueError> {
        guard let meaning = DebugKey.of(key) else {
            return .failure(ValueError(description: "unknown key \"\(key)\" in set (use Apple's CIRAWFilter property names, or tc.saturation / tc.vibrance)"))
        }
        if case let .string(s) = node.kind, s == "default" { return .success((.appleDefault, nil)) }
        switch meaning {
        case .highlightRecovery:
            if case let .bool(b) = node.kind { return .success((.bool(b), nil)) }
            return .failure(ValueError(description: "\(key) takes true, false or \"default\""))
        case .neutralLocation:
            if case let .array(items) = node.kind, items.count == 2,
               case let .number(x) = items[0].kind, case let .number(y) = items[1].kind, (0 ... 1).contains(x), (0 ... 1).contains(y) {
                return .success((.point(x, y), nil))
            }
            return .failure(ValueError(description: "neutralLocation takes [x, y] as fractions of the frame (0–1)"))
        case .decoderVersion:
            switch node.kind {
            case let .string(s) where RawPanel.major(s) != nil: return .success((.decoder(s), nil))
            case let .number(n) where n == n.rounded(): return .success((.decoder(String(Int(n))), nil))
            default: return .failure(ValueError(description: "decoderVersion takes Apple's version, such as \"8\" or \"8.dng\", or \"default\""))
            }
        case let .control(controlKey):
            guard let c = RawPanel.control(controlKey) else { return .failure(ValueError(description: "unknown key \"\(key)\"")) }
            if c.kind == .toggle {
                if case let .bool(b) = node.kind { return .success((.bool(b), nil)) }
                return .failure(ValueError(description: "\(key) takes true, false or \"default\""))
            }
            switch node.kind {
            case let .string(s) where s == "min": return .success((.resolved(Double(c.range.lowerBound), keyword: "min"), nil))
            case let .string(s) where s == "max": return .success((.resolved(Double(c.range.upperBound), keyword: "max"), nil))
            case let .number(n):
                let inside = Double(c.range.lowerBound) - 1e-9 ... Double(c.range.upperBound) + 1e-9
                if inside.contains(n) { return .success((.number(n), nil)) }
                if allowOutOfRange {
                    return .success((.number(n), "\(key) = \(n) is outside the slider (\(c.range.lowerBound)…\(c.range.upperBound)); sent to Apple as it is"))
                }
                return .failure(ValueError(description: "\(key) = \(n) is out of range (\(c.range.lowerBound)…\(c.range.upperBound)); add \"allowOutOfRange\": true to send it anyway"))
            default:
                return .failure(ValueError(description: "\(key) takes a number, \"min\", \"max\" or \"default\""))
            }
        }
    }
}

// MARK: Names and sizes

enum DebugNames {
    static func runFolder(script: Int, at date: Date) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyyMMdd-HHmmss"
        return String(format: "script-%02d_", script) + f.string(from: date)
    }

    /// "8" stays "8"; "8.dng" becomes "8dng".
    static func decoderTag(_ version: String) -> String { version.lowercased().replacingOccurrences(of: ".", with: "") }

    static func baseline(stem: String, decoder: String, script: Int) -> String {
        "\(stem)-baseline-raw\(decoderTag(decoder))-" + String(format: "%02d", script) + ".png"
    }

    static func zip(_ testId: String) -> String { "TC-test-\(testId).zip" }
}

/// Size estimates for the validation dialog, from the frame's size alone (nothing is rendered
/// before Run). PNG compression of a photo varies with its noise; the factors are averages.
enum DebugEstimate {
    static let frameLongEdge = 3000
    static let pngBytesPerPixel8 = 1.7 // 3 channels, compressed (measured on the made-up DNG: 1.65)
    static let pngBytesPerPixel16 = 4.5 // 4 channels of 16 bits, compressed (measured: 4.1)
    static let tiffBytesPerPixel = 5.0
    static let reportBytes = 9_000
    static let zipOverheadPerFile = 120

    static func frameSize(_ w: Int, _ h: Int) -> (Int, Int) {
        let k = min(1, Double(frameLongEdge) / Double(max(w, h, 1)))
        return (Int((Double(w) * k).rounded()), Int((Double(h) * k).rounded()))
    }

    static func cropSize(_ crop: [Double], _ w: Int, _ h: Int) -> (Int, Int) {
        (max(1, Int((crop[2] * Double(w)).rounded())), max(1, Int((crop[3] * Double(h)).rounded())))
    }

    static func frame(_ w: Int, _ h: Int) -> Int {
        let (fw, fh) = frameSize(w, h)
        return Int(Double(fw * fh) * pngBytesPerPixel8)
    }

    /// One zip: frame, crop and crop-default if asked, the TIFF if asked, and the report.
    static func zip(_ c: DebugCase, width w: Int, height h: Int, screen: Bool = false) -> Int {
        var bytes = frame(w, h) + reportBytes + 3 * zipOverheadPerFile
        if let crop = c.crop {
            let (cw, ch) = cropSize(crop, w, h)
            bytes += 2 * Int(Double(cw * ch) * pngBytesPerPixel16) + 2 * zipOverheadPerFile
        }
        if c.fullResTIFF { bytes += Int(Double(w * h) * tiffBytesPerPixel) + zipOverheadPerFile }
        if screen { bytes += frame(w, h) + zipOverheadPerFile }
        return bytes
    }

    static func plain(_ bytes: Int) -> String {
        bytes >= 1_000_000 ? String(format: "%.1f MB", Double(bytes) / 1_000_000) : String(format: "%.0f KB", Double(bytes) / 1_000)
    }
}
#endif
