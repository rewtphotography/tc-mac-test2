import Foundation

/// Where a mask's edge sits against the photo's own edge.
///
/// A segmentation model's answer, enlarged, puts its half-way line where the model thinks the
/// boundary is, give or take a model pixel. At full size a model pixel is three or four photo
/// pixels, and the photo knows better: across a clear edge its colour changes fastest at the
/// boundary itself. This file measures the distance between the two along the edge, and
/// moves the mask by it.
public struct EdgeOffset: Equatable {
    /// Mean signed distance, in pixels, from the photo's strongest colour change to the
    /// mask's half-way line, over clear edges away from hair. Positive: the mask reaches
    /// beyond the true edge (a rim of background). Negative: it stops short, inside the subject.
    public var mean: Float?
    /// The mean of the distances' sizes, whichever way they point.
    public var spread: Float?
    /// The share of clear edge points more than a pixel and a half out, either way.
    public var far: Float?
    /// How wide the mask's edge is there, and how wide the photo's own: the distance over
    /// which each goes from one side to the other, in pixels (means over the same points).
    public var maskWidth: Float?
    public var photoWidth: Float?
    /// How many edge points were clear enough to measure, and how many there were.
    public var measured = 0
    public var points = 0

    public init() {}

    public var summary: String {
        guard let mean = mean, let spread = spread, let far = far else { return "edge offset n/a (\(points) edge points, none clear enough to measure)" }
        let posix = Locale(identifier: "en_US_POSIX")
        return String(format: "edge offset %+.2f px (mean size %.2f px, %.0f%% over 1.5 px) · edge width %.1f px, the photo's %.1f px · from \(measured) clear edge points of \(points)",
                      locale: posix, mean, spread, far * 100, maskWidth ?? 0, photoWidth ?? 0)
    }
}

extension Matte {
    /// One point on a mask's half-way line.
    struct EdgePoint {
        var x: Int32, y: Int32
        /// The outward direction there (from subject to background).
        var nx: Float, ny: Float
        /// Signed distance from the photo's strongest colour change to the half-way line, along
        /// the outward direction.
        var offset: Float
        /// The width of the photo's edge there and of the mask's: the rise across the edge
        /// over its steepest slope, in pixels.
        var photoWidth: Float
        var maskWidth: Float
        /// The photo's colour (linear light) clear of the edge on the subject's side and on
        /// the background's: the two colours this stretch of edge lies between.
        var inner: SIMD3<Float>
        var outer: SIMD3<Float>
        /// How far the measurement is to be believed, 0 to 1.
        var confidence: Float
        /// How far the point is in the hair zone, 0 to 1, and how far in focus.
        var hair: Float
        var sharp: Float
    }

    /// A mask to read, either the snapped edge over the band or a finished mask over the photo.
    struct AlphaSource {
        var floats: UnsafeMutablePointer<Float>?
        var bytes: UnsafeMutablePointer<UInt8>?
        /// The part of the photo the values cover, and outside it the three-way split decides.
        var rect: PixelRect

        @inline(__always) func value(_ x: Int, _ y: Int, _ engine: Matte) -> Float {
            if rect.contains(x, y) {
                let i = (y - rect.y) * rect.w + (x - rect.x)
                if let f = floats { return f[i] }
                if let b = bytes { return Float(b[i]) * (1 / 255) }
            }
            let cx = min(max(x, 0), engine.W - 1) >> 2, cy = min(max(y, 0), engine.H - 1) >> 2
            return engine.tri0.p[cy * engine.qw + cx] == 2 ? 1 : 0
        }

        @inline(__always) func sample(_ x: Float, _ y: Float, _ engine: Matte) -> Float {
            let fx = x - 0.5, fy = y - 0.5
            let x0 = Int(fx.rounded(.down)), y0 = Int(fy.rounded(.down))
            let tx = fx - Float(x0), ty = fy - Float(y0)
            let a = value(x0, y0, engine), b = value(x0 + 1, y0, engine), c = value(x0, y0 + 1, engine), d = value(x0 + 1, y0 + 1, engine)
            return (a + (b - a) * tx) * (1 - ty) + (c + (d - c) * tx) * ty
        }
    }

