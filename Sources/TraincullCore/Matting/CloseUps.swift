import Foundation

/// Closer looks at the subject (masking spec v3, sections 3.2 and 4). The model sees the whole
/// frame at a fraction of its size; it is then shown square pieces of the subject cut from the
/// full-size photo, and what it says about each is merged back, but only close to the edge
/// that is already there, so a closer look can sharpen an edge and never invent a new region.
public enum CloseUps {
    /// Square tiles that together cover `box`, in the same pixels as the box. Each is as
    /// large as the box's shorter side but no more than half its longer side (so the model
    /// sees at least twice the detail it had of the whole frame; masking spec v4, 1.1),
    /// within `rules.tileLeast ... rules.tileCap`, and they overlap by `rules.tileOverlap`.
    /// If that takes more than `rules.tilesMost`, larger tiles are used. Tiles stay inside a
    /// picture `w` by `h`.
    public static func tiles(covering box: Box, w: Int, h: Int, rules: SubjectRules = SubjectRules()) -> [Box] {
        let bw = box.x1 - box.x0, bh = box.y1 - box.y0
        if bw <= 0 || bh <= 0 { return [] }
        var side = min(max(min(bw, bh), rules.tileLeast), rules.tileCap)
        side = min(side, max(max(bw, bh) / 2, rules.tileLeast))
        side = min(side, min(w, h))
        func count(_ span: Int, _ side: Int) -> Int {
            span <= side ? 1 : Int((Float(span - side) / ((1 - rules.tileOverlap) * Float(side))).rounded(.up)) + 1
        }
        let largest = min(rules.tileCap, min(w, h))
        while count(bw, side) * count(bh, side) > rules.tilesMost && side < largest {
            side = min(Int(Float(side) * 1.15) + 1, largest)
        }
        func starts(_ lo: Int, _ span: Int, _ limit: Int) -> [Int] {
            let n = count(span, side)
            if n == 1 {
                // One tile: centred on the box, pushed back inside the picture.
                return [min(max(lo + (span - side) / 2, 0), limit - side)]
            }
            return (0 ..< n).map { i in min(max(lo + Int((Float(i) * Float(span - side) / Float(n - 1)).rounded()), 0), limit - side) }
        }
        var out: [Box] = []
        for y in starts(box.y0, bh, h) {
            for x in starts(box.x0, bw, w) { out.append(Box(x0: x, y0: y, x1: x + side, y1: y + side)) }
        }
        return out
    }

    /// How far a close-up may change each pixel: 1 within `radius` pixels of the mask's
    /// present edge (its 0.5 line), fading to 0 half as far again out.
    public static func edgeZone(_ mask: Gray, radius: Float) -> Gray {
        let w = mask.w, h = mask.h
        let inside = mask.v.map { $0 >= 0.5 }
        let toInside = PlaneMath.distance(to: inside, w: w, h: h), toOutside = PlaneMath.distance(to: inside.map { !$0 }, w: w, h: h)
        var zone = Gray(w: w, h: h)
        let fade = max(radius * 0.5, 1)
        for i in 0 ..< w * h {
            let d = max(toInside[i], toOutside[i]) // one of the two is 0
            zone.v[i] = min(max((radius + fade - d) / fade, 0), 1)
        }
        return zone
    }

    /// The radius of that zone for a face of a given height, both in the same pixels.
    public static func mergeRadius(faceHeight: Int?, longEdge: Int, rules: SubjectRules = SubjectRules()) -> Float {
        let unit = faceHeight.map { Float($0) } ?? 0.1 * Float(longEdge)
        return rules.mergeFraction * unit + rules.mergePlus
    }

    /// Collects close-ups onto a canvas that may be finer than the picture the boxes are
    /// measured in, then lays them over the mask there.
    public struct Canvas {
        public let w: Int, h: Int
        /// Canvas pixels for each pixel of the picture the boxes and the zone are measured in.
        public let scale: Float
        var sum: [Float]
        var weight: [Float]
        public private(set) var tiles = 0
        /// The tiles added, in canvas pixels.
        var placed: [Box] = []

        public init(w: Int, h: Int, scale: Float) {
            self.w = w; self.h = h; self.scale = scale
            sum = [Float](repeating: 0, count: w * h)
            weight = [Float](repeating: 0, count: w * h)
        }

