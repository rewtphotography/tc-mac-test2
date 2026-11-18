import Foundation

/// How far a mask's edge is refined. Each tier includes the ones before it. Off is the edge
/// of the first-pass mask, snapped to the photo; the others add colour matting, and only in
/// the hair zone (masking spec v3, section 5).
public enum MatteTier: Int, CaseIterable {
    /// No colour matting: the first-pass mask, scaled up and snapped to the photo's edges.
    /// The reference every other tier is judged against.
    case off
    /// One colour for the subject and one for the background near each pixel. Quick; right for
    /// clean edges such as hair on a plain backdrop.
    case fast
    /// Many candidate colours gathered along rays, so several background colours behind one
    /// head of hair are told apart.
    case high
    /// Closed-form matting on top of High: every strand is solved for against its neighbours.
    case max

    public var name: String {
        switch self {
        case .off: return "Off"
        case .fast: return "Fast"
        case .high: return "High"
        case .max: return "Max"
        }
    }
}

/// A finer mask of one head, from a second look at just that part of the photo.
public struct HeadPatch {
    public var rect: PixelRect
    public var mask: Gray

    public init(rect: PixelRect, mask: Gray) {
        self.rect = rect
        self.mask = mask
    }
}

/// The numbers the plan says to tune. Defaults are the plan's.
public struct MatteSettings {
    public var foregroundThreshold: Float = 0.97
    public var backgroundThreshold: Float = 0.03
    public var contrastLow: Float = 0.02
    public var contrastHigh: Float = 0.10
    public var guidedRadius = 4
    public var guidedEpsilon: Float = 1e-4
    public var rays = 8
    public var raySteps = 24
    public var distanceWeight: Float = 0.5
    public var costFalloff: Float = 50
    public var softPrior = 0.05
    public var hardPrior = 100.0
    public var laplacianEpsilon = 1e-7
    public var maxIterations = 300
    public var tolerance = 1e-4
    public var tileCore = 896
    public var tileApron = 64
    /// The uncertain band's width as fractions of the face's height: how far the certain
    /// subject is pulled in, and how far the certain background is pushed out.
    public var bandIn: Float = 0.02
    public var bandOut: Float = 0.06
    /// Where the first-pass mask's edge is crisp, the uncertain band is only this many
    /// quarter-size pixels wide on each side (wide enough for the snap to carry the edge
    /// the few pixels it may need to: at one and two, an edge that wanted to move further
    /// stopped dead at the band's border, in steps the size of these pixels); the full band is kept for edges that are
    /// genuinely soft (hair). An edge counts as soft when it is wider than `softEdge`.
    public var adaptiveBand = true
    public var crispIn = 2
    public var crispOut = 3
    public var softEdge: Float = 4
    /// Colour matting runs in the hair zone only. With no face there is no hair zone to go
    /// by, and the whole edge is treated as one.
    public var hairOnly = true
    /// Outside the hair zone and in focus, the scaled-up edge is steepened by this much
    /// around its middle: a model's edge, enlarged, is wider than the real one.
    public var steepen: Float = 2
    /// First-pass values within this much of 0 or 1 are taken as 0 or 1. Must be at least
    /// as far in as the certain-area thresholds (0.03 from either end), or the edge of the
    /// uncertain band shows.
    public var haze: Float = 0.06
    /// The snap to the photo is trusted where the photo's brightness explains the mask this
    /// well (the squared correlation within a small window); below that the model's edge stands.
    public var snapLow: Float = 0.3
    public var snapHigh: Float = 0.7
    /// The snap looks this many pixels either side, and is done this many times over: each
    /// pass pulls a soft edge further onto the photo's.
    public var snapRadius = 6
    /// Off since the colour snap (spec v4, 1.3) took over: on real photos this snap, which
    /// switches on and off along an edge with how well brightness explains it, left the edge
    /// jagged in steps of a few pixels.
    public var snapPasses = 0
    /// The colour snap (masking spec v4, 1.3): in a ring this many pixels either side of the
    /// edge (at 33 megapixels; it scales with the square root of the photo's size), and where
    /// the subject's and background's colours are clearly different (the contrast measure
    /// between `colourLow` and `colourHigh`), the edge goes where the pixel's colour puts
    /// it, but never more than `colourReach` from where it was. Not in the hair zone.
    public var colourSnap = true
    public var colourRing: Float = 4
    public var colourLow: Float = 0.08
    public var colourHigh: Float = 0.20
    public var colourReach: Float = 0.6
    /// The two colours must also differ by this much outright (the distance between them,
    /// with each channel from 0 to 1) before the snap acts at all, and by `colourFull` for
    /// it to act fully. Black boots on dark asphalt differ a lot in proportion and hardly at
    /// all outright; snapping there turned the shadow under a sole into a whisker of mask.
    public var colourFloor: Float = 0.10
    public var colourFull: Float = 0.25
    /// And when they differ by this much outright, they are clearly different whatever the
    /// proportional measure says. That measure divides by how bright the two are, so skin
    /// against a pale, bright background (far apart, but both bright) scored a third:
    /// its edge was neither snapped nor cleaned, and kept a pale rim.
    public var colourPlain: Float = 0.45
    /// Edge pixels are part subject and part background. With this on, every such pixel's
    /// shares say how much of its light is the subject's (spec v4, 1.4), so darkening the
    /// background doesn't leave the background's light behind as a rim.
    public var decontaminate = true
    /// Decontamination also of pixels just inside the edge that the mask calls all subject
    /// (coverage 95% and over) but whose colour says a little background light lies over
    /// them: as far as that colour puts them at `tailCoverage` or more subject (less, and
    /// it is something else: a cuff, a highlight), within about eight pixels of the edge.
    public var innerTail = true
    public var tailCoverage: Float = 0.7
    /// The last word on colour (masking spec v5, 1.1): masking may take colour out of an
    /// edge pixel but never add any. Each edge pixel is rendered both ways (background
    /// darkened, subject darkened) and compared with the photo; if it has come out more
    /// colourful than the photo is there, or a different hue, its colour shares are replaced
    /// by one share for all three channels, which keeps the brightness and the photo's own colour.
    public var colourGuard = true
    public var guardChroma: Float = 0.02
    public var guardHue: Float = 15
    /// The guard's lightness bound: the subject's colour as an edge pixel's shares and
    /// coverage imply it may be this much (as a fraction of its brightness) darker than the
    /// darker of the pixel itself and the subject beside it, or lighter than the lighter. 0: no check.
    public var guardLightness: Float = 0.04
    public var guardLighter = true
    /// Spec v5, 1.3 has the snap left out where the background beside the edge is blown
    /// out, and where too little real background is near to know its colour. Both are here
    /// and both are off: tried on the owner's 7451, leaving the snap out beside the white
    /// background put a light rim back along the arm–waist gap, while the colour the spec
    /// was after came from the colour shares, not from the snap.
    /// Under the Refine Hair brush the guards are let go: the stroke is the user's leave to
    /// take out see-through blobs and bring back strands (masking spec v5, 2.3).
    public var relaxGuards = false
    public var snapSkipsBright = false
    public var snapNeedsBackground: Float = 0
    /// Where the first-pass mask was sure and the colours either side are less distinct
    /// than this (0 to 1), refinement may not change it (spec v3, section 5, "Guards").
    public var guardContrast: Float = 0.6
    /// Re-centring (the final masking round, priority 1): the snapped edge is moved onto the
    /// photo's strongest colour change along it. It looks `recentreReach` first-pass pixels
    /// either side (at least `recentreLeast` and at most `recentreMost` photo pixels), and
    /// smooths what it finds over `recentreSmooth` first-pass pixels along the edge.
    public var recentre = true
    public var recentreReach: Float = 1.5
    public var recentreLeast: Float = 4.5
    public var recentreMost: Float = 12
    public var recentreSmooth: Float = 3
    /// The enlarged first-pass edge is made steeper by its width over the photo's edge's
    /// width, within these limits. Below 1 it would be made softer than the model had it.
    /// Under 1 the edge is made wider instead: a closer look by the model at a soft edge
    /// (a hand a little out of focus) comes back hard, and a hard mask edge on a soft
    /// photo edge shows as a line.
    public var gainLeast: Float = 0.3
    public var gainMost: Float = 6
    /// A colour change counts as an edge from this much per pixel (all three channels
    /// together, in linear light, each from 0 to 1), and fully at three times it.
    public var edgeStrength: Float = 0.012
    /// The subject light bound (masking spec v6, 1.1, reshaped by the follow-up after alpha
    /// 17): at an edge, the subject's part of a pixel's light (the pixel times its shares)
    /// may be no lighter than `portionLightness` × the subject's colour at that coverage
    /// (+ `portionLightnessPlus`, Oklab L), and its hue and chroma no further than
    /// `portionHue` (Oklab a, b, scaled by its lightness over the subject's) from the
    /// subject's colour beside the edge. Whatever light it loses goes to the background.
    /// (The first form held each channel's brightness, and a teal pixel no brighter than
    /// a black sleeve passed in every channel.)
    public var lightBound = true
    public var portionLightness: Float = 1.1
    public var portionLightnessPlus: Float = 0.005
    public var portionHue: Float = 0.02
    /// The hair zone round each face (spec v6, section 5): a box this many face widths wide
    /// and face heights high, centred a quarter of a face height above the face's middle.
    /// (2.6 × 3.0 until v6: on 6303 its border ran through the peace sign.)
    public var hairBoxWidth: Float = 2.0
    public var hairBoxHeight: Float = 2.4
    /// The primary person's limbs and joints are never hair: this many face heights either
    /// side of each is taken out of the zone.
    public var bodyNotHair: Float = 0.25

    public init() {}
}

/// A finished mask for a whole photo.
public struct MatteOutput {
    public let w: Int
    public let h: Int
    /// How much of each pixel is subject, 0 to 255.
    public var alpha: [UInt8]
    /// For each pixel, four bytes: how much of its red, green and blue light comes from the
    /// subject (then 255). Equal to `alpha` away from edges. Blending with these instead of
    /// `alpha` keeps background colour out of hair when the two are adjusted differently.
    public var shares: [UInt8]
    /// The three-way split the refinement started from, a quarter of the photo's size:
    /// 0 background, 128 unknown, 255 subject.
    public var trimap: [UInt8]
    public let trimapW: Int
    public let trimapH: Int
    /// The part of the photo that holds every uncertain pixel.
    public var band: PixelRect
    public var unknownPixels: Int
    /// What each stage did and how long it took, for the diagnostics log.
    public var log: [String]
    /// Things that look wrong, found by the checks that run on every mask ("SEAM?", "GLOW?").
    public var warnings: [String] = []
    /// At the trimap's size: how far each part is in the hair zone, 0 to 255.
    public var hair: [UInt8] = []
    /// At the trimap's size: 1 where the edge was snapped to the photo, 2 where colour
    /// matting ran as well, 0 elsewhere.
    public var zones: [UInt8] = []
    /// Mean alpha just outside the snapped edge (halo) and mean 1 − alpha just inside it
    /// (erosion), in the hair zone and elsewhere; nil where there was nothing to measure.
    public var edgeQuality = EdgeQuality()
    /// How many edge pixels the colour guard had to put back. Near zero when all is well.
    public var guardCorrections = 0
    /// How many edge pixels the guard's lightness bound moved.
    public var lightnessCorrections = 0
    /// Where the finished edge sits against the photo's own, and where the first pass's did.
    public var edgeOffset = EdgeOffset()
    public var edgeOffsetBefore = EdgeOffset()
    /// How many edge pixels the subject light bound moved, and by how much on average (Oklab ΔE
    /// of the subject's part of the pixel).
    public var lightBounded = 0
    public var lightBoundDeltaE: Float = 0
    /// Where the hair zone came from: "faces", "the body pose's head", "none" or "the brush".
    public var hairZoneFrom = ""
}

/// How clean a finished edge is, measured in a ring 3 to 10 pixels either side of the
/// snapped first-pass edge (masking spec v3, section 10).
public struct EdgeQuality: Equatable {
    /// In the ring 3 to 10 pixels from the edge.
    public var haloHair: Float?
    public var erosionHair: Float?
    public var haloElsewhere: Float?
    public var erosionElsewhere: Float?
    /// In the ring right at the edge, 0 to 3 pixels from it (spec v4, 1.7): where a fringe shows.
    public var nearHaloHair: Float?
    public var nearErosionHair: Float?
    public var nearHaloElsewhere: Float?
    public var nearErosionElsewhere: Float?
    /// Away from hair and where the colours can be told apart: how far, on average, the
    /// mask is from what each edge pixel's own colour says it should be. A fringe measure
    /// that doesn't depend on where the edge was first drawn.
    public var fringe: Float?

    public init() {}

    public var summary: String {
        func text(_ v: Float?) -> String { v.map { String(format: "%.3f", locale: Locale(identifier: "en_US_POSIX"), $0) } ?? "n/a" }
        return "halo 0–3 px hair \(text(nearHaloHair)) · elsewhere \(text(nearHaloElsewhere)) · 3–10 px hair \(text(haloHair)) · elsewhere \(text(haloElsewhere))"
            + " · erosion 0–3 px hair \(text(nearErosionHair)) · elsewhere \(text(nearErosionElsewhere)) · 3–10 px hair \(text(erosionHair)) · elsewhere \(text(erosionElsewhere))"
            + " · colour fringe \(text(fringe))"
    }
}

/// Refines a rough subject mask into a matte with soft, strand-level edges. The rough mask
/// says what the subject is; this works out exactly where its edge lies, and only in the thin
/// band where that is uncertain, so the cost follows the length of the edge, not the size of
/// the photo. Everything here is plain arithmetic on the processor, tested on Linux.
public final class Matte {
    public let photo: Photo
    let settings: MatteSettings
    let W: Int, H: Int
    let qw: Int, qh: Int

