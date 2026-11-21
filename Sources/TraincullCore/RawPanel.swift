import Foundation

/// One editing control. Most are Apple's own raw controls (`CIRAWFilter` properties); a few
/// carry a new name with Apple's in brackets. Saturation and Vibrance are Core Image filters
/// applied after the raw decode. Every value is a Float: a toggle is 1 (on) or 0 (off).
public struct RawControl: Identifiable {
    public enum Kind: Equatable {
        case slider
        case toggle
        /// White balance by point: an eyedropper that sets Temperature and Tint.
        case neutralPoint
        /// Which of Apple's raw decoders is used.
        case decoder
    }

    public let key: String
    /// The label shown in the panel.
    public let title: String
    public let section: String
    public let kind: Kind
    /// The slider's range. Apple's default for a file may lie outside it; it is never clamped.
    public let range: ClosedRange<Float>
    /// The value used when the file gives no default of its own.
    public let neutral: Float
    /// What the value is called in Apple's API, for the log.
    public let appleProperty: String
    /// Apple's "is…Supported" property for this control, if it has one.
    public let supportProperty: String?
    public let isNew: Bool
    public let show: (Float) -> String
    /// Where the value is saved in the sidecar; an empty field is never saved.
    public let namespace: Xmp.Namespace
    public let field: String
    public let save: (Float) -> String

    public var id: String { key }
}

/// The decoder line: a plain label, or a menu when the file offers more than one decoder of
/// version 8 or later. Versions are Apple's own strings ("8", "8.dng", "9").
public enum DecoderLine: Equatable {
    case label(String)
    case menu([String])
}

/// Whether a control can be used for the current file.
public struct ControlState: Equatable {
    public let enabled: Bool
    public let redDot: Bool
}

public enum RawPanel {
    public static let unsupportedTip = "Not supported for this file"

    public static let sections = ["Raw & Detail", "Light", "Tone curve", "Colour", "Output"]

    private static let posix = Locale(identifier: "en_US_POSIX")
    private static func plain(_ v: Float) -> String { String(format: "%.2f", locale: posix, v) }
    private static func stored(_ v: Float) -> String { String(format: "%.3f", locale: posix, v) }
    private static func onOff(_ v: Float) -> String { v >= 0.5 ? "On" : "Off" }
    private static func trueFalse(_ v: Float) -> String { v >= 0.5 ? "True" : "False" }

    /// A control saved under TrainCull's own namespace, its field named after its key.
    private static func own(_ key: String, _ title: String, _ section: String, _ range: ClosedRange<Float>, _ neutral: Float,
                            apple: String, supported: String? = nil, new: Bool = false) -> RawControl {
        RawControl(key: key, title: title, section: section, kind: .slider, range: range, neutral: neutral,
                   appleProperty: apple, supportProperty: supported, isNew: new, show: plain,
                   namespace: .trainCull, field: key.prefix(1).uppercased() + key.dropFirst(), save: stored)
    }

    private static func toggle(_ key: String, _ title: String, _ section: String, apple: String, supported: String?) -> RawControl {
        RawControl(key: key, title: title, section: section, kind: .toggle, range: 0 ... 1, neutral: 0,
                   appleProperty: apple, supportProperty: supported, isNew: true, show: onOff,
                   namespace: .trainCull, field: key.prefix(1).uppercased() + key.dropFirst(), save: trueFalse)
    }

