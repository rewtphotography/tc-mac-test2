import CoreGraphics
import CoreML
import Foundation
import TraincullCore
import Vision

/// The segmentation models that ship inside the app. They are put there when the app is
/// built; the app itself never downloads anything.
enum BundledModels {
    /// Where the compiled models are: the app's resources, or a folder named by the
    /// TRAINCULL_MODELS environment variable (the automated build's tests use that).
    static func url(_ name: String) -> URL? {
        if let folder = ProcessInfo.processInfo.environment["TRAINCULL_MODELS"] {
            let url = URL(fileURLWithPath: folder).appendingPathComponent("\(name).mlmodelc")
            return FileManager.default.fileExists(atPath: url.path) ? url : nil
        }
        return Bundle.main.url(forResource: name, withExtension: "mlmodelc")
    }

    static var hasSAM: Bool { ["SAMImageEncoder", "SAMPromptEncoder", "SAMMaskDecoder"].allSatisfy { url($0) != nil } }
    static var hasBiRefNet: Bool { url("BiRefNet") != nil }

    static func load(_ name: String, units: MLComputeUnits = .all) throws -> MLModel {
        guard let url = url(name) else { throw Masking.Failure("the \(name) model isn't in this build") }
        let start = CFAbsoluteTimeGetCurrent()
        let config = MLModelConfiguration()
        config.computeUnits = units
        let model = try MLModel(contentsOf: url, configuration: config)
        Log.note("model", "\(name) loaded in \(Log.seconds(since: start))")
        return model
    }

    /// Fills a model input with numbers, in whatever number type the model asks for.
    static func array(_ values: [Float], shape: [Int], for name: String, of model: MLModel) throws -> MLMultiArray {
        let type = model.modelDescription.inputDescriptionsByName[name]?.multiArrayConstraint?.dataType ?? .float32
        let array = try MLMultiArray(shape: shape.map { NSNumber(value: $0) }, dataType: type)
        for (i, v) in values.enumerated() { array[i] = NSNumber(value: v) }
        return array
    }

    /// A model output as plain numbers.
    static func floats(_ array: MLMultiArray) -> [Float] {
        let n = array.count
        var out = [Float](repeating: 0, count: n)
        switch array.dataType {
        case .float32:
            let p = array.dataPointer.bindMemory(to: Float.self, capacity: n)
            for i in 0 ..< n { out[i] = p[i] }
        case .double:
            let p = array.dataPointer.bindMemory(to: Double.self, capacity: n)
            for i in 0 ..< n { out[i] = Float(p[i]) }
        default:
            #if arch(arm64)
            if array.dataType == .float16 {
                let p = array.dataPointer.bindMemory(to: Float16.self, capacity: n)
                for i in 0 ..< n { out[i] = Float(p[i]) }
                return out
            }
            #endif
            for i in 0 ..< n { out[i] = array[i].floatValue }
        }
        return out
    }

    /// A picture squashed to a square, as a model's image input.
    static func image(_ picture: CGImage, side: Int) throws -> MLFeatureValue {
        try MLFeatureValue(cgImage: picture, pixelsWide: side, pixelsHigh: side, pixelFormatType: kCVPixelFormatType_32BGRA,
                           options: [.cropAndScale: VNImageCropAndScaleOption.scaleFill.rawValue])
    }
}

/// Segment Anything 2.1 (Apple's Core ML conversion): given a picture and a few points or a
/// box, it returns the object they indicate. The picture is taken in once (the slow part);
/// after that each question about it is quick.
final class SAMModel {
    static let shared = SAMModel()
    static let side = 1024

    private var encoder: MLModel?
    private var prompter: MLModel?
    private var decoder: MLModel?
    private let lock = NSLock()

    /// A picture as SAM has taken it in.
    struct Embedding {
        let features: MLFeatureProvider
        let width: Int
        let height: Int
    }

    /// One of SAM's answers: a soft mask (256 × 256, covering the whole picture) and SAM's own
    /// estimate of how good it is.
    struct Answer {
        let mask: Gray
        let score: Float
    }

    /// A point (`label` 1 = this is the subject, 0 = this is not) in pixels of the picture.
    struct Point {
        var x: Float
        var y: Float
        var label: Float
    }

    private func loaded() throws -> (MLModel, MLModel, MLModel) {
        lock.lock()
        defer { lock.unlock() }
        if encoder == nil {
            encoder = try BundledModels.load("SAMImageEncoder")
            prompter = try BundledModels.load("SAMPromptEncoder")
            decoder = try BundledModels.load("SAMMaskDecoder")
        }
        return (encoder!, prompter!, decoder!)
    }

    func embed(_ picture: CGImage) throws -> Embedding {
        let (encoder, _, _) = try loaded()
        let start = CFAbsoluteTimeGetCurrent()
        let input = try MLDictionaryFeatureProvider(dictionary: ["image": BundledModels.image(picture, side: SAMModel.side)])
        let out = try encoder.prediction(from: input)
        Log.note("base", "SAM encode \(picture.width)×\(picture.height) → \(SAMModel.side)² in \(Log.seconds(since: start))")
        return Embedding(features: out, width: picture.width, height: picture.height)
    }

