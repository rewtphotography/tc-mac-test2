import Foundation

public struct RecipeError: Error, CustomStringConvertible {
    public let description: String
    public init(_ message: String) { description = message }
}

/// A format recipe: data (never code) describing where a raw format keeps its embedded JPEG
/// previews, orientation and (optionally) the camera's focus point. `RecipeReader` follows it.
/// ARW is built in (`BuiltInRecipes.arw`); others are imported.
///
/// Recipe file format, version 1 (JSON). This is a port of the Android app's
/// `format/Recipe.kt`; the format description lives there. The validation messages are the same.
public final class Recipe {
    public enum Structure { case tiff, header }

    public struct TiffPreview {
        public let fromSubIfds: Bool
        public let offsetTag: Int
        public let lengthTag: Int
        public let maxIfds: Int
        public let subIfdTag: Int
        public let requireTag: Int?
        public let requireValues: Set<Int64>
    }

    public struct HeaderPreview {
        public let offsetAt: Int64
        public let lengthAt: Int64
    }

    public enum OrientationRule: Equatable {
        case tag(Int)
        case embeddedJpeg
        case none
    }

    public enum Offsets { case file, makernote, embeddedTiff }

    public struct FocusRule {
        public let exifTag: Int
        public let makerNoteTag: Int
        public let prefix: String?
        public let skip: Int
        public let offsets: Offsets
        public let tag: Int
        public let values: [String]
        public let frameWidth: Int
        public let frameHeight: Int
    }

    public let id: String
    public let name: String
    public let extensions: [String]
    public let structure: Structure
    public let headerBytes: Int
    public let tiffPreviews: [TiffPreview]
    public let headerPreviews: [HeaderPreview]
    public let magic: String?
    public let bigEndian: Bool
    public let orientation: OrientationRule
    public let focus: FocusRule?
    /// The recipe file as imported, kept for export and re-parsing.
    public let source: String

    init(id: String, name: String, extensions: [String], structure: Structure, headerBytes: Int,
         tiffPreviews: [TiffPreview], headerPreviews: [HeaderPreview], magic: String?, bigEndian: Bool,
         orientation: OrientationRule, focus: FocusRule?, source: String) {
        self.id = id
        self.name = name
        self.extensions = extensions
        self.structure = structure
        self.headerBytes = headerBytes
        self.tiffPreviews = tiffPreviews
        self.headerPreviews = headerPreviews
        self.magic = magic
        self.bigEndian = bigEndian
        self.orientation = orientation
        self.focus = focus
        self.source = source
    }

    /// Short description for Settings, e.g. "TIFF · .nef · focus point".
    public var summary: String {
        var parts = [structure == .tiff ? "TIFF" : "fixed header"]
        parts.append(extensions.map { ".\($0)" }.joined(separator: ", "))
        if focus != nil { parts.append("focus point") }
        return parts.joined(separator: " · ")
    }

    public static let version = 1
    private static let reservedExtensions: Set<String> = ["xmp", "jpg", "jpeg", "tmp", "bak", "txt", "sha256"]

    private static func matches(_ s: String, _ pattern: String) -> Bool {
        s.range(of: "^(?:\(pattern))$", options: .regularExpression) != nil
    }