    /// The photo's colour in linear light at a point between pixels (pixel centres sit at
    /// .5). Linear, because that is where light adds up: a lens blurs an edge evenly either
    /// side of it in linear light, so the edge is where the linear colour changes fastest.
    /// In display values the same blur is lopsided and its steepest point sits towards the
    /// darker side, by half a pixel or so at a bright edge.
    @inline(__always) func colour(_ x: Float, _ y: Float) -> SIMD3<Float> {
        let fx = min(max(x - 0.5, 0), Float(W - 1)), fy = min(max(y - 0.5, 0), Float(H - 1))
        let x0 = Int(fx), y0 = Int(fy), x1 = min(x0 + 1, W - 1), y1 = min(y0 + 1, H - 1)
        let tx = fx - Float(x0), ty = fy - Float(y0)
        let src = photo.p, rowBytes = photo.rowBytes, lin = Matte.toLinear.p
        @inline(__always) func at(_ x: Int, _ y: Int) -> SIMD3<Float> {
            let i = y * rowBytes + x * 4
            return SIMD3(lin[Int(src[i])], lin[Int(src[i + 1])], lin[Int(src[i + 2])])
        }
        let top = at(x0, y0) * (1 - tx) + at(x1, y0) * tx
        let bottom = at(x0, y1) * (1 - tx) + at(x1, y1) * tx
        return top * (1 - ty) + bottom * ty
    }

