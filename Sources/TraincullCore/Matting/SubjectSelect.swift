import Foundation

/// A rectangle given by its edges, in pixels, as the selection rules use them.
public struct Box: Equatable {
    public var x0: Int, y0: Int, x1: Int, y1: Int

    public init(x0: Int, y0: Int, x1: Int, y1: Int) {
        self.x0 = x0; self.y0 = y0; self.x1 = x1; self.y1 = y1
    }

    public init(_ r: PixelRect) { self.init(x0: r.x, y0: r.y, x1: r.maxX, y1: r.maxY) }

    public var rect: PixelRect { PixelRect(x: x0, y: y0, w: max(x1 - x0, 0), h: max(y1 - y0, 0)) }
    public var area: Int { max(x1 - x0, 0) * max(y1 - y0, 0) }

    public func union(_ o: Box) -> Box { Box(x0: min(x0, o.x0), y0: min(y0, o.y0), x1: max(x1, o.x1), y1: max(y1, o.y1)) }

    /// Larger by a fraction of its size on every side, kept inside a picture.
    public func expanded(by fraction: Float, w: Int, h: Int) -> Box {
        let dx = Int((Float(x1 - x0) * fraction).rounded(.up)), dy = Int((Float(y1 - y0) * fraction).rounded(.up))
        return Box(x0: max(x0 - dx, 0), y0: max(y0 - dy, 0), x1: min(x1 + dx, w), y1: min(y1 + dy, h))
    }
}

/// The rules that turn a model's raw answer into the subject: which connected pieces of it to
/// keep (masking spec v2, section 6). The same rules run in `tools/bakeoff_subject.py`, where
/// they were compared against Photoshop's masks; `SubjectRules` holds the numbers both use.
public struct SubjectRules {
    public var feather = 24
    public var speckle: Float = 0.0002
    public var hole: Float = 0.0001
    public var attachDistance: Float = 0.01
    public var sharpRatio: Float = 1.6
    public var sharpPlus: Float = 0.8
    public var unmeasuredArea: Float = 0.02
    public var hybridOverlap: Float = 0.3
    public var hybridDilate: Float = 0.005
    public var boxExpand: Float = 0.10

    public init() {}
}

public enum SubjectSelect {
    /// What `keep` decided, for the log.
    public struct Decision {
        public var components = 0
        public var kept: [String] = []
        public var dropped: [String: Int] = [:]
        public var subjectSharpness: Float = 1

        public var summary: String {
            var k: [String: Int] = [:]
            for name in kept { k[name, default: 0] += 1 }
            let keptText = k.sorted { $0.key < $1.key }.map { "\($0.key) \($0.value)" }.joined(separator: ", ")
            let droppedText = dropped.sorted { $0.key < $1.key }.map { "\($0.key) \($0.value)" }.joined(separator: ", ")
            return "components \(components) → kept \(kept.count) (\(keptText))" + (dropped.isEmpty ? "" : " · dropped \(dropped.values.reduce(0, +)) (\(droppedText))")
        }
    }

    // MARK: Connected pieces

    /// Numbers each connected piece of a mask from 1 (0 is "not in the mask"). Pieces touching
    /// only at a corner count as connected.
    public static func label(_ mask: [Bool], w: Int, h: Int) -> (labels: [Int32], count: Int) {
        var labels = [Int32](repeating: 0, count: w * h)
        var stack: [Int32] = []
        var count: Int32 = 0
        for start in 0 ..< w * h where mask[start] && labels[start] == 0 {
            count += 1
            labels[start] = count
            stack.append(Int32(start))
            while let top = stack.popLast() {
                let x = Int(top) % w, y = Int(top) / w
                for ny in max(y - 1, 0) ... min(y + 1, h - 1) {
                    for nx in max(x - 1, 0) ... min(x + 1, w - 1) {
                        let j = ny * w + nx
                        if mask[j] && labels[j] == 0 {
                            labels[j] = count
                            stack.append(Int32(j))
                        }
                    }
                }
            }
        }
        return (labels, Int(count))
    }

