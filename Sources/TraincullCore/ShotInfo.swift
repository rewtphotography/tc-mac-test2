import Foundation

/// Camera settings for the settings line, e.g. "85mm @ f/2.8 · 1/250s · 400 ISO · a7IV".
/// Any part the file doesn't record is left out. A port of the Android app's `format/ShotInfo.kt`.
public struct ShotInfo: Equatable {
    public var focalMm: Double?
    public var fNumber: Double?
    public var exposureS: Double?
    public var iso: Int?
    /// The EXIF Model tag as recorded, e.g. "ILCE-7M4" or "NIKON D800E".
    public var model: String?

    public init(focalMm: Double? = nil, fNumber: Double? = nil, exposureS: Double? = nil, iso: Int? = nil, model: String? = nil) {
        self.focalMm = focalMm
        self.fNumber = fNumber
        self.exposureS = exposureS
        self.iso = iso
        self.model = model
    }

    public var isEmpty: Bool { focalMm == nil && fNumber == nil && exposureS == nil && iso == nil && model == nil }

    public func label() -> String {
        var parts: [String] = []
        let lens = [focalMm.map { "\(ShotInfo.num($0))mm" }, fNumber.map { "f/\(ShotInfo.num($0))" }].compactMap { $0 }
        if !lens.isEmpty { parts.append(lens.joined(separator: " @ ")) }
        if let s = exposureS { parts.append(ShotInfo.shutter(s)) }
        if let i = iso { parts.append("\(i) ISO") }
        if let m = model { parts.append(ShotInfo.cameraName(m)) }
        return parts.joined(separator: " · ")
    }

    /// Reads the settings from a TIFF-style file: model in IFD0, the rest in its Exif IFD.
    public static func fromTiff(_ tiff: Tiff, _ ifd0: Ifd) -> ShotInfo? {
        let exif = tiff.value(ifd0, 0x8769).flatMap { try? tiff.readIfd($0) }
        func positive(_ tag: Int) -> Double? {
            guard let e = exif, let v = tiff.rational(e, tag), v > 0 else { return nil }
            return v
        }
        var iso: Int?
        if let e = exif, let v = tiff.value(e, 0x8827), (1 ... 9_999_999).contains(v) { iso = Int(v) }
        let shot = ShotInfo(focalMm: positive(0x920A), fNumber: positive(0x829D), exposureS: positive(0x829A),
                            iso: iso, model: tiff.string(ifd0, 0x0110))
        return shot.isEmpty ? nil : shot
    }

    /// "85", "2.8", "24.5": whole numbers without a decimal, else one decimal.
    public static func num(_ v: Double) -> String {
        abs(v - v.rounded()) < 0.05 ? String(Int(v.rounded())) : String(format: "%.1f", locale: Locale(identifier: "en_US_POSIX"), v)
    }

    /// "1/250s" below a third of a second, else "0.5s", "2s", "30s".
    public static func shutter(_ s: Double) -> String {
        s < 0.3 ? "1/\(Int((1 / s).rounded()))s" : "\(num(s))s"
    }

    private static func groups(_ pattern: String, _ text: String) -> [String]? {
        guard let r = try? NSRegularExpression(pattern: pattern),
              let m = r.firstMatch(in: text, range: NSRange(location: 0, length: (text as NSString).length)) else { return nil }
        return (0 ..< m.numberOfRanges).map { i in
            let range = m.range(at: i)
            return range.location == NSNotFound ? "" : (text as NSString).substring(with: range)
        }
    }

    /// Real-world camera names: ILCE-7M4 → a7IV, ILCE-7RM5 → a7RV, NIKON D800E → D800E, NIKON Z 6_2 → Z6II.
    public static func cameraName(_ model: String) -> String {
        let m = model.trimmingCharacters(in: .whitespacesAndNewlines)
        if let g = groups(#"^ILCE-(\d+)([A-Z]*?)(?:M(\d))?([A-Z]?)$"#, m) {
            return "a\(g[1])\(g[2])\(Int(g[3]).map(roman) ?? "")\(g[4])"
        }
        if let g = groups(#"^DSC-RX(\d+)([A-Z]*?)(?:M(\d))?$"#, m) {
            return "RX\(g[1])\(g[2])\(Int(g[3]).map(roman) ?? "")"
        }
        if m.lowercased().hasPrefix("nikon ") {
            var rest = String(m.dropFirst(6)).trimmingCharacters(in: .whitespaces)
            if let g = groups(#"^Z (\S+)"#, rest) { rest = "Z" + g[1] + String(rest.dropFirst(g[0].count)) }
            if let g = groups(#"_(\d)$"#, rest), let n = Int(g[1]) { rest = String(rest.dropLast(2)) + roman(n) }
            return rest
        }
        if m.lowercased().hasPrefix("canon ") { return String(m.dropFirst(6)).trimmingCharacters(in: .whitespaces) }
        return m
    }

    private static func roman(_ n: Int) -> String {
        let names = ["I", "II", "III", "IV", "V", "VI", "VII", "VIII", "IX"]
        return (1 ... 9).contains(n) ? names[n - 1] : String(n)
    }
}
