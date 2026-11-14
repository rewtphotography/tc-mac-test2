import CoreGraphics
import CoreImage
import Foundation
import ImageIO
import TraincullCore
import Vision

/// Faces found in one frame, in pixels of the upright image they were detected in.
struct DetectedFaces {
    let subjects: [Subject]
    let imageWidth: Double
}

enum Imaging {
    /// One read at the start of each file covers the IFD tables and the preview on the α7 IV.
    static let firstReadBytes = 512 * 1024
    static let thumbnailPixels = 400

    static let ciContext = CIContext(options: [.cacheIntermediates: false])

    /// The embedded JPEG bytes a recipe points at.
    private static func jpegData(_ src: ByteSource, _ ref: JpegRef) -> Data? {
        (try? src.read(ref.offset, ref.length)).map { Data($0) }
    }

    private static func pixelSize(_ source: CGImageSource) -> Int {
        guard let p = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any] else { return 0 }
        let w = (p[kCGImagePropertyPixelWidth] as? Int) ?? 0
        let h = (p[kCGImagePropertyPixelHeight] as? Int) ?? 0
        return max(w, h)
    }

    /// The grid preview source: the recipe's preview, or the full JPEG when the "preview" is
    /// only a thumbnail (long side under 800 px).
    private static func previewSource(_ src: ByteSource, _ info: RawInfo) -> CGImageSource? {
        if let p = info.preview, let d = jpegData(src, p), let s = CGImageSourceCreateWithData(d as CFData, nil), pixelSize(s) >= 800 {
            return s
        }
        if let f = info.full, let d = jpegData(src, f) { return CGImageSourceCreateWithData(d as CFData, nil) }
        return nil
    }

    private static func decode(_ source: CGImageSource, maxPixels: Int?) -> CGImage? {
        var options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: false,
            kCGImageSourceShouldCacheImmediately: true,
        ]
        options[kCGImageSourceThumbnailMaxPixelSize] = maxPixels ?? max(pixelSize(source), 1)
        return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
    }

    /// Reads one raw file's header and returns what the recipe found plus an upright preview.
    /// `maxPixels` nil decodes the preview at its full size.
    static func preview(_ url: URL, _ formats: Formats, maxPixels: Int?) throws -> (RawInfo, CGImage) {
        let src = try FileByteSource(url: url)
        try src.readHeader(firstReadBytes)
        let info = try formats.parse(url.lastPathComponent, src)
        guard let source = previewSource(src, info), let image = decode(source, maxPixels: maxPixels) else {
            throw TiffError("the embedded preview couldn't be decoded")
        }
        return (info, rotated(image, clockwise: info.rotationDegrees))
    }

    /// The full-size embedded JPEG, upright. Used when Apple's decoder can't render the raw.
    static func fullJpeg(_ url: URL, _ formats: Formats) -> CGImage? {
        guard let src = try? FileByteSource(url: url) else { return nil }
        try? src.readHeader(firstReadBytes)
        guard let info = try? formats.parse(url.lastPathComponent, src), let ref = info.full,
              let data = jpegData(src, ref), let source = CGImageSourceCreateWithData(data as CFData, nil),
              let image = decode(source, maxPixels: nil) else { return nil }
        return rotated(image, clockwise: info.rotationDegrees)
    }

    /// `image` turned clockwise by 0, 90, 180 or 270 degrees.
    static func rotated(_ image: CGImage, clockwise degrees: Int) -> CGImage {
        if degrees != 90 && degrees != 180 && degrees != 270 { return image }
        let w = image.width, h = image.height
        let swap = degrees != 180
        let nw = swap ? h : w, nh = swap ? w : h
        var space = image.colorSpace ?? CGColorSpace(name: CGColorSpace.sRGB)!
        if space.model != .rgb { space = CGColorSpace(name: CGColorSpace.sRGB)! }
        let bitmapInfo = CGImageAlphaInfo.noneSkipFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
        guard let ctx = CGContext(data: nil, width: nw, height: nh, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: space, bitmapInfo: bitmapInfo) else { return image }
        ctx.interpolationQuality = .none
        ctx.translateBy(x: CGFloat(nw) / 2, y: CGFloat(nh) / 2)
        ctx.rotate(by: -CGFloat(degrees) * .pi / 180) // positive angles turn counter-clockwise here
        ctx.draw(image, in: CGRect(x: -CGFloat(w) / 2, y: -CGFloat(h) / 2, width: CGFloat(w), height: CGFloat(h)))
        return ctx.makeImage() ?? image
    }

    /// The size of the raw as Apple's decoder will render it (upright), without rendering it.
    static func rawSize(_ url: URL) -> CGSize? {
        guard let filter = CIRAWFilter(imageURL: url), let out = filter.outputImage else { return nil }
        let e = out.extent
        if e.isInfinite || e.isEmpty { return nil }
        return e.size
    }

    /// Renders the raw with Apple's built-in decoder and the frame's adjustments.
    /// `scale` below 1 gives a quick smaller render for live feedback while a slider moves.
    static func renderRaw(_ url: URL, _ values: [String: Float] = [:], scale: Float = 1) -> CGImage? {
        guard let filter = CIRAWFilter(imageURL: url) else { return nil }
        if scale < 1 { filter.scaleFactor = max(scale, 0.05) }
        Adjust.apply(values, to: filter)
        guard let decoded = filter.outputImage else { return nil }
        let out = Adjust.finish(decoded, values)
        let e = decoded.extent
        if e.isInfinite || e.isEmpty { return nil }
        let space = CGColorSpace(name: CGColorSpace.displayP3) ?? CGColorSpaceCreateDeviceRGB()
        return ciContext.createCGImage(out, from: e, format: .RGBA8, colorSpace: space)
    }

    /// The raw developed by Apple's decoder with the frame's adjustments, not yet turned into
    /// pixels, and the rectangle it covers. Exports render it at full quality.
    static func developed(_ url: URL, _ values: [String: Float]) -> (image: CIImage, extent: CGRect)? {
        guard let filter = CIRAWFilter(imageURL: url) else { return nil }
        Adjust.apply(values, to: filter)
        guard let decoded = filter.outputImage else { return nil }
        let e = decoded.extent
        if e.isInfinite || e.isEmpty { return nil }
        return (Adjust.finish(decoded, values), e)
    }

    /// Faces and eye centres in an upright image, using Apple's Vision framework. Faces are
    /// listed from left to right, so "the next face" means the same thing in every frame.
    static func detectFaces(_ image: CGImage) -> DetectedFaces {
        let w = Double(image.width), h = Double(image.height)
        let request = VNDetectFaceLandmarksRequest()
        let handler = VNImageRequestHandler(cgImage: image, options: [:])
        try? handler.perform([request])
        var subjects: [Subject] = []
        for face in request.results ?? [] {
            let box = face.boundingBox // fractions of the image, origin at the bottom left
            var s = Subject(left: Double(box.minX) * w, top: (1 - Double(box.maxY)) * h,
                            right: Double(box.maxX) * w, bottom: (1 - Double(box.minY)) * h)
            // Landmark points are fractions of the face box, origin at its bottom left.
            func centre(_ region: VNFaceLandmarkRegion2D?) -> (Double, Double)? {
                guard let points = region?.normalizedPoints, !points.isEmpty else { return nil }
                let mx = points.map { Double($0.x) }.reduce(0, +) / Double(points.count)
                let my = points.map { Double($0.y) }.reduce(0, +) / Double(points.count)
                let x = Double(box.minX) + mx * Double(box.width)
                let y = Double(box.minY) + my * Double(box.height)
                return (x * w, (1 - y) * h)
            }
            if let l = centre(face.landmarks?.leftEye), let r = centre(face.landmarks?.rightEye) {
                s.eye1X = l.0; s.eye1Y = l.1; s.eye2X = r.0; s.eye2Y = r.1
            }
            subjects.append(s)
        }
        subjects.sort { $0.centerX < $1.centerX }
        return DetectedFaces(subjects: subjects, imageWidth: w)
    }
}
