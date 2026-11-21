import CoreImage
import Foundation
import TraincullCore

/// The panel's controls are described in the core library (`RawPanel`); this is where they
/// meet Apple's raw filter.
typealias Control = RawControl

/// What Apple's decoder says about one file before anything is changed.
struct RawFacts {
    /// Apple's own default for every control, by control key (toggles as 1 or 0).
    var defaults: [String: Float]
    /// Apple's is…Supported flags, by property name.
    var supported: [String: Bool]
    var decoder: String
    var decoders: [String]
}

enum Adjust {
    static var controls: [Control] { RawPanel.controls }
    static var sections: [String] { RawPanel.sections }
    static func control(_ key: String) -> Control? { RawPanel.control(key) }

    /// Every control's value as the filter holds it now: Apple's defaults on a fresh filter,
    /// what Apple kept after values were set on one. Saturation and vibrance are not Apple's.
    static func properties(_ f: CIRAWFilter) -> [String: Float] {
        [
            "decoder": Float(RawPanel.major(f.decoderVersion.rawValue) ?? 0),
            "lensCorrection": f.isLensCorrectionEnabled ? 1 : 0,
            "luminanceNoise": f.luminanceNoiseReductionAmount,
            "colorNoise": f.colorNoiseReductionAmount,
            "moire": f.moireReductionAmount,
            "sharpness": f.sharpnessAmount,
            "detail": f.detailAmount,
            "contrast": f.contrastAmount,
            "temperature": f.neutralTemperature,
            "tint": f.neutralTint,
            "exposure": f.exposure,
            "baselineExposure": f.baselineExposure,
            "shadowBias": f.shadowBias,
            "boost": f.boostAmount,
            "shadowBoost": f.boostShadowAmount,
            "localToneMap": f.localToneMapAmount,
            "saturation": 1,
            "vibrance": 0,
            "gamutMapping": f.isGamutMappingEnabled ? 1 : 0,
        ]
    }

    /// Apple's is…Supported flags for the file the filter holds.
    static func supported(_ f: CIRAWFilter) -> [String: Bool] {
        [
            "isLensCorrectionSupported": f.isLensCorrectionSupported,
            "isLuminanceNoiseReductionSupported": f.isLuminanceNoiseReductionSupported,
            "isColorNoiseReductionSupported": f.isColorNoiseReductionSupported,
            "isMoireReductionSupported": f.isMoireReductionSupported,
            "isSharpnessSupported": f.isSharpnessSupported,
            "isDetailSupported": f.isDetailSupported,
            "isContrastSupported": f.isContrastSupported,
            "isLocalToneMapSupported": f.isLocalToneMapSupported,
        ]
    }

    /// Apple's defaults, supported flags and decoders for a file, from a fresh filter.
    static func facts(_ url: URL) -> RawFacts? {
        guard let f = CIRAWFilter(imageURL: url) else { return nil }
        return RawFacts(defaults: properties(f), supported: supported(f), decoder: f.decoderVersion.rawValue,
                        decoders: f.supportedDecoderVersions.map { $0.rawValue })
    }

    /// What Apple's decoder uses for this file when nothing is changed (white balance as shot).
    static func defaults(_ url: URL) -> [String: Float] { facts(url)?.defaults ?? [:] }

    /// Applies the changed values to Apple's raw filter. Anything not in `values` is left
    /// alone, so Apple's own default stays, unclamped; so is anything Apple doesn't support
    /// for this file.
    static func apply(_ values: [String: Float], to f: CIRAWFilter) {
        if values.isEmpty { return }
        let send = RawPanel.sendable(values, supported: supported(f))
        // The decoder first: the other controls belong to it.
        if let v = send["decoder"], let version = f.supportedDecoderVersions.first(where: {
            RawPanel.major($0.rawValue) == Int(v.rounded()) && $0.rawValue.lowercased().contains("dng") == f.decoderVersion.rawValue.lowercased().contains("dng")
        }) {
            f.decoderVersion = version
        }
        for (key, v) in send {
            switch key {
            case "exposure": f.exposure = v
            case "baselineExposure": f.baselineExposure = v
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
            case "lensCorrection": f.isLensCorrectionEnabled = v >= 0.5
            case "gamutMapping": f.isGamutMappingEnabled = v >= 0.5
            default: break
            }
        }
        // White balance last, temperature before tint.
        if let t = send["temperature"] { f.neutralTemperature = t }
        if let t = send["tint"] { f.neutralTint = t }
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

    static func fields(_ values: [String: Float]) -> [SidecarField] { RawPanel.fields(values) }

    static func read(_ text: String) -> [String: Float] { RawPanel.read(text) }
}