    // A quarter of the photo's size.
    var qrgb = Buf<Float>(0, 0)
    var m0q: Gray
    /// The rough mask at the size it was given, for the edge that is scaled up and snapped.
    let m0Fine: Gray
    let forced: Gray?
    /// How far each quarter-size pixel is in the hair zone, 0 to 1.
    var hairQ = Buf<Float>(0, 0)
    /// The same from the faces alone, without what the hair brush painted. Under the brush
    /// the mask is the matting model's and is not moved; the colours beside a clear edge
    /// there, and the light just inside it, are still worked out as anywhere else.
    var hairFaces = Buf<Float>(0, 0)
    /// Where the subject light bound is not applied, 0 to 1: the hair zone and, under the
    /// hair brush, the stroke (spec v6, 1.1). Not an Edge Brush stroke.
    var lightExcluded = Buf<Float>(0, 0)
    /// At quarter size: how far re-centring measured the photo's edge there (0 to 1), and
    /// whether certain subject lies within about ten pixels. The light bound trusts the
    /// subject's colour only where one of the two holds.
    var knownQ: Buf<Float>?
    var subjectNear = Buf<Float>(0, 0)
    let body: BodyPose?
    let forcedIsHair: Bool
    var hairZoneFrom = "faces"
    /// The three-way split and band of the whole edge. `triq` and `band` are these while the
    /// edge is snapped, and their hair-zone part while colour matting runs.
    var tri0 = Buf<UInt8>(0, 0)
    var band0 = PixelRect(x: 0, y: 0, w: 0, h: 0)
    var triM = Buf<UInt8>(0, 0)
    var bandM = PixelRect(x: 0, y: 0, w: 0, h: 0)
    /// The snapped edge over `band0`: the Off tier's answer.
    var offAlpha = Buf<Float>(0, 0)
    var mattedCount = 0
    /// Over `band0`: how far the colour snap acted on each pixel, 0 to 255.
    var ring = Buf<UInt8>(0, 0)
    /// At quarter size: how much certain background lies near each pixel, 0 to 1. Where
    /// there is little, the background colour there is a guess carried in from further away.
    var backgroundNear = Buf<Float>(0, 0)
    /// At quarter size: 2 where the subject's colour may be sampled, 0 where the background's may.
    var colourKind = Buf<UInt8>(0, 0)
    var guardNote = ""
    var snapNote = ""
    var recentreNote = ""
    var offsetBefore = EdgeOffset()
    /// How many photo pixels one pixel of the model's answer covers where the first-pass
    /// mask was made: the scale of its mistakes about where an edge is.
    let firstPassPixel: Float
    var fringeAfter: Float?
    var triq = Buf<UInt8>(0, 0) // 0 background, 1 unknown, 2 subject
    var fq = Buf<Float>(0, 0) // subject colour near each pixel
    var bq = Buf<Float>(0, 0) // background colour near each pixel
    /// The same, but right at a measured edge the colours found beside it there (see
    /// `recentre`). The snapped edge and its colour shares go by these.
    var fEdge = Buf<Float>(0, 0)
    var bEdge = Buf<Float>(0, 0)
    /// At quarter size: how much of each neighbourhood is inside the snapped edge. Just
    /// under 1 means "inside, but only just": where an edge's blur still reaches.
    var insideNear = Buf<Float>(0, 0)
    var coefA = Buf<Float>(0, 0) // guided upsampling of the rough mask
    var coefB = Buf<Float>(0, 0)
    var rIn: Float = 4
    var rOut: Float = 8

    // The photo's own size, over the band only.
    var band = PixelRect(x: 0, y: 0, w: 0, h: 0)
    var alpha = Buf<Float>(0, 0)
    var conf = Buf<UInt8>(0, 0)
    var fPair: Buf<UInt32>?
    var bPair: Buf<UInt32>?
    var unknownCount = 0
    var log: [String] = []
    var warnings: [String] = []
    /// The rough mask at quarter size, for the guards that keep the result near it.
    var m0qBuf = Buf<Float>(0, 0)
    /// How far each part is in focus, 1 (as sharp as the subject) to 0 (well out of focus), at
    /// quarter size. Colour arithmetic on a blurred edge only adds noise, so it is trusted less there.
    var focusQ: Buf<Float>?
    /// The contrast between subject and background colour at each band pixel, 0 to 255.
    var contrast = Buf<UInt8>(0, 0)
    /// Whether the Fast tier put each band pixel in the subject, to compare with the final answer.
    var fastHalf = Buf<UInt8>(0, 0)

    /// - Parameters:
    ///   - coarse: the rough mask, any size, covering the whole photo.
    ///   - faces: face rectangles in pixels of the photo, y down.
    ///   - patches: finer masks of each head, if a second look was taken.
    ///   - defocus: how blurred each part of the photo is (`SharpnessMap.dense`), any size.
    ///   - subjectSharpness: the blur of the subject itself, in the same units.
    ///   - forced: where the user has painted with the Refine Hair brush (any size, 0 to 1
    ///     over the photo). There everything but the face is uncertain, and that, not the
    ///     box round each head, is the hair zone.
    ///   - firstPassPixel: photo pixels for each pixel of the model answer the rough mask
    ///     came from. Without it, the rough mask's own pixel size is used.
    ///   - body: the primary person's body pose, in pixels of the photo: its limbs are never
    ///     hair, and with no face its head places the hair zone (spec v6, section 5).
    ///   - forcedIsHair: false for the Edge Brush: the stroke is held as the matting model
    ///     drew it, but it is a hard edge, and the light bound applies under it.
    public init(photo: Photo, coarse: Gray, faces: [PixelRect], patches: [HeadPatch] = [], settings: MatteSettings = MatteSettings(),
                defocus: Gray? = nil, subjectSharpness: Float? = nil, forced: Gray? = nil, firstPassPixel: Float? = nil,
                body: BodyPose? = nil, forcedIsHair: Bool = true) {
        self.forced = forced
        self.body = body
        self.forcedIsHair = forcedIsHair
        self.firstPassPixel = max(firstPassPixel ?? Float(photo.w) / Float(max(coarse.w, 1)), 1)
        self.photo = photo
        self.settings = settings
        W = photo.w; H = photo.h
        qw = (W + 3) / 4; qh = (H + 3) / 4
        m0q = coarse.resized(w: qw, h: qh)
        m0Fine = coarse
        if let defocus = defocus, let sharp = subjectSharpness {
            let d = defocus.resized(w: qw, h: qh)
            focusQ = Buf(d.v.map { 1 - smoothstep(sharp + 1.0, sharp + 2.5, $0) })
        }
        let start = Date()
        prepare(faces: faces, patches: patches)
        log.append("setup: band \(band0.w)×\(band0.h), \(unknownCount) uncertain pixels (\(mattedCount) in the hair zone), "
            + "edge widths \(Int(rIn))/\(Int(rOut)) px\(bandNote), \(Matte.seconds(start))")
        let snapStart = Date()
        snap()
        log.append("snap: \(Matte.seconds(snapStart))\(recentreNote)\(snapNote)")
    }

    var bandNote = ""

    static func seconds(_ since: Date) -> String {
        String(format: "%.2f s", locale: Locale(identifier: "en_US_POSIX"), Date().timeIntervalSince(since))
    }

    @inline(__always) static func pack(_ c: SIMD3<Float>) -> UInt32 {
        let v = (c.clamped(lowerBound: SIMD3(repeating: 0), upperBound: SIMD3(repeating: 1)) * 255).rounded(.toNearestOrAwayFromZero)
        return UInt32(v.x) | (UInt32(v.y) << 8) | (UInt32(v.z) << 16)
    }

    @inline(__always) static func unpack(_ p: UInt32) -> SIMD3<Float> {
        SIMD3(Float(p & 255), Float((p >> 8) & 255), Float((p >> 16) & 255)) * (1 / 255)
    }

    /// Three channels blended from the four quarter-size pixels around a point of the photo.
    @inline(__always) func sample3(_ p: UnsafeMutablePointer<Float>, _ x: Int, _ y: Int) -> SIMD3<Float> {
        let fx = min(max((Float(x) + 0.5) * 0.25 - 0.5, 0), Float(qw - 1)), fy = min(max((Float(y) + 0.5) * 0.25 - 0.5, 0), Float(qh - 1))
        let x0 = Int(fx), y0 = Int(fy), x1 = min(x0 + 1, qw - 1), y1 = min(y0 + 1, qh - 1)
        let tx = fx - Float(x0), ty = fy - Float(y0)
        let i00 = (y0 * qw + x0) * 3, i10 = (y0 * qw + x1) * 3, i01 = (y1 * qw + x0) * 3, i11 = (y1 * qw + x1) * 3
        let a = SIMD3(p[i00], p[i00 + 1], p[i00 + 2]), b = SIMD3(p[i10], p[i10 + 1], p[i10 + 2])
        let c = SIMD3(p[i01], p[i01 + 1], p[i01 + 2]), d = SIMD3(p[i11], p[i11 + 1], p[i11 + 2])
        let top = a + (b - a) * tx, bottom = c + (d - c) * tx
        return top + (bottom - top) * ty
    }

    @inline(__always) func sample1(_ p: UnsafeMutablePointer<Float>, _ x: Int, _ y: Int) -> Float {
        let fx = min(max((Float(x) + 0.5) * 0.25 - 0.5, 0), Float(qw - 1)), fy = min(max((Float(y) + 0.5) * 0.25 - 0.5, 0), Float(qh - 1))
        let x0 = Int(fx), y0 = Int(fy), x1 = min(x0 + 1, qw - 1), y1 = min(y0 + 1, qh - 1)
        let tx = fx - Float(x0), ty = fy - Float(y0)
        let top = p[y0 * qw + x0] + (p[y0 * qw + x1] - p[y0 * qw + x0]) * tx
        let bottom = p[y1 * qw + x0] + (p[y1 * qw + x1] - p[y1 * qw + x0]) * tx
        return top + (bottom - top) * ty
    }

    // MARK: Setup, at a quarter of the size

