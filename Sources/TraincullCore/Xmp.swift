import Foundation

/// Reads and edits `xmp:Rating` and `xmp:Label` in Adobe-style XMP sidecars without touching
/// anything else. Ratings: 1–5 stars, 0 = none, -1 = reject (Bridge's convention). Labels are
/// plain text that Bridge matches by name ("Select", "Second", "Approved", "Review", "To Do").
/// A port of the Android app's `xmp/Xmp.kt`.
public enum Xmp {
    private static func regex(_ p: String) -> NSRegularExpression { try! NSRegularExpression(pattern: p) }

    private static let attr = regex(#"(\bxmp:Rating\s*=\s*)(["'])([^"']*)\2"#)
    private static let elem = regex(#"(<xmp:Rating>)([^<]*)(</xmp:Rating>)"#)
    private static let labelAttr = regex(#"(\s*)\bxmp:Label\s*=\s*(["'])([^"']*)\2"#)
    private static let labelElem = regex(#"([ \t]*)<xmp:Label>([^<]*)</xmp:Label>(\r?\n)?"#)
    private static let description = regex(#"<rdf:Description\b"#)
    private static let xmpNs = "http://ns.adobe.com/xap/1.0/"

    private static func find(_ r: NSRegularExpression, _ text: String) -> NSTextCheckingResult? {
        r.firstMatch(in: text, range: NSRange(location: 0, length: (text as NSString).length))
    }

    private static func group(_ m: NSTextCheckingResult, _ i: Int, _ text: String) -> String {
        (text as NSString).substring(with: m.range(at: i))
    }

    private static func replacing(_ text: String, _ range: NSRange, _ with: String) -> String {
        (text as NSString).replacingCharacters(in: range, with: with)
    }

    public static func readRating(_ text: String) -> Int? {
        let v: String
        if let m = find(attr, text) {
            v = group(m, 3, text)
        } else if let m = find(elem, text) {
            v = group(m, 2, text)
        } else {
            return nil
        }
        guard let d = Double(v.trimmingCharacters(in: .whitespacesAndNewlines)), d.isFinite, abs(d) < 1e9 else { return nil }
        return Int(d)
    }

    /// A sidecar written completely ends with the closing xmpmeta tag.
    public static func isComplete(_ text: String) -> Bool { text.contains("</x:xmpmeta>") }

    public static func newSidecar(_ rating: Int, _ label: String? = nil) -> String {
        let labelLine = label.map { "\n   xmp:Label=\"\(escape($0))\"" } ?? ""
        return "<x:xmpmeta xmlns:x=\"adobe:ns:meta/\" x:xmptk=\"traincull\">\n"
            + " <rdf:RDF xmlns:rdf=\"http://www.w3.org/1999/02/22-rdf-syntax-ns#\">\n"
            + "  <rdf:Description rdf:about=\"\"\n"
            + "    xmlns:xmp=\"\(xmpNs)\"\n"
            + "   xmp:Rating=\"\(rating)\"\(labelLine)/>\n"
            + " </rdf:RDF>\n"
            + "</x:xmpmeta>\n"
    }

    /// The colour label's text, or nil when there is none.
    public static func readLabel(_ text: String) -> String? {
        let v: String
        if let m = find(labelAttr, text) {
            v = group(m, 3, text)
        } else if let m = find(labelElem, text) {
            v = group(m, 2, text)
        } else {
            return nil
        }
        let t = unescape(v).trimmingCharacters(in: .whitespacesAndNewlines)
        return t.isEmpty ? nil : t
    }

    /// Returns `existing` with only the label changed (`label` nil removes it), a fresh sidecar
    /// when `existing` is nil, or nil when the file has no place to put a label (left untouched).
    public static func withLabel(_ existing: String?, _ label: String?) -> String? {
        guard let existing = existing else { return newSidecar(0, label) }
        if let m = find(labelAttr, existing) {
            return label == nil ? replacing(existing, m.range, "") : replacing(existing, m.range(at: 3), escape(label!))
        }
        if let m = find(labelElem, existing) {
            return label == nil ? replacing(existing, m.range, "") : replacing(existing, m.range(at: 2), escape(label!))
        }
        guard let label = label else { return existing }
        return addAttribute(existing, "xmp:Label=\"\(escape(label))\"")
    }

    private static func escape(_ s: String) -> String {
        s.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;").replacingOccurrences(of: "\"", with: "&quot;")
            .replacingOccurrences(of: "'", with: "&apos;")
    }

    private static func unescape(_ s: String) -> String {
        s.replacingOccurrences(of: "&quot;", with: "\"").replacingOccurrences(of: "&apos;", with: "'")
            .replacingOccurrences(of: "&lt;", with: "<").replacingOccurrences(of: "&gt;", with: ">")
            .replacingOccurrences(of: "&amp;", with: "&")
    }

    /// Returns `existing` with only the rating changed, a fresh sidecar when `existing` is nil,
    /// or nil when the existing file has no place to put a rating (it is then left untouched).
    public static func withRating(_ existing: String?, _ rating: Int) -> String? {
        guard let existing = existing else { return newSidecar(rating) }
        if let m = find(attr, existing) { return replacing(existing, m.range(at: 3), String(rating)) }
        if let m = find(elem, existing) { return replacing(existing, m.range(at: 2), String(rating)) }
        // No rating yet: add an attribute to the first rdf:Description.
        return addAttribute(existing, "xmp:Rating=\"\(rating)\"")
    }

    // MARK: Other fields

    /// A namespace a field lives in, e.g. Camera Raw's settings or TrainCull's own.
    public struct Namespace {
        public let prefix: String
        public let uri: String

        public init(prefix: String, uri: String) {
            self.prefix = prefix
            self.uri = uri
        }

        /// Adobe Camera Raw's settings, which Photoshop, Lightroom and Bridge read.
        public static let cameraRaw = Namespace(prefix: "crs", uri: "http://ns.adobe.com/camera-raw-settings/1.0/")
        /// TrainCull's own adjustment values that have no equivalent other apps read.
        public static let trainCull = Namespace(prefix: "traincull", uri: "http://ns.traincull.app/1.0/")
    }

    private static func fieldPatterns(_ name: String) -> (NSRegularExpression, NSRegularExpression) {
        let n = NSRegularExpression.escapedPattern(for: name)
        return (regex(#"(\s*)\b"# + n + #"\s*=\s*(["'])([^"']*)\2"#),
                regex(#"([ \t]*)<"# + n + #">([^<]*)</"# + n + #">(\r?\n)?"#))
    }

    /// The value of one field such as "crs:Exposure2012", in attribute or element form.
    public static func readField(_ text: String, _ name: String) -> String? {
        let (attribute, element) = fieldPatterns(name)
        if let m = find(attribute, text) { return unescape(group(m, 3, text)) }
        if let m = find(element, text) { return unescape(group(m, 2, text)) }
        return nil
    }

    /// Returns `existing` with only that one field changed (`value` nil removes it), or nil when
    /// the file has no place to put it (it is then left untouched).
    public static func withField(_ existing: String, _ ns: Namespace, _ local: String, _ value: String?) -> String? {
        let name = "\(ns.prefix):\(local)"
        let (attribute, element) = fieldPatterns(name)
        if let m = find(attribute, existing) {
            return value == nil ? replacing(existing, m.range, "") : replacing(existing, m.range(at: 3), escape(value!))
        }
        if let m = find(element, existing) {
            return value == nil ? replacing(existing, m.range, "") : replacing(existing, m.range(at: 2), escape(value!))
        }
        guard let value = value else { return existing }
        return addAttribute(existing, "\(name)=\"\(escape(value))\"", ns)
    }

    /// Adds `attr` to the first rdf:Description (declaring its namespace if missing); nil if there is none.
    private static func addAttribute(_ existing: String, _ attr: String, _ space: Namespace = Namespace(prefix: "xmp", uri: xmpNs)) -> String? {
        let ns = existing as NSString
        guard let start = find(description, existing) else { return nil }
        guard let end = tagEnd(ns, start.range.location + start.range.length) else { return nil }
        let selfClosing = ns.character(at: end - 1) == 0x2F // '/'
        let insertAt = selfClosing ? end - 1 : end
        let tag = ns.substring(with: NSRange(location: start.range.location, length: end - start.range.location))
        let declared = regex(#"\bxmlns:"# + NSRegularExpression.escapedPattern(for: space.prefix) + #"\s*="#)
        let declaration = find(declared, tag) != nil ? "" : "\n    xmlns:\(space.prefix)=\"\(space.uri)\""
        return ns.substring(to: insertAt) + declaration + "\n   " + attr + ns.substring(from: insertAt)
    }

    /// Index of the '>' closing the tag that starts before `from`, skipping quoted values.
    private static func tagEnd(_ s: NSString, _ from: Int) -> Int? {
        var quote: unichar = 0
        var i = from
        while i < s.length {
            let c = s.character(at: i)
            if quote != 0 {
                if c == quote { quote = 0 }
            } else if c == 0x22 || c == 0x27 {
                quote = c
            } else if c == 0x3E {
                return i
            }
            i += 1
        }
        return nil
    }
}