    /// Parses and checks a recipe file; throws `RecipeError` with a readable message if it's wrong.
    public static func parse(_ text: String) throws -> Recipe {
        if text.utf16.count > 64 * 1024 { throw RecipeError("recipe file is too large") }
        let parsed: Any
        do {
            parsed = try JSONSerialization.jsonObject(with: Data(text.utf8), options: [])
        } catch {
            throw RecipeError("the recipe isn't valid JSON")
        }
        guard let root = parsed as? [String: Any] else { throw RecipeError("a recipe must be a JSON object") }
        let r = Reader(root, "recipe")
        let version = try r.int("recipe")
        if version != Recipe.version {
            throw RecipeError("recipe format \(version) isn't supported by this traincull (it reads version \(Recipe.version))")
        }
        let id = try r.string("id")
        if !matches(id, "[a-z0-9][a-z0-9-]{0,39}") { throw RecipeError("id must be lower-case letters, digits and '-'") }
        let name = try r.string("name").trimmingCharacters(in: .whitespacesAndNewlines)
        if name.isEmpty || name.count > 60 { throw RecipeError("name must be 1–60 characters") }
        let exts: [String] = try r.list("extensions").map {
            guard let s = $0 as? String else { throw RecipeError("extensions must be strings") }
            let lower = s.lowercased()
            return lower.hasPrefix(".") ? String(lower.dropFirst()) : lower
        }
        if exts.isEmpty || exts.count > 10 { throw RecipeError("give 1–10 extensions") }
        for e in exts {
            if !matches(e, "[a-z0-9]{1,8}") { throw RecipeError("extension \"\(e)\" isn't valid") }
            if reservedExtensions.contains(e) { throw RecipeError("extension \"\(e)\" can't be a raw format") }
        }
        let structure: Structure
        switch try r.string("structure") {
        case "tiff": structure = .tiff
        case "header": structure = .header
        case let s: throw RecipeError("structure \"\(s)\" isn't supported (use \"tiff\" or \"header\")")
        }
        let headerBytes = try r.optInt("headerBytes") ?? 65536
        if !(4096 ... 4 * 1024 * 1024).contains(headerBytes) { throw RecipeError("headerBytes must be 4096–4194304") }
        let previews = try r.list("previews")
        if previews.isEmpty || previews.count > 8 { throw RecipeError("give 1–8 preview sources") }
        var tiffPreviews: [TiffPreview] = []
        var headerPreviews: [HeaderPreview] = []
        for (i, p) in previews.enumerated() {
            guard let m = p as? [String: Any] else { throw RecipeError("previews[\(i)] must be an object") }
            let pr = Reader(m, "previews[\(i)]")
            if structure == .tiff {
                let from = try pr.optString("from") ?? "chain"
                if from != "chain" && from != "subifds" { throw RecipeError("previews[\(i)].from must be \"chain\" or \"subifds\"") }
                let maxIfds = try pr.optInt("maxIfds") ?? 8
                if !(1 ... 16).contains(maxIfds) { throw RecipeError("previews[\(i)].maxIfds must be 1–16") }
                let require: Set<Int64> = Set(try (pr.optList("requireValues") ?? []).map {
                    guard let n = Reader.number($0) else { throw RecipeError("previews[\(i)].requireValues must be numbers") }
                    return n
                })
                tiffPreviews.append(TiffPreview(
                    fromSubIfds: from == "subifds",
                    offsetTag: try pr.optTag("offsetTag") ?? 0x0201,
                    lengthTag: try pr.optTag("lengthTag") ?? 0x0202,
                    maxIfds: maxIfds,
                    subIfdTag: try pr.optTag("subIfdTag") ?? 0x014A,
                    requireTag: try pr.optTag("requireTag"),
                    requireValues: require
                ))
            } else {
                let off = try pr.long("offsetAt")
                let len = try pr.long("lengthAt")
                if !(0 ... 1_000_000).contains(off) || !(0 ... 1_000_000).contains(len) {
                    throw RecipeError("previews[\(i)] positions must be within the first 1 MB")
                }
                headerPreviews.append(HeaderPreview(offsetAt: off, lengthAt: len))
            }
        }
        let magic = try r.optString("magic")
        let bigEndian: Bool
        switch try r.optString("byteOrder") ?? "big" {
        case "big": bigEndian = true
        case "little": bigEndian = false
        case let b: throw RecipeError("byteOrder must be \"big\" or \"little\", not \"\(b)\"")
        }
        var orientation = OrientationRule.none
        if let m = try r.optMap("orientation") {
            let o = Reader(m, "orientation")
            switch try o.optString("from") ?? "ifd0" {
            case "ifd0":
                if structure != .tiff { throw RecipeError("orientation from ifd0 needs the tiff structure") }
                orientation = .tag(try o.optTag("tag") ?? 0x0112)
            case "embedded-jpeg": orientation = .embeddedJpeg
            case "none": orientation = .none
            case let from: throw RecipeError("orientation.from \"\(from)\" isn't supported")
            }
        }
        var focus: FocusRule?
        if let m = try r.optMap("focus") {
            if structure != .tiff { throw RecipeError("focus is only supported for the tiff structure") }
            let f = Reader(m, "focus")
            let mn = try f.optMap("makerNote").map { Reader($0, "focus.makerNote") }
            let values: [String] = try f.list("values").map {
                guard let s = $0 as? String else { throw RecipeError("focus.values must be names") }
                return s
            }
            let known: Set<String> = ["width", "height", "x", "y", "_"]
            for v in values where !known.contains(v) {
                throw RecipeError("focus.values: \"\(v)\" isn't one of width, height, x, y, _")
            }
            if !values.contains("x") || !values.contains("y") { throw RecipeError("focus.values must include x and y") }
            let offsets: Offsets
            switch try mn?.optString("offsets") ?? "file" {
            case "file": offsets = .file
            case "makernote": offsets = .makernote
            case "embedded-tiff": offsets = .embeddedTiff
            case let o: throw RecipeError("focus.makerNote.offsets \"\(o)\" isn't supported")
            }
            focus = FocusRule(
                exifTag: try f.optTag("exifTag") ?? 0x8769,
                makerNoteTag: try f.optTag("makerNoteTag") ?? 0x927C,
                prefix: try mn?.optString("prefix"),
                skip: try mn?.optInt("skip") ?? 0,
                offsets: offsets,
                tag: try f.tag("tag"),
                values: values,
                frameWidth: try f.optInt("frameWidth") ?? 0,
                frameHeight: try f.optInt("frameHeight") ?? 0
            )
        }
        return Recipe(id: id, name: name, extensions: exts, structure: structure, headerBytes: headerBytes,
                      tiffPreviews: tiffPreviews, headerPreviews: headerPreviews, magic: magic, bigEndian: bigEndian,
                      orientation: orientation, focus: focus, source: text)
    }