    private func prepare(faces: [PixelRect], patches: [HeadPatch]) {
        let W = self.W, H = self.H, qw = self.qw, qh = self.qh
        // The photo at a quarter size: each pixel the mean of a 4×4 block.
        let q = Buf<Float>(qw * qh * 3, 0)
        let src = photo.p, rowBytes = photo.rowBytes
        parallelRows(qh) { rows in
            for qy in rows {
                for qx in 0 ..< qw {
                    var s = SIMD3<Float>(repeating: 0)
                    var n: Float = 0
                    for y in (qy * 4) ..< min(qy * 4 + 4, H) {
                        for x in (qx * 4) ..< min(qx * 4 + 4, W) {
                            s += rgbAt(src, rowBytes, x, y)
                            n += 1
                        }
                    }
                    s /= max(n, 1)
                    let i = (qy * qw + qx) * 3
                    q.p[i] = s.x; q.p[i + 1] = s.y; q.p[i + 2] = s.z
                }
            }
        }
        qrgb = q

        // Edge widths follow the size of the largest face; without one, the size of the photo.
        if let faceHeight = faces.map({ Float($0.h) }).max(), faceHeight > 0 {
            rIn = min(max(settings.bandIn * faceHeight, 4), 64)
            rOut = min(max(settings.bandOut * faceHeight, 8), 160)
        } else {
            let unit = 0.3 * Float(max(W, H))
            rIn = min(max(settings.bandIn * unit, 4), 64)
            rOut = min(max(settings.bandOut * unit, 8), 160)
        }

        // The hair zone: around each head, outside the oval of the face. Curly hair masks tend
        // to fill the gaps between curls, so the certain-subject region is pulled in further there.
        // It fades in over a few pixels: a hard edge to the zone would show as a straight line in the mask.
        // With no face, the body pose's head stands in for one; with neither there is no
        // hair zone, and the whole outline is a plain edge (spec v6, section 5).
        var hair = [Float](repeating: 0, count: qw * qh)
        var heads = faces
        if heads.isEmpty, let made = body?.headBox() {
            heads = [made]
            hairZoneFrom = "the body pose's head"
        } else if heads.isEmpty {
            hairZoneFrom = "none (no face and no head in the body pose)"
        }
        for f in heads {
            let fw = Float(f.w), fh = Float(f.h)
            let bw = settings.hairBoxWidth * fw, bh = settings.hairBoxHeight * fh
            let cx = Float(f.x) + fw / 2, cy = Float(f.y) + fh / 2 - 0.25 * fh
            let head = PixelRect(x: Int(cx - bw / 2), y: Int(cy - bh / 2), w: Int(bw), h: Int(bh)).clamped(w: W, h: H)
            let ovalY = Float(f.y) + 0.325 * fh, a = fw / 2, b = 1.35 * fh / 2
            if head.isEmpty { continue }
            for qy in (head.y / 4) ..< min((head.maxY + 3) / 4, qh) {
                for qx in (head.x / 4) ..< min((head.maxX + 3) / 4, qw) {
                    let px = Float(qx) * 4 + 2, py = Float(qy) * 4 + 2
                    let dx = (px - (Float(f.x) + fw / 2)) / a, dy = (py - ovalY) / b
                    let outsideOval = min(max(((dx * dx + dy * dy).squareRoot() - 1) / 0.2, 0), 1)
                    let fromEdge = min(min(px - Float(head.x), Float(head.maxX) - px), min(py - Float(head.y), Float(head.maxY) - py))
                    let insideHead = min(max(fromEdge / max(0.15 * fw, 8), 0), 1)
                    hair[qy * qw + qx] = max(hair[qy * qw + qx], outsideOval * insideHead)
                }
            }
        }
        // The body is never hair: hands, forearms and shoulders near the face get the plain edge's clean-up.
        if let body = body, let faceHeight = heads.first.map({ Float($0.h) }), !heads.isEmpty {
            let limbs = Matte.bodyCells(body, radius: settings.bodyNotHair * faceHeight, qw: qw, qh: qh)
            for i in 0 ..< qw * qh { hair[i] *= 1 - limbs[i] }
        }
        if !settings.hairOnly { hair = [Float](repeating: 1, count: qw * qh) }
        hairFaces = Buf(hair)
        // Painted with the hair brush: the stroke is the hair zone, whatever the faces say.
        var painted: [Bool]?
        if let forced = forced {
            let f = forced.resized(w: qw, h: qh)
            var marks = [Bool](repeating: false, count: qw * qh)
            for i in 0 ..< qw * qh {
                hair[i] = min(max(f.v[i], 0), 1)
                marks[i] = f.v[i] > 0.02
            }
            // Not the face itself.
            for face in faces {
                let fw = Float(face.w), fh = Float(face.h)
                let ovalX = Float(face.x) + fw / 2, ovalY = Float(face.y) + 0.325 * fh, a = fw / 2, b = 1.35 * fh / 2
                let box = PixelRect(x: Int(ovalX - a), y: Int(ovalY - b), w: Int(2 * a) + 1, h: Int(2 * b) + 1).clamped(w: W, h: H)
                if box.isEmpty { continue }
                for qy in (box.y / 4) ..< min((box.maxY + 3) / 4, qh) {
                    for qx in (box.x / 4) ..< min((box.maxX + 3) / 4, qw) {
                        let dx = (Float(qx) * 4 + 2 - ovalX) / a, dy = (Float(qy) * 4 + 2 - ovalY) / b
                        if dx * dx + dy * dy < 0.8 { marks[qy * qw + qx] = false }
                    }
                }
            }
            painted = marks
        }
        hairQ = Buf(hair)
        if forced != nil && !forcedIsHair, let f = forced?.resized(w: qw, h: qh) {
            // The Edge Brush: its stroke is held, but it is no hair zone for the light bound.
            lightExcluded = Buf((0 ..< qw * qh).map { hairFaces.p[$0] * (1 - min(max(f.v[$0], 0), 1)) })
        } else {
            lightExcluded = Buf(hair)
        }
        if forced != nil { hairZoneFrom = forcedIsHair ? "the hair brush" : "the edge brush (faces only)" }
        classify(hair)
        if let painted = painted {
            for i in 0 ..< qw * qh where painted[i] { triq.p[i] = 1 }
        }
        if !patches.isEmpty {
            // A second, closer look at each head replaces the rough mask where it was uncertain,
            // fading out towards the edge of the patch.
            for patch in patches where !patch.rect.isEmpty {
                let r = patch.rect
                let feather = max(0.1 * Float(min(r.w, r.h)), 1)
                for qy in max(r.y / 4, 0) ..< min((r.maxY + 3) / 4, qh) {
                    for qx in max(r.x / 4, 0) ..< min((r.maxX + 3) / 4, qw) where triq.p[qy * qw + qx] == 1 {
                        let x = Float(qx) * 4 + 2, y = Float(qy) * 4 + 2
                        let edge = min(min(x - Float(r.x), Float(r.maxX) - x), min(y - Float(r.y), Float(r.maxY) - y))
                        if edge <= 0 { continue }
                        let t = min(edge / feather, 1)
                        let fine = patch.mask.sample((x - Float(r.x)) * Float(patch.mask.w) / Float(r.w), (y - Float(r.y)) * Float(patch.mask.h) / Float(r.h))
                        m0q.v[qy * qw + qx] += (fine - m0q.v[qy * qw + qx]) * t
                    }
                }
            }
            classify(hair)
        }

        // The part of the photo that holds every uncertain pixel.
        var x0 = qw, y0 = qh, x1 = -1, y1 = -1
        unknownCount = 0
        for qy in 0 ..< qh {
            for qx in 0 ..< qw where triq.p[qy * qw + qx] == 1 {
                x0 = min(x0, qx); x1 = max(x1, qx); y0 = min(y0, qy); y1 = max(y1, qy)
                unknownCount += 1
            }
        }
        unknownCount *= 16
        if x1 >= 0 {
            band = PixelRect(x: x0 * 4, y: y0 * 4, w: (x1 - x0 + 1) * 4, h: (y1 - y0 + 1) * 4).clamped(w: W, h: H)
        }
        tri0 = triq
        band0 = band

        // Colour matting's part of the edge: the hair zone. Outside it, uncertain pixels
        // are settled by the rough mask, so matting neither works on them nor reads them
        // as unknown.
        let tm = Buf(triq.array)
        var mx0 = qw, my0 = qh, mx1 = -1, my1 = -1
        mattedCount = 0
        for qy in 0 ..< qh {
            for qx in 0 ..< qw where tm.p[qy * qw + qx] == 1 {
                let i = qy * qw + qx
                if hair[i] > 0.004 {
                    mx0 = min(mx0, qx); mx1 = max(mx1, qx); my0 = min(my0, qy); my1 = max(my1, qy)
                    mattedCount += 1
                } else {
                    tm.p[i] = m0q.v[i] >= 0.5 ? 2 : 0
                }
            }
        }
        mattedCount *= 16
        triM = tm
        bandM = mx1 >= 0 ? PixelRect(x: mx0 * 4, y: my0 * 4, w: (mx1 - mx0 + 1) * 4, h: (my1 - my0 + 1) * 4).clamped(w: W, h: H)
            : PixelRect(x: 0, y: 0, w: 0, h: 0)

        // Where the subject's and the background's colours are taken from: wherever the rough
        // mask is sure, one quarter-size pixel clear of anything it isn't. That is closer to
        // the edge than the certain areas of the three-way split, and it reaches into narrow
        // gaps (between an arm and a waist) that the split leaves wholly uncertain; the
        // colour of what shows through such a gap is then its own, not a guess from elsewhere.
        let sureIn = PlaneMath.extremum(m0q, radius: 1, smallest: true), sureOut = PlaneMath.extremum(m0q, radius: 1, smallest: false)
        let kinds = Buf<UInt8>(qw * qh, 1)
        for i in 0 ..< qw * qh {
            if let painted = painted, painted[i] { continue }
            if sureIn.v[i] >= settings.foregroundThreshold { kinds.p[i] = 2 } else if sureOut.v[i] <= settings.backgroundThreshold { kinds.p[i] = 0 }
        }
        colourKind = kinds
        // Certain subject within about ten pixels: three quarter-size cells.
        let sureSubject = Gray(w: qw, h: qh, v: (0 ..< qw * qh).map { kinds.p[$0] == 2 ? 1 : 0 })
        subjectNear = Buf(PlaneMath.extremum(sureSubject, radius: 3, smallest: false).v)
        fq = Buf(pushPull(weightFor: 2))
        bq = Buf(pushPull(weightFor: 0))
        fEdge = fq
        bEdge = bq
        var near = [Float](repeating: 0, count: qw * qh)
        for i in 0 ..< qw * qh where triq.p[i] == 0 { near[i] = 1 }
        // Looked for across the band and a little beyond it: inside the band there is none by definition.
        PlaneMath.boxBlur(&near, w: qw, h: qh, radius: max(Int((rOut / 4).rounded()), settings.crispOut) + 4)
        backgroundNear = Buf(near)
        m0qBuf = Buf(m0q.v)

        // The rough mask, sharpened against the photo: within each small neighbourhood the mask
        // is fitted as a straight-line function of brightness, and those two numbers are then
        // applied to the full-size photo. Edges in the photo become edges in the mask.
        let n = qw * qh
        var g = [Float](repeating: 0, count: n), gg = [Float](repeating: 0, count: n), gp = [Float](repeating: 0, count: n)
        var p = m0q.v
        for i in 0 ..< n {
            let l = luma(SIMD3(q.p[i * 3], q.p[i * 3 + 1], q.p[i * 3 + 2]))
            g[i] = l; gg[i] = l * l; gp[i] = l * p[i]
        }
        PlaneMath.boxBlur(&g, w: qw, h: qh, radius: 2)
        PlaneMath.boxBlur(&p, w: qw, h: qh, radius: 2)
        PlaneMath.boxBlur(&gg, w: qw, h: qh, radius: 2)
        PlaneMath.boxBlur(&gp, w: qw, h: qh, radius: 2)
        var ca = [Float](repeating: 0, count: n), cb = [Float](repeating: 0, count: n)
        for i in 0 ..< n {
            let a = (gp[i] - g[i] * p[i]) / (gg[i] - g[i] * g[i] + 1e-3)
            ca[i] = a
            cb[i] = p[i] - a * g[i]
        }
        PlaneMath.boxBlur(&ca, w: qw, h: qh, radius: 2)
        PlaneMath.boxBlur(&cb, w: qw, h: qh, radius: 2)
        coefA = Buf(ca)
        coefB = Buf(cb)
    }

    /// Splits the quarter-size mask three ways: certainly subject, certainly background, unknown.
    private func classify(_ hair: [Float]) {
        let narrow = max(Int((rIn / 4).rounded()), 1), wide = max(Int((rOut / 4).rounded()), 2)
        let eroded = PlaneMath.extremum(m0q, radius: narrow, smallest: true)
        let erodedMore = PlaneMath.extremum(m0q, radius: narrow * 2, smallest: true)
        let dilated = PlaneMath.extremum(m0q, radius: wide, smallest: false)
        let n = qw * qh
        let t = Buf<UInt8>(n, 1)
        for i in 0 ..< n {
            if eroded.v[i] + (erodedMore.v[i] - eroded.v[i]) * hair[i] >= settings.foregroundThreshold {
                t.p[i] = 2
            } else if dilated.v[i] <= settings.backgroundThreshold {
                t.p[i] = 0
            }
        }
        triq = t
        bandNote = ""
        let crispIn = settings.crispIn, crispOut = settings.crispOut
        if !settings.adaptiveBand || (narrow <= crispIn && wide <= crispOut) { return }

        // Where the rough mask's own edge is crisp there is little to be uncertain about,
        // and a wide band only gives refinement room to do harm. How wide the edge is: the
        // pixels that are neither in nor out, for each pixel of edge length, nearby.
        var softCells = [Float](repeating: 0, count: n), edgeCells = [Float](repeating: 0, count: n)
        for y in 0 ..< qh {
            for x in 0 ..< qw {
                let i = y * qw + x, m = m0q.v[i]
                if m > 0.1 && m < 0.9 { softCells[i] = 1 }
                if m >= 0.5 {
                    let out = (x > 0 && m0q.v[i - 1] < 0.5) || (x < qw - 1 && m0q.v[i + 1] < 0.5)
                        || (y > 0 && m0q.v[i - qw] < 0.5) || (y < qh - 1 && m0q.v[i + qw] < 0.5)
                    if out { edgeCells[i] = 1 }
                }
            }
        }
        PlaneMath.boxBlur(&softCells, w: qw, h: qh, radius: 4)
        PlaneMath.boxBlur(&edgeCells, w: qw, h: qh, radius: 4)
        var softHere = Gray(w: qw, h: qh)
        for i in 0 ..< n where softCells[i] > 0 {
            let m = m0q.v[i]
            if edgeCells[i] > 0 {
                // Judged on the edge line itself, where the window takes in both of its sides.
                if m >= 0.5 && softCells[i] > settings.softEdge * edgeCells[i] { softHere.v[i] = 1 }
            } else if m > 0.1 && m < 0.9 {
                softHere.v[i] = 1 // no edge nearby at all, yet neither in nor out: a haze
            }
        }
        // The full band is kept all around anything soft, not just on top of it.
        let soft = PlaneMath.extremum(softHere, radius: wide + 4, smallest: false)
        let erodedCrisp = PlaneMath.extremum(m0q, radius: crispIn, smallest: true)
        let dilatedCrisp = PlaneMath.extremum(m0q, radius: crispOut, smallest: false)
        var full = 0, crisp = 0
        for i in 0 ..< n where t.p[i] == 1 {
            if soft.v[i] > 0.5 { full += 1; continue }
            if erodedCrisp.v[i] >= settings.foregroundThreshold {
                t.p[i] = 2
            } else if dilatedCrisp.v[i] <= settings.backgroundThreshold {
                t.p[i] = 0
            } else {
                crisp += 1
            }
        }
        bandNote = " · soft edge \(Matte.percent(full, full + crisp)) of the band, crisp \(Matte.percent(crisp, full + crisp))"
    }

    /// The colour of the nearest certain pixels of one kind, spread smoothly across the gaps
    /// between them: averaged down level by level, then filled back in from coarse to fine.
    private func pushPull(weightFor kind: UInt8) -> [Float] {
        struct Level { var w: Int, h: Int, c: [Float], wt: [Float] }
        var levels: [Level] = []
        var top = Level(w: qw, h: qh, c: [Float](repeating: 0, count: qw * qh * 3), wt: [Float](repeating: 0, count: qw * qh))
        for i in 0 ..< qw * qh where colourKind.p[i] == kind {
            top.wt[i] = 1
            top.c[i * 3] = qrgb.p[i * 3]; top.c[i * 3 + 1] = qrgb.p[i * 3 + 1]; top.c[i * 3 + 2] = qrgb.p[i * 3 + 2]
        }
        levels.append(top)
        // Down to a single pixel, so that every gap is filled from somewhere however far the
        // nearest certain pixel is. (Stopping at 16 left a narrow gap in a small patch with no
        // background colour at all: black, which the colour shares then could not use.)
        while max(levels.last!.w, levels.last!.h) > 1 {
            let fine = levels.last!
            let w = (fine.w + 1) / 2, h = (fine.h + 1) / 2
            var coarse = Level(w: w, h: h, c: [Float](repeating: 0, count: w * h * 3), wt: [Float](repeating: 0, count: w * h))
            for y in 0 ..< h {
                for x in 0 ..< w {
                    var s = SIMD3<Float>(repeating: 0)
                    var ws: Float = 0
                    for yy in (y * 2) ..< min(y * 2 + 2, fine.h) {
                        for xx in (x * 2) ..< min(x * 2 + 2, fine.w) {
                            let i = yy * fine.w + xx
                            s += SIMD3(fine.c[i * 3], fine.c[i * 3 + 1], fine.c[i * 3 + 2])
                            ws += fine.wt[i]
                        }
                    }
                    // Colours are stored already multiplied by their weight; keep the weight at most 1.
                    let i = y * w + x
                    let k = ws > 1 ? 1 / ws : 1
                    coarse.c[i * 3] = s.x * k; coarse.c[i * 3 + 1] = s.y * k; coarse.c[i * 3 + 2] = s.z * k
                    coarse.wt[i] = min(ws, 1)
                }
            }
            levels.append(coarse)
        }
        for l in stride(from: levels.count - 2, through: 0, by: -1) {
            let coarse = levels[l + 1]
            let cw = Gray(w: coarse.w, h: coarse.h, v: coarse.wt)
            let planes = (0 ..< 3).map { ch in Gray(w: coarse.w, h: coarse.h, v: (0 ..< coarse.w * coarse.h).map { coarse.c[$0 * 3 + ch] }) }
            let lw = levels[l].w, lh = levels[l].h
            let kx = Float(coarse.w) / Float(lw), ky = Float(coarse.h) / Float(lh)
            var c = levels[l].c, wt = levels[l].wt
            for y in 0 ..< lh {
                for x in 0 ..< lw {
                    let i = y * lw + x
                    let gap = 1 - wt[i]
                    if gap <= 0 { continue }
                    let sx = (Float(x) + 0.5) * kx, sy = (Float(y) + 0.5) * ky
                    for ch in 0 ..< 3 { c[i * 3 + ch] += gap * planes[ch].sample(sx, sy) }
                    wt[i] += gap * cw.sample(sx, sy)
                }
            }
            levels[l].c = c
            levels[l].wt = wt
        }
        var out = levels[0].c
        for i in 0 ..< qw * qh {
            let k = 1 / max(levels[0].wt[i], 1e-4)
            out[i * 3] *= k; out[i * 3 + 1] *= k; out[i * 3 + 2] *= k
        }
        return out
    }