        /// Adds the model's answer for one box (any size; it is stretched over the box). Where
        /// tiles overlap, each counts for more the further a pixel is from its border.
        public mutating func add(_ answer: Gray, box: Box, feather: Int) {
            let x0 = max(Int((Float(box.x0) * scale).rounded()), 0), y0 = max(Int((Float(box.y0) * scale).rounded()), 0)
            let x1 = min(Int((Float(box.x1) * scale).rounded()), w), y1 = min(Int((Float(box.y1) * scale).rounded()), h)
            if x1 <= x0 || y1 <= y0 { return }
            let kx = Float(answer.w) / Float(x1 - x0), ky = Float(answer.h) / Float(y1 - y0)
            let f = max(Float(feather) * scale, 1)
            let cw = w
            sum.withUnsafeMutableBufferPointer { sp in
                weight.withUnsafeMutableBufferPointer { wp in
                    let s = sp, wt = wp
                    parallelRows(y1 - y0) { rows in
                        for r in rows {
                            let y = y0 + r
                            for x in x0 ..< x1 {
                                let d = Float(min(min(x - x0, x1 - 1 - x), min(y - y0, y1 - 1 - y)))
                                let k = min(max(d / f, 0), 1) + 0.001
                                let v = answer.sample((Float(x - x0) + 0.5) * kx, (Float(y - y0) + 0.5) * ky)
                                s[y * cw + x] += k * v
                                wt[y * cw + x] += k
                            }
                        }
                    }
                }
            }
            tiles += 1
            placed.append(Box(x0: x0, y0: y0, x1: x1, y1: y1))
        }

        /// A check for lines where tiles meet (masking spec v4, 1.2): the merged mask's
        /// steps across tile borders against its steps half a tile further in, each at its
        /// 99th percentile. A border that shows has much larger ones; over 3 is worth a
        /// warning. Nil when there is too little edge on the borders to tell.
        public func seamRatio(_ merged: Gray) -> Float? {
            precondition(merged.w == w && merged.h == h)
            var across: [Float] = [], within: [Float] = []
            func step(_ x: Int, _ y: Int, _ dx: Int, _ dy: Int) -> Float? {
                let ax = x - dx, ay = y - dy
                if ax < 0 || ay < 0 || x >= w || y >= h { return nil }
                let a = merged.v[ay * w + ax], b = merged.v[y * w + x]
                // Only where there is an edge to cut: flat inside and flat outside say nothing.
                if (a < 0.02 && b < 0.02) || (a > 0.98 && b > 0.98) { return nil }
                return abs(a - b)
            }
            for tile in placed {
                let half = max((tile.x1 - tile.x0) / 2, 1)
                for (border, inward) in [(tile.x0, half), (tile.x1, -half)] where border > 0 && border < w {
                    for y in stride(from: tile.y0, to: tile.y1, by: 2) {
                        if let v = step(border, y, 1, 0) { across.append(v) }
                        if let v = step(border + inward, y, 1, 0) { within.append(v) }
                    }
                }
                for (border, inward) in [(tile.y0, half), (tile.y1, -half)] where border > 0 && border < h {
                    for x in stride(from: tile.x0, to: tile.x1, by: 2) {
                        if let v = step(x, border, 0, 1) { across.append(v) }
                        if let v = step(x, border + inward, 0, 1) { within.append(v) }
                    }
                }
            }
            if across.count < 100 || within.count < 100 { return nil }
            across.sort(); within.sort()
            return across[across.count * 99 / 100] / max(within[within.count * 99 / 100], 0.01)
        }

        /// The mask at the canvas's size: `base` stretched up, replaced by the close-ups
        /// where there are any, as far as `zone` (the size of `base`) allows.
        public func merged(over base: Gray, zone: Gray) -> Gray {
            var out = Gray(w: w, h: h)
            let kx = Float(base.w) / Float(w), ky = Float(base.h) / Float(h)
            let cw = w
            sum.withUnsafeBufferPointer { s in
                weight.withUnsafeBufferPointer { wt in
                    out.v.withUnsafeMutableBufferPointer { o in
                        let dst = o
                        parallelRows(h) { rows in
                            for y in rows {
                                for x in 0 ..< cw {
                                    let i = y * cw + x
                                    let bx = (Float(x) + 0.5) * kx, by = (Float(y) + 0.5) * ky
                                    var v = base.sample(bx, by)
                                    if wt[i] > 0 {
                                        let z = zone.sample(bx, by) * min(wt[i] / 0.5, 1)
                                        if z > 0 { v += (s[i] / wt[i] - v) * z }
                                    }
                                    dst[i] = v
                                }
                            }
                        }
                    }
                }
            }
            return out
        }
    }
}

