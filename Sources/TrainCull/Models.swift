import CoreGraphics
import CoreML
import Foundation
import TraincullCore
import Vision

/// The segmentation model that ships inside the app. It is put there when the app is built;
/// the app itself never downloads anything.
enum BundledModels {
    /// Where the compiled model is: the app's resources, or a folder named by the
    /// TRAINCULL_MODELS environment variable (the automated build's tests use that).
    static func url(_ name: String) -> URL? {
        if let folder = ProcessInfo.processInfo.environment["TRAINCULL_MODELS"] {
            let url = URL(fileURLWithPath: folder).appendingPathComponent("\(name).mlmodelc")
            return FileManager.default.fileExists(atPath: url.path) ? url : nil
        }
        return Bundle.main.url(forResource: name, withExtension: "mlmodelc")
    }

    static var hasBiRefNet: Bool { url("BiRefNet") != nil }

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

/// Which processors Core ML may run the model on. A debug choice, for comparing memory and
/// speed (masking spec v3, 2.2).
enum ModelUnits: String, CaseIterable {
    case gpu, neural, all

    var name: String {
        switch self {
        case .gpu: return "CPU + GPU"
        case .neural: return "CPU + Neural Engine"
        case .all: return "All"
        }
    }

    var units: MLComputeUnits {
        switch self {
        case .gpu: return .cpuAndGPU
        case .neural: return .cpuAndNeuralEngine
        case .all: return .all
        }
    }
}

/// BiRefNet_HR: finds whatever stands out in a picture, with fine edges. No questions asked of
/// it; it sees a picture squashed to a square (1024 × 1024 in this build) and returns one soft
/// mask of that size, covering the whole picture. One picture at a time: calls queue up.
final class BiRefNetModel {
    static let shared = BiRefNetModel()
    /// Part of the key masks are kept under: change it when the model or its input changes.
    static let version = "BiRefNet_HR-fp16-v3"

    private var model: MLModel?
    private var inputName = "image"
    private var side = 1024
    private var units = ModelUnits.gpu
    private let lock = NSLock()
    private var count = 0

    /// How many pictures the model has been shown since the app started.
    var calls: Int {
        lock.lock()
        defer { lock.unlock() }
        return count
    }

    var isLoaded: Bool {
        lock.lock()
        defer { lock.unlock() }
        return model != nil
    }

    /// The side of the square the model sees. Known for certain once it has been loaded.
    var inputSide: Int {
        lock.lock()
        defer { lock.unlock() }
        return side
    }

    var unitsName: String {
        lock.lock()
        defer { lock.unlock() }
        return units.name
    }

    /// Changes which processors the model runs on. It is loaded again when next needed.
    func setUnits(_ new: ModelUnits) {
        lock.lock()
        defer { lock.unlock() }
        if new == units { return }
        units = new
        model = nil
        Log.note("model", "BiRefNet will run on \(new.name) from the next call")
    }

    /// Lets go of the model and the memory it holds.
    func unload(_ why: String) {
        lock.lock()
        let had = model != nil
        model = nil
        lock.unlock()
        if had { Log.note("model", "BiRefNet unloaded (\(why)) · memory now \(MemoryStats.plain(MemoryMonitor.footprint()))") }
    }

    /// The model, loading it if need be. Call with the lock held.
    private func loaded() throws -> MLModel {
        if let model = model { return model }
        guard let url = BundledModels.url("BiRefNet") else { throw Masking.Failure("the BiRefNet model isn't in this build") }
        let start = CFAbsoluteTimeGetCurrent()
        let before = MemoryMonitor.footprint()
        let config = MLModelConfiguration()
        config.computeUnits = units.units
        let fresh = try MLModel(contentsOf: url, configuration: config)
        let description = fresh.modelDescription
        if let input = description.inputDescriptionsByName.first(where: { $0.value.imageConstraint != nil }) {
            inputName = input.key
            if let constraint = input.value.imageConstraint { side = constraint.pixelsWide }
        } else if let first = description.inputDescriptionsByName.keys.first {
            inputName = first
        }
        var numbers = "unknown"
        if let type = description.outputDescriptionsByName.values.first?.multiArrayConstraint?.dataType {
            numbers = type == .float32 ? "32-bit floats" : (type == .double ? "64-bit floats" : "16-bit floats")
        }
        let about = (description.metadata[.description] as? String) ?? "no description"
        let shape: String = "input \(side)² · output \(numbers) · weights and arithmetic 16-bit (set when converted) · \(units.name)"
        let memory: String = "memory before \(MemoryStats.plain(before)) · after \(MemoryStats.plain(MemoryMonitor.footprint()))"
        Log.note("model", "BiRefNet loaded in \(Log.seconds(since: start)) · \(shape) · \(memory) · \(about)")
        model = fresh
        return fresh
    }

    /// Loads the model and runs it once on a plain picture, so that the first real call
    /// doesn't pay for either. Safe to call when it is already warm.
    func prewarm() {
        guard BundledModels.hasBiRefNet, !isLoaded else { return }
        guard let ctx = CGContext(data: nil, width: 64, height: 64, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return }
        ctx.setFillColor(red: 0.4, green: 0.4, blue: 0.4, alpha: 1)
        ctx.fill(CGRect(x: 0, y: 0, width: 64, height: 64))
        guard let plain = ctx.makeImage() else { return }
        let start = CFAbsoluteTimeGetCurrent()
        do {
            _ = try segment(plain, what: "warm-up")
            Log.note("model", "BiRefNet ready in \(Log.seconds(since: start)) (loaded and run once)")
        } catch {
            Log.warn("BiRefNet couldn't be made ready: \(error)")
        }
    }

    /// The model's answer for one picture, at the model's own size; whoever asked stretches
    /// it to what they need. `what` names the call in the log.
    func segment(_ picture: CGImage, what: String) throws -> Gray {
        lock.lock()
        defer { lock.unlock() }
        let model = try loaded()
        let side = self.side, inputName = self.inputName
        let meter = JobMeter()
        let start = CFAbsoluteTimeGetCurrent()
        let result: Gray = try autoreleasepool {
            let input = try MLDictionaryFeatureProvider(dictionary: [inputName: BundledModels.image(picture, side: side)])
            let out = try model.prediction(from: input)
            guard let name = out.featureNames.first, let array = out.featureValue(for: name)?.multiArrayValue, array.shape.count >= 2 else {
                throw Masking.Failure("BiRefNet's answer isn't in the expected form")
            }
            let h = array.shape[array.shape.count - 2].intValue, w = array.shape[array.shape.count - 1].intValue
            let values = BundledModels.floats(array)
            guard w > 0, h > 0, values.count >= w * h else { throw Masking.Failure("BiRefNet's answer is empty") }
            return Gray(w: w, h: h, v: Array(values.suffix(w * h)).map { $0 >= 0 ? min($0, 1) : 0 })
        }
        count += 1
        let measured = meter.finish()
        var fields = meter.numbers
        fields["call"] = count
        fields["what"] = what
        fields["input_side"] = side
        fields["units"] = units.name
        Log.note("model", "BiRefNet #\(count) \(what) · \(picture.width)×\(picture.height) → \(side)² in \(Log.seconds(since: start)) · memory \(measured.memory) · \(units.name)",
                 fields: fields)
        return result
    }
}