    // MARK: Running the tiers

    /// Runs the refinement up to `tier`. `progress` is told what is being done; `cancelled` is
    /// asked between stages and tiles, and stops the work with what has been done so far.
    public func run(tier: MatteTier, progress: (String) -> Void = { _ in }, cancelled: () -> Bool = { false }) -> MatteOutput {
        // The same object can be run again at another tier: everything a run adds is reset.
        if setupLog.isEmpty { setupLog = log }
        log = setupLog
        warnings = []
        fPair = nil
        bPair = nil
        var matted = false
        if tier != .off && !bandM.isEmpty {
            triq = triM
            band = bandM
            var start = Date()
            progress("Fast")
            fast()
            log.append("fast: \(Matte.seconds(start))")
            if tier.rawValue >= MatteTier.high.rawValue && !cancelled() {
                start = Date()
                progress("High")
                high()
                log.append("high: \(Matte.seconds(start))")
            }
            if tier == .max && !cancelled() {
                start = Date()
                progress("Max")
                let note = closedForm(progress: progress, cancelled: cancelled)
                log.append("max: \(note), \(Matte.seconds(start))")
            }
            matted = true
            triq = tri0
            band = band0
        } else if tier != .off {
            log.append("no hair zone on the edge: nothing for colour matting to do")
        }
        let start = Date()
        var result = finish(matted: matted)
        log.append("finish: \(Matte.seconds(start))")
        log.append("edge quality: \(result.edgeQuality.summary)")
        result.log = log
        result.warnings = warnings
        return result
    }

    var setupLog: [String] = []

    // MARK: Off: the snapped edge

    /// The first-pass mask scaled up to the photo and snapped to the photo's own edges, over
    /// the whole uncertain band. No colour arithmetic: where the photo's brightness explains
    /// the mask (a clear edge in the photo), the mask's edge is moved onto it; where it
    /// doesn't (black shoes on dark asphalt), the model's edge stands, a little steepened.
    private func snap() {
        let band = band0, bw = band.w, bh = band.h, qw = self.qw, W = self.W, H = self.H
        let out = Buf<Float>(bw * bh, 0)
        offAlpha = out
        if band.isEmpty { return }
        let tq = tri0.p, src = photo.p, rowBytes = photo.rowBytes
        let fine = m0Fine
        let kx = Float(fine.w) / Float(W), ky = Float(fine.h) / Float(H)
        let hair = hairQ.p, focus = focusQ?.p
        let gain = max(settings.steepen, 1)
        let haze = min(max(settings.haze, 0), 0.2)
        let later = settings.recentre
        parallelRows(bh) { rows in
            for by in rows {
                let y = band.y + by
                for bx in 0 ..< bw {
                    let x = band.x + bx
                    let t = tq[(y >> 2) * qw + (x >> 2)]
                    if t != 1 {
                        out.p[by * bw + bx] = t == 2 ? 1 : 0
                        continue
                    }
                    var v = fine.sample((Float(x) + 0.5) * kx, (Float(y) + 0.5) * ky)
                    // A model that is 95% sure over a wide area means "subject", not "5% see-through".
                    // Stretching the scale a little at both ends says so, and makes the uncertain
                    // band meet the certain areas beside it without a step: left as it was, that
                    // step showed as square blocks the size of the quarter-size pixels.
                    v = min(max((v - haze) / (1 - 2 * haze), 0), 1)
                    // Hair and anything out of focus really are soft; they are left as they are.
                    // (With re-centring on, steepening is done there, by as much as the photo says.)
                    if later {
                        out.p[by * bw + bx] = v
                        continue
                    }
                    let sharp = focus.map { sample1($0, x, y) } ?? 1
                    let g = 1 + (gain - 1) * sharp * (1 - min(max(sample1(hair, x, y), 0), 1))
                    out.p[by * bw + bx] = min(max(0.5 + (v - 0.5) * g, 0), 1)
                }
            }
        }

        // Each strip of rows is worked on only across the columns that hold uncertain pixels.
        let stripRows = 128
        let strips = (bh + stripRows - 1) / stripRows
        var spans = [(lo: Int, hi: Int)](repeating: (bw, -1), count: strips)
        for qy in 0 ..< qh {
            let by = qy * 4 - band.y
            if by + 3 < 0 || by >= bh { continue }
            let strip = min(max(by, 0) / stripRows, strips - 1)
            for qx in 0 ..< qw where tq[qy * qw + qx] == 1 {
                let bx = qx * 4 - band.x
                spans[strip].lo = min(spans[strip].lo, max(bx, 0))
                spans[strip].hi = max(spans[strip].hi, min(bx + 3, bw - 1))
            }
        }
        // A strip's uncertain pixels can sit in a quarter-size row that starts in the strip above.
        var reach = spans
        for i in 1 ..< max(strips, 1) {
            reach[i].lo = min(spans[i].lo, spans[i - 1].lo)
            reach[i].hi = max(spans[i].hi, spans[i - 1].hi)
        }
        for _ in 0 ..< max(settings.snapPasses, 0) {
            guided(out, radius: max(settings.snapRadius, 1), gated: true, only: nil, spans: reach)
        }
        if settings.recentre { recentre(out, spans: reach) }
        if settings.colourSnap {
            colourSnap(out, spans: reach)
            guided(out, radius: 2, gated: false, only: ring, spans: reach)
        }
        // How much of each neighbourhood is inside the edge, for the inner tail.
        var inside = [Float](repeating: 0, count: qw * qh)
        for qy in 0 ..< qh {
            for qx in 0 ..< qw {
                let t = tq[qy * qw + qx]
                if t == 2 { inside[qy * qw + qx] = 1 }
                if t != 1 { continue }
                var s: Float = 0, n: Float = 0
                for y in (qy * 4) ..< min(qy * 4 + 4, H) where y >= band.y && y < band.maxY {
                    for x in (qx * 4) ..< min(qx * 4 + 4, W) where x >= band.x && x < band.maxX {
                        if out.p[(y - band.y) * bw + (x - band.x)] >= 0.5 { s += 1 }
                        n += 1
                    }
                }
                inside[qy * qw + qx] = n > 0 ? s / n : 0
            }
        }
        let megapixels = Float(W) * Float(H) / 1_000_000
        PlaneMath.boxBlur(&inside, w: qw, h: qh, radius: max(Int((2 * (megapixels / 33).squareRoot()).rounded()), 1))
        insideNear = Buf(inside)
    }

    /// One pass of the guided filter over the band's uncertain pixels: within each small
    /// window the mask is refitted as a straight-line function of the photo's brightness.
    /// `gated`: the fit is used only as far as brightness explains the mask there (the luma
    /// snap). `only`: a pass over just the pixels this marks.
    private func guided(_ out: Buf<Float>, radius r: Int, gated: Bool, only: Buf<UInt8>?, spans: [(lo: Int, hi: Int)]) {
        let band = band0, bw = band.w, bh = band.h, qw = self.qw
        let tq = tri0.p, src = photo.p, rowBytes = photo.rowBytes
        let eps = settings.guidedEpsilon, lo = settings.snapLow, hi = settings.snapHigh
        let stripRows = 128, apron = 2 * r
        let source = Buf(out.array)
        let marks = only?.p
        parallel(spans.count) { s in
            let y0 = s * stripRows, y1 = min(y0 + stripRows, bh)
            var x0 = spans[s].lo, x1 = spans[s].hi
            if x1 < x0 { return }
            x0 = max(x0 - apron, 0); x1 = min(x1 + apron, bw - 1)
            let sw = x1 - x0 + 1
            let ey0 = max(y0 - apron, 0), ey1 = min(y1 + apron, bh)
            let eh = ey1 - ey0, n = sw * eh
            var g = [Float](repeating: 0, count: n), p = [Float](repeating: 0, count: n)
            var gg = [Float](repeating: 0, count: n), gp = [Float](repeating: 0, count: n), pp = [Float](repeating: 0, count: n)
            for yy in 0 ..< eh {
                for xx in 0 ..< sw {
                    let l = luma(rgbAt(src, rowBytes, band.x + x0 + xx, band.y + ey0 + yy))
                    let v = source.p[(ey0 + yy) * bw + x0 + xx]
                    let i = yy * sw + xx
                    g[i] = l; p[i] = v; gg[i] = l * l; gp[i] = l * v; pp[i] = v * v
                }
            }
            let lumaKept = g
            PlaneMath.boxBlur(&g, w: sw, h: eh, radius: r)
            PlaneMath.boxBlur(&p, w: sw, h: eh, radius: r)
            PlaneMath.boxBlur(&gg, w: sw, h: eh, radius: r)
            PlaneMath.boxBlur(&gp, w: sw, h: eh, radius: r)
            if gated { PlaneMath.boxBlur(&pp, w: sw, h: eh, radius: r) }
            for i in 0 ..< n {
                let cov = gp[i] - g[i] * p[i]
                let varG = max(gg[i] - g[i] * g[i], 0)
                let k = cov / (varG + eps)
                if gated {
                    let varP = max(pp[i] - p[i] * p[i], 0)
                    pp[i] = cov * cov / ((varG + eps) * (varP + 1e-5)) // how well brightness explains the mask here
                }
                gp[i] = p[i] - k * g[i] // the offset
                gg[i] = k // the slope
            }
            PlaneMath.boxBlur(&gg, w: sw, h: eh, radius: r)
            PlaneMath.boxBlur(&gp, w: sw, h: eh, radius: r)
            if gated { PlaneMath.boxBlur(&pp, w: sw, h: eh, radius: r) }
            for y in y0 ..< y1 {
                for xx in 0 ..< sw where tq[((band.y + y) >> 2) * qw + ((band.x + x0 + xx) >> 2)] == 1 {
                    let at = y * bw + x0 + xx
                    var share: Float = 1
                    if let marks = marks {
                        if marks[at] == 0 { continue }
                        share = Float(marks[at]) / 255
                    }
                    let i = (y - ey0) * sw + xx
                    let fitted = min(max(gg[i] * lumaKept[i] + gp[i], 0), 1)
                    let base = source.p[at]
                    if gated { share *= smoothstep(lo, hi, pp[i]) }
                    out.p[at] = base + (fitted - base) * share
                }
            }
        }
    }