    /// Walks the half-way line of a mask within the uncertain band and, at each point, looks
    /// along the line straight across the edge for where the photo's colour changes fastest.
    /// `reach` is how far either side it looks, in pixels.
    func edgePoints(_ mask: AlphaSource, reach: Float) -> [EdgePoint] {
        let qw = self.qw, qh = self.qh, W = self.W, H = self.H
        let tq = tri0.p, hair = hairQ.p, focus = focusQ?.p
        let step: Float = 0.5
        // The line runs three pixels further each way than the edge is looked for, so that
        // there is room either side of wherever it is found to read the colours beside it.
        let search = Int((reach / step).rounded(.up))
        let half = search + Int(3 / step) + 1
        let count = 2 * half + 1
        let floorStrength = settings.edgeStrength
        let lock = NSLock()
        var all: [EdgePoint] = []
        parallelRows(qh) { rows in
            var found: [EdgePoint] = []
            var profile = [SIMD3<Float>](repeating: SIMD3(repeating: 0), count: count)
            var maskProfile = [Float](repeating: 0, count: count)
            var change = [Float](repeating: 0, count: count)
            for qy in rows {
                for qx in 0 ..< qw where tq[qy * qw + qx] == 1 {
                    for y in (qy * 4) ..< min(qy * 4 + 4, H) {
                        for x in (qx * 4) ..< min(qx * 4 + 4, W) {
                            let a = mask.value(x, y, self)
                            if a < 0.5 { continue }
                            if mask.value(x - 1, y, self) >= 0.5 && mask.value(x + 1, y, self) >= 0.5
                                && mask.value(x, y - 1, self) >= 0.5 && mask.value(x, y + 1, self) >= 0.5 { continue }
                            // Which way is out: down the slope of the mask, over a small neighbourhood.
                            var gx: Float = 0, gy: Float = 0
                            for dy in -3 ... 3 {
                                for dx in -3 ... 3 {
                                    let v = mask.value(x + dx, y + dy, self)
                                    gx += v * Float(dx); gy += v * Float(dy)
                                }
                            }
                            let g = (gx * gx + gy * gy).squareRoot()
                            if g < 1e-3 { continue }
                            let nx = -gx / g, ny = -gy / g
                            let cx = Float(x) + 0.5, cy = Float(y) + 0.5
                            // Where exactly the half-way line crosses this line.
                            var cross: Float = 0
                            var before = a
                            var t: Float = 0.25
                            while t <= 2.01 {
                                let v = mask.sample(cx + nx * t, cy + ny * t, self)
                                if v < 0.5 {
                                    cross = t - 0.25 + 0.25 * (before - 0.5) / max(before - v, 1e-4)
                                    break
                                }
                                before = v
                                cross = t
                                t += 0.25
                            }
                            // The photo's colour along the line, three lines abreast to quieten grain.
                            for i in 0 ..< count {
                                let t = Float(i - half) * step + cross
                                let px = cx + nx * t, py = cy + ny * t
                                profile[i] = (colour(px, py) + colour(px - ny, py + nx) + colour(px + ny, py - nx)) * (1 / 3)
                                maskProfile[i] = (mask.sample(px, py, self) + mask.sample(px - ny, py + nx, self) + mask.sample(px + ny, py - nx, self)) * (1 / 3)
                            }
                            var best = -1
                            var bestScore: Float = 0
                            change[0] = 0; change[count - 1] = 0
                            for i in 1 ..< count - 1 {
                                let d = profile[i + 1] - profile[i - 1]
                                change[i] = dot3(d, d).squareRoot()
                                if abs(i - half) > search { continue }
                                // Of two changes as strong, the nearer one is the edge meant.
                                let away = Float(i - half) * step / reach
                                let score = change[i] * (1 - 0.5 * away * away)
                                if score > bestScore { bestScore = score; best = i }
                            }
                            if best < 1 { continue }
                            // What the change is like away from the edge: at the two ends of the
                            // line, where a clear edge has died away. (The middle value along
                            // the line was used at first; across an edge six or eight pixels
                            // wide, a hand a little out of focus, half the line is edge, and
                            // such edges all read as unclear.)
                            let typical = (change[1] + change[2] + change[3] + change[count - 2] + change[count - 3] + change[count - 4]) / 6
                            let peak = change[best]
                            // Between samples: the top of the curve through the three around the peak.
                            var fine: Float = 0
                            if best > 1 && best < count - 2 {
                                let l = change[best - 1], r = change[best + 1]
                                let bend = l - 2 * peak + r
                                if bend < -1e-6 { fine = min(max(0.5 * (l - r) / bend, -0.5), 0.5) }
                            }
                            let at = (Float(best - half) + fine) * step
                            // How wide the photo's edge is: what it rises by across the hump of
                            // change around the peak, over its steepest slope. (A straight ramp
                            // comes out as its own width.) And the mask's, measured the same way.
                            var rise = peak * step
                            var i = best - 1
                            while i >= 1 && change[i] > 0.3 * peak { rise += change[i] * step; i -= 1 }
                            i = best + 1
                            while i < count - 1 && change[i] > 0.3 * peak { rise += change[i] * step; i += 1 }
                            let photoWidth = rise / max(peak, 1e-6)
                            var steepest: Float = 1e-3
                            for i in 1 ..< count - 1 { steepest = max(steepest, abs(maskProfile[i + 1] - maskProfile[i - 1])) }
                            let maskWidth = abs(maskProfile[count - 1] - maskProfile[0]) / steepest
                            // The colours either side: three quarters of the edge's width and a
                            // pixel and a half clear of its middle, where the blur has died away.
                            let clear = Int(((0.75 * min(photoWidth, 8) + 1.5) / step).rounded())
                            let iIn = max(best - clear, 1), iOut = min(best + clear, count - 2)
                            let inner = (profile[iIn] + profile[iIn - 1]) * 0.5, outer = (profile[iOut] + profile[iOut + 1]) * 0.5
                            let onEdge = abs(best - half) < search
                            let confidence = onEdge ? smoothstep(floorStrength, 3 * floorStrength, peak) * smoothstep(2, 4, peak / max(typical, 1e-4)) : 0
                            let inHair = min(max(sample1(hair, x, y), 0), 1)
                            let sharp = focus.map { sample1($0, x, y) } ?? 1
                            // The line was laid out from the crossing, so the distance from the
                            // strongest change to the half-way line is just minus where it was found.
                            found.append(EdgePoint(x: Int32(x), y: Int32(y), nx: nx, ny: ny, offset: -at, photoWidth: photoWidth, maskWidth: maskWidth,
                                                   inner: inner, outer: outer, confidence: confidence, hair: inHair, sharp: sharp))
                        }
                    }
                }
            }
            lock.lock()
            all.append(contentsOf: found)
            lock.unlock()
        }
        return all
    }

