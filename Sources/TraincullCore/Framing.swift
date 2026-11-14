import Foundation

/// A point or size in pixels of the full-size image.
public struct P: Equatable {
    public var x: Double
    public var y: Double

    public init(_ x: Double, _ y: Double) {
        self.x = x
        self.y = y
    }
}

/// One subject a detector found, in pixels of the upright full-size image. Anything a detector
/// can't provide is NaN. "Eye 1" and "eye 2" are in no particular order.
public struct Subject: Equatable {
    public var left: Double
    public var top: Double
    public var right: Double
    public var bottom: Double
    public var eye1X = Double.nan
    public var eye1Y = Double.nan
    public var eye2X = Double.nan
    public var eye2Y = Double.nan
    public var iris1X = Double.nan
    public var iris1Y = Double.nan
    public var iris2X = Double.nan
    public var iris2Y = Double.nan
    public var irisDiameter = Double.nan

    public init(left: Double, top: Double, right: Double, bottom: Double) {
        self.left = left
        self.top = top
        self.right = right
        self.bottom = bottom
    }

    public var hasEyes: Bool { !eye1X.isNaN && !eye1Y.isNaN && !eye2X.isNaN && !eye2Y.isNaN }
    public var hasIrises: Bool {
        !iris1X.isNaN && !iris1Y.isNaN && !iris2X.isNaN && !iris2Y.isNaN && !irisDiameter.isNaN && irisDiameter > 0
    }
    public var width: Double { right - left }
    public var height: Double { bottom - top }
    public var centerX: Double { (left + right) / 2 }
    public var centerY: Double { (top + bottom) / 2 }
}

/// Which signal framed the frame, best first.
public enum FramingMethod: String {
    case iris
    case eyes
    case faceBox = "face box"
    case focus = "focus point"
    case point = "clicked point"
}

/// What framed a frame. `anchor` is the point to place on screen (the eyes' midpoint).
/// `eyeSpan` is the eye-to-eye distance in image pixels, or the equivalent from iris size or
/// face width; nil when only a point is known.
public struct FaceResult: Equatable {
    public let method: FramingMethod
    public let anchor: P
    public let eyeSpan: Double?

    public init(method: FramingMethod, anchor: P, eyeSpan: Double?) {
        self.method = method
        self.anchor = anchor
        self.eyeSpan = eyeSpan
    }
}

/// Scale and centre for the zoom view (image coordinates; scale 1 = 100%).
public struct Framed: Equatable {
    public let scale: Double
    public let center: P
    public let keptPreviousZoom: Bool
}

/// A port of the Android app's `face/Framing.kt`.
public enum Framing {
    /// Average adult interpupillary distance ÷ iris diameter (63 mm ÷ 11.7 mm).
    public static let eyeSpanPerIris = 5.4

    /// Eye anchor on screen: centred horizontally, somewhat above the middle.
    public static let anchorX = 0.5
    public static let anchorY = 0.42

    /// Picks the best framing signal from one detected subject: iris → eyes → face box.
    public static func fromSubject(_ s: Subject) -> FaceResult {
        let boxW = s.width
        let boxResult = FaceResult(method: .faceBox, anchor: P(s.centerX, s.top + s.height * 0.42), eyeSpan: boxW * 0.45)
        if !s.hasEyes { return boxResult }
        let e1 = P(s.eye1X, s.eye1Y)
        let e2 = P(s.eye2X, s.eye2Y)
        let eyeDist = dist(e1, e2)
        // Profile or badly tracked: eye positions say little. Use the face box.
        if eyeDist < boxW * 0.15 { return boxResult }
        if s.hasIrises {
            let irisSpan = s.irisDiameter * eyeSpanPerIris
            // Head turns shrink the eye distance (ratio up to ~2.5); outside that, distrust iris.
            let ratio = irisSpan / eyeDist
            if ratio >= 0.7 && ratio <= 2.5 {
                return FaceResult(method: .iris, anchor: mid(P(s.iris1X, s.iris1Y), P(s.iris2X, s.iris2Y)), eyeSpan: irisSpan)
            }
        }
        return FaceResult(method: .eyes, anchor: mid(e1, e2), eyeSpan: eyeDist)
    }

    private static func mid(_ a: P, _ b: P) -> P { P((a.x + b.x) / 2, (a.y + b.y) / 2) }
    private static func dist(_ a: P, _ b: P) -> Double { ((a.x - b.x) * (a.x - b.x) + (a.y - b.y) * (a.y - b.y)).squareRoot() }

    /// Eye span on screen: a face is ~3 eye spans tall and ~2.3 wide, so this keeps forehead
    /// and chin roughly in frame.
    public static func targetEyeSpan(_ viewW: Double, _ viewH: Double) -> Double { min(viewW * 0.39, viewH * 0.28) }

    /// - Parameters:
    ///   - minScale: the view's fit-to-screen scale; framing never zooms out past it.
    ///   - previousScale: the last face-framed zoom, for the dead zone; nil if none.
    ///   - deadZone: keep `previousScale` if the new zoom is within this fraction of it.
    public static func frame(_ r: FaceResult, viewW: Double, viewH: Double, minScale: Double,
                             previousScale: Double?, deadZone: Double, eyesAt100: Bool = false) -> Framed {
        var kept = false
        var scale: Double
        if let span = r.eyeSpan {
            scale = eyesAt100 ? 1 : targetEyeSpan(viewW, viewH) / span
        } else {
            scale = 1 // a point only: check focus at 100%
        }
        let lower = min(minScale, 1)
        scale = min(max(scale, lower), 1) // never past actual pixels
        if !eyesAt100, r.eyeSpan != nil, let previous = previousScale, deadZone > 0, abs(scale / previous - 1) < deadZone {
            scale = min(max(previous, lower), 1)
            kept = true
        }
        return Framed(scale: scale, center: center(r.anchor, viewW: viewW, viewH: viewH, scale: scale), keptPreviousZoom: kept)
    }

    /// The centre that puts `anchor` at (anchorX, anchorY) of the view at a given zoom. The zoom
    /// view then clamps it so the image never leaves empty space at an edge. Also used on its
    /// own when a second image follows the first one's zoom in the side-by-side view.
    public static func center(_ anchor: P, viewW: Double, viewH: Double, scale: Double) -> P {
        P(anchor.x + (viewW * 0.5 - viewW * anchorX) / scale, anchor.y + (viewH * 0.5 - viewH * anchorY) / scale)
    }
}

extension Subject {
    /// The same subject with every coordinate multiplied by `k`: detection image → full image.
    public func scaled(_ k: Double) -> Subject {
        var s = Subject(left: left * k, top: top * k, right: right * k, bottom: bottom * k)
        s.eye1X = eye1X * k; s.eye1Y = eye1Y * k; s.eye2X = eye2X * k; s.eye2Y = eye2Y * k
        s.iris1X = iris1X * k; s.iris1Y = iris1Y * k; s.iris2X = iris2X * k; s.iris2Y = iris2Y * k
        s.irisDiameter = irisDiameter * k
        return s
    }
}