    /// The colour snap (masking spec v4, 1.3). Right at the edge, and only where the
    /// subject's colour and the background's are clearly different, each pixel's own colour
    /// says how much of it is subject: where it sits on the line from the nearby background
    /// colour to the nearby subject colour, in linear light. That moves an edge that sits a
    /// pixel or three off the true boundary onto it. Low-contrast edges are left alone.
    private func colourSnap(_ out: Buf<Float>, spans: [(lo: Int, hi: Int)]) {
        let band = band0, bw = band.w, bh = band.h, qw = self.qw
        let marks = Buf<UInt8>(bw * bh, 0)
        ring = marks
        let megapixels = Float(W) * Float(H) / 1_000_000
        let r = max(Int((settings.colourRing * (megapixels / 33).squareRoot()).rounded()), 2)
        let tq = tri0.p, src = photo.p, rowBytes = photo.rowBytes
        let fp = fEdge.p, bp = bEdge.p, hair = hairQ.p, lin = Matte.toLinear.p
        let c0 = settings.colourLow, c1 = settings.colourHigh, most = settings.colourReach
        let floor0 = settings.colourFloor, floor1 = settings.colourFull, plainly = settings.colourPlain
        let skipBright = settings.snapSkipsBright, needNear = settings.snapNeedsBackground, nearB = backgroundNear.p
        let stripRows = 128, apron = r + 1
        let source = Buf(out.array)
        let lock = NSLock()
        var inRing = 0, passed = 0, changed = 0
        var moved = 0.0, fringeBefore = 0.0, fringeNow = 0.0, judged = 0.0, hairBorder = 0.0, hairBorderWeight = 0.0
        parallel(spans.count) { s in
            let y0 = s * stripRows, y1 = min(y0 + stripRows, bh)
            var x0 = spans[s].lo, x1 = spans[s].hi
            if x1 < x0 { return }
            x0 = max(x0 - apron, 0); x1 = min(x1 + apron, bw - 1)
            let sw = x1 - x0 + 1
            let ey0 = max(y0 - apron, 0), ey1 = min(y1 + apron, bh)
            let eh = ey1 - ey0
            // How much of each pixel's neighbourhood is inside the mask: a half means the edge runs through it.
            var inside = [Float](repeating: 0, count: sw * eh)
            for yy in 0 ..< eh {
                for xx in 0 ..< sw where source.p[(ey0 + yy) * bw + x0 + xx] >= 0.5 { inside[yy * sw + xx] = 1 }
            }
            PlaneMath.boxBlur(&inside, w: sw, h: eh, radius: r)
            var nRing = 0, nPassed = 0, nChanged = 0
            var sMoved = 0.0, sBefore = 0.0, sNow = 0.0, sJudged = 0.0, sEdgeOfHair = 0.0, sEdgeOfHairWeight = 0.0
            for y in y0 ..< y1 {
                let py = band.y + y
                for xx in 0 ..< sw where tq[(py >> 2) * qw + ((band.x + x0 + xx) >> 2)] == 1 {
                    let px = band.x + x0 + xx
                    let part = inside[(y - ey0) * sw + xx]
                    let inHair: Float = min(max(sample1(hair, px, py), 0), 1)
                    let weight = smoothstep(0, 0.35, min(part, 1 - part)) * (1 - inHair)
                    if weight <= 0.004 { continue }
                    let at = y * bw + x0 + xx
                    let I = rgbAt(src, rowBytes, px, py)
                    let F = sample3(fp, px, py), B = sample3(bp, px, py)
                    let d = F - B
                    let dd = dot3(d, d)
                    var confidence = Matte.apart(F, B, low: c0, high: c1, floor0: floor0, floor1: floor1, plain: plainly)
                    // Blown highlights have lost their colour; trust them less.
                    if max(I.max(), B.max()) >= 0.985 { confidence *= 0.5 }
                    // Beside a blown-out background its true colour and brightness are unknown,
                    // and in a narrow gap its colour is a guess from further away: no snap there.
                    if skipBright { confidence *= 1 - Matte.blownOut(B) }
                    if needNear > 0 { confidence *= smoothstep(needNear * 0.4, needNear, sample1(nearB, px, py)) }
                    // The mix itself is worked out in linear light, where light adds up.
                    @inline(__always) func linear(_ c: SIMD3<Float>) -> SIMD3<Float> {
                        SIMD3(lin[Int(min(max(c.x, 0), 1) * 255)], lin[Int(min(max(c.y, 0), 1) * 255)], lin[Int(min(max(c.z, 0), 1) * 255)])
                    }
                    // The tidy-up afterwards acts as far as the colours were trusted, and no further:
                    // on a grainy low-contrast edge it would only copy the grain into the mask.
                    marks.p[at] = UInt8(min(weight * confidence, 1) * 255)
                    let Il = linear(I), Fl = linear(F), Bl = linear(B)
                    let dl = Fl - Bl
                    let byColour = min(max(dot3(Il - Bl, dl) / (dot3(dl, dl) + 1e-7), 0), 1)
                    let base = source.p[at]
                    var value = base + (byColour - base) * confidence * weight
                    value = min(max(value, base - most), base + most)
                    out.p[at] = value
                    nRing += 1
                    if confidence > 0.5 {
                        nPassed += 1
                        // The fringe figure counts only pixels clear of the hair zone. On its
                        // border the snap is deliberately held back, and counting what it
                        // leaves there as fringe made a photo that is mostly hair (7473) read
                        // three times worse than the rest.
                        if inHair <= 0.02 {
                            sJudged += Double(weight)
                            sBefore += Double(abs(base - byColour) * weight)
                            sNow += Double(abs(value - byColour) * weight)
                        } else {
                            sEdgeOfHair += Double(abs(value - byColour) * weight)
                            sEdgeOfHairWeight += Double(weight)
                        }
                    }
                    if abs(value - base) > 0.02 { nChanged += 1 }
                    sMoved += Double(abs(value - base))
                }
            }
            lock.lock()
            inRing += nRing; passed += nPassed; changed += nChanged
            moved += sMoved; fringeBefore += sBefore; fringeNow += sNow; judged += sJudged
            hairBorder += sEdgeOfHair; hairBorderWeight += sEdgeOfHairWeight
            lock.unlock()
        }
        let posix = Locale(identifier: "en_US_POSIX")
        if judged > 0 { fringeAfter = Float(fringeNow / judged) }
        snapNote = " · colour snap ±\(r) px: \(inRing) px in the ring away from hair, \(Matte.percent(passed, inRing)) clear enough to judge, \(changed) moved, mean move "
            + String(format: "%.3f", locale: posix, inRing > 0 ? moved / Double(inRing) : 0)
            + String(format: " · colour fringe %.3f → %.3f", locale: posix, judged > 0 ? fringeBefore / judged : 0, judged > 0 ? fringeNow / judged : 0)
            + String(format: " (on the hair zone's border, not counted: %.3f)", locale: posix, hairBorderWeight > 0 ? hairBorder / hairBorderWeight : 0)
    }

    /// Whether each row of the band holds any uncertain pixel.
    func rowsWithUnknown() -> [Bool] {
        var qrow = [Bool](repeating: false, count: qh)
        for qy in 0 ..< qh {
            for qx in 0 ..< qw where triq.p[qy * qw + qx] == 1 {
                qrow[qy] = true
                break
            }
        }
        return (0 ..< band.h).map { qrow[(band.y + $0) >> 2] }
    }

    // MARK: Fast

    /// For each uncertain pixel: where its colour sits on the line between the nearby subject
    /// colour and the nearby background colour. Where those two colours are too alike to tell
    /// apart, the rough mask is kept instead.
    private func fast() {
        let band = self.band, bw = band.w, bh = band.h, qw = self.qw
        let a = Buf<Float>(bw * bh, 0), cf = Buf<UInt8>(bw * bh, 0), ct = Buf<UInt8>(bw * bh, 0)
        let c0 = settings.contrastLow, c1 = settings.contrastHigh
        let src = photo.p, rowBytes = photo.rowBytes, tq = triq.p
        let fp = fq.p, bp = bq.p, ca = coefA.p, cb = coefB.p, focus = focusQ?.p
        parallelRows(bh) { rows in
            for by in rows {
                let y = band.y + by
                for bx in 0 ..< bw {
                    let x = band.x + bx
                    let t = tq[(y >> 2) * qw + (x >> 2)]
                    if t != 1 {
                        a.p[by * bw + bx] = t == 2 ? 1 : 0
                        continue
                    }
                    let I = rgbAt(src, rowBytes, x, y)
                    let F = sample3(fp, x, y), B = sample3(bp, x, y)
                    let base = min(max(sample1(ca, x, y) * luma(I) + sample1(cb, x, y), 0), 1)
                    let d = F - B
                    let dd = dot3(d, d)
                    let al = min(max(dot3(I - B, d) / (dd + 1e-6), 0), 1)
                    // Contrast between the two colours, whatever the exposure.
                    let cn = dd / (dot3(F, F) + dot3(B, B) + 1e-6)
                    var c = smoothstep(c0, c1, cn)
                    // Blown highlights have lost their colour; trust them less.
                    if max(I.max(), B.max()) >= 0.985 { c *= 0.5 }
                    ct.p[by * bw + bx] = UInt8(c * 255)
                    // Out of focus, the true edge is a blur; stay with the rough mask there.
                    if let focus = focus { c *= sample1(focus, x, y) }
                    a.p[by * bw + bx] = base + (al - base) * c
                    cf.p[by * bw + bx] = UInt8(c * 255)
                }
            }
        }
        alpha = a
        conf = cf
        contrast = ct
        guidedCleanup(alpha)
        let half = Buf<UInt8>(bw * bh, 0)
        for i in 0 ..< bw * bh where a.p[i] >= 0.5 { half.p[i] = 1 }
        fastHalf = half
    }

    /// Smooths a mask along the photo's own edges and free of its grain: within each small
    /// window the mask is refitted as a straight-line function of brightness (the guided
    /// filter). Only uncertain pixels are changed.
    func guidedCleanup(_ a: Buf<Float>) {
        let band = self.band, bw = band.w, bh = band.h, qw = self.qw
        let r = settings.guidedRadius, eps = settings.guidedEpsilon
        let has = rowsWithUnknown()
        let stripRows = 128, apron = 2 * r
        let strips = (bh + stripRows - 1) / stripRows
        let source = Buf(a.array)
        let src = photo.p, rowBytes = photo.rowBytes, tq = triq.p
        parallel(strips) { s in
            let y0 = s * stripRows, y1 = min(y0 + stripRows, bh)
            if !has[y0 ..< y1].contains(true) { return }
            let ey0 = max(y0 - apron, 0), ey1 = min(y1 + apron, bh)
            let eh = ey1 - ey0, n = bw * eh
            var g = [Float](repeating: 0, count: n), p = [Float](repeating: 0, count: n)
            var gg = [Float](repeating: 0, count: n), gp = [Float](repeating: 0, count: n)
            for yy in 0 ..< eh {
                for x in 0 ..< bw {
                    let l = luma(rgbAt(src, rowBytes, band.x + x, band.y + ey0 + yy))
                    let v = source.p[(ey0 + yy) * bw + x]
                    let i = yy * bw + x
                    g[i] = l; p[i] = v; gg[i] = l * l; gp[i] = l * v
                }
            }
            let lumaKept = g
            PlaneMath.boxBlur(&g, w: bw, h: eh, radius: r)
            PlaneMath.boxBlur(&p, w: bw, h: eh, radius: r)
            PlaneMath.boxBlur(&gg, w: bw, h: eh, radius: r)
            PlaneMath.boxBlur(&gp, w: bw, h: eh, radius: r)
            for i in 0 ..< n {
                let k = (gp[i] - g[i] * p[i]) / (gg[i] - g[i] * g[i] + eps)
                gp[i] = p[i] - k * g[i] // the offset
                gg[i] = k // the slope
            }
            PlaneMath.boxBlur(&gg, w: bw, h: eh, radius: r)
            PlaneMath.boxBlur(&gp, w: bw, h: eh, radius: r)
            for y in y0 ..< y1 {
                for x in 0 ..< bw where tq[((band.y + y) >> 2) * qw + ((band.x + x) >> 2)] == 1 {
                    let i = (y - ey0) * bw + x
                    a.p[y * bw + x] = min(max(gg[i] * lumaKept[i] + gp[i], 0), 1)
                }
            }
        }
    }

    // MARK: High

    /// Gathers candidate subject and background colours along rays from each uncertain pixel
    /// and keeps the pair that best explains the pixel. Rays in different directions reach
    /// different things, so a backdrop and a decoration in front of it are both found, and
    /// each strand is matched with the one actually behind it.
    private func high() {
        let band = self.band, bw = band.w, bh = band.h, qw = self.qw, qh = self.qh, W = self.W, H = self.H
        var isF = [Bool](repeating: false, count: qw * qh), isB = [Bool](repeating: false, count: qw * qh)
        for i in 0 ..< qw * qh {
            isF[i] = triq.p[i] == 2
            isB[i] = triq.p[i] == 0
        }
        let distF = Buf(PlaneMath.distance(to: isF, w: qw, h: qh)), distB = Buf(PlaneMath.distance(to: isB, w: qw, h: qh))
        let f1 = Buf<UInt32>(bw * bh, 0), b1 = Buf<UInt32>(bw * bh, 0)
        let K = min(max(settings.rays, 1), 8), raySteps = settings.raySteps
        let maxLen = 2.5 * rOut
        let wd = settings.distanceWeight
        // Sixteen rotations of the ray pattern, so neighbouring pixels probe different directions.
        let dirs = Buf<SIMD2<Float>>((0 ..< 16 * K).map { i in
            let rot = Float(i / K) / 16 * (2 * Float.pi / Float(K))
            let th = rot + Float(i % K) * 2 * Float.pi / Float(K)
            return SIMD2(cos(th), sin(th))
        })
        let src = photo.p, rowBytes = photo.rowBytes, tq = triq.p, fp = fq.p, bp = bq.p

        /// Walks from `origin` along `dir` to the first certain pixel of one kind. Each step is
        /// the distance to the nearest such pixel, which can never jump over one; distances
        /// are in quarter-size pixels, so a block's worth is held back.
        @inline(__always) func trace(_ origin: SIMD2<Float>, _ dir: SIMD2<Float>, _ kind: UInt8, _ dist: UnsafeMutablePointer<Float>) -> (SIMD3<Float>, Float)? {
            var t: Float = 0
            var steps = 0
            while steps < raySteps && t < maxLen {
                let q = origin + dir * t
                if q.x < 0 || q.y < 0 { return nil }
                let qx = Int(q.x), qy = Int(q.y)
                if qx >= W || qy >= H { return nil }
                let cell = (qy >> 2) * qw + (qx >> 2)
                if tq[cell] == kind { return (rgbAt(src, rowBytes, qx, qy), t) }
                t += max(4 * (dist[cell] - 1.5), 1)
                steps += 1
            }
            return nil
        }

        parallelRows(bh) { rows in
            var Fc = [SIMD3<Float>](repeating: SIMD3(repeating: 0), count: 8), Bc = Fc
            var dF = [Float](repeating: 0, count: 8), dB = dF
            for by in rows {
                let y = band.y + by
                for bx in 0 ..< bw {
                    let x = band.x + bx
                    if tq[(y >> 2) * qw + (x >> 2)] != 1 { continue }
                    let Ip = rgbAt(src, rowBytes, x, y)
                    let origin = SIMD2(Float(x) + 0.5, Float(y) + 0.5)
                    var nF = 0, nB = 0
                    let first = ((x & 3) + 4 * (y & 3)) * K
                    for k in 0 ..< K {
                        let dir = dirs.p[first + k]
                        if let (c, t) = trace(origin, dir, 2, distF.p) { Fc[nF] = c; dF[nF] = t; nF += 1 }
                        if let (c, t) = trace(origin, dir, 0, distB.p) { Bc[nB] = c; dB[nB] = t; nB += 1 }
                    }
                    // No certain pixel in reach: fall back on the smooth local colours.
                    if nF == 0 { Fc[0] = sample3(fp, x, y); dF[0] = maxLen; nF = 1 }
                    if nB == 0 { Bc[0] = sample3(bp, x, y); dB[0] = maxLen; nB = 1 }
                    var best = Float.infinity
                    var bestF = Fc[0], bestB = Bc[0]
                    for i in 0 ..< nF {
                        for j in 0 ..< nB {
                            let c = Matte.pairCost(Ip, Fc[i], Bc[j]).cost * (1 + wd * (dF[i] + dB[j]) / maxLen)
                            if c < best { best = c; bestF = Fc[i]; bestB = Bc[j] }
                        }
                    }
                    f1.p[by * bw + bx] = Matte.pack(bestF)
                    b1.p[by * bw + bx] = Matte.pack(bestB)
                }
            }
        }

        // Each pixel then tries its neighbours' pairs against its own colour and averages the
        // best three, which removes the speckle of pixel-by-pixel choices.
        let alphaHigh = Buf(alpha.array)
        let confHigh = Buf<UInt8>(bw * bh, 0)
        let f2 = Buf<UInt32>(bw * bh, 0), b2 = Buf<UInt32>(bw * bh, 0)
        let c0 = settings.contrastLow, c1 = settings.contrastHigh, falloff = settings.costFalloff
        let focus = focusQ?.p
        parallelRows(bh) { rows in
            for by in rows {
                let y = band.y + by
                for bx in 0 ..< bw {
                    let x = band.x + bx
                    if tq[(y >> 2) * qw + (x >> 2)] != 1 { continue }
                    let Ip = rgbAt(src, rowBytes, x, y)
                    var c0b = Float.infinity, c1b = Float.infinity, c2b = Float.infinity
                    var j0 = -1, j1 = -1, j2 = -1
                    for ny in max(by - 2, 0) ... min(by + 2, bh - 1) {
                        for nx in max(bx - 2, 0) ... min(bx + 2, bw - 1) {
                            if tq[((band.y + ny) >> 2) * qw + ((band.x + nx) >> 2)] != 1 { continue }
                            let j = ny * bw + nx
                            let c = Matte.pairCost(Ip, Matte.unpack(f1.p[j]), Matte.unpack(b1.p[j])).cost
                            if c < c0b {
                                c2b = c1b; j2 = j1; c1b = c0b; j1 = j0; c0b = c; j0 = j
                            } else if c < c1b {
                                c2b = c1b; j2 = j1; c1b = c; j1 = j
                            } else if c < c2b {
                                c2b = c; j2 = j
                            }
                        }
                    }
                    var F = SIMD3<Float>(repeating: 0), B = F
                    var n: Float = 0
                    if j0 >= 0 { F += Matte.unpack(f1.p[j0]); B += Matte.unpack(b1.p[j0]); n += 1 }
                    if j1 >= 0 { F += Matte.unpack(f1.p[j1]); B += Matte.unpack(b1.p[j1]); n += 1 }
                    if j2 >= 0 { F += Matte.unpack(f1.p[j2]); B += Matte.unpack(b1.p[j2]); n += 1 }
                    F /= max(n, 1); B /= max(n, 1)
                    let fit = Matte.pairCost(Ip, F, B)
                    let d = F - B
                    let cn = dot3(d, d) / (dot3(F, F) + dot3(B, B) + 1e-6)
                    let i = by * bw + bx
                    alphaHigh.p[i] = fit.alpha
                    var trust = exp(-falloff * fit.cost) * smoothstep(c0, c1, cn)
                    if let focus = focus { trust *= sample1(focus, x, y) }
                    confHigh.p[i] = UInt8(min(max(trust, 0), 1) * 255)
                    f2.p[i] = Matte.pack(F)
                    b2.p[i] = Matte.pack(B)
                }
            }
        }
        fPair = f2
        bPair = b2
        guidedCleanup(alphaHigh)
        // Take the new answer as far as it can be trusted; elsewhere keep the Fast one.
        let a = alpha.p, cf = conf.p
        var buckets = [Int](repeating: 0, count: 5), counted = 0
        for by in 0 ..< bh {
            for bx in 0 ..< bw where tq[((band.y + by) >> 2) * qw + ((band.x + bx) >> 2)] == 1 {
                let i = by * bw + bx
                buckets[min(Int(confHigh.p[i]) * 5 / 256, 4)] += 1
                counted += 1
                if confHigh.p[i] > 0 {
                    a[i] += (alphaHigh.p[i] - a[i]) * (Float(confHigh.p[i]) / 255)
                    cf[i] = max(cf[i], confHigh.p[i])
                }
            }
        }
        let names = ["0–.2", ".2–.4", ".4–.6", ".6–.8", ".8–1"]
        log.append("high trust " + zip(names, buckets).map { "\($0):\(Matte.percent($1, counted))" }.joined(separator: " "))
    }