    /// A mask without its specks and with its pinholes filled.
    public static func tidy(_ mask: [Bool], w: Int, h: Int, rules: SubjectRules = SubjectRules()) -> [Bool] {
        var out = mask
        let n = Float(w * h)
        let (lab, count) = label(mask, w: w, h: h)
        if count > 0 {
            var areas = [Int](repeating: 0, count: count + 1)
            for l in lab where l > 0 { areas[Int(l)] += 1 }
            for i in 0 ..< w * h where lab[i] > 0 && Float(areas[Int(lab[i])]) < rules.speckle * n { out[i] = false }
        }
        let (holes, holeCount) = label(out.map { !$0 }, w: w, h: h)
        if holeCount > 0 {
            var areas = [Int](repeating: 0, count: holeCount + 1), open = [Bool](repeating: false, count: holeCount + 1)
            for i in 0 ..< w * h where holes[i] > 0 {
                areas[Int(holes[i])] += 1
                let x = i % w, y = i / w
                if x == 0 || y == 0 || x == w - 1 || y == h - 1 { open[Int(holes[i])] = true }
            }
            for i in 0 ..< w * h where holes[i] > 0 && !open[Int(holes[i])] && Float(areas[Int(holes[i])]) < rules.hole * n { out[i] = true }
        }
        return out
    }

    /// The typical blur of the edges just inside a region's boundary; nil with too few to tell.
    static func edgeSharp(_ region: [Bool], _ map: SharpnessMap) -> Float? {
        let w = map.w, h = map.h
        let inner = PlaneMath.extremum(Gray(w: w, h: h, v: region.map { $0 ? 1 : 0 }), radius: 4, smallest: true)
        var values: [Float] = []
        for i in 0 ..< w * h where region[i] && inner.v[i] < 0.5 && map.edge[i] { values.append(map.sigma[i]) }
        if values.count < 50 { return nil }
        values.sort()
        return values[values.count / 2]
    }

    // MARK: Keeping the subject

    /// Keeps the piece of a soft mask that holds the face, and the pieces attached to it that
    /// are about as sharp: a prop in the hand stays, a person behind does not.
    ///
    /// - Parameters:
    ///   - soft: a model's answer, 0 to 1, the size of the sharpness map.
    ///   - face: the subject's face, in the same pixels.
    ///   - mustKeep: pieces this says yes to are kept whatever the other rules say.
    public static func keep(_ soft: Gray, sharpness map: SharpnessMap, face: PixelRect, rules: SubjectRules = SubjectRules(),
                            mustKeep: (([Bool]) -> Bool)? = nil) -> (mask: Gray, decision: Decision) {
        let w = soft.w, h = soft.h, n = w * h
        precondition(map.w == w && map.h == h)
        var decision = Decision()
        let hard = soft.v.map { $0 >= 0.5 }
        let (lab, count) = label(hard, w: w, h: h)
        decision.components = count
        if count == 0 { return (Gray(w: w, h: h), decision) }
        var areas = [Int](repeating: 0, count: count + 1)
        for l in lab where l > 0 { areas[Int(l)] += 1 }

        // The piece with the face in it: under the face's centre, else the one that covers most of the face.
        let cx = min(max(face.x + face.w / 2, 0), w - 1), cy = min(max(face.y + face.h / 2, 0), h - 1)
        var primary = Int(lab[cy * w + cx])
        if primary == 0 {
            var inFace = [Int](repeating: 0, count: count + 1)
            let f = face.clamped(w: w, h: h)
            for y in f.y ..< f.maxY { for x in f.x ..< f.maxX where lab[y * w + x] > 0 { inFace[Int(lab[y * w + x])] += 1 } }
            primary = inFace.indices.max { inFace[$0] < inFace[$1] } ?? 0
            if primary == 0 || inFace[primary] == 0 { primary = areas.indices.dropFirst().max { areas[$0] < areas[$1] } ?? 1 }
        }
        func piece(_ i: Int) -> [Bool] { lab.map { Int($0) == i } }
        let sp = edgeSharp(piece(primary), map) ?? map.faceSharp(face) ?? 1
        decision.subjectSharpness = sp
        let limit = max(rules.sharpRatio * sp, sp + rules.sharpPlus)

        var kept = Set([primary])
        decision.kept.append("primary")
        if let mustKeep = mustKeep {
            for i in 1 ... count where !kept.contains(i) && Float(areas[i]) >= rules.speckle * Float(n) && mustKeep(piece(i)) {
                kept.insert(i)
                decision.kept.append("overlap")
            }
        }
        let reach = rules.attachDistance * Float(max(w, h))
        var why = [Int: String]()
        for _ in 0 ..< 3 {
            let distance = PlaneMath.distance(to: lab.map { kept.contains(Int($0)) }, w: w, h: h)
            var nearest = [Float](repeating: .infinity, count: count + 1)
            for i in 0 ..< n where lab[i] > 0 { nearest[Int(lab[i])] = min(nearest[Int(lab[i])], distance[i]) }
            var added = false
            for i in 1 ... count where !kept.contains(i) {
                if Float(areas[i]) < rules.speckle * Float(n) { why[i] = "speckle"; continue }
                if nearest[i] > reach { why[i] = "disconnected"; continue }
                let sharp = edgeSharp(piece(i), map)
                if let sharp = sharp, sharp <= limit {
                    kept.insert(i)
                } else if sharp == nil, Float(areas[i]) < rules.unmeasuredArea * Float(n) {
                    kept.insert(i)
                } else {
                    why[i] = "defocused"
                    continue
                }
                decision.kept.append("attached")
                why[i] = nil
                added = true
            }
            if !added { break }
        }
        for reason in why.values { decision.dropped[reason, default: 0] += 1 }

        let keepMask = tidy(lab.map { kept.contains(Int($0)) }, w: w, h: h, rules: rules)
        // The soft fringe just outside the kept pieces stays; the dropped pieces go entirely.
        let near = PlaneMath.extremum(Gray(w: w, h: h, v: keepMask.map { $0 ? 1 : 0 }), radius: 6, smallest: false)
        var out = Gray(w: w, h: h)
        for i in 0 ..< n {
            if keepMask[i] {
                out.v[i] = max(soft.v[i], 0.51)
            } else if near.v[i] > 0.5 && !hard[i] {
                out.v[i] = soft.v[i]
            }
        }
        return (out, decision)
    }

