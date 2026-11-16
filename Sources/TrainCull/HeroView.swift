import AppKit
import QuartzCore
import SwiftUI
import TraincullCore

/// The large focus image. It starts fitted; a click goes to face zoom (or to the clicked point
/// when no face is known); a second click returns to fit. Two-finger drag pans, pinch zooms.
/// There is no loupe and no mouse-drag panning. Going to a zoom and back is a short glide, not
/// a jump. In the side-by-side view there are two of these, and one follows the other's zoom.
///
/// Coordinates: the image "space" is the full-size frame in pixels, x to the right and y down.
/// The picture drawn may be a smaller preview of the same frame; it is stretched over the space.
final class HeroNSView: NSView {
    private var image: CGImage?
    private(set) var space = CGSize.zero
    private var isFit = true
    /// View points per space pixel, when not fitted.
    private var scale: CGFloat = 1
    private var center = CGPoint.zero
    private var downPoint: CGPoint?
    /// The last face-framed zoom (1 = 100%), for the dead zone.
    private var lastFaceScale: Double?

    /// A glide in progress from an earlier zoom to the current one. `fromInverse` is one over
    /// the scale it started at: the view moves evenly in that, which keeps the point being
    /// zoomed to steady on screen.
    private struct Glide {
        let fromInverse: CGFloat
        let fromCenter: CGPoint
        let start: CFTimeInterval
        var frames = 0
    }

    private var glide: Glide?
    private var glideTimer: Timer?
    static let glideSeconds: CFTimeInterval = 0.22

    enum UserZoom { case click, pinch }

    /// What to frame for a click at a point of the space.
    var targetFor: ((CGPoint) -> FaceResult)?
    /// Called when the zoom changes: fitted or not, and the zoom in percent.
    var onZoom: ((Bool, Int) -> Void)?
    /// Asked before a click is acted on; answering false swallows the click.
    var acceptsClick: (() -> Bool)?
    /// Called after a click or a pinch here changed the zoom, so the image beside this one can follow.
    var onUserZoom: ((UserZoom) -> Void)?

    static let maxZoom: CGFloat = 4 // 400%: a mask's edge is judged at 200 to 400%

    // MARK: Mask tools

    /// What a drag on the image does while a mask tool is chosen.
    enum Tool: Equatable {
        case none
        /// Drag out a box.
        case box
        /// Paint with a round brush; the radius is in pixels of the photo.
        case brush(radius: CGFloat)
    }

    /// Something a tool did earlier, drawn faintly while a tool is active.
    enum Mark {
        case box(CGRect, restore: Bool)
        case stroke([CGPoint], radius: CGFloat, restore: Bool)
    }

    var tool = Tool.none {
        didSet {
            if tool != oldValue {
                dragStart = nil
                dragPoints = []
                needsDisplay = true
            }
        }
    }
    var marks: [Mark] = [] { didSet { needsDisplay = true } }
    /// A box dragged out, in pixels of the photo; `restore` when Option was held.
    var onBox: ((CGRect, Bool) -> Void)?
    /// A stroke painted, as points in pixels of the photo, with the brush's radius.
    var onStroke: (([CGPoint], CGFloat, Bool) -> Void)?
    private var dragStart: CGPoint?
    private var dragPoints: [CGPoint] = []
    private var dragRestores = false
    private var hover: CGPoint?
    private var tracking: NSTrackingArea?
    static let deadZone = 0.05

    override var acceptsFirstResponder: Bool { true }
    override var isOpaque: Bool { true }

    private var backing: CGFloat { window?.backingScaleFactor ?? 2 }
    private var fitScale: CGFloat {
        guard space.width > 0, space.height > 0, bounds.width > 0, bounds.height > 0 else { return 1 }
        return min(bounds.width / space.width, bounds.height / space.height)
    }
    /// Where the view is heading: the zoom and centre it shows once any glide has finished.
    private var targetScale: CGFloat { isFit ? fitScale : scale }
    private var targetCenter: CGPoint { isFit ? CGPoint(x: space.width / 2, y: space.height / 2) : center }