    static func percent(_ part: Int, _ whole: Int) -> String { "\(whole > 0 ? Int((100 * Double(part) / Double(whole)).rounded()) : 0)%" }

    /// How well a subject colour and a background colour explain a pixel: the mix of the two
    /// that comes closest, and how far off even that is, relative to how different they are.
    @inline(__always) static func pairCost(_ I: SIMD3<Float>, _ F: SIMD3<Float>, _ B: SIMD3<Float>) -> (alpha: Float, cost: Float) {
        let d = F - B
        let dd = dot3(d, d)
        let a = min(max(dot3(I - B, d) / (dd + 1e-6), 0), 1)
        let r = I - (F * a + B * (1 - a))
        return (a, dot3(r, r) / (dd + 1e-6))
    }

    // MARK: Finish

    /// 8-bit sRGB values to linear light, by the exact sRGB curve (masking spec v6, 1.2).
    static let toLinear = Buf<Float>(sRGBToLinearTable)

    /// What the checks on a finished mask count, over the uncertain band.
    struct BandStats {
        var n = 0, zero = 0, low = 0, mid = 0, high = 0, one = 0
        var background = 0, backgroundMid = 0
        var heldUp = 0, heldDown = 0, blurred = 0
        var both = 0, either = 0
        var cleaned = 0, tails = 0
        var shift = 0.0

        mutating func add(_ o: BandStats) {
            cleaned += o.cleaned; shift += o.shift; tails += o.tails
            n += o.n; zero += o.zero; low += o.low; mid += o.mid; high += o.high; one += o.one
            background += o.background; backgroundMid += o.backgroundMid
            heldUp += o.heldUp; heldDown += o.heldDown; blurred += o.blurred
            both += o.both; either += o.either
        }
    }

    /// Writes the mask out for the whole photo, with the per-colour shares: the snapped edge
    /// everywhere, and in the hair zone the colour matting's answer, as far as each pixel is in it.
    private func finish(matted: Bool) -> MatteOutput {
        let W = self.W, H = self.H, qw = self.qw
        let b0 = band0, bw0 = b0.w, bm = bandM, bwm = bm.w
        let alpha8 = Buf<UInt8>(W * H, 0)
        let shares = Buf<UInt8>(W * H * 4, 255)
        let haveOff = !b0.isEmpty && offAlpha.count == b0.w * b0.h
        let haveMatte = matted && !bm.isEmpty && alpha.count == bm.w * bm.h
        let src = photo.p, rowBytes = photo.rowBytes, t0 = tri0.p, tm = triM.p, fp = fEdge.p, bp = bEdge.p
        let near = insideNear.count == qw * qh ? insideNear.p : nil
        let hairOwn = hairFaces.p
        let off = offAlpha.p, a = alpha.p, f = fPair?.p, b = bPair?.p, lin = Matte.toLinear.p
        let m0 = m0qBuf.p, ct = contrast.p, focus = focusQ?.p, fastHalf = self.fastHalf.p, hair = hairQ.p
        let sureAbove = settings.guardContrast * 255
        let decontaminate = settings.decontaminate, relaxed = settings.relaxGuards
        let tails = settings.innerTail, tailLeast = settings.tailCoverage, plainly = settings.colourPlain
        let c0 = settings.colourLow, c1 = settings.colourHigh, floor0 = settings.colourFloor, floor1 = settings.colourFull
        let falloff = settings.costFalloff
        let lock = NSLock()
        var stats = BandStats()
        parallelRows(H) { rows in
            var local = BandStats()
            for y in rows {
                for x in 0 ..< W {
                    let cell = (y >> 2) * qw + (x >> 2)
                    let t = t0[cell]
                    var a8: UInt8 = t == 2 ? 255 : 0
                    var s = SIMD3<Float>(repeating: t == 2 ? 1 : 0)
                    if t == 1 && haveOff && b0.contains(x, y) {
                        // Written so that a value that isn't a number at all comes out as 0.
                        let snapped = off[(y - b0.y) * bw0 + (x - b0.x)]
                        var al: Float = snapped >= 0 ? min(snapped, 1) : 0
                        s = SIMD3(repeating: al)
                        var pair = -1
                        var colours = decontaminate
                        if haveMatte && tm[cell] == 1 && bm.contains(x, y) {
                            let i = (y - bm.y) * bwm + (x - bm.x)
                            var m: Float = a[i] >= 0 ? min(a[i], 1) : 0
                            // The guards. Where the rough mask was sure, the answer may only
                            // stray from it where the colours either side are distinct enough
                            // to go by, and then only so far; and out of focus, the background
                            // may not turn into subject at all.
                            let rough = sample1(m0, x, y)
                            let sure = Float(ct[i]) > sureAbove
                            let reach = 0.3 + 0.7 * Float(ct[i]) / 255
                            let sharp = focus.map { sample1($0, x, y) } ?? 1
                            if relaxed {
                                // No guards under the hair brush.
                            } else if rough >= 0.9 {
                                let least = sure ? rough - reach : rough
                                if m < least { m = least; local.heldUp += 1 }
                            } else if rough <= 0.1 {
                                let most = sure ? rough + reach * sharp : rough
                                if m > most { m = most; local.heldDown += 1 }
                            }
                            local.n += 1
                            if sharp < 0.5 { local.blurred += 1 }
                            if m <= 0.002 { local.zero += 1 } else if m < 0.2 { local.low += 1 } else if m <= 0.8 { local.mid += 1 }
                            else if m < 0.998 { local.high += 1 } else { local.one += 1 }
                            if rough <= 0.1 {
                                local.background += 1
                                if m >= 0.2 && m <= 0.8 { local.backgroundMid += 1 }
                            }
                            let now = m >= 0.5, before = fastHalf[i] == 1
                            if now && before { local.both += 1 }
                            if now || before { local.either += 1 }
                            let weight = min(max(sample1(hair, x, y), 0), 1)
                            al += (m - al) * weight
                            s = SIMD3(repeating: al)
                            if weight > 0.25 {
                                pair = i
                                colours = true
                            }
                        }
                        // The inner tail (final masking round, priority 1). A pixel just inside
                        // the edge is all subject as far as the mask goes, yet a lens's blur
                        // still lays a few per cent of the background's light over it; beside a
                        // bright background and on a dark subject that is a fifth of the pixel's
                        // brightness, and it stays behind as a pale rim when the background is
                        // darkened. Such pixels get colour shares too, as far as they are
                        // within reach of the edge and their colour says "nearly all subject".
                        var tail: Float = 0
                        if colours && al >= 0.9 && tails && pair < 0, let near = near {
                            let weight = min(max(sample1(hairOwn, x, y), 0), 1)
                            let sharp = focus.map { sample1($0, x, y) } ?? 1
                            tail = smoothstep(0, 0.3, 1 - sample1(near, x, y)) * (1 - weight) * sharp
                        }
                        if colours && al > (tails ? 0.004 : 0.05) && (al < 0.95 || tail > 0) {
                            let I = rgbAt(src, rowBytes, x, y)
                            let F = pair >= 0 && f != nil ? Matte.unpack(f![pair]) : sample3(fp, x, y)
                            let B = pair >= 0 && b != nil ? Matte.unpack(b![pair]) : sample3(bp, x, y)
                            let fit = Matte.shares(pixel: I, subject: F, background: B, alpha: al, lin: lin, low: c0, high: c1,
                                                   floor0: floor0, floor1: floor1, falloff: falloff, plain: plainly)
                            // Nothing at all at 5% and 95% coverage, coming in over the next few per cent.
                            var part: Float = min(min(al - 0.05, 0.95 - al) / 0.05, 1)
                            if tail > 0 { part = max(part, tail * smoothstep(tailLeast, tailLeast + 0.15, fit.coverage)) }
                            if part > 0 || al < 0.1 {
                                let plain = SIMD3<Float>(repeating: al)
                                // Under 10% coverage the shares may only take light away, in
                                // full; they add any only as coverage rises from 5% to 10%. A
                                // pixel of bright background that is 4% subject would otherwise
                                // keep 4% of the background's light: a faint line outside the edge.
                                // (All three together, by the same factor: never one channel on its own.)
                                let lowered: SIMD3<Float> = tails && al < 0.1 ? fit.shares * min(1, al / max(fit.shares.max(), 1e-6)) : plain
                                let moved: SIMD3<Float> = (lowered - plain) + (fit.shares - lowered) * max(part, 0)
                                s = plain + moved
                                local.cleaned += 1
                                if al >= 0.95 { local.tails += 1 }
                                let shift: Float = (abs(moved.x) + abs(moved.y) + abs(moved.z)) / 3
                                local.shift += Double(shift)
                            }
                        }
                        a8 = UInt8((al * 255).rounded())
                    }
                    alpha8.p[y * W + x] = a8
                    let o = (y * W + x) * 4
                    shares.p[o] = UInt8((s.x * 255).rounded())
                    shares.p[o + 1] = UInt8((s.y * 255).rounded())
                    shares.p[o + 2] = UInt8((s.z * 255).rounded())
                }
            }
            lock.lock()
            stats.add(local)
            lock.unlock()
        }
        if stats.n > 0 {
            let p = { (v: Int) in Matte.percent(v, stats.n) }
            let glow = stats.background > 0 ? 100 * Double(stats.backgroundMid) / Double(stats.background) : 0
            let flagged = glow > 5
            if flagged { warnings.append("GLOW?") }
            log.append("hair band α 0:\(p(stats.zero)) · low:\(p(stats.low)) · mid:\(p(stats.mid)) · high:\(p(stats.high)) · 1:\(p(stats.one))"
                + " · mid-in-confident-bg \(String(format: "%.1f", locale: Locale(identifier: "en_US_POSIX"), glow))%\(flagged ? " GLOW?" : "")")
            let agreement = stats.either > 0 ? Double(stats.both) / Double(stats.either) : 1
            log.append("guards: subject \(stats.heldUp) px · background \(stats.heldDown) px · out-of-focus \(p(stats.blurred)) of band"
                + " · fast↔final IoU \(String(format: "%.3f", locale: Locale(identifier: "en_US_POSIX"), agreement))")
        }
        if stats.cleaned > 0 {
            log.append("decontaminated: \(stats.cleaned) edge pixels given their own colour shares (\(stats.tails) of them just inside the edge), mean shift "
                + String(format: "%.3f", locale: Locale(identifier: "en_US_POSIX"), stats.shift / Double(stats.cleaned)))
        }
        if settings.colourGuard && haveOff {
            let corrected = guardColour(alpha8, shares)
            guardCorrections = corrected.fixed
            log.append("colour guard: \(corrected.fixed) of \(corrected.checked) edge pixels had gained colour and were put back\(corrected.fixed > 0 ? guardNote : "")\(lightnessNote)")
        }
        var bounded = (moved: 0, deltaE: Float(0))
        // Part of decontamination: with that off, the shares are the mask, as before.
        if settings.lightBound && settings.decontaminate && haveOff {
            bounded = holdPortion(alpha8, shares)
            log.append("light bound: \(bounded.moved) pixels moved towards the subject's colour, mean ΔE "
                + String(format: "%.4f", locale: Locale(identifier: "en_US_POSIX"), bounded.deltaE) + " (Oklab, the subject's part of the pixel)")
        }
        let n = qw * qh
        var tri8 = [UInt8](repeating: 0, count: n), hair8 = [UInt8](repeating: 0, count: n), zones = [UInt8](repeating: 0, count: n)
        for i in 0 ..< n {
            tri8[i] = t0[i] == 2 ? 255 : (t0[i] == 1 ? 128 : 0)
            hair8[i] = UInt8(min(max(hair[i], 0), 1) * 255)
            if t0[i] == 1 { zones[i] = matted && tm[i] == 1 ? 2 : 1 }
        }
        var out = MatteOutput(w: W, h: H, alpha: alpha8.array, shares: shares.array, trimap: tri8,
                              trimapW: qw, trimapH: qh, band: b0, unknownPixels: unknownCount, log: [], warnings: warnings)
        out.hair = hair8
        out.zones = zones
        out.edgeQuality = edgeQuality(alpha8)
        out.guardCorrections = guardCorrections
        out.lightnessCorrections = lightnessCorrections
        out.edgeOffset = edgeOffset(of: alpha8)
        out.edgeOffsetBefore = offsetBefore
        out.lightBounded = bounded.moved
        out.lightBoundDeltaE = bounded.deltaE
        out.hairZoneFrom = hairZoneFrom
        log.append("edge placement: " + out.edgeOffset.summary)
        log.append("hair zone from \(hairZoneFrom)")
        return out
    }