/// A person's joints as a body-pose detector found them, by name, in pixels with y down.
public struct BodyPose {
    public struct Joint: Equatable {
        public var x: Float, y: Float, confidence: Float

        public init(x: Float, y: Float, confidence: Float) {
            self.x = x; self.y = y; self.confidence = confidence
        }
    }

    public var joints: [String: Joint]

    public init(joints: [String: Joint]) { self.joints = joints }

    /// The limb segments that count as "certainly this person's body" (spec v3, section 7).
    public static let limbs: [(String, String)] = [
        ("leftShoulder", "leftElbow"), ("leftElbow", "leftWrist"), ("rightShoulder", "rightElbow"), ("rightElbow", "rightWrist"),
        ("leftHip", "leftKnee"), ("leftKnee", "leftAnkle"), ("rightHip", "rightKnee"), ("rightKnee", "rightAnkle"),
    ]

    /// The joints found with at least `least` confidence.
    public func sure(_ least: Float) -> [String: Joint] { joints.filter { $0.value.confidence >= least } }

    /// Where the head is: the nose, else the neck, else the middle of the shoulders.
    public func head(_ least: Float) -> Joint? {
        let j = sure(least)
        if let nose = j["nose"] { return nose }
        if let neck = j["neck"] { return neck }
        if let l = j["leftShoulder"], let r = j["rightShoulder"] { return Joint(x: (l.x + r.x) / 2, y: (l.y + r.y) / 2, confidence: min(l.confidence, r.confidence)) }
        return nil
    }

    /// Which of several poses belongs to a face: the one whose head is nearest the face's
    /// centre, if that is within one and a half face heights. Nil when none is.
    public static func match(_ poses: [BodyPose], face: PixelRect, least: Float = 0.3) -> Int? {
        let cx = Float(face.x) + Float(face.w) / 2, cy = Float(face.y) + Float(face.h) / 2
        var best: (index: Int, distance: Float)?
        for (i, pose) in poses.enumerated() {
            guard let head = pose.head(least) else { continue }
            let d = ((head.x - cx) * (head.x - cx) + (head.y - cy) * (head.y - cy)).squareRoot()
            if d <= 1.5 * Float(face.h), d < (best?.distance ?? .infinity) { best = (i, d) }
        }
        return best?.index
    }

    /// The pixels within `radius` of this pose's limb lines and sure joints, in a picture
    /// `w` by `h`: what a mask piece must touch to count as confirmed body.
    public func confirmed(radius: Float, w: Int, h: Int, least: Float = 0.3) -> [Bool] {
        var out = [Bool](repeating: false, count: w * h)
        let j = sure(least)
        var segments: [(Joint, Joint)] = BodyPose.limbs.compactMap { a, b in
            guard let p = j[a], let q = j[b] else { return nil }
            return (p, q)
        }
        for name in ["leftShoulder", "rightShoulder", "leftElbow", "rightElbow", "leftWrist", "rightWrist",
                     "leftHip", "rightHip", "leftKnee", "rightKnee", "leftAnkle", "rightAnkle"] {
            if let p = j[name] { segments.append((p, p)) }
        }
        let r2 = radius * radius
        for (p, q) in segments {
            let x0 = max(Int(min(p.x, q.x) - radius), 0), x1 = min(Int(max(p.x, q.x) + radius) + 1, w)
            let y0 = max(Int(min(p.y, q.y) - radius), 0), y1 = min(Int(max(p.y, q.y) + radius) + 1, h)
            if x1 <= x0 || y1 <= y0 { continue }
            let dx = q.x - p.x, dy = q.y - p.y
            let len2 = dx * dx + dy * dy
            for y in y0 ..< y1 {
                for x in x0 ..< x1 {
                    let px = Float(x) + 0.5 - p.x, py = Float(y) + 0.5 - p.y
                    let t = len2 > 0 ? min(max((px * dx + py * dy) / len2, 0), 1) : 0
                    let ex = px - t * dx, ey = py - t * dy
                    if ex * ex + ey * ey <= r2 { out[y * w + x] = true }
                }
            }
        }
        return out
    }
}