    /// What is on screen right now: the target, or a point on the way to it.
    private var shown: (scale: CGFloat, center: CGPoint) {
        let s = targetScale, c = targetCenter
        guard let g = glide, s > 0 else { return (s, c) }
        let t = min(max((CACurrentMediaTime() - g.start) / HeroNSView.glideSeconds, 0), 1)
        let eased = CGFloat(1 - pow(1 - t, 3)) // quick at first, settling at the end
        let inverse = g.fromInverse + (1 / s - g.fromInverse) * eased
        return (1 / inverse, CGPoint(x: g.fromCenter.x + (c.x - g.fromCenter.x) * eased,
                                     y: g.fromCenter.y + (c.y - g.fromCenter.y) * eased))
    }

    private var shownScale: CGFloat { shown.scale }
    private var shownCenter: CGPoint { shown.center }

    /// Shows a picture of the current frame. `newFrame` returns to the fitted view, unless
    /// `keepZoom` asks a zoomed view to stay at the same magnification and the same spot of the
    /// new frame (stepping through a burst in the side-by-side view).
    func show(_ picture: CGImage?, space newSpace: CGSize, newFrame: Bool, keepZoom: Bool = false) {
        if newFrame {
            stopGlide()
            if keepZoom, !isFit, space.width > 0, space.height > 0, newSpace.width > 0, fitScale > 0 {
                let magnification = scale / fitScale
                let spot = CGPoint(x: center.x / space.width, y: center.y / space.height)
                space = newSpace
                scale = magnification * fitScale
                center = CGPoint(x: spot.x * newSpace.width, y: spot.y * newSpace.height)
            } else {
                isFit = true
            }
        } else if !isFit, space.width > 0, newSpace.width > 0, newSpace != space {
            // A sharper picture of the same frame arrived with a different pixel grid.
            let k = newSpace.width / space.width
            if let g = glide {
                glide = Glide(fromInverse: g.fromInverse * k, fromCenter: CGPoint(x: g.fromCenter.x * k, y: g.fromCenter.y * k),
                              start: g.start, frames: g.frames)
            }
            center = CGPoint(x: center.x * k, y: center.y * k)
            scale /= k
        }
        image = picture
        space = newSpace
        clamp()
        report()
        needsDisplay = true
    }

    func fit(animated: Bool = true) {
        if isFit { return }
        let from = shown
        isFit = true
        report()
        settle(from: from, animated: animated)
    }

    var isZoomed: Bool { !isFit }

    /// View points per image pixel when zoomed; nil when fitted.
    var zoomScale: CGFloat? { isFit ? nil : scale }

    /// The middle of the view as a fraction of the image, 0 to 1 each way.
    var spot: CGPoint {
        guard space.width > 0, space.height > 0 else { return CGPoint(x: 0.5, y: 0.5) }
        let c = targetCenter
        return CGPoint(x: c.x / space.width, y: c.y / space.height)
    }

    /// Follows the image beside this one: the same zoom, centred on this image's own face when
    /// one is given, else on the given spot of the frame, else where it already is.
    func follow(scale target: CGFloat?, face: FaceResult?, spot: CGPoint?, animated: Bool) {
        guard image != nil, space.width > 0, bounds.width > 0 else { return }
        let limit = max(HeroNSView.maxZoom / backing, fitScale)
        guard let target = target, min(target, limit) > fitScale * 1.001 else {
            fit(animated: animated)
            return
        }
        let from = shown
        let s = min(target, limit)
        var c = targetCenter
        if let face = face {
            let b = Double(backing)
            let p = Framing.center(face.anchor, viewW: Double(bounds.width) * b, viewH: Double(bounds.height) * b, scale: Double(s) * b)
            c = CGPoint(x: p.x, y: p.y)
        } else if let spot = spot {
            c = CGPoint(x: spot.x * space.width, y: spot.y * space.height)
        }
        isFit = false
        scale = s
        center = c
        clamp()
        report()
        settle(from: from, animated: animated)
    }

    // MARK: Gliding

    /// Redraws at the new zoom: as a glide from where the view was, or at once.
    private func settle(from: (scale: CGFloat, center: CGPoint), animated: Bool) {
        guard animated, window != nil, from.scale > 0, !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else {
            stopGlide()
            needsDisplay = true
            return
        }
        glide = Glide(fromInverse: 1 / from.scale, fromCenter: from.center, start: CACurrentMediaTime())
        if glideTimer == nil {
            let timer = Timer(timeInterval: 1.0 / 120.0, repeats: true) { [weak self] _ in self?.tick() }
            RunLoop.main.add(timer, forMode: .common)
            glideTimer = timer
        }
        needsDisplay = true
    }

