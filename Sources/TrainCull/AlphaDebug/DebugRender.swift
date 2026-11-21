#if TC_ALPHA_DEBUG
import CoreGraphics
import CoreImage
import CryptoKit
import Foundation
import ImageIO
import TraincullCore

/// Every picture the debug tools write comes from the 16-bit TIFF export's own render
/// (`Imaging.developedReading` then `Export.render16`): only the last step differs. The frame
/// is that render made smaller in Core Graphics and turned into 8-bit Display P3; a crop is cut
/// straight from it, at full resolution and still 16-bit ProPhoto RGB.
enum DebugRender {
    struct Failure: Error, CustomStringConvertible {
        let description: String
    }

    struct Rendered {
        /// Full resolution, 16-bit ProPhoto RGB: exactly what a TIFF export would hold.
        let pixels: CGImage
        let readBack: [String: Float]
        let decoder: String
        let milliseconds: Double
    }

    static func render(_ url: URL, _ values: [String: Float]) throws -> Rendered {
        let start = CFAbsoluteTimeGetCurrent()
        return try autoreleasepool {
            guard let developed = Imaging.developedReading(url, values) else {
                throw Failure(description: "Apple's decoder can't develop \(url.lastPathComponent)")
            }
            let pixels = try Export.render16(developed.image, developed.extent)
            return Rendered(pixels: pixels, readBack: developed.readBack, decoder: developed.decoder,
                            milliseconds: (CFAbsoluteTimeGetCurrent() - start) * 1000)
        }
    }

    /// The frame image: the whole picture, long edge 3000 px (or its own size if smaller),
    /// 8-bit, Display P3.
    static func frame(_ full: CGImage) throws -> CGImage {
        let (w, h) = DebugEstimate.frameSize(full.width, full.height)
        return try redraw(full, width: w, height: h)
    }

    /// `image` (or the part of it in `from`, in its pixels, origin top left) drawn at a size,
    /// 8-bit Display P3, with Core Graphics' best smoothing.
    static func redraw(_ image: CGImage, from: CGRect? = nil, width: Int, height: Int) throws -> CGImage {
        guard let p3 = CGColorSpace(name: CGColorSpace.displayP3),
              let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0, space: p3,
                                  bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { throw Failure(description: "no drawing context") }
        ctx.interpolationQuality = .high
        var source = image
        if let from = from, let part = image.cropping(to: from.integral) { source = part }
        ctx.draw(source, in: CGRect(x: 0, y: 0, width: width, height: height))
        guard let out = ctx.makeImage() else { throw Failure(description: "the frame couldn't be drawn") }
        return out
    }

    /// The crop rectangle in pixels for fractions [x, y, w, h] (origin top left).
    static func cropRect(_ fractions: [Double], _ w: Int, _ h: Int) -> CGRect {
        let x = Int((fractions[0] * Double(w)).rounded()), y = Int((fractions[1] * Double(h)).rounded())
        let (cw, ch) = DebugEstimate.cropSize(fractions, w, h)
        return CGRect(x: x, y: y, width: min(cw, w - x), height: min(ch, h - y))
    }

    /// A crop at full resolution, untouched: 16-bit ProPhoto RGB, as the TIFF holds it.
    static func crop(_ full: CGImage, _ rect: CGRect) throws -> CGImage {
        guard let out = full.cropping(to: rect) else { throw Failure(description: "the crop lies outside the picture") }
        return out
    }

    /// A PNG of the picture, its colour space embedded.
    static func png(_ image: CGImage) throws -> Data {
        let data = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(data, "public.png" as CFString, 1, nil) else { throw Failure(description: "PNG can't be written") }
        CGImageDestinationAddImage(dest, image, nil)
        guard CGImageDestinationFinalize(dest) else { throw Failure(description: "the PNG couldn't be encoded") }
        return data as Data
    }

    /// The first 12 hex characters of the SHA-256.
    static func checksum(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined().prefix(12).description
    }