    var guardCorrections = 0
    var lightnessCorrections = 0
    var lightnessNote = ""

    /// How blown out a background colour is, 0 to 1: a channel at or all but at clipping, or
    /// very bright overall (masking spec v5, 1.2). (Until the final round this began a tenth
    /// short of clipping. A pale green wall at 0.89 is not clipped; its colour is known, and
    /// treating it as lost left its green in the edge pixels it was mixed into.)
    @inline(__always) static func blownOut(_ b: SIMD3<Float>) -> Float {
        max(smoothstep(0.93, 0.99, b.max()), smoothstep(0.90, 0.97, luma(b)))
    }

    /// How far two colours (display values) are far enough apart to go by, 0 to 1: enough in
    /// proportion to their brightness or plainly enough outright, and never when they barely
    /// differ outright.
    @inline(__always) static func apart(_ F: SIMD3<Float>, _ B: SIMD3<Float>, low: Float, high: Float, floor0: Float, floor1: Float, plain: Float) -> Float {
        let d: SIMD3<Float> = F - B
        let dd: Float = dot3(d, d)
        let outright: Float = dd.squareRoot()
        let relative: Float = smoothstep(low, high, dd / (dot3(F, F) + dot3(B, B) + 1e-6))
        return max(relative, smoothstep(floor1, max(plain, floor1 + 0.01), outright)) * smoothstep(floor0, floor1, outright)
    }

    /// How much of each channel of a pixel's light is the subject's (masking spec v5, 1.2).
    /// `pixel`, `subject` and `background` are display values; the arithmetic is in linear light.
    ///
    /// The colours are believed only where they explain the pixel: where the nearby subject
    /// and background colours are clearly different, and the pixel really is a mix of the
    /// two (it lies on the line between them). There, the pixel's own colour says how much
    /// of it is subject, and the subject's share of each channel is that much of the
    /// subject's colour over the pixel's. Everywhere else (a blonde strand over a navy suit,
    /// where neither colour is the strand's) the share is simply the mask's coverage.
    /// Nothing is clipped channel by channel: if a share would pass 1 all three are scaled
    /// together, so hue is kept. Beside a blown-out background, whose real colour is lost,
    /// one share serves all three channels: brightness only.
    @inline(__always)
    static func shares(pixel I: SIMD3<Float>, subject F: SIMD3<Float>, background B: SIMD3<Float>, alpha al: Float,
                       lin: UnsafeMutablePointer<Float>, low: Float, high: Float, floor0: Float, floor1: Float, falloff: Float, plain plainly: Float = 0.45)
        -> (shares: SIMD3<Float>, coverage: Float) {
        let plain = SIMD3<Float>(repeating: al)
        // Are the two colours far enough apart to go by? The same test the colour snap uses.
        var trust: Float = apart(F, B, low: low, high: high, floor0: floor0, floor1: floor1, plain: plainly)
        if trust <= 0.004 { return (plain, al) }
        @inline(__always) func linear(_ c: SIMD3<Float>) -> SIMD3<Float> {
            SIMD3(lin[Int(min(max(c.x, 0), 1) * 255)], lin[Int(min(max(c.y, 0), 1) * 255)], lin[Int(min(max(c.z, 0), 1) * 255)])
        }
        let Il: SIMD3<Float> = linear(I), fl: SIMD3<Float> = linear(F), bl: SIMD3<Float> = linear(B)
        let d: SIMD3<Float> = fl - bl
        let dd: Float = dot3(d, d) + 1e-7
        // Where the pixel sits between the two, and how far off the line between them it is.
        let byColour: Float = min(max(dot3(Il - bl, d) / dd, 0), 1)
        let rest: SIMD3<Float> = Il - (fl * byColour + bl * (1 - byColour))
        // (Gently: a lens's colour fringe puts an edge pixel a little off that line, and those
        // are the very pixels this is for.)
        trust *= exp(-0.3 * falloff * dot3(rest, rest) / dd)
        if trust <= 0.004 { return (plain, byColour) }
        // The pixel's light, split in two: the subject's and the background's. On the line
        // between the two colours that is simply so much of each. What the pixel has beyond
        // that (no real pixel sits exactly on the line: skin has texture, a wall has grain)
        // goes to whichever supplies most of its light, in proportion. Given to the other,
        // a small difference in a bright subject's colour became the whole of a dim
        // background's light, strongly coloured: it showed as soon as the subject was darkened.
        let fromSubject: Float = luma(fl) * byColour, fromBackground: Float = luma(bl) * (1 - byColour)
        let toSubject: Float = fromSubject / max(fromSubject + fromBackground, 1e-6)
        let own: SIMD3<Float> = fl * byColour + rest * toSubject
        let together: Float = min(max(luma(own) / max(luma(Il), 1e-4), 0), 1)
        let each = Matte.unclipped(own: own, pixel: Il, together: together)
        let bright: Float = blownOut(B)
        let single = SIMD3<Float>(repeating: together)
        let model: SIMD3<Float> = each + (single - each) * bright
        return (plain + (model - plain) * trust, byColour)
    }

    /// The subject's share of each channel, `own` over the pixel's light, with nothing cut
    /// off channel by channel (masking spec v6, 1.3): a channel over 1 scales all three
    /// down together, and one below 0 gives the single share `together` to all three. A channel
    /// with next to no light of its own (a pure colour) says nothing about the split and
    /// takes `together`; divided by almost nothing it would scale the other two to nothing.
    @inline(__always)
    static func unclipped(own: SIMD3<Float>, pixel Il: SIMD3<Float>, together: Float) -> SIMD3<Float> {
        var each = SIMD3<Float>(repeating: together)
        for c in 0 ..< 3 where Il[c] > 0.002 { each[c] = own[c] / Il[c] }
        // A channel the fit puts below 0 means the fit doesn't explain the pixel (a lens's
        // fringe, as a rule): the subject's part then takes the pixel's own colour, one share
        // for all three. (Moved only until that channel reached 0, as alpha 17 did, it left a
        // red share of exactly 0 beside green and blue ones: a teal rim on a black sleeve.)
        if each.min() < 0 { return SIMD3<Float>(repeating: max(together, 0)) }
        let highest = each.max()
        if highest > 1 { each /= highest }
        return pointwiseMax(each, SIMD3<Float>(repeating: 0))
    }

    /// The quarter-size cells within `radius` photo pixels of a body pose's limbs and joints,
    /// softened by a cell so the hair zone fades out round them.
    static func bodyCells(_ body: BodyPose, radius: Float, qw: Int, qh: Int) -> [Float] {
        let small = BodyPose(joints: body.joints.mapValues { BodyPose.Joint(x: $0.x / 4, y: $0.y / 4, confidence: $0.confidence) })
        let hard = small.confirmed(radius: max(radius / 4, 1), w: qw, h: qh)
        var soft = hard.map { $0 ? Float(1) : 0 }
        soft = PlaneMath.extremum(Gray(w: qw, h: qh, v: soft), radius: 1, smallest: false).v
        PlaneMath.boxBlur(&soft, w: qw, h: qh, radius: 1)
        return soft
    }

    /// The subject light bound (masking spec v6, 1.1, as reshaped after alpha 17). Runs
    /// last, after the colour guard, so nothing undoes it. Away from the hair zone, and only
    /// where the subject's colour beside the edge can be believed (re-centring measured the
    /// edge there, or certain subject is within about ten pixels), the subject's part of
    /// each edge pixel's light, P = I × shares (linear), is held to the subject's colour F:
    /// no lighter than `portionLightness` × the lightness of coverage × F (+ a little), and
    /// in Oklab its (a, b) within `portionHue` of F's, both scaled by P's lightness over F's.
    /// The new shares are P' / I, all three scaled down together if one would pass 1; what
    /// P loses goes to the background. A teal pixel at the edge of a black sleeve, as dark
    /// as the sleeve, then keeps the sleeve's colour, and its teal goes when the background
    /// is darkened. Just inside the edge (coverage all but full) it acts as far as the inner
    /// tail reaches, fading out further in.
    func holdPortion(_ alpha8: Buf<UInt8>, _ shares: Buf<UInt8>) -> (moved: Int, deltaE: Float) {
        let b = band0, W = self.W, qw = self.qw
        if b.isEmpty { return (0, 0) }
        let src = photo.p, rowBytes = photo.rowBytes, lin = Matte.toLinear.p, t0 = tri0.p
        let fp = fEdge.p, bp = bEdge.p, excluded = lightExcluded.p, near = subjectNear.p
        let measured = knownQ?.p, inside = insideNear.count == qw * qh ? insideNear.p : nil
        let lighter = settings.portionLightness, plus = settings.portionLightnessPlus, hue = settings.portionHue
        let lock = NSLock()
        var moved = 0
        var removed = 0.0
        @inline(__always) func linear(_ c: SIMD3<Float>) -> SIMD3<Float> {
            SIMD3(lin[Int(min(max(c.x, 0), 1) * 255)], lin[Int(min(max(c.y, 0), 1) * 255)], lin[Int(min(max(c.z, 0), 1) * 255)])
        }
        parallelRows(b.h) { rows in
            var n = 0
            var sum = 0.0
            for by in rows {
                let y = b.y + by
                for x in b.x ..< b.maxX where t0[(y >> 2) * qw + (x >> 2)] == 1 {
                    let a8 = alpha8.p[y * W + x]
                    if a8 <= 1 { continue }
                    let al = Float(a8) / 255
                    // Part-covered pixels fully; all but fully covered ones as far as the inner tail reaches.
                    var reach: Float = 1
                    if a8 >= 254 {
                        guard let inside = inside else { continue }
                        reach = smoothstep(0, 0.3, 1 - sample1(inside, x, y))
                        if reach <= 0 { continue }
                    }
                    let keepOut = min(max(sample1(excluded, x, y), 0), 1)
                    if keepOut >= 0.99 { continue }
                    let believed = (measured.map { sample1($0, x, y) } ?? 0) > 0.05 || sample1(near, x, y) > 0.5
                    if !believed { continue }
                    let o = (y * W + x) * 4
                    let s = SIMD3<Float>(Float(shares.p[o]), Float(shares.p[o + 1]), Float(shares.p[o + 2])) / 255
                    if s.max() <= 0.004 { continue }
                    let i = y * rowBytes + x * 4
                    let I = SIMD3<Float>(lin[Int(src[i])], lin[Int(src[i + 1])], lin[Int(src[i + 2])])
                    let f3 = sample3(fp, x, y), b3 = sample3(bp, x, y)
                    let F = linear(f3), B = linear(b3)
                    let FLab = Oklab.from(linear: F)
                    if FLab.x < 0.01 { continue }
                    let across = F - B
                    let byColour = min(max(dot3(I - B, across) / (dot3(across, across) + 1e-7), 0), 1)
                    let told = Matte.apart(f3, b3, low: settings.colourLow, high: settings.colourHigh, floor0: settings.colourFloor,
                                           floor1: settings.colourFull, plain: settings.colourPlain)
                    let cover = al + max(byColour - al, 0) * told
                    let P = I * s
                    let before = Oklab.from(linear: P)
                    var lab = before
                    // Lightness. Scaling linear light by m scales the whole Oklab vector by
                    // m^(1/3), so scaling the vector keeps the hue.
                    let most = Oklab.from(linear: F * max(cover, 0)).x * lighter + plus
                    if lab.x > most && lab.x > 0 { lab *= most / lab.x }
                    // Hue and chroma: within `hue` of the subject's own, at this lightness.
                    let r = min(lab.x / FLab.x, 1.5)
                    let centre = SIMD2<Float>(FLab.y, FLab.z) * r, radius = hue * r
                    let ab = SIMD2<Float>(lab.y, lab.z), d = ab - centre
                    let distance = (d * d).sum().squareRoot()
                    if distance > radius { lab = SIMD3(lab.x, centre.x + d.x * radius / distance, centre.y + d.y * radius / distance) }
                    if Oklab.distance(lab, before) < 1e-4 { continue }
                    var P2 = Oklab.toLinear(lab)
                    if P2.min() < 0 {
                        // Out of gamut: back towards the subject's colour at this lightness (F
                        // scaled, which is in gamut) until it is in.
                        let safe = Oklab.from(linear: F * (r * r * r))
                        var lo: Float = 0, hi: Float = 1 // how far from `safe` towards `lab`
                        for _ in 0 ..< 10 {
                            let mid = (lo + hi) / 2
                            if Oklab.toLinear(safe + (lab - safe) * mid).min() >= 0 { lo = mid } else { hi = mid }
                        }
                        P2 = pointwiseMax(Oklab.toLinear(safe + (lab - safe) * lo), SIMD3<Float>(repeating: 0))
                    }
                    var s2 = s
                    for c in 0 ..< 3 where I[c] > 1e-4 { s2[c] = P2[c] / I[c] }
                    let highest = s2.max()
                    if highest > 1 { s2 /= highest }
                    let k = (1 - keepOut) * reach
                    let now = s + (s2 - s) * k
                    let r8 = (now * 255).rounded(.toNearestOrAwayFromZero)
                    let nr = UInt8(min(max(r8.x, 0), 255)), ng = UInt8(min(max(r8.y, 0), 255)), nb = UInt8(min(max(r8.z, 0), 255))
                    if nr == shares.p[o] && ng == shares.p[o + 1] && nb == shares.p[o + 2] { continue }
                    shares.p[o] = nr; shares.p[o + 1] = ng; shares.p[o + 2] = nb
                    n += 1
                    sum += Double(Oklab.distance(before, Oklab.from(linear: I * now)))
                }
            }
            lock.lock()
            moved += n
            removed += sum
            lock.unlock()
        }
        return (moved, moved > 0 ? Float(removed / Double(moved)) : 0)
    }

