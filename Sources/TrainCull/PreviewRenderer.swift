import CoreImage
import Foundation
import TraincullCore

/// How the large image is rendered while editing (alpha: tunable from the Debug menu). Read from
/// UserDefaults each time, so a change takes effect at once; without the Debug menu the
/// defaults apply.
struct PreviewTuning {
    static let settleChoices: [Double] = [0.1, 0.25, 0.4, 0.75, 1.0]
    static let keys = (settle: "TCPreviewSettleDelay", draft: "TCPreviewDraftMode", viewSize: "TCPreviewViewSizeSettle",
                       region: "TCPreviewVisibleRegion", legacy: "TCPreviewLegacy")
    /// View-size settled render at fit: on, after test C3b (see the notes).
    static let viewSizeSettleDefault = true

    /// Seconds from the last change (or a drag's release) to the settled render.
    var settleDelay: Double
    /// Apple's draft mode for the frames shown while a slider moves.
    var draftMode: Bool
    /// At fit, the settled render is made at the view's size rather than full resolution.
    var viewSizeSettle: Bool
    /// Zoomed in, renders cover only the part in view.
    var visibleRegion: Bool
    /// The alpha 2 way (a new filter and a full decode for every render, no draft mode, full
    /// resolution settled, 0.4 s): a launch setting for comparison runs only.
    var legacy: Bool

    static var current: PreviewTuning {
        let d = UserDefaults.standard
        if d.bool(forKey: keys.legacy) {
            return PreviewTuning(settleDelay: 0.4, draftMode: false, viewSizeSettle: false, visibleRegion: false, legacy: true)
        }
        return PreviewTuning(settleDelay: d.object(forKey: keys.settle) as? Double ?? 0.25,
                             draftMode: d.object(forKey: keys.draft) as? Bool ?? true,
                             viewSizeSettle: d.object(forKey: keys.viewSize) as? Bool ?? viewSizeSettleDefault,
                             visibleRegion: d.object(forKey: keys.region) as? Bool ?? true,
                             legacy: false)
    }

    var fields: [String: Any] {
        ["settleDelay": settleDelay, "draftMode": draftMode, "viewSizeSettle": viewSizeSettle, "visibleRegion": visibleRegion, "legacy": legacy]
    }

    var text: String {
        legacy ? "alpha 2 path" : String(format: "settle %.2f s", settleDelay)
            + " · draft mode \(draftMode ? "on" : "off") · view-size settle \(viewSizeSettle ? "on" : "off") · visible region \(visibleRegion ? "on" : "off")"
    }
}

/// Renders the single view's previews of one file. One Apple raw filter is made when the file is
/// selected and reused for every render while it stays selected: only its settings change, on
/// this renderer's own queue. At most one render runs and one waits; a newer request replaces
/// the waiting one. Core Image can't stop a render that has started, so one already running
/// finishes and the caller throws its result away if newer values have been shown.
final class PreviewRenderer {
    /// What the view wants, before the frame's size is known.
    enum Want: Equatable {
        /// The whole picture: at the view's size (its long edge in screen pixels), or at full
        /// resolution when nil.
        case whole(viewLongEdge: CGFloat?)
        /// The part in view, as fractions of the frame (origin top left), at the zoom shown:
        /// screen pixels per pixel of the frame.
        case region(CGRect, screenPixelsPerPixel: CGFloat)

        var text: String {
            switch self {
            case let .whole(edge): return edge.map { "whole at view size (\(Int($0)) px)" } ?? "whole at full resolution"
            case let .region(r, k): return String(format: "region %.3f,%.3f %.3f×%.3f at %.2f px/px", r.minX, r.minY, r.width, r.height, k)
            }
        }
    }

    struct Request {
        let seq: Int
        let values: [String: Float]
        let want: Want
        let draft: Bool
        let requested: CFAbsoluteTime
    }

    struct Frame {
        let request: Request
        let image: CGImage
        /// What the picture covers, in full-size pixels (origin top left).
        let rect: CGRect
        let fullSize: CGSize
        let scale: Float
        let readBack: [String: Float]
        let renderMs: Double
        let peakBytes: Double
        /// Apple raw filters made by this renderer so far.
        let creations: Int
        var isWhole: Bool { rect.origin == .zero && rect.size == fullSize }
    }

    let url: URL
    let legacy: Bool
    private let queue = DispatchQueue(label: "preview", qos: .userInteractive)
    // Only touched on `queue`.
    private var filter: CIRAWFilter?
    private var applied: [String: Float] = [:]
    private var fullSize = CGSize.zero
    private var creations = 0
    // Only touched on the main thread.
    private var running = false
    private var waiting: (Request, (Frame?) -> Void)?
    /// Requests replaced by a newer one before they started.
    private(set) var replaced = 0
    var isIdle: Bool { !running && waiting == nil }

    init(url: URL, legacy: Bool) {
        self.url = url
        self.legacy = legacy
    }

