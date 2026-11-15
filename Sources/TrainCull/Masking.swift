import AppKit
import CoreImage
import TraincullCore
import Vision

/// The three areas a local adjustment can act on.
enum LocalArea: Int, CaseIterable {
    case subject, background, skin

    var name: String {
        switch self {
        case .subject: return "Subject"
        case .background: return "Background"
        case .skin: return "Skin"
        }
    }
}

/// One area's adjustment.
struct LocalLayer: Equatable {
    var exposure: Float = 0 // stops
    var saturation: Float = 1
    var warmth: Float = 0 // -1 cooler … 1 warmer

    var isNeutral: Bool { exposure == 0 && saturation == 1 && warmth == 0 }
}

/// A frame's local adjustments, one layer for each area.
struct LocalEdits: Equatable {
    var layers = [LocalLayer](repeating: LocalLayer(), count: LocalArea.allCases.count)

    var isNeutral: Bool { layers.allSatisfy { $0.isNeutral } }
}

/// What the large image shows while a mask is being judged.
enum MaskView: Int, CaseIterable {
    case photo, overlay, mask, onBlack, onWhite

    var name: String {
        switch self {
        case .photo: return "Photo"
        case .overlay: return "Red Overlay"
        case .mask: return "Mask"
        case .onBlack: return "On Black"
        case .onWhite: return "On White"
        }
    }
}

/// A finished mask, as pictures Core Image can blend with.
final class MaskResult {
    let width: Int
    let height: Int
    /// How much of each pixel is subject.
    let alpha: CGImage
    /// How much of each pixel's red, green and blue light is the subject's.
    let shares: CGImage
    let skin: CGImage?
    /// For inspection: the three-way split and the first-pass mask the refinement started from.
    let trimap: CGImage
    let coarse: CGImage
    let tier: MatteTier
    let summary: String

    init(width: Int, height: Int, alpha: CGImage, shares: CGImage, skin: CGImage?, trimap: CGImage, coarse: CGImage, tier: MatteTier, summary: String) {
        self.width = width; self.height = height
        self.alpha = alpha; self.shares = shares; self.skin = skin
        self.trimap = trimap; self.coarse = coarse
        self.tier = tier; self.summary = summary
    }

    func picture(for area: LocalArea) -> CGImage? { area == .skin ? skin : shares }
}

/// A mask and what to do with it when a frame is rendered.
struct LocalRender {
    let mask: MaskResult
    var edits: LocalEdits
    var view: MaskView
    var area: LocalArea
}

/// Subject, hair-edge and skin masks. Apple's Vision says roughly what the subject is; the
/// matting engine in TraincullCore works out exactly where its edge lies. Masks are made from
/// a neutral render of the raw, so the frame's own edits never move them.
enum Masking {
    struct Failure: Error, CustomStringConvertible {
        let description: String
        init(_ message: String) { description = message }
    }

    static let proxyLongEdge = 2048

    // MARK: Pictures and planes

