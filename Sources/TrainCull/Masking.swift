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

/// Where the first, rough idea of the subject comes from. BiRefNet is the subject model
/// (masking spec v3); Apple's Vision masks are kept behind a debug switch, for comparison.
enum SubjectSource: String, CaseIterable {
    case vision = "V", birefnet = "A"

    var name: String {
        switch self {
        case .vision: return "Vision (legacy)"
        case .birefnet: return "BiRefNet"
        }
    }

    /// Whether this build carries the model the source needs.
    var available: Bool {
        switch self {
        case .vision: return true
        case .birefnet: return BundledModels.hasBiRefNet
        }
    }
}

/// The user's Focus strictness: how readily pieces that are softer than the subject's face
/// are left out of the mask.
enum FocusStrictness: String, CaseIterable {
    case loose, moderate, strict

    var name: String { rawValue.capitalized }

    var factor: Float {
        switch self {
        case .loose: return 0.6
        case .moderate: return 1.0
        case .strict: return 1.4
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
    case photo, overlay, mask, onBlack, onWhite, dimmed, zones

    var name: String {
        switch self {
        case .photo: return "Photo"
        case .overlay: return "Red Overlay"
        case .mask: return "Mask"
        case .onBlack: return "On Black"
        case .onWhite: return "On White"
        case .dimmed: return "Background −3 EV"
        case .zones: return "Zones (debug)"
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
    /// For inspection, laid over the photo: the hair zone, where the edge was snapped and
    /// where colour matting ran, the close-up boxes, the body pose.
    let debug: CGImage?
    let tier: MatteTier
    let edge: EdgeQuality
    let summary: String

    init(width: Int, height: Int, alpha: CGImage, shares: CGImage, skin: CGImage?, trimap: CGImage, coarse: CGImage, debug: CGImage? = nil,
         tier: MatteTier, edge: EdgeQuality = EdgeQuality(), summary: String) {
        self.width = width; self.height = height
        self.alpha = alpha; self.shares = shares; self.skin = skin
        self.trimap = trimap; self.coarse = coarse; self.debug = debug
        self.tier = tier; self.edge = edge; self.summary = summary
    }

    func picture(for area: LocalArea) -> CGImage? { area == .skin ? skin : shares }
}

/// What is known about a photo's subject before any edge is refined: the faces, the
/// sharpness map, the body pose and the first-pass mask. Making it runs the model; it is kept
/// for each photo so that changing the refinement tier doesn't (masking spec v3, section 9).
final class SubjectBase {
    let key: String
    let source: SubjectSource
    /// Faces in pixels of the full photo, largest first.
    let faces: [PixelRect]
    let proxy: CGImage
    let ranking: Masking.Ranking
    /// The first-pass mask after selection and close-ups, possibly finer than the proxy.
    let coarse: Gray
    /// The same before the close-ups, at the proxy's size; nil when it didn't come from BiRefNet.
    let selected: Gray?
    let patches: [HeadPatch]
    let poses: [BodyPose]
    let primaryPose: Int?
    /// The close-up boxes, in proxy pixels, and whether each was used.
    let tiles: [(box: Box, used: Bool)]
    let subjectBox: Box?
    /// How much the close-up tiles' borders show in the mask; over 3 is a visible seam.
    let seam: Float?
    let seconds: Double

    init(key: String, source: SubjectSource, faces: [PixelRect], proxy: CGImage, ranking: Masking.Ranking, coarse: Gray, selected: Gray?,
         patches: [HeadPatch], poses: [BodyPose], primaryPose: Int?, tiles: [(box: Box, used: Bool)], subjectBox: Box?, seam: Float? = nil, seconds: Double) {
        self.key = key; self.source = source; self.faces = faces; self.proxy = proxy; self.ranking = ranking
        self.coarse = coarse; self.selected = selected; self.patches = patches
        self.poses = poses; self.primaryPose = primaryPose; self.tiles = tiles; self.subjectBox = subjectBox; self.seam = seam; self.seconds = seconds
    }
}

/// A mask and what to do with it when a frame is rendered.
struct LocalRender {
    let mask: MaskResult
    var edits: LocalEdits
    var view: MaskView
    var area: LocalArea
}

/// Subject, hair-edge and skin masks. BiRefNet says what the subject is; the matting engine
/// in TraincullCore works out exactly where its edge lies. Masks are made from
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

    // MARK: Body pose

    private static let jointNames: [(VNHumanBodyPoseObservation.JointName, String)] = [
        (.nose, "nose"), (.neck, "neck"), (.root, "root"),
        (.leftShoulder, "leftShoulder"), (.rightShoulder, "rightShoulder"), (.leftElbow, "leftElbow"), (.rightElbow, "rightElbow"),
        (.leftWrist, "leftWrist"), (.rightWrist, "rightWrist"), (.leftHip, "leftHip"), (.rightHip, "rightHip"),
        (.leftKnee, "leftKnee"), (.rightKnee, "rightKnee"), (.leftAnkle, "leftAnkle"), (.rightAnkle, "rightAnkle"),
    ]

    /// Every person's joints as Apple's body-pose detector finds them, in pixels of the
    /// picture with y down.
    static func bodyPoses(_ image: CGImage) -> [BodyPose] {
        autoreleasepool {
            let request = VNDetectHumanBodyPoseRequest()
            let handler = VNImageRequestHandler(cgImage: image, options: [:])
            guard (try? handler.perform([request])) != nil, let people = request.results else { return [] }
            let w = Float(image.width), h = Float(image.height)
            var poses: [BodyPose] = []
            for person in people {
                var joints: [String: BodyPose.Joint] = [:]
                for (joint, name) in jointNames {
                    guard let point = try? person.recognizedPoint(joint), point.confidence > 0 else { continue }
                    // Vision counts from the bottom left, in fractions of the picture.
                    joints[name] = BodyPose.Joint(x: Float(point.location.x) * w, y: (1 - Float(point.location.y)) * h, confidence: Float(point.confidence))
                }
                if !joints.isEmpty { poses.append(BodyPose(joints: joints)) }
            }
            return poses
        }
    }

    // MARK: What is kept between runs

    static let keptNeutrals = 3
    static let keptBases = 3
    private static let keptLock = NSLock()
    /// Neutral renders of the last few raws: making or remaking a mask, changing its tier or
    /// exporting its debug bundle then doesn't develop the raw again.
    private static var neutrals: [(url: URL, image: CGImage)] = []
    /// What is known about the subject of the last few photos masked.
    private static var bases: [SubjectBase] = []
    /// The edge engine set up for the last photo masked, so another tier starts from there.
    private static var keptMatte: (base: SubjectBase, matte: Matte)?

    /// A neutral render of a raw: the camera's white balance, Apple's defaults, none of the frame's edits.
    static func neutral(_ url: URL) throws -> CGImage {
        keptLock.lock()
        var hit: CGImage?
        if let i = neutrals.firstIndex(where: { $0.url == url }) {
            let entry = neutrals.remove(at: i)
            neutrals.append(entry)
            hit = entry.image
        }
        let had = neutrals.count
        keptLock.unlock()
        if let hit = hit {
            Log.debug("cache", "neutral \(url.lastPathComponent) · hit")
            return hit
        }
        let started = CFAbsoluteTimeGetCurrent()
        guard let reference = Imaging.renderRaw(url) else { throw Failure("Apple's raw decoder can't open this file on this Mac") }
        keptLock.lock()
        neutrals.removeAll { $0.url == url }
        neutrals.append((url, reference))
        while neutrals.count > keptNeutrals { neutrals.removeFirst() }
        let now = neutrals.count
        keptLock.unlock()
        let why: String = had == 0 ? "cold" : "another image"
        Log.note("cache", "neutral \(url.lastPathComponent) · miss: \(why) · rendered \(reference.width)×\(reference.height) in \(Log.seconds(since: started)) · \(now) of \(keptNeutrals) kept")
        return reference
    }

    /// Lets go of everything kept: another folder was opened, or the Mac is short of memory.
    static func forgetAll(_ why: String) {
        keptLock.lock()
        let had = neutrals.count + bases.count + (keptMatte == nil ? 0 : 1)
        neutrals = []
        bases = []
        keptMatte = nil
        keptLock.unlock()
        if had > 0 { Log.note("cache", "masking caches emptied (\(why))") }
    }

    /// Forgets what is known about one photo's subject, so that Remake works it out afresh.
    static func forgetBase(_ url: URL) {
        let prefix = url.path + "|"
        keptLock.lock()
        let had = bases.count
        bases.removeAll { $0.key.hasPrefix(prefix) }
        if let kept = keptMatte, kept.base.key.hasPrefix(prefix) { keptMatte = nil }
        let dropped = had - bases.count
        keptLock.unlock()
        if dropped > 0 { Log.note("cache", "base \(url.lastPathComponent) · cleared for a remake") }
    }

    /// What a photo's base is kept under: the file, where the subject comes from, the settings
    /// that change it, and the model.
    static func baseKey(_ url: URL, _ subject: SubjectSource, _ rules: SubjectRules) -> String {
        "\(url.path)|\(subject.rawValue)|\(rules.focusStrictness)|\(proxyLongEdge)|\(BiRefNetModel.version)"
    }

    /// What is kept, for the log's regular summary.
    static var keptSummary: String {
        keptLock.lock()
        defer { keptLock.unlock() }
        let bytes = neutrals.reduce(0) { $0 + $1.image.bytesPerRow * $1.image.height }
        return "neutral renders \(neutrals.count) / \(MemoryStats.plain(UInt64(bytes))) · bases \(bases.count) · edge engine \(keptMatte == nil ? "not kept" : "kept")"
    }

    // MARK: The subject

    /// The faces of a picture ranked as subjects, with what was measured to rank them.
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

    /// A picture drawn into a square of a given side, in sRGB: what the model is shown.
    static func square(of image: CGImage, side: Int) -> CGImage? {
        guard let ctx = CGContext(data: nil, width: side, height: side, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return nil }
        ctx.interpolationQuality = .high
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: side, height: side))
        return ctx.makeImage()
    }

    /// What BiRefNet's part of the base comes to.
    struct ModelPass {
        var coarse: Gray
        var selected: Gray
        var poses: [BodyPose] = []
        var primaryPose: Int?
        var tiles: [(box: Box, used: Bool)] = []
        var subjectBox: Box?
        var seam: Float?
    }

    /// The first pass from BiRefNet (masking spec v3, sections 3, 4.1, 6 and 7): the whole
    /// frame, the pieces of its answer that are the subject, then closer looks at the subject
    /// cut from the full-size photo. `face` is the subject's face in proxy pixels, if any.
    static func birefnetPass(proxy small: CGImage, reference: CGImage, face: PixelRect?, sharpness map: SharpnessMap, rules: SubjectRules,
                             name: String, progress: (String) -> Void) throws -> ModelPass {
        let w = small.width, h = small.height
        let posix = Locale(identifier: "en_US_POSIX")
        let side = BundledModels.hasBiRefNet ? BiRefNetModel.shared.inputSide : 1024

        // The body pose: which limbs are certainly the subject's.
        var stage = CFAbsoluteTimeGetCurrent()
        progress("Body pose")
        let poses = bodyPoses(small)
        var primaryPose: Int?
        if let face = face { primaryPose = BodyPose.match(poses, face: face, least: rules.poseConfidence) }
        var limbs: [Bool]?
        if let i = primaryPose, let face = face {
            limbs = poses[i].confirmed(radius: rules.capsule * Float(face.h), w: w, h: h, least: rules.poseConfidence)
        }
        var matched = "not matched"
        if let i = primaryPose { matched = "matched (pose \(i + 1))" } else if face == nil { matched = "not matched (no face)" }
        else if !poses.isEmpty { matched = "not matched (no pose's head is near the primary face)" }
        Log.note("pose", "\(name): \(poses.count) pose(s) in \(Log.seconds(since: stage)) · primary person \(matched)")
        for (i, pose) in poses.enumerated().prefix(6) {
            let sure = pose.sure(rules.poseConfidence).count
            var joints: [String] = []
            for (jointName, joint) in pose.joints.sorted(by: { $0.key < $1.key }) {
                joints.append(jointName + " " + String(format: "%.2f", locale: posix, joint.confidence))
            }
            let which: String = i == primaryPose ? " (primary)" : ""
            Log.note("pose", "\(name): pose \(i + 1)\(which) · \(sure) of \(pose.joints.count) joints sure · \(joints.joined(separator: ", "))")
        }

        // The whole frame, and which pieces of the answer are the subject.
        progress("BiRefNet")
        guard let frame = square(of: small, side: side) else { throw Failure("the photo couldn't be prepared for the model") }
        let whole = try BiRefNetModel.shared.segment(frame, what: "\(name) whole frame (\(w)×\(h) proxy)").resized(w: w, h: h)
        var mustKeep: (([Bool]) -> Bool)?
        if let limbs = limbs {
            mustKeep = { piece in
                var touching = 0
                for i in 0 ..< piece.count where piece[i] && limbs[i] {
                    touching += 1
                    if touching >= 16 { return true }
                }
                return false
            }
        }
        stage = CFAbsoluteTimeGetCurrent()
        let (kept, decision) = SubjectSelect.keep(whole, sharpness: map, face: face, rules: rules, mustKeep: mustKeep)
        Log.note("base", "\(name): \(decision.summary) · \(Log.seconds(since: stage))")
        for line in decision.details { Log.note("base", "\(name): \(line)") }
        if primaryPose != nil {
            for (i, pose) in poses.enumerated() where i != primaryPose {
                var inside = 0
                for joint in pose.sure(rules.poseConfidence).values where kept.at(Int(joint.x), Int(joint.y)) >= 0.5 { inside += 1 }
                if inside >= 4 { Log.warn("\(name): OTHER-PERSON? \(inside) joints of pose \(i + 1), which is not the subject's, lie inside the subject mask") }
            }
        }
        var pass = ModelPass(coarse: kept, selected: kept, poses: poses, primaryPose: primaryPose)

        // Closer looks at the subject, from the full-size photo.
        var x0 = w, y0 = h, x1 = 0, y1 = 0
        for y in 0 ..< h {
            for x in 0 ..< w where kept.v[y * w + x] >= 0.5 {
                x0 = min(x0, x); x1 = max(x1, x + 1); y0 = min(y0, y); y1 = max(y1, y + 1)
            }
        }
        if x1 <= x0 {
            Log.warn("\(name): BiRefNet selected nothing in this photo")
            return pass
        }
        let box = Box(x0: x0, y0: y0, x1: x1, y1: y1).expanded(by: rules.boxExpand, w: w, h: h)
        pass.subjectBox = box
        let percent = 100 * Double(box.area) / Double(w * h)
        let size = "\(box.x1 - box.x0)×\(box.y1 - box.y0) px of the proxy, \(String(format: "%.0f", locale: posix, percent))% of the frame"
        stage = CFAbsoluteTimeGetCurrent()
        let grid = CloseUps.tiles(covering: box, w: w, h: h, rules: rules)
        let radius = CloseUps.mergeRadius(faceHeight: face?.h, longEdge: max(w, h), rules: rules)
        let zone = CloseUps.edgeZone(kept, radius: radius)
        let scale = Double(reference.width) / Double(w)
        // The mask is kept at up to half the photo's size from here on: finer than that, a
        // close-up has nothing to add.
        let cw = min(reference.width, max(w, (reference.width + 1) / 2))
        let ch = max(Int((Double(cw) * Double(reference.height) / Double(reference.width)).rounded()), 1)
        var canvas = CloseUps.Canvas(w: cw, h: ch, scale: Float(cw) / Float(w))
        for (n, tile) in grid.enumerated() {
            var holdsEdge = false
            search: for y in stride(from: tile.y0, to: tile.y1, by: 2) {
                for x in stride(from: tile.x0, to: tile.x1, by: 2) where zone.v[y * w + x] > 0 {
                    holdsEdge = true
                    break search
                }
            }
            let rect = CGRect(x: (Double(tile.x0) * scale).rounded(), y: (Double(tile.y0) * scale).rounded(),
                              width: (Double(tile.x1 - tile.x0) * scale).rounded(), height: (Double(tile.y1 - tile.y0) * scale).rounded())
            guard holdsEdge, let crop = reference.cropping(to: rect), let picture = square(of: crop, side: side) else {
                pass.tiles.append((tile, false))
                continue
            }
            progress("Close-up \(n + 1) of \(grid.count)")
            let answer = try BiRefNetModel.shared.segment(picture, what: "\(name) close-up \(n + 1)/\(grid.count) (\(crop.width)×\(crop.height) px of the photo)")
            canvas.add(answer, box: tile, feather: rules.feather)
            pass.tiles.append((tile, true))
        }
        var seamText = "seam check n/a"
        if canvas.tiles > 0 {
            let joined = canvas.merged(over: kept, zone: zone)
            pass.coarse = joined
            // Where tiles meet must not show (masking spec v4, 1.2).
            if let ratio = canvas.seamRatio(joined) {
                pass.seam = ratio
                seamText = "seam ratio " + String(format: "%.1f", locale: posix, ratio) + (ratio > 3 ? " SEAM?" : " OK")
                if ratio > 3 { Log.warn("\(name): SEAM? the close-up tiles' borders show in the mask (ratio \(String(format: "%.1f", locale: posix, ratio)))") }
            }
        }
        let tileSide = grid.first.map { $0.x1 - $0.x0 } ?? 0
        let detail = tileSide > 0 ? 100 * Double(side) / (Double(tileSide) * scale) : 0
        let wholeDetail = 100 * Double(side) / Double(max(reference.width, reference.height))
        let detailText: String = String(format: "%.0f", locale: posix, detail)
        let wholeText: String = String(format: "%.0f", locale: posix, wholeDetail)
        let ran: String = "\(name): close-up run: the subject's box is \(size) → \(canvas.tiles) of \(grid.count) tile(s) of \(tileSide) px used (a tile with no edge in it is left out)"
        let saw: String = "the model saw \(detailText)% of the photo's detail there, \(wholeText)% in the whole frame"
        let kept2: String = "the edge may move \(Int(radius)) px · \(seamText) · mask kept at \(pass.coarse.w)×\(pass.coarse.h) · \(Log.seconds(since: stage))"
        Log.note("base", [ran, saw, kept2].joined(separator: " · "))
        return pass
    }

    /// What is known about a photo's subject, from the kept copy when there is one. `key`
    /// nil never keeps or reuses anything (tests). `given` supplies the first-pass mask itself.
    static func base(reference: CGImage, name: String, key: String?, faces known: DetectedFaces?, rules: SubjectRules = SubjectRules(),
                     subject: SubjectSource, coarse given: Gray? = nil, progress: (String) -> Void) throws -> SubjectBase {
        if let key = key {
            keptLock.lock()
            let hit = bases.first { $0.key == key }
            keptLock.unlock()
            if let hit = hit {
                Log.note("cache", "base \(name) · hit: the subject is already known, the model is not run again")
                return hit
            }
            Log.note("cache", "base \(name) · miss")
        }
        let started = CFAbsoluteTimeGetCurrent()
        let W = reference.width, H = reference.height
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
            Log.warn("\(name): no usable face; the largest thing the model finds is taken as the subject, and the whole edge is treated as hair")
        }

        // The first pass: roughly what the subject is, from the chosen source.
        progress("Finding the subject")
        stage = CFAbsoluteTimeGetCurrent()
        var used = subject
        var coarse = given
        var pass: ModelPass?
        if coarse == nil && subject == .birefnet {
            if !BundledModels.hasBiRefNet {
                Log.warn("\(name): the BiRefNet model isn't in this build; using Vision")
                used = .vision
            } else if let map = ranking.sharpness {
                let made = try birefnetPass(proxy: small, reference: reference, face: ranking.primary?.face, sharpness: map, rules: rules, name: name, progress: progress)
                pass = made
                coarse = made.coarse
            } else {
                Log.warn("\(name): the photo's sharpness couldn't be measured; using Vision")
                used = .vision
            }
        }
        var kind = given == nil ? used.name : "given"
        if coarse == nil, let people = personMask(small), people.v.reduce(0, +) / Float(people.v.count) > 0.003 {
            coarse = people
            kind = "Vision people"
        }
        if coarse == nil, let whole = subjectMask(small) {
            coarse = whole
            kind = "Vision foreground"
        }
        guard let first = coarse else { throw Failure("no subject was found in this photo") }
        var area: Float = 0
        for v in first.v where v >= 0.5 { area += 1 }
        let coverage = 100 * area / Float(max(first.v.count, 1))
        Log.note("base", "\(name): candidate \(used.rawValue) (\(kind)) · subject area "
            + "\(String(format: "%.1f", locale: Locale(identifier: "en_US_POSIX"), coverage))% of frame · first pass \(Log.seconds(since: stage))")

        // Vision's masks are coarse around hair: a second, closer look at each head, at full size.
        var patches: [HeadPatch] = []
        if given == nil && used == .vision {
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

        let seconds = CFAbsoluteTimeGetCurrent() - started
        let made = SubjectBase(key: key ?? "", source: used, faces: faces, proxy: small, ranking: ranking, coarse: first, selected: pass?.selected,
                               patches: patches, poses: pass?.poses ?? [], primaryPose: pass?.primaryPose, tiles: pass?.tiles ?? [],
                               subjectBox: pass?.subjectBox, seam: pass?.seam, seconds: seconds)
        if key != nil {
            keptLock.lock()
            bases.removeAll { $0.key == made.key }
            bases.append(made)
            while bases.count > keptBases { bases.removeFirst() }
            keptLock.unlock()
        }
        Log.note("base", "\(name): base ready in \(Log.seconds(since: started))")
        MemoryMonitor.mark("finding the subject of \(name)")
        return made
    }

    // MARK: Making a mask

    /// Makes the masks for one raw file. Runs for seconds; call it off the main thread.
    /// What is known about the photo's subject is kept, so making it again at another tier
    /// only refines the edge again. `partial` is handed the Off mask as soon as it is ready.
    static func make(url: URL, tier: MatteTier, faces known: DetectedFaces?, settings: MatteSettings = MatteSettings(), rules: SubjectRules = SubjectRules(),
                     subject: SubjectSource = .birefnet, progress: (String) -> Void, partial: ((MaskResult) -> Void)? = nil,
                     cancelled: () -> Bool) throws -> MaskResult {
        let reference = try neutral(url)
        return try make(reference: reference, name: url.lastPathComponent, key: baseKey(url, subject, rules), tier: tier, faces: known,
                        settings: settings, rules: rules, subject: subject, progress: progress, partial: partial, cancelled: cancelled)
    }

    /// The same, from a picture already rendered.
    static func make(reference: CGImage, name: String, key: String? = nil, tier: MatteTier, faces known: DetectedFaces?,
                     settings: MatteSettings = MatteSettings(), rules: SubjectRules = SubjectRules(), subject: SubjectSource = .vision,
                     coarse given: Gray? = nil, progress: (String) -> Void, partial: ((MaskResult) -> Void)? = nil,
                     cancelled: () -> Bool) throws -> MaskResult {
        let started = CFAbsoluteTimeGetCurrent()
        let found = try base(reference: reference, name: name, key: key, faces: known, rules: rules, subject: subject, coarse: given, progress: progress)
        if cancelled() { throw Failure("stopped") }

        // The edge engine, set up once for each base: the snapped edge (Off) is part of the setup.
        var ready: Matte?
        keptLock.lock()
        if let kept = keptMatte, kept.base === found { ready = kept.matte }
        keptLock.unlock()
        if ready != nil {
            Log.note("cache", "edge \(name) · hit: only the \(tier.name) refinement runs")
        } else {
            progress("Preparing the edge")
            guard let photo = photo(from: reference) else { throw Failure("the rendered photo isn't in the expected 8-bit form") }
            let fresh = Matte(photo: photo, coarse: found.coarse, faces: found.faces, patches: found.patches, settings: settings,
                              defocus: found.ranking.sharpness?.dense, subjectSharpness: found.ranking.primary?.sharp)
            if key != nil {
                keptLock.lock()
                keptMatte = (found, fresh)
                keptLock.unlock()
            }
            ready = fresh
            MemoryMonitor.mark("setting up the edge of \(name)")
        }
        guard let matte = ready else { throw Failure("the edge couldn't be set up") }
        if cancelled() { throw Failure("stopped") }

        // Shown as it comes: the snapped edge first, then the hair.
        if tier != .off, let partial = partial {
            let first = matte.run(tier: .off)
            if let shown = try? result(first, base: found, photo: matte.photo, name: name, tier: .off, started: started, final: false) { partial(shown) }
            if cancelled() { throw Failure("stopped") }
        }
        let out = matte.run(tier: tier, progress: progress, cancelled: cancelled)
        for line in out.log { Log.note("mask", "\(name): \(line)") }
        for warning in out.warnings { Log.warn("\(name): \(warning) (\(tier.name) mask)") }
        MemoryMonitor.mark("refining a \(tier.name) mask")
        return try result(out, base: found, photo: matte.photo, name: name, tier: tier, started: started, final: true)
    }

    /// The engine's answer as pictures, with the skin mask when this is the finished mask.
    private static func result(_ out: MatteOutput, base: SubjectBase, photo: Photo, name: String, tier: MatteTier,
                               started: CFAbsoluteTime, final: Bool) throws -> MaskResult {
        let W = out.w, H = out.h
        var skin: CGImage?
        if final {
            // Skin: its colour is learned from the cheeks and nose of each face.
            let stage = CFAbsoluteTimeGetCurrent()
            var samples: [SIMD3<Float>] = []
            for f in base.faces.prefix(4) {
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
                let bytes = SkinMask.make(photo: photo, alpha: out.alpha, model: model, exclusion: featureExclusion(base.proxy))
                skin = picture(gray: bytes, w: W, h: H)
                Log.note("mask", "\(name): skin from \(samples.count) samples in \(Log.seconds(since: stage))")
            } else {
                Log.note("mask", "\(name): no skin mask (\(base.faces.isEmpty ? "no face found" : "too few skin samples"))")
            }
        }

        let first = base.coarse
        let coarse8 = first.v.map { UInt8(min(max($0, 0), 1) * 255) }
        guard let alpha = picture(gray: out.alpha, w: W, h: H), let shares = picture(rgbx: out.shares, w: W, h: H),
              let trimap = picture(gray: out.trimap, w: out.trimapW, h: out.trimapH),
              let rough = picture(gray: coarse8, w: first.w, h: first.h) else { throw Failure("the mask couldn't be stored") }
        let megapixels = String(format: "%.1f", locale: Locale(identifier: "en_US_POSIX"), Double(out.unknownPixels) / 1_000_000)
        var summary: String = "\(tier.name) mask from \(base.source.name) in \(Log.seconds(since: started)): \(megapixels) MP of edge snapped"
        if tier != .off { summary += ", hair refined" }
        if let halo = out.edgeQuality.haloElsewhere {
            let haloText: String = String(format: "%.3f", locale: Locale(identifier: "en_US_POSIX"), halo)
            summary += " · halo away from hair \(haloText)"
            if final && halo > 0.02 { Log.warn("\(name): HALO? mean alpha \(haloText) just outside the edge, away from hair (\(tier.name) mask)") }
        }
        if let fringe = out.edgeQuality.fringe {
            summary += " · colour fringe " + String(format: "%.3f", locale: Locale(identifier: "en_US_POSIX"), fringe)
        }
        if !out.warnings.isEmpty { summary += " · check: " + out.warnings.joined(separator: ", ") }
        if final {
            var fields: [String: Any] = ["image": name, "tier": tier.name, "seconds": CFAbsoluteTimeGetCurrent() - started, "edge_pixels": out.unknownPixels]
            let q = out.edgeQuality
            let metrics: [(String, Float?)] = [("halo_near_hair", q.nearHaloHair), ("halo_near_elsewhere", q.nearHaloElsewhere), ("halo_hair", q.haloHair),
                                               ("halo_elsewhere", q.haloElsewhere), ("erosion_near_hair", q.nearErosionHair),
                                               ("erosion_near_elsewhere", q.nearErosionElsewhere), ("erosion_hair", q.erosionHair),
                                               ("erosion_elsewhere", q.erosionElsewhere), ("colour_fringe", q.fringe)]
            for (key, value) in metrics { if let value = value { fields[key] = Double(value) } }
            Log.note("mask", "\(name): \(summary)", fields: fields)
        }
        return MaskResult(width: W, height: H, alpha: alpha, shares: shares, skin: skin, trimap: trimap, coarse: rough,
                          debug: overlay(out, base: base), tier: tier, edge: out.edgeQuality, summary: summary)
    }

    /// A see-through picture of what was done where, a quarter of the photo's size: the hair
    /// zone (blue), the edge that was snapped (green) and where colour matting ran as well
    /// (pink), the close-up boxes (yellow), the body poses (white) and the subject's face (cyan).
    static func overlay(_ out: MatteOutput, base: SubjectBase) -> CGImage? {
        let w = out.trimapW, h = out.trimapH
        guard w > 0, h > 0, out.hair.count == w * h, out.zones.count == w * h,
              let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                                  space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        ctx.clear(CGRect(x: 0, y: 0, width: w, height: h))
        guard let data = ctx.data else { return nil }
        let p = data.assumingMemoryBound(to: UInt8.self)
        let rowBytes = ctx.bytesPerRow
        for y in 0 ..< h {
            for x in 0 ..< w {
                let i = y * w + x
                var r: Float = 0, g: Float = 0, b: Float = 0, a: Float = 0
                if out.zones[i] == 1 {
                    r = 0.1; g = 1; b = 0.3; a = 0.7
                } else if out.zones[i] == 2 {
                    r = 1; g = 0.2; b = 0.9; a = 0.7
                } else if out.hair[i] > 0 {
                    r = 0.2; g = 0.5; b = 1; a = 0.3 * Float(out.hair[i]) / 255
                }
                if a == 0 { continue }
                let o = y * rowBytes + x * 4
                p[o] = UInt8(r * a * 255); p[o + 1] = UInt8(g * a * 255); p[o + 2] = UInt8(b * a * 255); p[o + 3] = UInt8(a * 255)
            }
        }
        // Lines are given with y down; the drawing context counts it upwards.
        ctx.translateBy(x: 0, y: CGFloat(h))
        ctx.scaleBy(x: 1, y: -1)
        let k = CGFloat(w) / CGFloat(max(base.proxy.width, 1))
        let line = max(CGFloat(w) / 700, 1.5)
        func rect(_ b: Box) -> CGRect { CGRect(x: CGFloat(b.x0) * k, y: CGFloat(b.y0) * k, width: CGFloat(b.x1 - b.x0) * k, height: CGFloat(b.y1 - b.y0) * k) }
        ctx.setLineWidth(line)
        for tile in base.tiles {
            ctx.setStrokeColor(red: 1, green: 0.85, blue: 0, alpha: tile.used ? 1 : 0.35)
            ctx.stroke(rect(tile.box).insetBy(dx: line, dy: line))
        }
        if let box = base.subjectBox {
            ctx.setStrokeColor(red: 1, green: 0.5, blue: 0, alpha: 1)
            ctx.setLineDash(phase: 0, lengths: [6 * line, 4 * line])
            ctx.stroke(rect(box))
            ctx.setLineDash(phase: 0, lengths: [])
        }
        let bones = BodyPose.limbs + [("leftShoulder", "rightShoulder"), ("leftHip", "rightHip"), ("neck", "nose")]
        for (i, pose) in base.poses.enumerated() {
            let sure = pose.sure(0.3)
            ctx.setStrokeColor(red: 1, green: 1, blue: 1, alpha: i == base.primaryPose ? 1 : 0.45)
            ctx.setLineWidth(i == base.primaryPose ? 2 * line : line)
            for (from, to) in bones {
                guard let a = sure[from], let b = sure[to] else { continue }
                ctx.move(to: CGPoint(x: CGFloat(a.x) * k, y: CGFloat(a.y) * k))
                ctx.addLine(to: CGPoint(x: CGFloat(b.x) * k, y: CGFloat(b.y) * k))
                ctx.strokePath()
            }
        }
        if let face = base.ranking.primary?.face {
            ctx.setLineWidth(line)
            ctx.setStrokeColor(red: 0, green: 1, blue: 1, alpha: 1)
            ctx.stroke(rect(Box(face)))
        }
        return ctx.makeImage()
    }

    // MARK: Debug bundle

    static func png(_ image: CGImage) -> Data? {
        let data = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(data, "public.png" as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(dest, image, nil)
        return CGImageDestinationFinalize(dest) ? data as Data : nil
    }

    private static func png(_ plane: Gray) -> Data? {
        picture(gray: plane.v.map { UInt8(($0 >= 0 ? min($0, 1) : 0) * 255) }, w: plane.w, h: plane.h).flatMap { png($0) }
    }

    /// Writes what the masking pipeline saw and decided for this photo into a new folder next
    /// to the raw, for looking into a mask outside the app.
    static func debugBundle(url: URL, faces known: DetectedFaces?, rules: SubjectRules = SubjectRules(), subject: SubjectSource = .birefnet,
                            mask: MaskResult?) throws -> URL {
        let reference = try neutral(url)
        let fm = FileManager.default
        let parent = url.deletingLastPathComponent(), stem = url.deletingPathExtension().lastPathComponent
        var folder = parent.appendingPathComponent("\(stem)-maskdebug", isDirectory: true)
        var n = 2
        while fm.fileExists(atPath: folder.path) {
            folder = parent.appendingPathComponent("\(stem)-maskdebug-\(n)", isDirectory: true)
            n += 1
        }
        try fm.createDirectory(at: folder, withIntermediateDirectories: false)
        try writeBundle(reference: reference, name: url.lastPathComponent, key: baseKey(url, subject, rules), into: folder,
                        faces: known, rules: rules, subject: subject, mask: mask)
        return folder
    }

    /// The bundle's files, into a folder that exists.
    static func writeBundle(reference: CGImage, name: String, key: String?, into folder: URL, faces known: DetectedFaces?,
                            rules: SubjectRules = SubjectRules(), subject: SubjectSource, mask: MaskResult?) throws {
        let found = try base(reference: reference, name: name, key: key, faces: known, rules: rules, subject: subject, progress: { _ in })
        let small = found.proxy
        guard let proxyData = png(small) else { throw Failure("the proxy couldn't be encoded") }
        try proxyData.write(to: folder.appendingPathComponent("proxy.png"))
        var written = ["proxy.png"]
        func write(_ data: Data?, _ file: String) throws {
            guard let data = data else { return }
            try data.write(to: folder.appendingPathComponent(file))
            written.append(file)
        }
        func json(_ object: [String: Any], _ file: String) throws {
            try write(try JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys]), file)
        }

        // Faces, in proxy pixels with y down, best subject first.
        func list(_ r: PixelRect) -> [Int] { [r.x, r.y, r.w, r.h] }
        func list(_ b: Box) -> [Int] { [b.x0, b.y0, b.x1, b.y1] }
        let marks = faceMarks(small)
        var facesJSON: [[String: Any]] = []
        for (i, candidate) in found.ranking.candidates.enumerated() {
            var entry: [String: Any] = ["rect": list(candidate.face), "primary": i == 0, "score": Double(candidate.score)]
            if let sharp = candidate.sharp { entry["faceSharp"] = Double(sharp) }
            let cx = CGFloat(candidate.face.x) + CGFloat(candidate.face.w) / 2, cy = CGFloat(candidate.face.y) + CGFloat(candidate.face.h) / 2
            if let mark = marks.first(where: { $0.rect.contains(CGPoint(x: cx, y: cy)) }) {
                entry["landmarks"] = mark.regions.mapValues { points in points.map { [Double($0.x), Double($0.y)] } }
            }
            facesJSON.append(entry)
        }
        let facesDoc: [String: Any] = ["image": name, "proxy_size": [small.width, small.height], "full_size": [reference.width, reference.height],
                                       "units": "proxy pixels, origin top left, y down", "faces": facesJSON]
        try json(facesDoc, "faces.json")

        try write(found.selected.flatMap { png($0) }, "m0_birefnet.png")
        try write(png(found.coarse), "m0_final.png")
        try write(mask.flatMap { png($0.alpha) }, "final_alpha.png")
        if let dense = found.ranking.sharpness?.dense {
            try write(png(Gray(w: dense.w, h: dense.h, v: dense.v.map { $0 / SharpnessMap.most })), "sharpness.png")
        }
        var posesJSON: [[String: Any]] = []
        for (i, pose) in found.poses.enumerated() {
            let joints: [String: [Double]] = pose.joints.mapValues { [Double($0.x), Double($0.y), Double($0.confidence)] }
            let entry: [String: Any] = ["primary": i == found.primaryPose, "joints": joints]
            posesJSON.append(entry)
        }
        let posesDoc: [String: Any] = ["units": "proxy pixels, origin top left, y down; each joint is x, y, confidence", "poses": posesJSON]
        try json(posesDoc, "pose.json")
        var regions: [String: Any] = [
            "units": "proxy pixels, origin top left, y down; boxes are x0, y0, x1, y1",
            "tiles": found.tiles.map { tile -> [String: Any] in ["box": list(tile.box), "used": tile.used] },
            "growth": [],
            "mask_size": [found.coarse.w, found.coarse.h],
        ]
        if let box = found.subjectBox { regions["subject_box"] = list(box) }
        if let seam = found.seam { regions["tile_seam_ratio"] = Double(seam) }
        try json(regions, "regions.json")

        var alphaNote = " (not written: no mask had been made)"
        if let mask = mask { alphaNote = " (\(mask.tier.name) tier)" }
        let readme = """
        Mask debug bundle for \(name)

        proxy.png         the picture the pipeline works from (sRGB, long edge \(proxyLongEdge))
        faces.json        the faces found, best subject first, with their outlines
        m0_birefnet.png   the subject after the whole-frame pass and the selection rules (from \(found.source.name))
        m0_final.png      the same after the close-ups: what the edge refinement starts from
        final_alpha.png   the finished mask, at the photo's size\(alphaNote)
        sharpness.png     how out of focus each part is: black is sharp, white is \(Int(SharpnessMap.most)) px of blur or more
        pose.json         the body poses found
        regions.json      the subject's box and the close-up tiles

        To compare against Photoshop: open proxy.png, Select Subject, and save the mask at the same
        size in this folder as ps_mask-<number>.jpg. Then compress this folder (right-click,
        Compress) and send the zip.
        """
        try write(Data(readme.utf8), "README.txt")
        Log.note("mask", "\(name): debug bundle written to \(folder.path) · \(written.joined(separator: ", "))")
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
        case .dimmed:
            // Everything but the chosen area three stops darker: a halo shows as a bright rim.
            let dark = out.applyingFilter("CIExposureAdjust", parameters: [kCIInputEVKey: -3])
            return mix(out, dark, mask: chosenShares, extent: extent)
        case .zones:
            guard let debug = local.mask.debug else { return out }
            return data(debug, over: extent).applyingFilter("CISourceOverCompositing", parameters: [kCIInputBackgroundImageKey: out]).cropped(to: extent)
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