    /// Apple's defaults, supported flags and decoders for the file, and its full size, read from
    /// the renderer's own filter before anything is set on it. `done` on the main thread.
    func facts(_ done: @escaping (RawFacts?, CGSize) -> Void) {
        queue.async {
            if self.legacy {
                // As alpha 2 did: a filter for the defaults and another for the size.
                let facts = Adjust.facts(self.url)
                let size = Imaging.rawSize(self.url) ?? .zero
                self.creations += 2
                if self.fullSize == .zero { self.fullSize = size }
                DispatchQueue.main.async { done(facts, size) }
                return
            }
            if self.filter == nil { _ = self.prepared([:]) }
            let facts = self.filter.flatMap { f -> RawFacts? in
                self.applied.isEmpty ? RawFacts(defaults: Adjust.properties(f), supported: Adjust.supported(f), decoder: f.decoderVersion.rawValue,
                                                decoders: f.supportedDecoderVersions.map { $0.rawValue }) : nil
            } ?? Adjust.facts(self.url)
            let size = self.fullSize
            DispatchQueue.main.async { done(facts, size) }
        }
    }

    /// Renders at once on the renderer's queue and waits (the tests).
    func renderNow(_ request: Request) -> Frame? {
        queue.sync { autoreleasepool { render(request) } }
    }

    /// Main thread. `done` comes back on the main thread, with nil if Apple's decoder failed.
    func submit(_ request: Request, done: @escaping (Frame?) -> Void) {
        if running {
            if waiting != nil { replaced += 1 }
            waiting = (request, done)
            return
        }
        start(request, done)
    }

    private func start(_ request: Request, _ done: @escaping (Frame?) -> Void) {
        running = true
        queue.async {
            let frame = autoreleasepool { self.render(request) }
            DispatchQueue.main.async {
                self.running = false
                done(frame)
                if let next = self.waiting {
                    self.waiting = nil
                    self.start(next.0, next.1)
                }
            }
        }
    }

    /// The filter to render with: the kept one with only what changed set on it. A control that
    /// goes back to Apple's default can't be unset on a filter (setting the default value
    /// explicitly can differ by a level), so then a fresh filter is made. The alpha 2 path makes
    /// a fresh one every time.
    private func prepared(_ values: [String: Float]) -> CIRAWFilter? {
        let unset = applied.keys.contains { values[$0] == nil }
        if filter == nil || unset || legacy {
            filter = CIRAWFilter(imageURL: url)
            creations += 1
            applied = [:]
            if let f = filter, fullSize == .zero, let e = f.outputImage?.extent, !e.isInfinite, !e.isEmpty { fullSize = e.size }
        }
        guard let f = filter else { return nil }
        let changed = values.filter { applied[$0.key] != $0.value }
        Adjust.apply(changed, to: f)
        applied = values
        return f
    }

    private func render(_ r: Request) -> Frame? {
        let start = CFAbsoluteTimeGetCurrent()
        let meter = JobMeter()
        guard let f = prepared(r.values), fullSize.width > 0 else { _ = meter.finish(); return nil }
        // Resolve what the view wants into a scale and, for a region, a rectangle of the frame.
        var part = CGRect(origin: .zero, size: fullSize)
        let scale: Float
        switch r.want {
        case let .whole(edge):
            scale = edge.map { Float(min(1, max(0.1, $0 / max(fullSize.width, fullSize.height)))) } ?? 1
        case let .region(fraction, k):
            part = CGRect(x: fraction.minX * fullSize.width, y: fraction.minY * fullSize.height,
                          width: fraction.width * fullSize.width, height: fraction.height * fullSize.height)
            scale = Float(min(1, max(0.05, k)))
        }
        // Draft mode is only ever turned on, and back off, here: a filter that never drafted is
        // left as Apple made it.
        if f.isDraftModeEnabled != r.draft { f.isDraftModeEnabled = r.draft }
        if f.scaleFactor != scale { f.scaleFactor = scale }
        guard let decoded = f.outputImage else { _ = meter.finish(); return nil }
        let e = decoded.extent
        if e.isInfinite || e.isEmpty { _ = meter.finish(); return nil }
        let out = Adjust.finish(decoded, r.values)
        let k = e.width / fullSize.width // rendered pixels per full-size pixel
        var from = e
        var rect = CGRect(origin: .zero, size: fullSize)
        if case .region = r.want {
            from = CGRect(x: e.minX + part.minX * k, y: e.maxY - part.maxY * k, width: part.width * k, height: part.height * k)
                .integral.intersection(e)
            if from.isEmpty { _ = meter.finish(); return nil }
            rect = CGRect(x: (from.minX - e.minX) / k, y: (e.maxY - from.maxY) / k, width: from.width / k, height: from.height / k)
        }
        guard let image = Imaging.pixels(out, from: from) else { _ = meter.finish(); return nil }
        var readBack = Adjust.properties(f)
        readBack["saturation"] = r.values["saturation"] ?? 1
        readBack["vibrance"] = r.values["vibrance"] ?? 0
        let measured = meter.finish()
        return Frame(request: r, image: image, rect: rect, fullSize: fullSize, scale: scale, readBack: readBack,
                     renderMs: (CFAbsoluteTimeGetCurrent() - start) * 1000,
                     peakBytes: (measured.fields["memory_peak"] as? Double) ?? 0, creations: creations)
    }
}