    /// How far either side of the mask's edge the photo's is looked for, in photo pixels:
    /// a model pixel and a half, within limits.
    var edgeReach: Float { min(max(settings.recentreReach * firstPassPixel, settings.recentreLeast), settings.recentreMost) }

    /// The figure for the log: over clear edges away from hair and in focus.
    static func offsetSummary(_ points: [EdgePoint]) -> EdgeOffset {
        var out = EdgeOffset()
        var sum = 0.0, size = 0.0, far = 0, own = 0.0, photo = 0.0
        for p in points where p.hair <= 0.02 {
            out.points += 1
            if p.confidence < 0.5 || p.sharp < 0.5 { continue }
            out.measured += 1
            sum += Double(p.offset); size += Double(abs(p.offset))
            own += Double(p.maskWidth); photo += Double(p.photoWidth)
            if abs(p.offset) > 1.5 { far += 1 }
        }
        if out.measured >= 50 {
            let n = Double(out.measured)
            out.mean = Float(sum / n)
            out.spread = Float(size / n)
            out.far = Float(far) / Float(out.measured)
            out.maskWidth = Float(own / n)
            out.photoWidth = Float(photo / n)
        }
        return out
    }

    /// How far a finished mask's edge sits from the photo's.
    func edgeOffset(of alpha8: Buf<UInt8>) -> EdgeOffset {
        let reach = edgeReach
        let mask = AlphaSource(floats: nil, bytes: alpha8.p, rect: PixelRect(x: 0, y: 0, w: W, h: H))
        return Matte.offsetSummary(edgePoints(mask, reach: reach))
    }