    private func tick() {
        if let g = glide, CACurrentMediaTime() - g.start >= HeroNSView.glideSeconds {
            Log.note("zoom", "glide drew \(g.frames) frames in \(Int(HeroNSView.glideSeconds * 1000)) ms")
            stopGlide()
        }
        needsDisplay = true
    }

    private func stopGlide() {
        glideTimer?.invalidate()
        glideTimer = nil
        glide = nil
    }

    /// Frames `result` the way the Android app does: eyes anchored, capped at 100%.
    func zoom(to result: FaceResult, animated: Bool = true) {
        guard space.width > 0, bounds.width > 0 else { return }
        let from = shown
        let b = Double(backing)
        let framed = Framing.frame(result, viewW: Double(bounds.width) * b, viewH: Double(bounds.height) * b,
                                   minScale: Double(fitScale) * b, previousScale: lastFaceScale, deadZone: HeroNSView.deadZone)
        if result.eyeSpan != nil { lastFaceScale = framed.scale }
        let target = CGFloat(framed.scale / b)
        if target <= fitScale * 1.001 {
            isFit = true
        } else {
            isFit = false
            scale = target
            center = CGPoint(x: framed.center.x, y: framed.center.y)
            clamp()
        }
        report()
        settle(from: from, animated: animated)
    }

    private func report() { onZoom?(isFit, Int((targetScale * backing * 100).rounded())) }

    /// Keeps the image from leaving empty space at an edge.
    private func clamp() {
        guard !isFit, scale > 0 else { return }
        let vw = bounds.width / scale, vh = bounds.height / scale
        center.x = vw >= space.width ? space.width / 2 : min(max(center.x, vw / 2), space.width - vw / 2)
        center.y = vh >= space.height ? space.height / 2 : min(max(center.y, vh / 2), space.height - vh / 2)
    }

    /// The point of the space under a point of the view.
    private func spacePoint(_ p: CGPoint) -> CGPoint {
        let s = shownScale, c = shownCenter
        return CGPoint(x: c.x + (p.x - bounds.width / 2) / s, y: c.y + ((bounds.height - p.y) - bounds.height / 2) / s)
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        clamp()
        report()
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        NSColor(srgbRed: 0.043, green: 0.043, blue: 0.047, alpha: 1).setFill()
        bounds.fill()
        guard let picture = image, space.width > 0, space.height > 0,
              let ctx = NSGraphicsContext.current?.cgContext else { return }
        let gliding = glide != nil
        if gliding { glide?.frames += 1 }
        // A draw that takes longer than two frames of a 60 Hz screen is worth a line in the log.
        let drawStarted = CACurrentMediaTime()
        defer {
            let took = CACurrentMediaTime() - drawStarted
            if took > 0.033 {
                Log.note("draw", "slow: \(Int(took * 1000)) ms for a \(picture.width)×\(picture.height) picture, \(isFit ? "fitted" : "zoomed")\(gliding ? ", gliding" : "")")
            }
        }
        let (s, c) = shown
        let vw = bounds.width / s, vh = bounds.height / s
        let whole = CGRect(origin: .zero, size: space)
        let visible = CGRect(x: c.x - vw / 2, y: c.y - vh / 2, width: vw, height: vh).intersection(whole)
        if visible.isEmpty { return }
        // Draw only the visible part, so panning a 33 or 61 megapixel image stays quick.
        let kx = CGFloat(picture.width) / space.width, ky = CGFloat(picture.height) / space.height
        let pictureBounds = CGRect(x: 0, y: 0, width: picture.width, height: picture.height)
        let crop = CGRect(x: visible.minX * kx, y: visible.minY * ky, width: visible.width * kx, height: visible.height * ky)
            .integral.intersection(pictureBounds)
        guard !crop.isEmpty, let part = picture.cropping(to: crop) else { return }
        let x = crop.minX / kx, y = crop.minY / ky, w = crop.width / kx, h = crop.height / ky
        let left = bounds.width / 2 + (x - c.x) * s
        let top = bounds.height / 2 + (y - c.y) * s // measured down from the top of the view
        // True pixels at 100% and above on the full-size picture; smooth otherwise. A glide
        // draws quickly and the last frame, once it has stopped, is drawn properly.
        ctx.interpolationQuality = gliding ? .low : ((kx > 0.99 && s * backing >= 1) ? .none : .high)
        ctx.draw(part, in: CGRect(x: left, y: bounds.height - top - h * s, width: w * s, height: h * s))
        drawTools(ctx)
    }