    /// Asks about a picture already taken in. A box is given as its two corners. SAM returns
    /// three answers, from the whole object to its parts.
    func decode(_ e: Embedding, points: [Point], box: Box? = nil) throws -> [Answer] {
        let (_, prompter, decoder) = try loaded()
        var all = points
        if let box = box {
            // SAM's convention: label 2 is a box's top-left corner, 3 its bottom-right.
            all.append(Point(x: Float(box.x0), y: Float(box.y0), label: 2))
            all.append(Point(x: Float(box.x1), y: Float(box.y1), label: 3))
        }
        guard !all.isEmpty, all.count <= 14 else { throw Masking.Failure("SAM was given \(all.count) points") }
        // Points are in pixels of the square the picture was squashed to.
        let kx = Float(SAMModel.side) / Float(e.width), ky = Float(SAMModel.side) / Float(e.height)
        let coords = all.flatMap { [$0.x * kx, $0.y * ky] }
        let asked = try MLDictionaryFeatureProvider(dictionary: [
            "points": BundledModels.array(coords, shape: [1, all.count, 2], for: "points", of: prompter),
            "labels": BundledModels.array(all.map { $0.label }, shape: [1, all.count], for: "labels", of: prompter),
        ])
        let prompt = try prompter.prediction(from: asked)
        guard let sparse = prompt.featureValue(for: "sparse_embeddings"), let dense = prompt.featureValue(for: "dense_embeddings"),
              let embedding = e.features.featureValue(for: "image_embedding"), let s0 = e.features.featureValue(for: "feats_s0"),
              let s1 = e.features.featureValue(for: "feats_s1") else { throw Masking.Failure("SAM's models don't fit together as expected") }
        let out = try decoder.prediction(from: MLDictionaryFeatureProvider(dictionary: [
            "image_embedding": embedding, "sparse_embedding": sparse, "dense_embedding": dense, "feats_s0": s0, "feats_s1": s1,
        ]))
        guard let masks = out.featureValue(for: "low_res_masks")?.multiArrayValue, let scores = out.featureValue(for: "scores")?.multiArrayValue,
              masks.shape.count == 4 else { throw Masking.Failure("SAM's answer isn't in the expected form") }
        let count = masks.shape[1].intValue, h = masks.shape[2].intValue, w = masks.shape[3].intValue
        let logits = BundledModels.floats(masks), marks = BundledModels.floats(scores)
        return (0 ..< count).map { k in
            var g = Gray(w: w, h: h)
            for i in 0 ..< w * h { g.v[i] = 1 / (1 + exp(-min(max(logits[k * w * h + i], -30), 30))) }
            return Answer(mask: g, score: k < marks.count ? marks[k] : 0)
        }
    }

    /// The answer that contains a point and that SAM rates highest, stretched to a given size.
    func best(_ answers: [Answer], containing point: (x: Float, y: Float), in e: Embedding, w: Int, h: Int) -> (mask: Gray, score: Float)? {
        func holds(_ a: Answer) -> Bool {
            a.mask.sample(point.x / Float(e.width) * Float(a.mask.w), point.y / Float(e.height) * Float(a.mask.h)) >= 0.5
        }
        let pool = answers.filter(holds)
        guard let pick = (pool.isEmpty ? answers : pool).max(by: { $0.score < $1.score }) else { return nil }
        return (pick.mask.resized(w: w, h: h), pick.score)
    }
}

/// BiRefNet_HR: finds whatever stands out in a picture, with fine edges. No questions asked of
/// it; it sees the picture squashed to 2048 × 2048 and returns one soft mask of that size,
/// covering the whole picture.
final class BiRefNetModel {
    static let shared = BiRefNetModel()
    static let side = 2048

    private var model: MLModel?
    private let lock = NSLock()

    func segment(_ picture: CGImage) throws -> Gray {
        lock.lock()
        defer { lock.unlock() }
        // Not the Neural Engine: preparing a model this large for it can take minutes.
        if model == nil { model = try BundledModels.load("BiRefNet", units: .cpuAndGPU) }
        guard let model = model, let inputName = model.modelDescription.inputDescriptionsByName.keys.first else {
            throw Masking.Failure("the BiRefNet model isn't in this build")
        }
        let start = CFAbsoluteTimeGetCurrent()
        let input = try MLDictionaryFeatureProvider(dictionary: [inputName: BundledModels.image(picture, side: BiRefNetModel.side)])
        let out = try model.prediction(from: input)
        guard let name = out.featureNames.first, let array = out.featureValue(for: name)?.multiArrayValue, array.shape.count >= 2 else {
            throw Masking.Failure("BiRefNet's answer isn't in the expected form")
        }
        let h = array.shape[array.shape.count - 2].intValue, w = array.shape[array.shape.count - 1].intValue
        let values = BundledModels.floats(array)
        Log.note("base", "BiRefNet \(picture.width)×\(picture.height) → \(BiRefNetModel.side)² in \(Log.seconds(since: start))")
        // At the model's own size; whoever asked stretches it to what they need.
        return Gray(w: w, h: h, v: Array(values.suffix(w * h)).map { min(max($0, 0), 1) })
    }
}