    /// In pipeline order. Existing controls keep their keys, ranges, defaults and sidecar
    /// fields; only their section and, for four, their label changed.
    public static let controls: [RawControl] = [
        // Raw & Detail
        RawControl(key: "decoder", title: "Decoder", section: "Raw & Detail", kind: .decoder, range: 8 ... 99, neutral: 8,
                   appleProperty: "decoderVersion", supportProperty: nil, isNew: true, show: { "RAW \(Int($0))" },
                   namespace: .trainCull, field: "DecoderVersion", save: { String(Int($0.rounded())) }),
        toggle("lensCorrection", "Lens correction", "Raw & Detail", apple: "isLensCorrectionEnabled", supported: "isLensCorrectionSupported"),
        own("luminanceNoise", "Luminance noise reduction", "Raw & Detail", 0 ... 1, 0,
            apple: "luminanceNoiseReductionAmount", supported: "isLuminanceNoiseReductionSupported"),
        own("colorNoise", "Colour noise reduction", "Raw & Detail", 0 ... 1, 0,
            apple: "colorNoiseReductionAmount", supported: "isColorNoiseReductionSupported"),
        own("moire", "Moiré reduction", "Raw & Detail", 0 ... 1, 0, apple: "moireReductionAmount", supported: "isMoireReductionSupported"),
        own("sharpness", "Sharpness", "Raw & Detail", 0 ... 1, 0, apple: "sharpnessAmount", supported: "isSharpnessSupported"),
        own("detail", "Detail", "Raw & Detail", 0 ... 3, 0, apple: "detailAmount", supported: "isDetailSupported"),
        own("contrast", "Local contrast (Contrast)", "Raw & Detail", 0 ... 1, 0, apple: "contrastAmount", supported: "isContrastSupported"),
        // Light
        RawControl(key: "temperature", title: "Temperature", section: "Light", kind: .slider, range: 2000 ... 12000, neutral: 5500,
                   appleProperty: "neutralTemperature", supportProperty: nil, isNew: false, show: { String(format: "%.0f K", locale: posix, $0) },
                   namespace: .cameraRaw, field: "Temperature", save: { String(Int($0.rounded())) }),
        RawControl(key: "tint", title: "Tint", section: "Light", kind: .slider, range: -150 ... 150, neutral: 0,
                   appleProperty: "neutralTint", supportProperty: nil, isNew: false, show: { String(format: "%+.0f", locale: posix, $0) },
                   namespace: .cameraRaw, field: "Tint", save: { String(format: "%+d", locale: posix, Int($0.rounded())) }),
        RawControl(key: "neutralPoint", title: "White balance by point", section: "Light", kind: .neutralPoint, range: 0 ... 1, neutral: 0,
                   appleProperty: "neutralLocation", supportProperty: nil, isNew: true, show: { _ in "" },
                   namespace: .trainCull, field: "", save: { _ in "" }),
        RawControl(key: "exposure", title: "Exposure", section: "Light", kind: .slider, range: -3 ... 3, neutral: 0,
                   appleProperty: "exposure", supportProperty: nil, isNew: false, show: { String(format: "%+.2f EV", locale: posix, $0) },
                   namespace: .cameraRaw, field: "Exposure2012", save: { String(format: "%+.2f", locale: posix, $0) }),
        RawControl(key: "baselineExposure", title: "Baseline exposure", section: "Light", kind: .slider, range: -3 ... 3, neutral: 0,
                   appleProperty: "baselineExposure", supportProperty: nil, isNew: true, show: { String(format: "%+.2f EV", locale: posix, $0) },
                   namespace: .trainCull, field: "BaselineExposure", save: stored),
        toggle("highlightRecovery", "Highlight recovery", "Light", apple: "isHighlightRecoveryEnabled", supported: "isHighlightRecoverySupported"),
        own("shadowBias", "Blacks (Shadow bias)", "Light", -1 ... 1, 0, apple: "shadowBias"),
        // Tone curve
        own("boost", "Tone curve (Boost)", "Tone curve", 0 ... 1, 1, apple: "boostAmount"),
        own("shadowBoost", "Shadows (Shadow boost)", "Tone curve", 0 ... 2, 0, apple: "boostShadowAmount"),
        own("localToneMap", "Local tone map", "Tone curve", 0 ... 1, 0, apple: "localToneMapAmount", supported: "isLocalToneMapSupported"),
        // Colour
        own("saturation", "Saturation", "Colour", 0 ... 2, 1, apple: "CIColorControls.inputSaturation (Core Image, after the decode)"),
        own("vibrance", "Vibrance", "Colour", -1 ... 1, 0, apple: "CIVibrance.inputAmount (Core Image, after the decode)"),
        // Output
        toggle("gamutMapping", "Gamut mapping", "Output", apple: "isGamutMappingEnabled", supported: nil),
    ]