    /// Typed access to a JSON object with clear error messages.
    private struct Reader {
        let m: [String: Any]
        let place: String

        init(_ m: [String: Any], _ place: String) {
            self.m = m
            self.place = place
        }

        /// A JSON number as an integer; nil for text, booleans and anything else.
        static func number(_ v: Any?) -> Int64? {
            guard let v = v, !(v is String), !(v is NSNull) else { return nil }
            if let n = v as? NSNumber {
                #if canImport(Darwin)
                if CFGetTypeID(n) == CFBooleanGetTypeID() { return nil }
                #endif
                return n.int64Value
            }
            return nil
        }

        func has(_ k: String) -> Bool { m[k] != nil && !(m[k] is NSNull) }

        func string(_ k: String) throws -> String {
            guard let s = m[k] as? String else { throw RecipeError("\(place).\(k) must be text") }
            return s
        }

        func optString(_ k: String) throws -> String? { has(k) ? try string(k) : nil }

        func long(_ k: String) throws -> Int64 {
            guard let n = Reader.number(m[k]) else { throw RecipeError("\(place).\(k) must be a number") }
            return n
        }

        func int(_ k: String) throws -> Int { Int(try long(k)) }
        func optInt(_ k: String) throws -> Int? { has(k) ? try int(k) : nil }

        func list(_ k: String) throws -> [Any] {
            guard let l = m[k] as? [Any] else { throw RecipeError("\(place).\(k) must be a list") }
            return l
        }

        func optList(_ k: String) throws -> [Any]? { has(k) ? try list(k) : nil }

        func optMap(_ k: String) throws -> [String: Any]? {
            guard has(k) else { return nil }
            guard let v = m[k] as? [String: Any] else { throw RecipeError("\(place).\(k) must be an object") }
            return v
        }

        func tag(_ k: String) throws -> Int {
            var t: Int64?
            if let s = m[k] as? String {
                t = s.lowercased().hasPrefix("0x") ? Int64(s.dropFirst(2), radix: 16) : Int64(s)
            } else {
                t = Reader.number(m[k])
            }
            guard let value = t else { throw RecipeError("\(place).\(k) must be a tag number like \"0x0112\"") }
            if !(0 ... 0xFFFF).contains(value) { throw RecipeError("\(place).\(k) is out of range") }
            return Int(value)
        }

        func optTag(_ k: String) throws -> Int? { has(k) ? try tag(k) : nil }
    }
}

/// Recipes that ship with TrainCull. ARW is the reference the recipe reader must match.
public enum BuiltInRecipes {
    /// Sony ARW (α7 IV): IFD0 preview, IFD1 thumbnail, IFD2 full JPEG; FocusLocation in the maker note.
    /// Copied verbatim from the Android app.
    public static let arwJson = """
    {
      "recipe": 1,
      "id": "sony-arw",
      "name": "Sony ARW",
      "extensions": ["arw"],
      "structure": "tiff",
      "headerBytes": 65536,
      "previews": [
        { "from": "chain", "maxIfds": 8, "offsetTag": "0x0201", "lengthTag": "0x0202" }
      ],
      "orientation": { "from": "ifd0", "tag": "0x0112" },
      "focus": {
        "exifTag": "0x8769",
        "makerNoteTag": "0x927C",
        "makerNote": { "prefix": "SONY", "skip": 12, "offsets": "file" },
        "tag": "0x2027",
        "values": ["width", "height", "x", "y"]
      }
    }
    """

    public static let arw: Recipe = try! Recipe.parse(arwJson)

    public static let all: [Recipe] = [arw]
}