    // MARK: Putting answers together

    /// 1 inside a box, fading to 0 across its outer `feather` pixels.
    public static func featherIn(_ box: Box, w: Int, h: Int, feather: Int) -> Gray {
        var g = Gray(w: w, h: h)
        if box.x1 <= box.x0 || box.y1 <= box.y0 { return g }
        for y in max(box.y0, 0) ..< min(box.y1, h) {
            for x in max(box.x0, 0) ..< min(box.x1, w) {
                let d = min(min(x - box.x0, box.x1 - 1 - x), min(y - box.y0, box.y1 - 1 - y))
                g.v[y * w + x] = min(max(Float(d) / Float(max(feather, 1)), 0), 1)
            }
        }
        return g
    }

    /// A closer look at one box laid over the whole-picture answer, fading in at the box's edges.
    /// `inside` is the size of the box.
    public static func merge(_ whole: Gray, inside: Gray, box: Box, rules: SubjectRules = SubjectRules()) -> Gray {
        let w = whole.w, h = whole.h
        let weight = featherIn(box, w: w, h: h, feather: rules.feather)
        let bw = box.x1 - box.x0, bh = box.y1 - box.y0
        var out = whole
        for y in max(box.y0, 0) ..< min(box.y1, h) {
            for x in max(box.x0, 0) ..< min(box.x1, w) {
                let i = y * w + x
                let v = inside.sample((Float(x - box.x0) + 0.5) * Float(inside.w) / Float(bw), (Float(y - box.y0) + 0.5) * Float(inside.h) / Float(bh))
                out.v[i] = weight.v[i] * v + (1 - weight.v[i]) * whole.v[i]
            }
        }
        return out
    }

    /// The hybrid: one model's shapes (`shape`, good at edges and props), kept where another
    /// (`which`, good at telling people apart) agrees they are the subject, or where they are
    /// attached and sharp. What only `which` claims is added too.
    public static func hybrid(shape: Gray, which: Gray, sharpness map: SharpnessMap, face: PixelRect,
                              rules: SubjectRules = SubjectRules()) -> (mask: Gray, decision: Decision) {
        let w = shape.w, h = shape.h
        let radius = max(Int(rules.hybridDilate * Float(max(w, h))), 1)
        let wide = PlaneMath.extremum(Gray(w: w, h: h, v: which.v.map { $0 >= 0.5 ? 1 : 0 }), radius: radius, smallest: false)
        var (mask, decision) = keep(shape, sharpness: map, face: face, rules: rules) { piece in
            var inside = 0, total = 0
            for i in 0 ..< w * h where piece[i] {
                total += 1
                if wide.v[i] > 0.5 { inside += 1 }
            }
            return total > 0 && Float(inside) / Float(total) >= rules.hybridOverlap
        }
        for i in 0 ..< w * h where which.v[i] >= 0.5 && mask.v[i] < 0.5 { mask.v[i] = max(mask.v[i], which.v[i]) }
        return (mask, decision)
    }

    // MARK: What a point-and-box model is given

    /// The two points that say "this person": the middle of the face, and the chest two
    /// face-heights below it when that is inside the picture.
    public static func points(face: PixelRect, h: Int) -> [(x: Float, y: Float)] {
        let cx = Float(face.x) + Float(face.w) / 2, cy = Float(face.y) + Float(face.h) / 2
        var out = [(cx, cy)]
        if cy + 2 * Float(face.h) < Float(h) { out.append((cx, cy + 2 * Float(face.h))) }
        return out
    }
}
