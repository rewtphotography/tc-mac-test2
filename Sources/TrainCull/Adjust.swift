import CoreImage
import Foundation
import TraincullCore

/// One editing control. The controls are Apple's own raw controls under Apple's own names,
/// relabelled only in stops and Kelvin, so they can be judged on their own terms.
struct Control: Identifiable {
    let key: String
    let title: String
    let section: String
    let range: ClosedRange<Float>
    /// The value used when the file gives no default of its own.
    let neutral: Float
    let show: (Float) -> String
    /// Where the value is saved in the sidecar.
    let namespace: Xmp.Namespace
    let field: String
    let save: (Float) -> String

    var id: String { key }
}

enum Adjust {
    private static func plain(_ v: Float) -> String { String(format: "%.2f", v) }
    private static func stored(_ v: Float) -> String { String(format: "%.3f", locale: Locale(identifier: "en_US_POSIX"), v) }

    private static func own(_ key: String, _ title: String, _ section: String, _ range: ClosedRange<Float>, _ neutral: Float) -> Control {
        Control(key: key, title: title, section: section, range: range, neutral: neutral, show: plain,
                namespace: .trainCull, field: key.prefix(1).uppercased() + key.dropFirst(), save: stored)
    }

    static let controls: [Control] = [
        Control(key: "exposure", title: "Exposure", section: "Light", range: -3 ... 3, neutral: 0,
                show: { String(format: "%+.2f EV", $0) },
                namespace: .cameraRaw, field: "Exposure2012",
                save: { String(format: "%+.2f", locale: Locale(identifier: "en_US_POSIX"), $0) }),
        own("boost", "Boost", "Light", 0 ... 1, 1),
        own("shadowBoost", "Shadow boost", "Light", 0 ... 2, 0),
        own("shadowBias", "Shadow bias", "Light", -1 ... 1, 0),
        own("contrast", "Contrast", "Light", 0 ... 1, 0),
        own("localToneMap", "Local tone map", "Light", 0 ... 1, 0),
        Control(key: "temperature", title: "Temperature", section: "Colour", range: 2000 ... 12000, neutral: 5500,
                show: { String(format: "%.0f K", $0) },
                namespace: .cameraRaw, field: "Temperature", save: { String(Int($0.rounded())) }),
        Control(key: "tint", title: "Tint", section: "Colour", range: -150 ... 150, neutral: 0,
                show: { String(format: "%+.0f", $0) },
                namespace: .cameraRaw, field: "Tint", save: { String(format: "%+d", Int($0.rounded())) }),
        own("saturation", "Saturation", "Colour", 0 ... 2, 1),
        own("vibrance", "Vibrance", "Colour", -1 ... 1, 0),
        own("sharpness", "Sharpness", "Detail", 0 ... 1, 0),
        own("detail", "Detail", "Detail", 0 ... 3, 0),
        own("luminanceNoise", "Luminance noise reduction", "Detail", 0 ... 1, 0),
        own("colorNoise", "Colour noise reduction", "Detail", 0 ... 1, 0),
        own("moire", "Moiré reduction", "Detail", 0 ... 1, 0),
    ]

    static let sections = ["Light", "Colour", "Detail"]

    /// What Apple's decoder uses for this file when nothing is changed (white balance as shot).
    static func defaults(_ url: URL) -> [String: Float] {
        guard let f = CIRAWFilter(imageURL: url) else { return [:] }
        return [
            "exposure": f.exposure,
            "boost": f.boostAmount,
            "shadowBoost": f.boostShadowAmount,
            "shadowBias": f.shadowBias,
            "contrast": f.contrastAmount,
            "localToneMap": f.localToneMapAmount,
            "temperature": f.neutralTemperature,
            "tint": f.neutralTint,
            "saturation": 1,
            "vibrance": 0,
            "sharpness": f.sharpnessAmount,
            "detail": f.detailAmount,
            "luminanceNoise": f.luminanceNoiseReductionAmount,
            "colorNoise": f.colorNoiseReductionAmount,
            "moire": f.moireReductionAmount,
        ]
    }

    /// Applies the changed values to Apple's raw filter. Anything not in `values` is left alone.
    static func apply(_ values: [String: Float], to f: CIRAWFilter) {
        for (key, v) in values {
            switch key {
            case "exposure": f.exposure = v
            case "boost": f.boostAmount = v
            case "shadowBoost": f.boostShadowAmount = v
            case "shadowBias": f.shadowBias = v
            case "contrast": f.contrastAmount = v
            case "localToneMap": f.localToneMapAmount = v
            case "sharpness": f.sharpnessAmount = v
            case "detail": f.detailAmount = v
            case "luminanceNoise": f.luminanceNoiseReductionAmount = v
            case "colorNoise": f.colorNoiseReductionAmount = v
            case "moire": f.moireReductionAmount = v
            default: break
            }
        }
        // White balance last, temperature before tint.
        if let t = values["temperature"] { f.neutralTemperature = t }
        if let t = values["tint"] { f.neutralTint = t }
    }

    /// Saturation and vibrance are Core Image filters applied after the raw decode.
    static func finish(_ image: CIImage, _ values: [String: Float]) -> CIImage {
        var out = image
        if let s = values["saturation"] {
            out = out.applyingFilter("CIColorControls", parameters: [kCIInputSaturationKey: s])
        }
        if let v = values["vibrance"] {
            out = out.applyingFilter("CIVibrance", parameters: ["inputAmount": v])
        }
        return out
    }

    // MARK: Sidecar

    /// The fields to write for a frame's changed values; unchanged controls are removed.
    static func fields(_ values: [String: Float]) -> [SidecarField] {
        var out = controls.map { c in SidecarField(c.namespace, c.field, values[c.key].map(c.save)) }
        // Camera Raw only honours a temperature and tint when its white balance says "Custom".
        if values["temperature"] != nil || values["tint"] != nil {
            out.append(SidecarField(.cameraRaw, "WhiteBalance", "Custom"))
        }
        return out
    }

    /// The changed values a sidecar holds. Temperature and tint count only when the sidecar's
    /// white balance is "Custom" or absent: "As Shot" values there are Adobe's own reading.
    static func read(_ text: String) -> [String: Float] {
        var out: [String: Float] = [:]
        let whiteBalance = Xmp.readField(text, "crs:WhiteBalance")
        for c in controls {
            if (c.key == "temperature" || c.key == "tint") && whiteBalance != nil && whiteBalance != "Custom" { continue }
            guard let raw = Xmp.readField(text, "\(c.namespace.prefix):\(c.field)"),
                  let v = Float(raw.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: "+", with: "")) else { continue }
            out[c.key] = min(max(v, c.range.lowerBound), c.range.upperBound)
        }
        return out
    }
}