    /// The camera settings Apple's image reader finds in the raw file.
    static func fileInfo(_ url: URL, width: Int, height: Int) -> [String: Any] {
        var out: [String: Any] = ["name": url.lastPathComponent, "width": width, "height": height]
        for key in ["camera", "lens", "iso", "shutter", "aperture"] { out[key] = NSNull() }
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any] else { return out }
        let tiff = props[kCGImagePropertyTIFFDictionary] as? [CFString: Any] ?? [:]
        let exif = props[kCGImagePropertyExifDictionary] as? [CFString: Any] ?? [:]
        let aux = props[kCGImagePropertyExifAuxDictionary] as? [CFString: Any] ?? [:]
        let camera = [tiff[kCGImagePropertyTIFFMake] as? String, tiff[kCGImagePropertyTIFFModel] as? String].compactMap { $0 }
        if !camera.isEmpty { out["camera"] = camera.joined(separator: " ") }
        if let lens = (exif[kCGImagePropertyExifLensModel] as? String) ?? (aux[kCGImagePropertyExifAuxLensModel] as? String) { out["lens"] = lens }
        if let iso = (exif[kCGImagePropertyExifISOSpeedRatings] as? [Any])?.first { out["iso"] = iso }
        if let t = exif[kCGImagePropertyExifExposureTime] as? Double {
            out["shutter"] = t >= 1 ? String(format: "%.1f s", t) : "1/\(Int((1 / t).rounded())) s"
        }
        if let f = exif[kCGImagePropertyExifFNumber] as? Double { out["aperture"] = String(format: "f/%.1f", f) }
        return out
    }

    /// How this render was made, for report.json.
    static func pipeline(_ url: URL) -> [String: Any] {
        let fresh = CIRAWFilter(imageURL: url)
        let ctx = Imaging.ciContext
        return [
            "path": "the 16-bit TIFF export's render (Imaging.developed, Export.render16); frame and crops written from it",
            "draftMode": fresh?.isDraftModeEnabled ?? false,
            "draftModeSetByTrainCull": false,
            "renderScale": 1.0,
            "workingFormat": ctx.workingFormat == .RGBAh ? "RGBAh (16-bit half float)" : "\(ctx.workingFormat.rawValue)",
            "workingColorSpace": ctx.workingColorSpace?.name.map { $0 as String } ?? NSNull(),
            "renderColorSpace": "ProPhoto RGB (ROMM), 16-bit, as the TIFF export",
            "frameColorSpace": "Display P3, 8-bit (drawn from the 16-bit render with Core Graphics, high quality)",
            "cropColorSpace": "ProPhoto RGB (ROMM), 16-bit, cut from the 16-bit render unchanged",
        ]
    }

    /// Every control (old and new): label, Apple property, the value used, Apple's default, what
    /// Apple read back, whether it is supported, whether the case moved it, and the slider range.
    static func controls(values: [String: Float], moved: Set<String>, facts: RawFacts, readBack: [String: Float]) -> [[String: Any]] {
        func number(_ v: Float?) -> Any { v.map { Double($0) as Any } ?? NSNull() }
        return RawPanel.controls.filter { $0.kind != .neutralPoint }.map { c in
            let supported: Any = c.supportProperty.map { (facts.supported[$0] ?? false) as Any } ?? "n/a"
            return [
                "label": c.title,
                "appleProperty": c.appleProperty,
                "valueUsed": number(values[c.key] ?? facts.defaults[c.key]),
                "appleDefault": number(facts.defaults[c.key]),
                "readBack": number(readBack[c.key]),
                "supported": supported,
                "moved": moved.contains(c.key),
                "sliderRange": c.kind == .slider ? [Double(c.range.lowerBound), Double(c.range.upperBound)] as Any : NSNull(),
            ]
        }
    }

    /// report.json: built as a dictionary, then the case's own text put in where the placeholder is,
    /// so it is copied exactly as the script wrote it.
    static func reportData(_ report: [String: Any], caseText: String) throws -> Data {
        var r = report
        let placeholder = "@@TRAINCULL-CASE-ENTRY@@"
        r["caseEntry"] = placeholder
        let data = try JSONSerialization.data(withJSONObject: r, options: [.prettyPrinted, .sortedKeys])
        let text = String(decoding: data, as: UTF8.self).replacingOccurrences(of: "\"\(placeholder)\"", with: caseText)
        return Data(text.utf8)
    }
}
#endif