    // MARK: Input

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking = tracking { removeTrackingArea(tracking) }
        let area = NSTrackingArea(rect: bounds, options: [.mouseMoved, .mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect], owner: self, userInfo: nil)
        addTrackingArea(area)
        tracking = area
    }

    override func mouseMoved(with event: NSEvent) {
        guard tool != .none else { return }
        hover = convert(event.locationInWindow, from: nil)
        needsDisplay = true
    }

    override func mouseExited(with event: NSEvent) {
        if hover != nil {
            hover = nil
            needsDisplay = true
        }
    }

    override func mouseDown(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        downPoint = p
        guard tool != .none, image != nil, space.width > 0 else { return }
        dragRestores = event.modifierFlags.contains(.option)
        dragStart = spacePoint(p)
        dragPoints = [spacePoint(p)]
        needsDisplay = true
    }

    override func mouseDragged(with event: NSEvent) {
        guard tool != .none, dragStart != nil else { return }
        let p = convert(event.locationInWindow, from: nil)
        hover = p
        let at = spacePoint(p)
        // A point every couple of screen points is plenty for a stroke.
        if let last = dragPoints.last, hypot(at.x - last.x, at.y - last.y) * shownScale >= 2 { dragPoints.append(at) }
        if dragPoints.count == 1, case .box = tool { dragPoints.append(at) }
        if case .box = tool { dragPoints[dragPoints.count - 1] = at }
        needsDisplay = true
    }

    override func mouseUp(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        defer { downPoint = nil }
        if tool != .none {
            defer {
                dragStart = nil
                dragPoints = []
                needsDisplay = true
            }
            guard let start = dragStart, image != nil else { return }
            let end = spacePoint(p)
            let whole = CGRect(origin: .zero, size: space)
            switch tool {
            case .box:
                let box = CGRect(x: min(start.x, end.x), y: min(start.y, end.y), width: abs(end.x - start.x), height: abs(end.y - start.y)).intersection(whole)
                // A click, or a sliver: not a box.
                if box.width * shownScale >= 8 && box.height * shownScale >= 8 { onBox?(box, dragRestores) }
            case let .brush(radius):
                let points = dragPoints.filter { whole.insetBy(dx: -radius, dy: -radius).contains($0) }
                if !points.isEmpty { onStroke?(points, radius, dragRestores) }
            case .none:
                break
            }
            return
        }
        guard let d = downPoint, hypot(p.x - d.x, p.y - d.y) < 4, image != nil, space.width > 0 else { return }
        guard acceptsClick?() ?? true else { return }
        if !isFit {
            fit()
            onUserZoom?(.click)
            return
        }
        let at = spacePoint(p)
        guard CGRect(origin: .zero, size: space).contains(at) else { return }
        zoom(to: targetFor?(at) ?? FaceResult(method: .point, anchor: P(Double(at.x), Double(at.y)), eyeSpan: nil))
        onUserZoom?(.click)
    }

    /// The point of the view over a point of the space (the photo's pixels), y up as AppKit draws.
    private func viewPoint(_ q: CGPoint) -> CGPoint {
        let s = shownScale, c = shownCenter
        return CGPoint(x: bounds.width / 2 + (q.x - c.x) * s, y: bounds.height - (bounds.height / 2 + (q.y - c.y) * s))
    }

    /// The tools' marks: what was done earlier, faintly; the drag in progress; the brush's outline.
    private func drawTools(_ ctx: CGContext) {
        guard tool != .none else { return }
        let s = shownScale
        func path(_ points: [CGPoint]) {
            guard let first = points.first else { return }
            ctx.beginPath()
            ctx.move(to: viewPoint(first))
            for q in points.dropFirst() { ctx.addLine(to: viewPoint(q)) }
            if points.count == 1 { ctx.addLine(to: viewPoint(first)) }
        }
        func box(_ r: CGRect) -> CGRect {
            let a = viewPoint(CGPoint(x: r.minX, y: r.minY)), b = viewPoint(CGPoint(x: r.maxX, y: r.maxY))
            return CGRect(x: min(a.x, b.x), y: min(a.y, b.y), width: abs(b.x - a.x), height: abs(b.y - a.y))
        }
        ctx.saveGState()
        ctx.setLineCap(.round)
        ctx.setLineJoin(.round)
        for mark in marks {
            switch mark {
            case let .box(r, restore):
                ctx.setStrokeColor(red: restore ? 0.6 : 1, green: restore ? 0.8 : 0.85, blue: restore ? 1 : 0.2, alpha: 0.35)
                ctx.setLineWidth(1)
                ctx.stroke(box(r))
            case let .stroke(points, radius, restore):
                ctx.setStrokeColor(red: restore ? 0.6 : 1, green: restore ? 0.8 : 0.85, blue: restore ? 1 : 0.2, alpha: 0.10)
                ctx.setLineWidth(max(2 * radius * s, 1))
                path(points)
                ctx.strokePath()
            }
        }
        // The drag in progress.
        if let start = dragStart, let last = dragPoints.last {
            let colour: (CGFloat, CGFloat, CGFloat) = dragRestores ? (0.6, 0.8, 1) : (1, 0.85, 0.2)
            switch tool {
            case .box:
                let r = CGRect(x: min(start.x, last.x), y: min(start.y, last.y), width: abs(last.x - start.x), height: abs(last.y - start.y))
                ctx.setFillColor(red: colour.0, green: colour.1, blue: colour.2, alpha: 0.10)
                ctx.fill(box(r))
                ctx.setStrokeColor(red: colour.0, green: colour.1, blue: colour.2, alpha: 0.9)
                ctx.setLineWidth(1.5)
                ctx.stroke(box(r))
            case let .brush(radius):
                ctx.setStrokeColor(red: colour.0, green: colour.1, blue: colour.2, alpha: 0.30)
                ctx.setLineWidth(max(2 * radius * s, 1))
                path(dragPoints)
                ctx.strokePath()
            case .none:
                break
            }
        }
        // The brush's size, round the pointer.
        if case let .brush(radius) = tool, let at = hover {
            let r = radius * s
            ctx.setStrokeColor(red: 1, green: 1, blue: 1, alpha: 0.9)
            ctx.setLineWidth(1)
            ctx.strokeEllipse(in: CGRect(x: at.x - r, y: at.y - r, width: 2 * r, height: 2 * r))
            ctx.setStrokeColor(red: 0, green: 0, blue: 0, alpha: 0.6)
            ctx.strokeEllipse(in: CGRect(x: at.x - r - 1, y: at.y - r - 1, width: 2 * r + 2, height: 2 * r + 2))
        }
        ctx.restoreGState()
    }

    /// Two-finger drag on the trackpad pans a zoomed image.
    override func scrollWheel(with event: NSEvent) {
        guard !isFit else { return }
        stopGlide()
        let k: CGFloat = event.hasPreciseScrollingDeltas ? 1 : 10
        center.x -= event.scrollingDeltaX * k / scale
        center.y -= event.scrollingDeltaY * k / scale
        clamp()
        needsDisplay = true
    }

    /// Pinch zooms about the pointer, between fit and 200%.
    override func magnify(with event: NSEvent) {
        guard image != nil, space.width > 0 else { return }
        stopGlide()
        let p = convert(event.locationInWindow, from: nil)
        let under = spacePoint(p)
        let limit = max(HeroNSView.maxZoom / backing, fitScale)
        let s = min(max(shownScale * (1 + event.magnification), fitScale), limit)
        if s <= fitScale * 1.0001 {
            isFit = true
        } else {
            isFit = false
            scale = s
            center = CGPoint(x: under.x - (p.x - bounds.width / 2) / s,
                             y: under.y - ((bounds.height - p.y) - bounds.height / 2) / s)
            clamp()
        }
        report()
        needsDisplay = true
        onUserZoom?(.pinch)
    }
}

/// One large image. `slot` 0 is the single view and the left side of the side-by-side view;
/// slot 1 is the right side.
struct HeroView: NSViewRepresentable {
    let session: Session
    let slot: Int

    func makeNSView(context: Context) -> HeroNSView {
        let view = HeroNSView()
        session.attach(view, slot: slot)
        return view
    }

    func updateNSView(_ view: HeroNSView, context: Context) {}
}
