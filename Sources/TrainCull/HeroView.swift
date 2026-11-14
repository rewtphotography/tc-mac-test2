import AppKit
import SwiftUI
import TraincullCore

/// The large focus image. It starts fitted; a click goes to face zoom (or to the clicked point
/// when no face is known); a second click returns to fit. Two-finger drag pans, pinch zooms.
/// There is no loupe and no mouse-drag panning.
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

    /// What to frame for a click at a point of the space.
    var targetFor: ((CGPoint) -> FaceResult)?
    /// Called when the zoom changes: fitted or not, and the zoom in percent.
    var onZoom: ((Bool, Int) -> Void)?

    static let maxZoom: CGFloat = 2 // 200%
    static let deadZone = 0.05

    override var acceptsFirstResponder: Bool { true }
    override var isOpaque: Bool { true }

    private var backing: CGFloat { window?.backingScaleFactor ?? 2 }
    private var fitScale: CGFloat {
        guard space.width > 0, space.height > 0, bounds.width > 0, bounds.height > 0 else { return 1 }
        return min(bounds.width / space.width, bounds.height / space.height)
    }
    private var shownScale: CGFloat { isFit ? fitScale : scale }
    private var shownCenter: CGPoint { isFit ? CGPoint(x: space.width / 2, y: space.height / 2) : center }

    /// Shows a picture of the current frame. `newFrame` returns to the fitted view.
    func show(_ picture: CGImage?, space newSpace: CGSize, newFrame: Bool) {
        if newFrame {
            isFit = true
        } else if !isFit, space.width > 0, newSpace.width > 0, newSpace != space {
            // A sharper picture of the same frame arrived with a different pixel grid.
            let k = newSpace.width / space.width
            center = CGPoint(x: center.x * k, y: center.y * k)
            scale /= k
        }
        image = picture
        space = newSpace
        clamp()
        report()
        needsDisplay = true
    }

    func fit() {
        if isFit { return }
        isFit = true
        report()
        needsDisplay = true
    }

    var isZoomed: Bool { !isFit }

    /// Frames `result` the way the Android app does: eyes anchored, capped at 100%.
    func zoom(to result: FaceResult) {
        guard space.width > 0, bounds.width > 0 else { return }
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
        needsDisplay = true
    }

    private func report() { onZoom?(isFit, Int((shownScale * backing * 100).rounded())) }

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
        let s = shownScale, c = shownCenter
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
        // True pixels at 100% and above on the full-size picture; smooth otherwise.
        ctx.interpolationQuality = (kx > 0.99 && s * backing >= 1) ? .none : .high
        ctx.draw(part, in: CGRect(x: left, y: bounds.height - top - h * s, width: w * s, height: h * s))
    }

    // MARK: Input

    override func mouseDown(with event: NSEvent) {
        downPoint = convert(event.locationInWindow, from: nil)
    }

    override func mouseUp(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        defer { downPoint = nil }
        guard let d = downPoint, hypot(p.x - d.x, p.y - d.y) < 4, image != nil, space.width > 0 else { return }
        if !isFit {
            fit()
            return
        }
        let at = spacePoint(p)
        guard CGRect(origin: .zero, size: space).contains(at) else { return }
        zoom(to: targetFor?(at) ?? FaceResult(method: .point, anchor: P(Double(at.x), Double(at.y)), eyeSpan: nil))
    }

    /// Two-finger drag on the trackpad pans a zoomed image.
    override func scrollWheel(with event: NSEvent) {
        guard !isFit else { return }
        let k: CGFloat = event.hasPreciseScrollingDeltas ? 1 : 10
        center.x -= event.scrollingDeltaX * k / scale
        center.y -= event.scrollingDeltaY * k / scale
        clamp()
        needsDisplay = true
    }

    /// Pinch zooms about the pointer, between fit and 200%.
    override func magnify(with event: NSEvent) {
        guard image != nil, space.width > 0 else { return }
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
    }
}

struct HeroView: NSViewRepresentable {
    let session: Session

    func makeNSView(context: Context) -> HeroNSView {
        let view = HeroNSView()
        session.attach(view)
        return view
    }

    func updateNSView(_ view: HeroNSView, context: Context) {}
}