    public static func control(_ key: String) -> RawControl? { controls.first { $0.key == key } }

    /// The controls that hold a value of their own (everything but the eyedropper).
    public static var valued: [RawControl] { controls.filter { $0.kind != .neutralPoint } }

    // MARK: Supported or not

    /// A control Apple reports unsupported for this file is greyed out and gets a red dot.
    /// Controls without an "is…Supported" property, or whose flag isn't known, never do.
    public static func state(_ c: RawControl, supported: [String: Bool]) -> ControlState {
        guard let property = c.supportProperty, supported[property] == false else { return ControlState(enabled: true, redDot: false) }
        return ControlState(enabled: false, redDot: true)
    }

    /// The values to hand Apple: nothing for a control it doesn't support for this file.
    public static func sendable(_ values: [String: Float], supported: [String: Bool]) -> [String: Float] {
        values.filter { key, _ in control(key).map { state($0, supported: supported).enabled } ?? true }
    }

    // MARK: Decoder

    /// The major version of one of Apple's decoder strings: "8.dng" is 8; "None" is nil.
    public static func major(_ version: String) -> Int? { Int(version.prefix { $0.isNumber }) }

    public static func decoderName(_ version: String) -> String {
        guard let m = major(version) else { return version }
        return version.lowercased().contains("dng") ? "RAW \(m) (DNG)" : "RAW \(m)"
    }

    /// A label when the file offers one decoder of version 8 or later, a menu of exactly those
    /// when it offers more. Versions below 8 are never listed.
    public static func decoderLine(_ versions: [String]) -> DecoderLine {
        let recent = versions.filter { (major($0) ?? 0) >= 8 }
            .sorted { (major($0) ?? 0, $0) < (major($1) ?? 0, $1) }
        if recent.count > 1 { return .menu(recent) }
        if let only = recent.first { return .label(decoderName(only)) }
        // An old file with no decoder from 8 on: say what is there, as a label.
        let newest = versions.filter { major($0) != nil }.max { (major($0) ?? 0) < (major($1) ?? 0) }
        return .label(newest.map(decoderName) ?? "RAW")
    }

    // MARK: Sidecar

    /// The fields to write for a frame's changed values; unchanged controls are removed.
    public static func fields(_ values: [String: Float]) -> [SidecarField] {
        var out = valued.map { c in SidecarField(c.namespace, c.field, values[c.key].map(c.save)) }
        // Camera Raw only honours a temperature and tint when its white balance says "Custom".
        if values["temperature"] != nil || values["tint"] != nil {
            out.append(SidecarField(.cameraRaw, "WhiteBalance", "Custom"))
        }
        return out
    }

    /// The changed values a sidecar holds. Temperature and tint count only when the sidecar's
    /// white balance is "Custom" or absent: "As Shot" values there are Adobe's own reading.
    public static func read(_ text: String) -> [String: Float] {
        var out: [String: Float] = [:]
        let whiteBalance = Xmp.readField(text, "crs:WhiteBalance")
        for c in valued {
            if (c.key == "temperature" || c.key == "tint") && whiteBalance != nil && whiteBalance != "Custom" { continue }
            guard let raw = Xmp.readField(text, "\(c.namespace.prefix):\(c.field)")?.trimmingCharacters(in: .whitespaces) else { continue }
            switch c.kind {
            case .toggle:
                switch raw.lowercased() {
                case "true", "1": out[c.key] = 1
                case "false", "0": out[c.key] = 0
                default: break
                }
            case .decoder:
                if let v = Int(raw) { out[c.key] = Float(v) }
            case .slider:
                guard let v = Float(raw.replacingOccurrences(of: "+", with: "")) else { continue }
                out[c.key] = min(max(v, c.range.lowerBound), c.range.upperBound)
            case .neutralPoint:
                break
            }
        }
        return out
    }
}