    /// The colour guard (masking spec v5, 1.1). Every edge pixel whose channels have
    /// different shares is rendered with the background three stops darker, and with the
    /// subject three stops darker, and each is compared in Oklab with the photo's own pixel
    /// and those around it: it may not be more colourful than the most colourful of
    /// those (in absolute terms or for its brightness), and if it has any colour to speak of
    /// its hue must be within a few degrees of one of theirs. A pixel that fails gets one
    /// share for all three channels: the same brightness, the photo's own colour.
    private func guardColour(_ alpha8: Buf<UInt8>, _ shares: Buf<UInt8>) -> (checked: Int, fixed: Int) {
        let b = band0, W = self.W, H = self.H
        if b.isEmpty { return (0, 0) }
        let src = photo.p, rowBytes = photo.rowBytes, lin = Matte.toLinear.p
        let fp = fEdge.p, bp = bEdge.p
        let tolerance = settings.guardChroma, degrees = settings.guardHue
        let lock = NSLock()
        var checked = 0, fixed = 0
        var reasons = [0, 0, 0, 0, 0, 0]
        let lightness = settings.guardLightness, upper = settings.guardLighter
        @inline(__always) func linear(_ x: Int, _ y: Int) -> SIMD3<Float> {
            let o = y * rowBytes + x * 4
            return SIMD3(lin[Int(src[o])], lin[Int(src[o + 1])], lin[Int(src[o + 2])])
        }
        parallelRows(b.h) { rows in
            var nChecked = 0, nFixed = 0
            var why = [0, 0, 0, 0, 0, 0]
            var around = [SIMD3<Float>](repeating: SIMD3(repeating: 0), count: 27)
            for by in rows {
                let y = b.y + by
                for x in b.x ..< b.maxX {
                    let o = (y * W + x) * 4
                    let r = shares.p[o], g = shares.p[o + 1], bl = shares.p[o + 2]
                    let a8 = alpha8.p[y * W + x]
                    let spread = max(r, max(g, bl)) - min(r, min(g, bl))
                    // Only pixels whose shares are their own: not plain coverage.
                    if spread < 3 && abs(Int(r) - Int(a8)) < 3 { continue }
                    nChecked += 1
                    let s: SIMD3<Float> = SIMD3<Float>(Float(r), Float(g), Float(bl)) / 255
                    let I: SIMD3<Float> = linear(x, y)
                    defer {
                        // Lightness (final masking round, priority 2c). The shares and the
                        // coverage together say what colour the subject is at this pixel: the
                        // pixel's light that is the subject's, over how much of the pixel the
                        // subject covers. That may not be darker than both the pixel itself
                        // and the subject beside it (a dark seam), nor lighter than both.
                        let al = Float(a8) / 255
                        if lightness > 0 && al >= 0.03 {
                            let now = SIMD3<Float>(Float(shares.p[o]), Float(shares.p[o + 1]), Float(shares.p[o + 2])) / 255
                            let c3: SIMD3<Float> = sample3(fp, x, y)
                            let beside = SIMD3<Float>(lin[Int(min(max(c3.x, 0), 1) * 255)], lin[Int(min(max(c3.y, 0), 1) * 255)], lin[Int(min(max(c3.z, 0), 1) * 255)])
                            // How much of the pixel the subject covers: what the mask says, or
                            // what the pixel's colour says where that is more and the two
                            // colours can be told apart. (Soft hair the mask gives 30% to, that
                            // is plainly the hair's colour, keeps its light; that is the point
                            // of the shares, not a fault to put right.)
                            let b3: SIMD3<Float> = sample3(bp, x, y)
                            let behind = SIMD3<Float>(lin[Int(min(max(b3.x, 0), 1) * 255)], lin[Int(min(max(b3.y, 0), 1) * 255)], lin[Int(min(max(b3.z, 0), 1) * 255)])
                            let across: SIMD3<Float> = beside - behind
                            let byColour: Float = min(max(dot3(I - behind, across) / (dot3(across, across) + 1e-7), 0), 1)
                            let told: Float = Matte.apart(c3, b3, low: settings.colourLow, high: settings.colourHigh, floor0: settings.colourFloor,
                                                          floor1: settings.colourFull, plain: settings.colourPlain)
                            let cover: Float = al + max(byColour - al, 0) * told
                            let own: Float = luma(I * now) / cover
                            let here: Float = luma(I), there: Float = luma(beside)
                            let least: Float = min(here, there) * (1 - lightness) - 0.001, most: Float = max(here, there) * (1 + lightness) + 0.001
                            var scale: Float = 1
                            if own < least { scale = least / max(own, 1e-5); why[4] += 1 } else if own > most && upper { scale = most / own; why[5] += 1 }
                            // All three channels by the same amount, and never so far that
                            // one of them would be cut off at 1: that would tint what is left.
                            if scale > 1 { scale = min(scale, 1 / max(now.max(), 1e-4)) }
                            if scale != 1 {
                                let moved: SIMD3<Float> = (now * scale).clamped(lowerBound: SIMD3(repeating: 0), upperBound: SIMD3(repeating: 1))
                                shares.p[o] = UInt8((moved.x * 255).rounded())
                                shares.p[o + 1] = UInt8((moved.y * 255).rounded())
                                shares.p[o + 2] = UInt8((moved.z * 255).rounded())
                            }
                        }
                    }
                    if spread < 3 { continue }
                    // The photo here and around here: the most colour there is, and its hues.
                    // (Two pixels each way: an edge is two or three pixels wide, and the colours
                    // either side of it are the ones a cleaned-up edge pixel may take.)
                    var most: Float = 0, mostFor: Float = 0, n = 0
                    for ny in max(y - 2, 0) ... min(y + 2, H - 1) {
                        for nx in max(x - 2, 0) ... min(x + 2, W - 1) {
                            let lab: SIMD3<Float> = Oklab.from(linear: linear(nx, ny))
                            let c: Float = Oklab.chroma(lab)
                            let forItsBrightness: Float = c / max(lab.x, 0.02)
                            most = max(most, c)
                            mostFor = max(mostFor, forItsBrightness)
                            around[n] = lab
                            n += 1
                        }
                    }
                    // And the colours the edge is being cleaned towards: the subject's and the
                    // background's near here. A pixel may come out looking like either.
                    for field in [fp, bp] {
                        let c3: SIMD3<Float> = sample3(field, x, y)
                        let l3 = SIMD3<Float>(lin[Int(min(max(c3.x, 0), 1) * 255)], lin[Int(min(max(c3.y, 0), 1) * 255)], lin[Int(min(max(c3.z, 0), 1) * 255)])
                        let lab: SIMD3<Float> = Oklab.from(linear: l3)
                        let c: Float = Oklab.chroma(lab)
                        most = max(most, c)
                        mostFor = max(mostFor, c / max(lab.x, 0.02))
                        around[n] = lab
                        n += 1
                    }
                    var failed = false
                    for k in 0 ..< 2 {
                        let one = SIMD3<Float>(repeating: 1)
                        let rest: SIMD3<Float> = one - s
                        // Background three stops darker, then subject three stops darker.
                        let kept: SIMD3<Float> = k == 0 ? s + rest * 0.125 : s * 0.125 + rest
                        let out: SIMD3<Float> = I * kept
                        let lab: SIMD3<Float> = Oklab.from(linear: out)
                        let c: Float = Oklab.chroma(lab)
                        let forItsBrightness: Float = c / max(lab.x, 0.02)
                        let allowed: Float = mostFor * 1.25 + tolerance
                        if c > most + tolerance {
                            failed = true
                            why[0] += 1
                            break
                        }
                        if c > tolerance && forItsBrightness > allowed {
                            failed = true
                            why[1] += 1
                            break
                        }
                        if c > 0.03 {
                            var nearest: Float = 180
                            for i in 0 ..< n where Oklab.chroma(around[i]) > 0.015 { nearest = min(nearest, Oklab.hueApart(lab, around[i])) }
                            if nearest > degrees {
                                failed = true
                                why[2 + k] += 1
                                break
                            }
                        }
                    }
                    if !failed { continue }
                    // One share for all three: what the three came to in brightness.
                    let weights: SIMD3<Float> = SIMD3<Float>(0.2126, 0.7152, 0.0722) * I
                    let weighted: SIMD3<Float> = weights * s
                    let together: Float = weighted.sum() / max(weights.sum(), 1e-6)
                    let byte = UInt8((min(max(together, 0), 1) * 255).rounded())
                    shares.p[o] = byte; shares.p[o + 1] = byte; shares.p[o + 2] = byte
                    nFixed += 1
                }
            }
            lock.lock()
            checked += nChecked; fixed += nFixed
            for i in 0 ..< 6 { reasons[i] += why[i] }
            lock.unlock()
        }
        guardNote = " (more colourful outright \(reasons[0]), for its brightness \(reasons[1]), hue with the background darkened \(reasons[2]), with the subject darkened \(reasons[3]))"
        lightnessNote = "; lightness: \(reasons[4]) had come out darker than the subject beside them and were raised, \(reasons[5]) lighter and were lowered"
        lightnessCorrections = reasons[4] + reasons[5]
        return (checked, fixed)
    }

    /// Halo and erosion (masking spec v3, section 10, and v4, 1.7), measured at half size in
    /// two rings either side of the finished Off edge: right at it (0 to about 3 pixels) and
    /// further out (3 to 10).
    private func edgeQuality(_ alpha8: Buf<UInt8>) -> EdgeQuality {
        var quality = EdgeQuality()
        quality.fringe = fringeAfter
        let b = band0, W = self.W, qw = self.qw
        if b.isEmpty || offAlpha.count != b.w * b.h { return quality }
        let hw = (b.w + 1) / 2, hh = (b.h + 1) / 2
        let hard = Buf<Float>(hw * hh, 0), final = Buf<Float>(hw * hh, 0)
        let t0 = tri0.p, off = offAlpha.p
        parallelRows(hh) { rows in
            for hy in rows {
                for hx in 0 ..< hw {
                    var so: Float = 0, sf: Float = 0, n: Float = 0
                    for y in (b.y + hy * 2) ..< min(b.y + hy * 2 + 2, b.maxY) {
                        for x in (b.x + hx * 2) ..< min(b.x + hx * 2 + 2, b.maxX) {
                            let t = t0[(y >> 2) * qw + (x >> 2)]
                            so += t == 1 ? off[(y - b.y) * b.w + (x - b.x)] : (t == 2 ? 1 : 0)
                            sf += Float(alpha8.p[y * W + x]) / 255
                            n += 1
                        }
                    }
                    hard.p[hy * hw + hx] = so >= 0.5 * n ? 1 : 0
                    final.p[hy * hw + hx] = sf / max(n, 1)
                }
            }
        }
        let edge = Gray(w: hw, h: hh, v: hard.array)
        let outNear = PlaneMath.extremum(edge, radius: 1, smallest: false), outFar = PlaneMath.extremum(edge, radius: 5, smallest: false)
        let inNear = PlaneMath.extremum(edge, radius: 1, smallest: true), inFar = PlaneMath.extremum(edge, radius: 5, smallest: true)
        // [hair, elsewhere] × [sum, count], for each ring.
        var halo = [Double](repeating: 0, count: 4), erosion = [Double](repeating: 0, count: 4)
        var nearHalo = [Double](repeating: 0, count: 4), nearErosion = [Double](repeating: 0, count: 4)
        let hair = hairQ.p
        for hy in 0 ..< hh {
            let qy = (b.y + hy * 2) >> 2
            for hx in 0 ..< hw {
                let i = hy * hw + hx
                let zone = hair[qy * qw + ((b.x + hx * 2) >> 2)] > 0.5 ? 0 : 2
                if edge.v[i] < 0.5 {
                    if outNear.v[i] > 0.5 {
                        nearHalo[zone] += Double(final.p[i]); nearHalo[zone + 1] += 1
                    } else if outFar.v[i] > 0.5 {
                        halo[zone] += Double(final.p[i]); halo[zone + 1] += 1
                    }
                } else if inNear.v[i] < 0.5 {
                    nearErosion[zone] += Double(1 - final.p[i]); nearErosion[zone + 1] += 1
                } else if inFar.v[i] < 0.5 {
                    erosion[zone] += Double(1 - final.p[i]); erosion[zone + 1] += 1
                }
            }
        }
        func mean(_ v: [Double], _ zone: Int) -> Float? { v[zone + 1] >= 50 ? Float(v[zone] / v[zone + 1]) : nil }
        quality.haloHair = mean(halo, 0)
        quality.haloElsewhere = mean(halo, 2)
        quality.erosionHair = mean(erosion, 0)
        quality.erosionElsewhere = mean(erosion, 2)
        quality.nearHaloHair = mean(nearHalo, 0)
        quality.nearHaloElsewhere = mean(nearHalo, 2)
        quality.nearErosionHair = mean(nearErosion, 0)
        quality.nearErosionElsewhere = mean(nearErosion, 2)
        return quality
    }
}
