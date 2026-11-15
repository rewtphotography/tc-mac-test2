import AppKit
import CoreImage
import ImageIO
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

/// Where the first, rough idea of the subject comes from. The letters are the candidates of
/// the masking spec's bake-off.
enum SubjectSource: String, CaseIterable {
    case vision = "V", birefnet = "A", sam = "B", samCrop = "B2", hybrid = "C"

    var name: String {
        switch self {
        case .vision: return "Vision"
        case .birefnet: return "BiRefNet"
        case .sam: return "SAM"
        case .samCrop: return "SAM + close-up"
        case .hybrid: return "Hybrid"
        }
    }

    /// Whether this build carries the models the source needs.
    var available: Bool {
        switch self {
        case .vision: return true
        case .birefnet: return BundledModels.hasBiRefNet
        case .sam, .samCrop: return BundledModels.hasSAM
        case .hybrid: return BundledModels.hasSAM && BundledModels.hasBiRefNet
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
        // In sRGB, which is what Vision and every segmentation model were trained on.
        guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return nil }
        ctx.interpolationQuality = .high
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        return ctx.makeImage()
    }

    /// The brightness of a picture, 0 to 1, top row first.
    static func luma(of image: CGImage) -> Gray? {
        guard let photo = photo(from: image) else { return nil }
        var out = Gray(w: photo.w, h: photo.h)
        for y in 0 ..< photo.h {
            for x in 0 ..< photo.w {
                let c = photo.rgb(x, y)
                out.v[y * photo.w + x] = 0.2126 * c.x + 0.7152 * c.y + 0.0722 * c.z
            }
        }
        return out
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

    /// One face as Apple's landmark detector sees it, in pixels of the picture with y down.
    struct FaceMarks {
        let rect: CGRect
        /// Outlines by name: leftEye, rightEye, leftEyebrow, rightEyebrow, outerLips, nose, faceContour.
        let regions: [String: [CGPoint]]
    }

    static func faceMarks(_ image: CGImage) -> [FaceMarks] {
        autoreleasepool {
            let request = VNDetectFaceLandmarksRequest()
            let handler = VNImageRequestHandler(cgImage: image, options: [:])
            guard (try? handler.perform([request])) != nil, let faces = request.results else { return [] }
            let w = CGFloat(image.width), h = CGFloat(image.height)
            return faces.map { face in
                let box = face.boundingBox // fractions of the picture, origin at the bottom left
                let rect = CGRect(x: box.minX * w, y: (1 - box.maxY) * h, width: box.width * w, height: box.height * h)
                var regions: [String: [CGPoint]] = [:]
                if let marks = face.landmarks {
                    let named: [(String, VNFaceLandmarkRegion2D?)] = [
                        ("leftEye", marks.leftEye), ("rightEye", marks.rightEye), ("leftEyebrow", marks.leftEyebrow),
                        ("rightEyebrow", marks.rightEyebrow), ("outerLips", marks.outerLips), ("nose", marks.nose),
                        ("faceContour", marks.faceContour),
                    ]
                    for (name, region) in named {
                        guard let points = region?.pointsInImage(imageSize: CGSize(width: w, height: h)), !points.isEmpty else { continue }
                        regions[name] = points.map { CGPoint(x: $0.x, y: h - $0.y) }
                    }
                }
                return FaceMarks(rect: rect, regions: regions)
            }
        }
    }

    /// Where skin must not be selected: eyes, eyebrows and lips, drawn from Apple's face
    /// landmarks, a little enlarged and feathered. A plane the size of `image`, 1 = keep out.
    static func featureExclusion(_ image: CGImage, marks: [FaceMarks]? = nil) -> Gray? {
        let faces = marks ?? faceMarks(image)
        if faces.isEmpty { return nil }
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
            grow = max(grow, 0.02 * face.rect.height)
            ctx.setLineWidth(grow)
            for name in ["leftEye", "rightEye", "leftEyebrow", "rightEyebrow", "outerLips"] {
                guard let points = face.regions[name], points.count > 2 else { continue }
                // The drawing context counts y upwards; the points count it downwards.
                ctx.beginPath()
                ctx.addLines(between: points.map { CGPoint(x: $0.x, y: CGFloat(h) - $0.y) })
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

    // MARK: Making a mask

    /// Makes the masks for one raw file. Runs for seconds; call it off the main thread.
    static func make(url: URL, tier: MatteTier, faces known: DetectedFaces?, settings: MatteSettings = MatteSettings(),
                     subject: SubjectSource = .vision, progress: (String) -> Void, cancelled: () -> Bool) throws -> MaskResult {
        let reference = try neutral(url)
        return try make(reference: reference, name: url.lastPathComponent, tier: tier, faces: known, settings: settings,
                        subject: subject, progress: progress, cancelled: cancelled)
    }

    /// A first pass from the segmentation models, at the proxy's size (masking spec v2,
    /// section 6). `face` is the subject's face in proxy pixels.
    static func modelPass(_ source: SubjectSource, proxy small: CGImage, reference: CGImage, face: PixelRect, sharpness map: SharpnessMap,
                          name: String, progress: (String) -> Void) throws -> Gray {
        let w = small.width, h = small.height
        let rules = SubjectRules()
        let scale = Double(reference.width) / Double(w)
        let body = Box(SubjectChoice.bodyBox(face: face, w: w, h: h))
        /// A box of the proxy, cut from the full-size photo.
        func crop(_ box: Box) -> CGImage? {
            let x: Double = Double(box.x0) * scale, y: Double = Double(box.y0) * scale
            let cw: Double = Double(box.x1 - box.x0) * scale, ch: Double = Double(box.y1 - box.y0) * scale
            return reference.cropping(to: CGRect(x: x, y: y, width: cw, height: ch))
        }
        let centre: (x: Float, y: Float) = (Float(face.x) + Float(face.w) / 2, Float(face.y) + Float(face.h) / 2)
        var asked: [SAMModel.Point] = []
        for point in SubjectSelect.points(face: face, h: h) { asked.append(SAMModel.Point(x: point.x, y: point.y, label: 1)) }

        // BiRefNet's shapes: the whole proxy, then a closer look at the subject's box.
        var shape: Gray?
        var wide = body
        if source == .birefnet || source == .hybrid {
            progress("BiRefNet")
            let whole = try BiRefNetModel.shared.segment(small).resized(w: w, h: h)
            let (roughKept, _) = SubjectSelect.keep(whole, sharpness: map, face: face, rules: rules)
            var x0 = w, y0 = h, x1 = 0, y1 = 0
            for y in 0 ..< h { for x in 0 ..< w where roughKept.v[y * w + x] >= 0.5 { x0 = min(x0, x); x1 = max(x1, x + 1); y0 = min(y0, y); y1 = max(y1, y + 1) } }
            if x1 > x0 { wide = body.union(Box(x0: x0, y0: y0, x1: x1, y1: y1)) }
            wide = wide.expanded(by: rules.boxExpand, w: w, h: h)
            var merged = whole
            if wide.area * 10 <= w * h * 8, let close = crop(wide) {
                progress("BiRefNet close-up")
                merged = SubjectSelect.merge(whole, inside: try BiRefNetModel.shared.segment(close), box: wide, rules: rules)
            } else {
                Log.note("base", "\(name): BiRefNet close-up skipped (the subject's box is most of the frame)")
            }
            shape = merged
        }
        if source == .birefnet, let shape = shape {
            let (mask, decision) = SubjectSelect.keep(shape, sharpness: map, face: face, rules: rules)
            Log.note("base", "\(name): \(decision.summary)")
            return mask
        }

        // SAM: which thing is the subject, from two points on them and a box around them.
        progress("SAM")
        let taken = try SAMModel.shared.embed(small)
        let box = source == .hybrid ? wide : body
        let answers = try SAMModel.shared.decode(taken, points: asked, box: box)
        guard let which = SAMModel.shared.best(answers, containing: centre, in: taken, w: w, h: h) else { throw Failure("SAM gave no answer") }
        var answer = which.mask
        Log.note("base", "\(name): SAM primary IoU \(String(format: "%.2f", which.score)) · box \(box.x0),\(box.y0)–\(box.x1),\(box.y1) · points \(asked.count)")
        if which.score < 0.85 { Log.warn("\(name): SAM is unsure of its answer (\(String(format: "%.2f", which.score)))") }
        if source == .samCrop, let close = crop(body) {
            progress("SAM close-up")
            let k = Float(close.width) / Float(body.x1 - body.x0)
            let closeW = Float(close.width), closeH = Float(close.height)
            var inside: [SAMModel.Point] = []
            for point in asked {
                let x: Float = (point.x - Float(body.x0)) * k
                let y: Float = (point.y - Float(body.y0)) * k
                if x >= 0, y >= 0, x < closeW, y < closeH { inside.append(SAMModel.Point(x: x, y: y, label: 1)) }
            }
            let again = try SAMModel.shared.embed(close)
            let all = Box(x0: 0, y0: 0, x1: close.width, y1: close.height)
            let closeAnswers = try SAMModel.shared.decode(again, points: inside, box: all)
            if let first = inside.first,
               let closer = SAMModel.shared.best(closeAnswers, containing: (first.x, first.y), in: again, w: 512, h: 512) {
                answer = SubjectSelect.merge(answer, inside: closer.mask, box: body, rules: rules)
                Log.note("base", "\(name): SAM close-up IoU \(String(format: "%.2f", closer.score))")
            }
        }
        if source == .hybrid, let shape = shape {
            let (mask, decision) = SubjectSelect.hybrid(shape: shape, which: answer, sharpness: map, face: face, rules: rules)
            Log.note("base", "\(name): \(decision.summary)")
            return mask
        }
        let (mask, decision) = SubjectSelect.keep(answer, sharpness: map, face: face, rules: rules)
        Log.note("base", "\(name): \(decision.summary)")
        return mask
    }

    /// The last neutral render, kept so that remaking a mask at another quality, or exporting
    /// its debug bundle, doesn't develop the raw again.
    private static var kept: (url: URL, image: CGImage)?
    private static let keptLock = NSLock()

    /// A neutral render of a raw: the camera's white balance, Apple's defaults, none of the frame's edits.
    static func neutral(_ url: URL) throws -> CGImage {
        keptLock.lock()
        let hit = kept?.url == url ? kept?.image : nil
        keptLock.unlock()
        if let hit = hit {
            Log.debug("cache", "neutral \(url.lastPathComponent) · hit")
            return hit
        }
        let started = CFAbsoluteTimeGetCurrent()
        guard let reference = Imaging.renderRaw(url) else { throw Failure("Apple's raw decoder can't open this file on this Mac") }
        Log.note("cache", "neutral \(url.lastPathComponent) · miss: \(kept == nil ? "cold" : "another image") · rendered \(reference.width)×\(reference.height) in \(Log.seconds(since: started))")
        keptLock.lock()
        kept = (url, reference)
        keptLock.unlock()
        return reference
    }

    static func forgetNeutral() {
        keptLock.lock()
        kept = nil
        keptLock.unlock()
    }

    /// The faces of a picture ranked as subjects (§5.1 of the masking spec), with what was
    /// measured to rank them.
    struct Ranking {
        let sharpness: SharpnessMap?
        let candidates: [SubjectChoice.Candidate]
        var primary: SubjectChoice.Candidate? { candidates.first }
    }

    static func rank(proxy small: CGImage, faces: [PixelRect]) -> Ranking {
        guard let luma = luma(of: small) else { return Ranking(sharpness: nil, candidates: []) }
        let map = SharpnessMap(luma: luma)
        return Ranking(sharpness: map, candidates: SubjectChoice.rank(faces, sharpness: map))
    }

    /// The same, from a picture already rendered.
    static func make(reference: CGImage, name: String, tier: MatteTier, faces known: DetectedFaces?, settings: MatteSettings = MatteSettings(),
                     subject: SubjectSource = .vision, coarse given: Gray? = nil, progress: (String) -> Void, cancelled: () -> Bool) throws -> MaskResult {
        let started = CFAbsoluteTimeGetCurrent()
        let W = reference.width, H = reference.height
        guard let photo = photo(from: reference) else { throw Failure("the rendered photo isn't in the expected 8-bit form") }
        guard let small = proxy(of: reference, longEdge: proxyLongEdge) else { throw Failure("the photo couldn't be scaled down") }

        // Faces, in pixels of the full photo with y down.
        var stage = CFAbsoluteTimeGetCurrent()
        let found = known ?? Imaging.detectFaces(small)
        let k = found.imageWidth > 0 ? Double(W) / found.imageWidth : 1
        let faces = found.subjects.map { s in
            PixelRect(x: Int(s.left * k), y: Int(s.top * k), w: max(Int(s.width * k), 1), h: max(Int(s.height * k), 1))
        }.sorted { $0.h > $1.h }

        // Which face is the subject, and how sharp it is: the rest of the photo is judged
        // against that, so that colour arithmetic isn't trusted where things are out of focus.
        let toProxy = Double(small.width) / Double(W)
        let ranking = rank(proxy: small, faces: faces.map { f in
            PixelRect(x: Int(Double(f.x) * toProxy), y: Int(Double(f.y) * toProxy), w: max(Int(Double(f.w) * toProxy), 1), h: max(Int(Double(f.h) * toProxy), 1))
        })
        let number = { (v: Float?) in v.map { String(format: "%.2f px", locale: Locale(identifier: "en_US_POSIX"), $0) } ?? "unmeasured" }
        if let primary = ranking.primary {
            let others = ranking.candidates.dropFirst().map { number($0.sharp) }.joined(separator: ", ")
            Log.note("base", "\(name): faces \(faces.count) → primary score \(Int(primary.score)), faceSharp \(number(primary.sharp))"
                + (others.isEmpty ? "" : " · others' faceSharp [\(others)]") + " · sharpness map in \(Log.seconds(since: stage))")
        } else {
            Log.warn("\(name): no usable face; the whole photo is treated as in focus")
        }

        // The first pass: roughly what the subject is, from the chosen source.
        progress("Finding the subject")
        stage = CFAbsoluteTimeGetCurrent()
        var used = subject
        var coarse = given
        if coarse == nil && subject != .vision {
            if let primary = ranking.primary, let map = ranking.sharpness {
                coarse = try modelPass(subject, proxy: small, reference: reference, face: primary.face, sharpness: map, name: name, progress: progress)
            } else {
                Log.warn("\(name): \(subject.name) needs a face to start from and none was found; using Vision")
                used = .vision
            }
        }
        var visionKind = "given"
        if coarse == nil, let people = personMask(small), people.v.reduce(0, +) / Float(people.v.count) > 0.003 {
            coarse = people
            visionKind = "people"
        }
        if coarse == nil, let whole = subjectMask(small) {
            coarse = whole
            visionKind = "foreground"
        }
        guard let first = coarse else { throw Failure("no subject was found in this photo") }
        let coverage = 100 * first.v.reduce(0, +) / Float(max(first.v.count, 1))
        Log.note("base", "\(name): candidate \(used.rawValue) (\(used == .vision ? "Vision \(visionKind)" : used.name)) · subject area "
            + "\(String(format: "%.1f", locale: Locale(identifier: "en_US_POSIX"), coverage))% of frame · first pass \(Log.seconds(since: stage))")

        // A second, closer look at each head, at full size, for the better tiers. Vision's
        // look, so only when Vision made the first pass.
        var patches: [HeadPatch] = []
        if tier != .fast && given == nil && used == .vision {
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

        let matte = Matte(photo: photo, coarse: first, faces: faces, patches: patches, settings: settings,
                          defocus: ranking.sharpness?.dense, subjectSharpness: ranking.primary?.sharp)
        MemoryMonitor.mark("setting up a \(tier.name) mask")
        let out = matte.run(tier: tier, progress: progress, cancelled: cancelled)
        for line in out.log { Log.note("mask", "\(name): \(line)") }
        for warning in out.warnings { Log.warn("\(name): \(warning) (\(tier.name) mask)") }
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
        let summary = "\(tier.name) mask from \(used.name) in \(Log.seconds(since: started)): \(megapixels) MP of edge refined"
            + (out.warnings.isEmpty ? "" : " · check: " + out.warnings.joined(separator: ", "))
        Log.note("mask", "\(name): \(summary)")
        return MaskResult(width: W, height: H, alpha: alpha, shares: shares, skin: skin, trimap: trimap, coarse: rough, tier: tier, summary: summary)
    }

    // MARK: Debug bundle

    static func png(_ image: CGImage) -> Data? {
        let data = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(data, "public.png" as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(dest, image, nil)
        return CGImageDestinationFinalize(dest) ? data as Data : nil
    }

    /// Writes what a subject-selection model would be given for this photo, and what the
    /// current first pass makes of it, into a new folder next to the raw: the inputs for
    /// comparing models outside the app (the masking spec's bake-off).
    static func debugBundle(url: URL, faces known: DetectedFaces?) throws -> URL {
        let reference = try neutral(url)
        let W = reference.width, H = reference.height
        guard let small = proxy(of: reference, longEdge: proxyLongEdge), let proxyData = png(small) else { throw Failure("the photo couldn't be scaled down") }
        let scale = Double(W) / Double(small.width)

        let marks = faceMarks(small)
        var rects = marks.map { PixelRect(x: Int($0.rect.minX), y: Int($0.rect.minY), w: max(Int($0.rect.width), 1), h: max(Int($0.rect.height), 1)) }
        if rects.isEmpty, let found = known, found.imageWidth > 0 {
            let k = Double(small.width) / found.imageWidth
            rects = found.subjects.map { PixelRect(x: Int($0.left * k), y: Int($0.top * k), w: max(Int($0.width * k), 1), h: max(Int($0.height * k), 1)) }
        }
        let ranking = rank(proxy: small, faces: rects)

        let fm = FileManager.default
        let parent = url.deletingLastPathComponent(), base = url.deletingPathExtension().lastPathComponent
        var folder = parent.appendingPathComponent("\(base)-maskdebug", isDirectory: true)
        var n = 2
        while fm.fileExists(atPath: folder.path) {
            folder = parent.appendingPathComponent("\(base)-maskdebug-\(n)", isDirectory: true)
            n += 1
        }
        try fm.createDirectory(at: folder, withIntermediateDirectories: false)
        try proxyData.write(to: folder.appendingPathComponent("proxy.png"))

        // Faces, in proxy pixels with y down, best subject first.
        func list(_ r: PixelRect) -> [Int] { [r.x, r.y, r.w, r.h] }
        var facesJSON: [[String: Any]] = []
        for (i, candidate) in ranking.candidates.enumerated() {
            var entry: [String: Any] = ["rect": list(candidate.face), "primary": i == 0, "score": Double(candidate.score)]
            if let sharp = candidate.sharp { entry["faceSharp"] = Double(sharp) }
            if let mark = marks.first(where: { abs(Int($0.rect.minX) - candidate.face.x) <= 1 && abs(Int($0.rect.minY) - candidate.face.y) <= 1 }) {
                entry["landmarks"] = mark.regions.mapValues { points in points.map { [Double($0.x), Double($0.y)] } }
            }
            facesJSON.append(entry)
        }
        let facesDoc: [String: Any] = ["image": url.lastPathComponent, "proxy_size": [small.width, small.height], "full_size": [W, H],
                                       "units": "proxy pixels, origin top left, y down", "faces": facesJSON]
        try JSONSerialization.data(withJSONObject: facesDoc, options: [.prettyPrinted, .sortedKeys]).write(to: folder.appendingPathComponent("faces.json"))

        // The body box of the primary face, cut from the full-size render.
        if let primary = ranking.primary {
            let box = SubjectChoice.bodyBox(face: primary.face, w: small.width, h: small.height)
            let full = PixelRect(x: Int(Double(box.x) * scale), y: Int(Double(box.y) * scale), w: Int(Double(box.w) * scale), h: Int(Double(box.h) * scale)).clamped(w: W, h: H)
            if let crop = reference.cropping(to: CGRect(x: full.x, y: full.y, width: full.w, height: full.h)),
               let shrunk = proxy(of: crop, longEdge: proxyLongEdge), let data = png(shrunk) {
                try data.write(to: folder.appendingPathComponent("box_crop_hr.png"))
                let doc: [String: Any] = ["box_proxy": list(box), "box_full": list(full), "crop_size": [shrunk.width, shrunk.height],
                                          "units": "pixels, origin top left, y down; x, y, width, height"]
                try JSONSerialization.data(withJSONObject: doc, options: [.prettyPrinted, .sortedKeys]).write(to: folder.appendingPathComponent("box.json"))
            }
        }

        // The current first pass, at the proxy's size.
        var source = "none"
        var first = personMask(small)
        if let people = first, people.v.reduce(0, +) / Float(people.v.count) > 0.003 { source = "people" } else {
            first = subjectMask(small)
            source = first == nil ? "none" : "foreground"
        }
        if let first = first?.resized(w: small.width, h: small.height),
           let picture = picture(gray: first.v.map { UInt8(min(max($0, 0), 1) * 255) }, w: first.w, h: first.h), let data = png(picture) {
            try data.write(to: folder.appendingPathComponent("current_m0.png"))
        }

        let readme = """
        Mask debug bundle for \(url.lastPathComponent)

        proxy.png         the picture a subject-selection model is given (sRGB, long edge \(proxyLongEdge))
        box_crop_hr.png   the area around the main person, from the full-size photo; box.json says where it is
        faces.json        the faces found, best subject first, with their outlines
        current_m0.png    what TrainCull's current first pass selects (Vision \(source))

        To make the reference mask ("ground truth") for this photo:
          1. Open proxy.png in Photoshop.
          2. Paint the subject pure white and everything else pure black, at the same size.
             Include anything the subject is holding or wearing. Leave other people out.
          3. Save it in this folder as gt_subject.png. (A Photoshop Select Subject mask saved as
             ps_mask-<number>.jpg is also understood, as a reference rather than the truth.)
          Optional: the same for skin only, saved as gt_skin.png.
        Then compress this folder (right-click, Compress) and send the zip.
        """
        try Data(readme.utf8).write(to: folder.appendingPathComponent("README.txt"))
        Log.note("mask", "\(url.lastPathComponent): debug bundle written to \(folder.path) · faces \(ranking.candidates.count) · first pass \(source)")
        return folder
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
            // The mask's numbers are amounts, not brightnesses. Shown as they are they would
            // come out too light, so they are treated as display values for this view only.
            return chosen.applyingFilter("CISRGBToneCurveToLinear")
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