    /// Puts the first-pass edge where the photo's is, and makes it as wide as the photo's
    /// (the final masking round, priority 1). `out` holds the first-pass mask enlarged over
    /// the band, not yet steepened.
    ///
    /// Enlarged from a model that saw a third of the detail, the mask's edge is a ramp six
    /// to eight photo pixels wide, and its half-way line sits up to a model pixel off the
    /// true boundary. The photo's edge is two or three pixels wide. What is left over shows
    /// as a rim of background, the same width all round. Along the half-way line the
    /// photo's steepest colour change is found, and how wide the photo's edge is there;
    /// both are smoothed along the edge (one point may be wrong, a stretch of them is not).
    /// Every pixel near the edge then takes the mask's value from that far across it, made
    /// steeper by as much as the photo's edge is narrower than the mask's. What is joined
    /// to what stays as it was; only where the edge sits and how wide it is change.
    /// In hair and out of focus there is no one boundary to find: nothing moves there, and
    /// the edge is left as soft as the model had it. Where an edge can't be measured (the
    /// two sides too alike), it is steepened by `settings.steepen`, as before.
    func recentre(_ out: Buf<Float>, spans: [(lo: Int, hi: Int)]) {
        let band = band0, bw = band.w, bh = band.h, qw = self.qw, qh = self.qh
        if band.isEmpty { return }
        let reach = edgeReach
        let source = Buf(out.array)
        let mask = AlphaSource(floats: source.p, bytes: nil, rect: band)
        let points = edgePoints(mask, reach: reach)
        offsetBefore = Matte.offsetSummary(points)

        // What was found, gathered at quarter size and smoothed along the edge. A point far
        // from what its neighbours say has found some other line (a nail, a seam, a shadow);
        // it is left out and the smoothing done again.
        let n = qw * qh
        let r = max(Int((settings.recentreSmooth * firstPassPixel / 4).rounded()), 2)
        let least = settings.gainLeast, most = settings.gainMost
        var field = [Float](repeating: 0, count: n), gains = [Float](repeating: 0, count: n), weight = [Float](repeating: 0, count: n)
        var colours = [[Float]](repeating: [Float](repeating: 0, count: n), count: 6)
        var widths = [Float](repeating: 0, count: n)
        func gather(_ keep: (EdgePoint) -> Bool) {
            for i in 0 ..< n { field[i] = 0; gains[i] = 0; weight[i] = 0; widths[i] = 0 }
            for c in 0 ..< 6 { for i in 0 ..< n { colours[c][i] = 0 } }
            for p in points where p.confidence > 0 && keep(p) {
                let cell = (Int(p.y) >> 2) * qw + (Int(p.x) >> 2)
                field[cell] += p.offset * p.confidence
                gains[cell] += Foundation.log(min(max(p.maskWidth / max(p.photoWidth, 0.5), least), most)) * p.confidence
                weight[cell] += p.confidence
                widths[cell] += min(p.maskWidth, 16) * p.confidence
                for c in 0 ..< 3 {
                    colours[c][cell] += p.inner[c] * p.confidence
                    colours[3 + c][cell] += p.outer[c] * p.confidence
                }
            }
            for _ in 0 ..< 2 {
                PlaneMath.boxBlur(&field, w: qw, h: qh, radius: r)
                PlaneMath.boxBlur(&gains, w: qw, h: qh, radius: r)
                PlaneMath.boxBlur(&weight, w: qw, h: qh, radius: r)
                PlaneMath.boxBlur(&widths, w: qw, h: qh, radius: r)
                for c in 0 ..< 6 { PlaneMath.boxBlur(&colours[c], w: qw, h: qh, radius: r) }
            }
        }
        gather { _ in true }
        let first = field, firstWeight = weight
        gather { p in
            let cell = (Int(p.y) >> 2) * qw + (Int(p.x) >> 2)
            let w = firstWeight[cell]
            return w > 1e-6 && abs(p.offset - first[cell] / w) <= 1.5
        }
        // How much evidence a place needs before it is believed: a few clear points nearby.
        let cells = Float(2 * r + 1)
        let enough = 3 / (cells * cells)
        let shift = Buf<Float>(n, 0), gain = Buf<Float>(n, 0), known = Buf<Float>(n, 0), spread = Buf<Float>(n, 0)
        var moved = 0.0, steepened = 0.0, measuredCells = 0
        for i in 0 ..< n where weight[i] > 1e-6 {
            let trust = smoothstep(0.25 * enough, enough, weight[i])
            shift.p[i] = min(max(field[i] / weight[i], -reach), reach) * trust
            gain.p[i] = exp(gains[i] / weight[i])
            // Wider, where the photo's edge is wider than the mask's: by a blur across the
            // edge this many pixels long, which turns the mask's width into the photo's.
            if gain.p[i] < 1 {
                let own = widths[i] / weight[i]
                spread.p[i] = min(own * (1 / (gain.p[i] * gain.p[i]) - 1).squareRoot(), 2 * reach) * trust
            }
            known.p[i] = trust
            if tri0.p[i] == 1 && trust > 0.5 { moved += Double(shift.p[i]); steepened += Double(gain.p[i]); measuredCells += 1 }
        }
        // The colours either side of the edge, read off the photo right beside it, replace
        // the ones spread in from the certain areas wherever the edge could be measured:
        // a finger's edge is in shadow, and darker than the skin a dozen pixels in.
        let fLocal = Buf(fq.array), bLocal = Buf(bq.array)
        let hairCells = hairFaces.p, focusCells = focusQ?.p
        for i in 0 ..< n where known.p[i] > 0 {
            let firm = known.p[i] * (1 - min(max(hairCells[i], 0), 1)) * (focusCells?[i] ?? 1)
            if firm <= 0 { continue }
            for c in 0 ..< 3 {
                // (Kept as display values, like the fields they stand in for.)
                let f = pow(min(max(colours[c][i] / weight[i], 0), 1), 1 / 2.2), b = pow(min(max(colours[3 + c][i] / weight[i], 0), 1), 1 / 2.2)
                fLocal.p[i * 3 + c] += (f - fLocal.p[i * 3 + c]) * firm
                bLocal.p[i * 3 + c] += (b - bLocal.p[i * 3 + c]) * firm
            }
        }
        fEdge = fLocal
        bEdge = bLocal

        let hair = hairQ.p, focus = focusQ?.p, tq = tri0.p
        let fallback = max(settings.steepen, 1)
        let stripRows = 128, blur = 3
        let apron = 4 * blur + Int(reach.rounded(.up)) + 2
        let lock = NSLock()
        var changed = 0
        parallel(spans.count) { s in
            let y0 = s * stripRows, y1 = min(y0 + stripRows, bh)
            var x0 = spans[s].lo, x1 = spans[s].hi
            if x1 < x0 { return }
            x0 = max(x0 - apron, 0); x1 = min(x1 + apron, bw - 1)
            let sw = x1 - x0 + 1
            let ey0 = max(y0 - apron, 0), ey1 = min(y1 + apron, bh)
            let eh = ey1 - ey0
            var soft = [Float](repeating: 0, count: sw * eh)
            for yy in 0 ..< eh {
                for xx in 0 ..< sw { soft[yy * sw + xx] = source.p[(ey0 + yy) * bw + x0 + xx] }
            }
            PlaneMath.boxBlur(&soft, w: sw, h: eh, radius: blur)
            PlaneMath.boxBlur(&soft, w: sw, h: eh, radius: blur)
            var count = 0
            for y in y0 ..< y1 {
                let py = band.y + y
                let ly = y - ey0
                for xx in 0 ..< sw where tq[(py >> 2) * qw + ((band.x + x0 + xx) >> 2)] == 1 {
                    let px = band.x + x0 + xx
                    let at = y * bw + x0 + xx
                    // Hair and anything out of focus really are soft; they are left as they are.
                    let sharp = focus.map { sample1($0, px, py) } ?? 1
                    let firm = sharp * (1 - min(max(sample1(hair, px, py), 0), 1))
                    let sure = min(max(sample1(known.p, px, py), 0), 1)
                    var value = source.p[at]
                    let d = sample1(shift.p, px, py) * firm
                    let wider = sample1(spread.p, px, py) * firm
                    if (abs(d) >= 0.05 || wider >= 0.3) && ly >= 1 && ly < eh - 1 && xx >= 1 && xx < sw - 1 {
                        let i = ly * sw + xx
                        let gx = soft[i + 1] - soft[i - 1], gy = soft[i + sw] - soft[i - sw]
                        let g = (gx * gx + gy * gy).squareRoot()
                        if g >= 1e-4 {
                            let nx = -gx / g, ny = -gy / g
                            let cx = Float(px) + 0.5 + nx * d, cy = Float(py) + 0.5 + ny * d
                            // The value from `d` pixels further out (or in, when it is negative)...
                            value = mask.sample(cx, cy, self)
                            // ...and, to widen, the average along a short line across the edge there.
                            if wider >= 0.3 {
                                var sum = value
                                for k in 1 ... 3 {
                                    let t = wider * Float(k) / 6
                                    sum += mask.sample(cx + nx * t, cy + ny * t, self) + mask.sample(cx - nx * t, cy - ny * t, self)
                                }
                                value = sum / 7
                            }
                        }
                    }
                    let wanted = fallback + (max(sample1(gain.p, px, py), 1) - fallback) * sure
                    let steep = 1 + (wanted - 1) * firm
                    value = min(max(0.5 + (value - 0.5) * steep, 0), 1)
                    if abs(value - min(max(0.5 + (source.p[at] - 0.5) * (1 + (fallback - 1) * firm), 0), 1)) > 0.02 { count += 1 }
                    out.p[at] = value
                }
            }
            lock.lock()
            changed += count
            lock.unlock()
        }
        let posix = Locale(identifier: "en_US_POSIX")
        let cellsMeasured = Double(max(measuredCells, 1))
        recentreNote = " · first pass: " + offsetBefore.summary
            + String(format: " · re-centred: looked ±%.1f px, mean move %+.2f px, mean steepening ×%.2f, \(changed) px differ from plain steepening",
                     locale: posix, reach, moved / cellsMeasured, steepened / cellsMeasured)
    }
}