    static func picture(gray bytes: [UInt8], w: Int, h: Int) -> CGImage? {
        guard bytes.count >= w * h, let provider = CGDataProvider(data: Data(bytes) as CFData) else { return nil }
        return CGImage(width: w, height: h, bitsPerComponent: 8, bitsPerPixel: 8, bytesPerRow: w, space: CGColorSpaceCreateDeviceGray(),
                       bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.none.rawValue), provider: provider, decode: nil,
                       shouldInterpolate: true, intent: .defaultIntent)
    }

    static func picture(rgbx bytes: [UInt8], w: Int, h: Int) -> CGImage? {
        guard bytes.count >= w * h * 4, let provider = CGDataProvider(data: Data(bytes) as CFData) else { return nil }
        return CGImage(width: w, height: h, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: w * 4, space: CGColorSpaceCreateDeviceRGB(),
                       bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue), provider: provider, decode: nil,
                       shouldInterpolate: true, intent: .defaultIntent)
    }

    /// The pixels of a rendered picture, for the matting engine. Nil unless it is 8-bit with
    /// red, green and blue first, which is what the raw render produces.
    static func photo(from image: CGImage) -> Photo? {
        let alpha = image.alphaInfo
        let order = image.bitmapInfo.intersection(.byteOrderMask)
        guard image.bitsPerComponent == 8, image.bitsPerPixel == 32,
              alpha == .noneSkipLast || alpha == .premultipliedLast || alpha == .last,
              order == [] || order == .byteOrder32Big,
              let data = image.dataProvider?.data, let base = CFDataGetBytePtr(data) else { return nil }
        let length = CFDataGetLength(data)
        guard length >= (image.height - 1) * image.bytesPerRow + image.width * 4 else { return nil }
        return Photo(w: image.width, h: image.height, rowBytes: image.bytesPerRow, bytes: UnsafeRawBufferPointer(start: base, count: length))
    }

    /// A Vision result as a plane of numbers from 0 to 1, top row first.
    static func gray(from buffer: CVPixelBuffer) -> Gray? {
        CVPixelBufferLockBaseAddress(buffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
        let w = CVPixelBufferGetWidth(buffer), h = CVPixelBufferGetHeight(buffer), rowBytes = CVPixelBufferGetBytesPerRow(buffer)
        guard w > 0, h > 0, let base = CVPixelBufferGetBaseAddress(buffer) else { return nil }
        var out = Gray(w: w, h: h)
        switch CVPixelBufferGetPixelFormatType(buffer) {
        case kCVPixelFormatType_OneComponent8:
            for y in 0 ..< h {
                let row = base.advanced(by: y * rowBytes).assumingMemoryBound(to: UInt8.self)
                for x in 0 ..< w { out.v[y * w + x] = Float(row[x]) / 255 }
            }
        case kCVPixelFormatType_OneComponent32Float:
            for y in 0 ..< h {
                let row = base.advanced(by: y * rowBytes).assumingMemoryBound(to: Float.self)
                for x in 0 ..< w { out.v[y * w + x] = min(max(row[x], 0), 1) }
            }
        default:
            return nil
        }
        return out
    }

    /// A smaller copy of a picture, for Vision, which wants a normal displayed image.
    static func proxy(of image: CGImage, longEdge: Int) -> CGImage? {
        let k = min(1, Double(longEdge) / Double(max(image.width, image.height)))
        let w = max(Int((Double(image.width) * k).rounded()), 1), h = max(Int((Double(image.height) * k).rounded()), 1)
        guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: image.colorSpace ?? CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return nil }
        ctx.interpolationQuality = .high
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        return ctx.makeImage()
    }

    // MARK: Apple's first pass

    /// Every person in the picture as one soft mask.
    static func personMask(_ image: CGImage) -> Gray? {
        autoreleasepool {
            let request = VNGeneratePersonSegmentationRequest()
            request.qualityLevel = .accurate
            request.outputPixelFormat = kCVPixelFormatType_OneComponent8
            let handler = VNImageRequestHandler(cgImage: image, options: [:])
            guard (try? handler.perform([request])) != nil, let buffer = request.results?.first?.pixelBuffer else { return nil }
            return gray(from: buffer)
        }
    }

    /// Whatever stands out from the background, person or not, as one soft mask.
    static func subjectMask(_ image: CGImage) -> Gray? {
        autoreleasepool {
            let request = VNGenerateForegroundInstanceMaskRequest()
            let handler = VNImageRequestHandler(cgImage: image, options: [:])
            guard (try? handler.perform([request])) != nil, let found = request.results?.first, !found.allInstances.isEmpty,
                  let buffer = try? found.generateScaledMaskForImage(forInstances: found.allInstances, from: handler) else { return nil }
            return gray(from: buffer)
        }
    }

    /// Where skin must not be selected: eyes, eyebrows and lips, drawn from Apple's face
    /// landmarks, a little enlarged and feathered. A plane the size of `image`, 1 = keep out.
    static func featureExclusion(_ image: CGImage) -> Gray? {
        autoreleasepool {
            let request = VNDetectFaceLandmarksRequest()
            let handler = VNImageRequestHandler(cgImage: image, options: [:])
            guard (try? handler.perform([request])) != nil, let faces = request.results, !faces.isEmpty else { return nil }
            let w = image.width, h = image.height
            guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w,
                                      space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue) else { return nil }
            ctx.setFillColor(gray: 0, alpha: 1)
            ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
            ctx.setFillColor(gray: 1, alpha: 1)
            ctx.setStrokeColor(gray: 1, alpha: 1)
            ctx.setLineJoin(.round)
            var grow: CGFloat = 2
            for face in faces {
                guard let marks = face.landmarks else { continue }
                grow = max(grow, 0.02 * face.boundingBox.height * CGFloat(h))
                ctx.setLineWidth(grow)
                for region in [marks.leftEye, marks.rightEye, marks.leftEyebrow, marks.rightEyebrow, marks.outerLips] {
                    // Points in pixels with the origin at the bottom left, as the drawing context has it.
                    guard let points = region?.pointsInImage(imageSize: CGSize(width: w, height: h)), points.count > 2 else { continue }
                    ctx.beginPath()
                    ctx.addLines(between: points)
                    ctx.closePath()
                    ctx.drawPath(using: .fillStroke)
                }
            }
            guard let data = ctx.data else { return nil }
            let bytes = data.assumingMemoryBound(to: UInt8.self)
            var out = Gray(w: w, h: h)
            for y in 0 ..< h { for x in 0 ..< w { out.v[y * w + x] = Float(bytes[y * ctx.bytesPerRow + x]) / 255 } }
            return out.blurred(radius: max(Int(grow / 3), 1))
        }
    }

    // MARK: Making a mask

    /// Makes the masks for one raw file. Runs for seconds; call it off the main thread.
    static func make(url: URL, tier: MatteTier, faces known: DetectedFaces?, progress: (String) -> Void, cancelled: () -> Bool) throws -> MaskResult {
        let started = CFAbsoluteTimeGetCurrent()
        progress("Rendering")
        // A neutral render: the camera's white balance, Apple's defaults, none of the frame's edits.
        guard let reference = Imaging.renderRaw(url) else { throw Failure("Apple's raw decoder can't open this file on this Mac") }
        Log.note("mask", "\(url.lastPathComponent): neutral render \(reference.width)×\(reference.height) in \(Log.seconds(since: started))")
        return try make(reference: reference, name: url.lastPathComponent, tier: tier, faces: known, progress: progress, cancelled: cancelled)
    }

    /// The same, from a picture already rendered.
    static func make(reference: CGImage, name: String, tier: MatteTier, faces known: DetectedFaces?,
                     coarse given: Gray? = nil, progress: (String) -> Void, cancelled: () -> Bool) throws -> MaskResult {
        let started = CFAbsoluteTimeGetCurrent()
        let W = reference.width, H = reference.height
        guard let photo = photo(from: reference) else { throw Failure("the rendered photo isn't in the expected 8-bit form") }
        guard let small = proxy(of: reference, longEdge: proxyLongEdge) else { throw Failure("the photo couldn't be scaled down") }

        // Apple's first pass: people if there are any, else whatever stands out.
        progress("Finding the subject")
        var stage = CFAbsoluteTimeGetCurrent()
        var source = "given"
        var coarse = given
        if coarse == nil, let people = personMask(small), people.v.reduce(0, +) / Float(people.v.count) > 0.003 {
            coarse = people
            source = "people"
        }
        if coarse == nil, let subject = subjectMask(small) {
            coarse = subject
            source = "foreground"
        }
        guard let first = coarse else { throw Failure("no subject was found in this photo") }
        Log.note("mask", "\(name): first pass (\(source)) \(first.w)×\(first.h) in \(Log.seconds(since: stage))")

        // Faces, in pixels of the full photo with y down.
        let found = known ?? Imaging.detectFaces(small)
        let k = found.imageWidth > 0 ? Double(W) / found.imageWidth : 1
        let faces = found.subjects.map { s in
            PixelRect(x: Int(s.left * k), y: Int(s.top * k), w: max(Int(s.width * k), 1), h: max(Int(s.height * k), 1))
        }.sorted { $0.h > $1.h }

        // A second, closer look at each head, at full size, for the better tiers.
        var patches: [HeadPatch] = []
        if tier != .fast && given == nil {
            stage = CFAbsoluteTimeGetCurrent()
            for f in faces.prefix(4) {
                let cx = Double(f.x) + Double(f.w) / 2, cy = Double(f.y) + Double(f.h) / 2 - 0.25 * Double(f.h)
                let rect = PixelRect(x: Int(cx - 1.3 * Double(f.w)), y: Int(cy - 1.5 * Double(f.h)), w: Int(2.6 * Double(f.w)), h: Int(3.0 * Double(f.h)))
                    .clamped(w: W, h: H)
                guard rect.w > 64, rect.h > 64, let crop = reference.cropping(to: CGRect(x: rect.x, y: rect.y, width: rect.w, height: rect.h)),
                      let mask = personMask(crop) else { continue }
                patches.append(HeadPatch(rect: rect, mask: mask))
            }
            Log.note("mask", "\(name): \(patches.count) head close-up(s) of \(faces.count) face(s) in \(Log.seconds(since: stage))")
        }
        if cancelled() { throw Failure("stopped") }

        let matte = Matte(photo: photo, coarse: first, faces: faces, patches: patches)
        MemoryMonitor.mark("setting up a \(tier.name) mask")
        let out = matte.run(tier: tier, progress: progress, cancelled: cancelled)
        for line in out.log { Log.note("mask", "\(name): \(line)") }
        MemoryMonitor.mark("refining a \(tier.name) mask")

        // Skin: its colour is learned from the cheeks and nose of each face.
        var skin: CGImage?
        stage = CFAbsoluteTimeGetCurrent()
        var samples: [SIMD3<Float>] = []
        for f in faces.prefix(4) {
            let spots: [(Double, Double)] = [(0.28, 0.58), (0.72, 0.58), (0.5, 0.52)]
            let r = max(f.w / 40, 3)
            for (u, v) in spots {
                let sx = f.x + Int(Double(f.w) * u), sy = f.y + Int(Double(f.h) * v)
                for y in (sy - r) ... (sy + r) {
                    for x in (sx - r) ... (sx + r) where x >= 0 && y >= 0 && x < W && y < H && out.alpha[y * W + x] == 255 {
                        samples.append(photo.rgb(x, y))
                    }
                }
            }
        }
        if let model = SkinModel(samples: samples) {
            let bytes = SkinMask.make(photo: photo, alpha: out.alpha, model: model, exclusion: featureExclusion(small))
            skin = picture(gray: bytes, w: W, h: H)
            Log.note("mask", "\(name): skin from \(samples.count) samples in \(Log.seconds(since: stage))")
        } else {
            Log.note("mask", "\(name): no skin mask (\(faces.isEmpty ? "no face found" : "too few skin samples"))")
        }

        let coarse8 = first.v.map { UInt8(min(max($0, 0), 1) * 255) }
        guard let alpha = picture(gray: out.alpha, w: W, h: H), let shares = picture(rgbx: out.shares, w: W, h: H),
              let trimap = picture(gray: out.trimap, w: out.trimapW, h: out.trimapH),
              let rough = picture(gray: coarse8, w: first.w, h: first.h) else { throw Failure("the mask couldn't be stored") }
        let megapixels = String(format: "%.1f", Double(out.unknownPixels) / 1_000_000)
        let summary = "\(tier.name) mask in \(Log.seconds(since: started)): \(megapixels) MP of edge refined"
        Log.note("mask", "\(name): \(summary)")
        return MaskResult(width: W, height: H, alpha: alpha, shares: shares, skin: skin, trimap: trimap, coarse: rough, tier: tier, summary: summary)
    }

    // MARK: Using a mask

    private static let mixKernel = CIColorKernel(source: """
    kernel vec4 mixByMask(__sample a, __sample d, __sample m) { return vec4(mix(d.rgb, a.rgb, m.rgb), 1.0); }
    """)

    private static let cutoutKernel = CIColorKernel(source: """
    kernel vec4 cutout(__sample d, __sample s, __sample a, float c) { return vec4(d.rgb * s.rgb + vec3(c) * (1.0 - a.r), 1.0); }
    """)

    /// Whether colours can be blended channel by channel. If not, blending falls back on one
    /// number per pixel, which is a little less clean at hair edges.
    static var blendsByChannel: Bool { mixKernel != nil }

    /// A mask picture as Core Image data, stretched over `extent`. It is numbers, not colours,
    /// so it is kept out of colour management.
    static func data(_ picture: CGImage, over extent: CGRect) -> CIImage {
        let image = CIImage(cgImage: picture, options: [.colorSpace: NSNull()])
        let sx = extent.width / CGFloat(picture.width), sy = extent.height / CGFloat(picture.height)
        return image.samplingLinear()
            .transformed(by: CGAffineTransform(scaleX: sx, y: sy))
            .transformed(by: CGAffineTransform(translationX: extent.minX, y: extent.minY))
            .cropped(to: extent)
    }

    /// `adjusted` where the mask is 1 and `original` where it is 0, separately for red, green and blue.
    static func mix(_ adjusted: CIImage, _ original: CIImage, mask: CIImage, extent: CGRect) -> CIImage {
        if let kernel = mixKernel, let out = kernel.apply(extent: extent, arguments: [adjusted, original, mask]) { return out }
        return adjusted.applyingFilter("CIBlendWithMask", parameters: [kCIInputBackgroundImageKey: original, kCIInputMaskImageKey: mask])
    }

    static func adjust(_ image: CIImage, _ layer: LocalLayer) -> CIImage {
        var out = image
        if layer.exposure != 0 { out = out.applyingFilter("CIExposureAdjust", parameters: [kCIInputEVKey: layer.exposure]) }
        if layer.saturation != 1 { out = out.applyingFilter("CIColorControls", parameters: [kCIInputSaturationKey: layer.saturation]) }
        if layer.warmth != 0 {
            // More red and less blue is warmer. Plain gains, so the blend stays exact.
            let w = CGFloat(layer.warmth) * 0.25
            out = out.applyingFilter("CIColorMatrix", parameters: [
                "inputRVector": CIVector(x: 1 + w, y: 0, z: 0, w: 0),
                "inputBVector": CIVector(x: 0, y: 0, z: 1 - w, w: 0),
            ])
        }
        return out
    }

    /// Applies a frame's local adjustments, and the chosen way of looking at the mask, to a
    /// developed image.
    static func apply(_ local: LocalRender, to image: CIImage, extent: CGRect) -> CIImage {
        var out = image
        let shares = data(local.mask.shares, over: extent)
        for area in LocalArea.allCases where !local.edits.layers[area.rawValue].isNeutral {
            let mask: CIImage
            switch area {
            case .subject: mask = shares
            case .background: mask = shares.applyingFilter("CIColorInvert")
            case .skin:
                guard let skin = local.mask.skin else { continue }
                mask = data(skin, over: extent)
            }
            out = mix(adjust(out, local.edits.layers[area.rawValue]), out, mask: mask, extent: extent)
        }

        let alpha = data(local.mask.alpha, over: extent)
        // The mask being looked at: the chosen area's.
        var chosen = alpha, chosenShares = shares
        if local.area == .background {
            chosen = alpha.applyingFilter("CIColorInvert")
            chosenShares = shares.applyingFilter("CIColorInvert")
        } else if local.area == .skin, let skin = local.mask.skin {
            chosen = data(skin, over: extent)
            chosenShares = chosen
        }
        switch local.view {
        case .photo:
            return out
        case .mask:
            return chosen
        case .overlay:
            let red = CIImage(color: CIColor(red: 1, green: 0, blue: 0)).cropped(to: extent)
            let half = chosen.applyingFilter("CIColorMatrix", parameters: [
                "inputRVector": CIVector(x: 0.55, y: 0, z: 0, w: 0), "inputGVector": CIVector(x: 0, y: 0.55, z: 0, w: 0),
                "inputBVector": CIVector(x: 0, y: 0, z: 0.55, w: 0),
            ])
            return red.applyingFilter("CIBlendWithMask", parameters: [kCIInputBackgroundImageKey: out, kCIInputMaskImageKey: half])
        case .onBlack, .onWhite:
            // The area cut out and laid on a plain colour, which shows any halo at once.
            let c: Float = local.view == .onWhite ? 1 : 0
            if let kernel = cutoutKernel, let cut = kernel.apply(extent: extent, arguments: [out, chosenShares, chosen, c]) { return cut }
            let plain = CIImage(color: CIColor(red: CGFloat(c), green: CGFloat(c), blue: CGFloat(c))).cropped(to: extent)
            return out.applyingFilter("CIBlendWithMask", parameters: [kCIInputBackgroundImageKey: plain, kCIInputMaskImageKey: chosen])
        }
    }
}
