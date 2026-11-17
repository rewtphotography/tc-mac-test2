import AppKit
import CoreGraphics
import Foundation
import TraincullCore

/// The mask tools (masking spec v5, section 2).
enum MaskTool: String, CaseIterable {
    case none, edges, hair, clean

    var name: String {
        switch self {
        case .none: return "Off"
        case .edges: return "Refine Edges"
        case .hair: return "Refine Hair"
        case .clean: return "Clean Edge"
        }
    }

    var hint: String {
        switch self {
        case .none: return ""
        case .edges: return "Drag a box round fingers, footwear, a gap or a prop's edge. Hold Option while dragging to put the automatic mask back inside the box."
        case .hair: return "Paint over curls or flowing hair. Hold Option while painting to put the automatic mask back."
        case .clean: return "Paint along a hard edge that still has a rim. Hold Option while painting to put the automatic mask back."
        }
    }
}

/// How Refine Hair picks its method.
enum HairMethod: String, CaseIterable {
    case auto, colour, model

    var name: String {
        switch self {
        case .auto: return "Automatic"
        case .colour: return "Colour matting"
        case .model: return "Matting model"
        }
    }
}

/// One thing a tool did: kept so it can be drawn, undone, and done again after a Remake.
struct RefineOp {
    var tool: MaskTool
    var box: PixelRect?
    var stroke: RefineStroke?
    /// Option was held: put the automatic mask back here.
    var restore: Bool
    var clean = CleanSettings()

    var mark: HeroNSView.Mark {
        if let box = box { return .box(CGRect(x: box.x, y: box.y, width: box.w, height: box.h), restore: restore) }
        let points = (stroke?.points ?? []).map { CGPoint(x: CGFloat($0.x), y: CGFloat($0.y)) }
        return .stroke(points, radius: CGFloat(stroke?.radius ?? 1), restore: restore)
    }
}

/// What a tool replaced, to put back on Undo.
struct RefineUndo {
    let rect: PixelRect
    let alpha: [UInt8]
    let shares: [UInt8]
}

/// The settings the tools run with.
struct RefineOptions {
    var settings = MatteSettings()
    var hairMethod = HairMethod.auto
    var contrastNeeded: Float = 0.5
    var textureAllowed: Float = 0.03
}

extension Masking {
    /// A picture's bytes, when it has exactly the plain layout the mask pictures are made with.
    static func bytes(of image: CGImage, count: Int) -> [UInt8]? {
        guard image.bytesPerRow * image.height == count, let data = image.dataProvider?.data, CFDataGetLength(data) >= count,
              let p = CFDataGetBytePtr(data) else { return nil }
        return Array(UnsafeBufferPointer(start: p, count: count))
    }

    /// A model's reading of one area of the full-size photo. In one pass (the area squeezed
    /// to the model's size), or `tiled`: in overlapping tiles no larger than 1536 pixels, so
    /// the model sees at least four times the detail it had of the whole frame.
    static func look(_ model: BiRefNetModel, reference: CGImage, area: PixelRect, tiled: Bool, what: String) throws -> Gray {
        let side = model.inputSide
        func picture(_ r: PixelRect) throws -> CGImage {
            guard let crop = reference.cropping(to: CGRect(x: r.x, y: r.y, width: r.w, height: r.h)), let shown = square(of: crop, side: side) else {
                throw Failure("the area couldn't be cut from the photo")
            }
            return shown
        }
        if !tiled { return try model.segment(try picture(area), what: "\(what) (\(area.w)×\(area.h) px)") }
        var rules = SubjectRules()
        rules.tileCap = min(1536, min(area.w, area.h))
        rules.tileLeast = min(512, min(area.w, area.h))
        rules.tilesMost = 12
        let grid = CloseUps.tiles(covering: Box(x0: 0, y0: 0, x1: area.w, y1: area.h), w: area.w, h: area.h, rules: rules)
        let tileSide = max(grid.first.map { $0.x1 - $0.x0 } ?? area.w, 1)
        let k = min(Float(side) / Float(tileSide), 1)
        var canvas = CloseUps.Canvas(w: max(Int(Float(area.w) * k), 1), h: max(Int(Float(area.h) * k), 1), scale: k)
        for (n, tile) in grid.enumerated() {
            let r = PixelRect(x: area.x + tile.x0, y: area.y + tile.y0, w: tile.x1 - tile.x0, h: tile.y1 - tile.y0)
            let answer = try model.segment(try picture(r), what: "\(what) tile \(n + 1)/\(grid.count) (\(r.w)×\(r.h) px)")
            canvas.add(answer, box: tile, feather: 48)
        }
        return canvas.average()
    }

    /// Whether an area is large enough that one pass is not the model's best look at it.
    static func wantsTiles(_ area: PixelRect) -> Bool { max(area.w, area.h) > 1840 }

    private static func union(_ a: PixelRect?, _ b: PixelRect) -> PixelRect {
        guard let a = a else { return b }
        let x0 = min(a.x, b.x), y0 = min(a.y, b.y), x1 = max(a.maxX, b.maxX), y1 = max(a.maxY, b.maxY)
        return PixelRect(x: x0, y: y0, w: x1 - x0, h: y1 - y0)
    }

    private static func region(_ bytes: [UInt8], width W: Int, _ r: PixelRect, channels: Int) -> [UInt8] {
        var out = [UInt8](repeating: 0, count: r.w * r.h * channels)
        for y in 0 ..< r.h {
            let from = ((r.y + y) * W + r.x) * channels, to = y * r.w * channels
            out.replaceSubrange(to ..< to + r.w * channels, with: bytes[from ..< from + r.w * channels])
        }
        return out
    }

    /// A mask with new alpha and shares, everything else as it was.
    private static func rebuilt(_ mask: MaskResult, alpha: [UInt8], shares: [UInt8], summary: String) throws -> MaskResult {
        guard let a = picture(gray: alpha, w: mask.width, h: mask.height), let s = picture(rgbx: shares, w: mask.width, h: mask.height) else {
            throw Failure("the mask couldn't be stored")
        }
        return MaskResult(width: mask.width, height: mask.height, alpha: a, shares: s, skin: mask.skin, trimap: mask.trimap, coarse: mask.coarse,
                          debug: mask.debug, tier: mask.tier, edge: mask.edge, summary: summary, beforeHands: mask.beforeHands)
    }

    /// Applies one tool operation to a frame's mask. `automatic` is the mask as Make Mask left
    /// it, for Option-restore. `partial` is handed the quick result when a slower, better one
    /// follows. Returns the new mask and what to put back on Undo.
    static func refine(url: URL, mask: MaskResult, automatic: MaskResult, op: RefineOp, options: RefineOptions, faces known: DetectedFaces?,
                       rules: SubjectRules, subject: SubjectSource, progress: (String) -> Void,
                       partial: ((MaskResult) -> Void)?) throws -> (mask: MaskResult, undo: RefineUndo) {
        let started = CFAbsoluteTimeGetCurrent()
        let name = url.lastPathComponent
        let reference = try neutral(url)
        let W = reference.width, H = reference.height
        guard mask.width == W, mask.height == H, let alpha0 = bytes(of: mask.alpha, count: W * H),
              let shares0 = bytes(of: mask.shares, count: W * H * 4) else { throw Failure("the mask doesn't fit this photo") }
        // The same faces, sharpness and photo the automatic mask was made from.
        let found = try base(reference: reference, name: name, key: baseKey(url, subject, rules), faces: known, rules: rules, subject: subject, progress: progress)
        var kept: Photo?
        keptLock.lock()
        if let engine = keptMatte, engine.base === found { kept = engine.matte.photo }
        keptLock.unlock()
        guard let photo = kept ?? Masking.photo(from: reference) else { throw Failure("the rendered photo isn't in the expected 8-bit form") }
        let context = RefineContext(photo: photo, faces: found.faces, defocus: found.ranking.sharpness?.dense,
                                    subjectSharpness: found.ranking.primary?.sharp, settings: options.settings)

        var alpha = alpha0, shares = shares0
        var touched: PixelRect?
        var notes: [String] = []
        var changed = 0, corrections = 0
        var method = op.tool.name
        /// Lays a result into a fresh copy of the mask as it was before this operation.
        func lay(_ result: RefineResult) {
            alpha = alpha0
            shares = shares0
            changed = Refine.paste(result.output, at: result.patch, weight: result.weight, alpha: &alpha, shares: &shares, width: W)
            corrections = result.output.guardCorrections
            touched = union(touched, result.patch)
            notes = result.log
        }
        func show(_ what: String) {
            guard let partial = partial, let quick = try? rebuilt(mask, alpha: alpha, shares: shares, summary: "\(op.tool.name): \(what)…") else { return }
            partial(quick)
        }

        if op.restore {
            // Option: the automatic mask back, inside the box or under the stroke.
            guard let baseAlpha = bytes(of: automatic.alpha, count: W * H), let baseShares = bytes(of: automatic.shares, count: W * H * 4) else {
                throw Failure("the automatic mask isn't to hand")
            }
            let area: PixelRect, weight: Gray
            if let box = op.box {
                area = box
                weight = Refine.weight(box: box, in: box, feather: 1)
            } else if let stroke = op.stroke {
                area = Refine.bounds(of: stroke, w: W, h: H)
                weight = Refine.weight(stroke: stroke, in: area)
            } else {
                throw Failure("nothing was drawn")
            }
            changed = Refine.restore(weight: weight, at: area, baseAlpha: baseAlpha, baseShares: baseShares, alpha: &alpha, shares: &shares, width: W)
            touched = area
            method = "\(op.tool.name), restore"
            notes = ["the automatic mask put back"]
        } else {
            switch op.tool {
            case .edges:
                guard var box = op.box else { throw Failure("no box was drawn") }
                var latest: RefineResult?
                var grown = 0
                var stopped = "the subject stays inside the box"
                while true {
                    let area = Refine.lookArea(box: box, w: W, h: H)
                    progress("Looking closer")
                    let answer = try look(.shared, reference: reference, area: area, tiled: false, what: "\(name) box")
                    let made = Refine.edges(box: box, look: area, answer: answer, alpha: alpha0, context: context)
                    latest = made
                    let off = made.runsOff
                    if !(off.left || off.right || off.top || off.bottom) { break }
                    if grown >= 4 { stopped = "four extensions made"; break }
                    if CFAbsoluteTimeGetCurrent() - started > 6 { stopped = "out of time (6 s)"; break }
                    // Half as large again towards wherever the subject runs off: a staff or a sword is followed.
                    let dx = box.w / 2, dy = box.h / 2
                    let x0 = off.left ? box.x - dx : box.x, y0 = off.top ? box.y - dy : box.y
                    let x1 = off.right ? box.maxX + dx : box.maxX, y1 = off.bottom ? box.maxY + dy : box.maxY
                    let wider = PixelRect(x: x0, y: y0, w: x1 - x0, h: y1 - y0).clamped(w: W, h: H)
                    if wider == box { stopped = "the photo's edge reached"; break }
                    box = wider
                    grown += 1
                    Log.note("tool", "\(name): box grown to \(box.w)×\(box.h) px (\(off.left ? "left " : "")\(off.top ? "up " : "")\(off.right ? "right " : "")\(off.bottom ? "down" : ""))")
                }
                guard let result = latest else { throw Failure("the box couldn't be worked on") }
                lay(result)
                let area = Refine.lookArea(box: box, w: W, h: H)
                let detail = 100 * Double(min(BiRefNetModel.shared.inputSide, max(area.w, area.h))) / Double(max(area.w, area.h))
                var passes = "one pass, the model saw \(Int(detail))% of the photo's detail"
                if wantsTiles(area) {
                    show("first look")
                    progress("Looking closer, in tiles")
                    let single = changed
                    let fine = try look(.shared, reference: reference, area: area, tiled: true, what: "\(name) box")
                    var covered = 0
                    for v in fine.v where v >= 0.5 { covered += 1 }
                    let share = 100 * Double(covered) / Double(max(fine.v.count, 1))
                    lay(Refine.edges(box: box, look: area, answer: fine, alpha: alpha0, context: context))
                    let tiled = changed
                    passes = "one pass (\(single) px changed), then tiles of up to 1536 px (\(tiled) px changed; the tiles call "
                        + String(format: "%.0f", locale: Locale(identifier: "en_US_POSIX"), share) + "% of the area subject)"
                    // Alpha 14 once reported a tiled box as "0 px changed" where the single
                    // look had changed thousands. It could not be reproduced from the
                    // engine's side; if it happens the single look stands, and the log says so.
                    if tiled == 0 && single > 0 {
                        Log.warn("\(name): TILES? the tiled look changed nothing where the single look changed \(single) px; the single look is kept")
                        lay(result)
                        passes += " · the tiles changed nothing: the single look is kept"
                    }
                }
                notes.insert("\(passes) · growth: \(grown) extension(s), \(stopped)", at: 0)
            case .clean:
                guard let stroke = op.stroke else { throw Failure("no stroke was painted") }
                lay(Refine.clean(stroke: stroke, alpha: alpha0, context: context, clean: op.clean))
            case .hair:
                guard let stroke = op.stroke else { throw Failure("no stroke was painted") }
                let choice = Refine.hairChoice(stroke: stroke, alpha: alpha0, context: context,
                                               contrastNeeded: options.contrastNeeded, textureAllowed: options.textureAllowed)
                var colour = choice.colour
                var why = choice.why
                if options.hairMethod == .colour { colour = true; why = "colour matting, as set under Debug · " + choice.why }
                if options.hairMethod == .model { colour = false; why = "the matting model, as set under Debug · " + choice.why }
                if !colour && !BiRefNetModel.matting.isAvailable {
                    colour = true
                    why = "colour matting: the matting model isn't in this build · " + choice.why
                }
                if colour {
                    method = "Refine Hair, colour matting"
                    progress("Colour matting")
                    lay(Refine.hair(stroke: stroke, look: nil, answer: nil, alpha: alpha0, context: context, progress: progress))
                } else {
                    method = "Refine Hair, matting model"
                    let area = Refine.lookArea(stroke: stroke, w: W, h: H)
                    progress("Matting model")
                    let answer = try look(.matting, reference: reference, area: area, tiled: false, what: "\(name) hair")
                    lay(Refine.hair(stroke: stroke, look: area, answer: answer, alpha: alpha0, context: context))
                    if wantsTiles(area) {
                        show("first look")
                        progress("Matting model, in tiles")
                        let fine = try look(.matting, reference: reference, area: area, tiled: true, what: "\(name) hair")
                        lay(Refine.hair(stroke: stroke, look: area, answer: fine, alpha: alpha0, context: context))
                    }
                }
                notes.insert(why, at: 0)
            case .none:
                throw Failure("no tool is chosen")
            }
        }
        guard let rect = touched else { throw Failure("nothing was changed") }
        let undo = RefineUndo(rect: rect, alpha: region(alpha0, width: W, rect, channels: 1), shares: region(shares0, width: W, rect, channels: 4))
        let seconds = CFAbsoluteTimeGetCurrent() - started
        let summary = "\(method): \(changed) px changed in \(String(format: "%.2f", locale: Locale(identifier: "en_US_POSIX"), seconds)) s"
            + (corrections > 0 ? " · colour guard put \(corrections) px back" : "")
        Log.note("tool", "\(name): \(summary) · \(notes.joined(separator: " · "))",
                 fields: ["image": name, "tool": op.tool.rawValue, "method": method, "restore": op.restore, "pixels_changed": changed,
                          "colour_guard_corrections": corrections, "seconds": seconds])
        return (try rebuilt(mask, alpha: alpha, shares: shares, summary: summary), undo)
    }

    /// A mask with one operation taken back.
    static func undone(_ mask: MaskResult, _ undo: RefineUndo) throws -> MaskResult {
        let W = mask.width, H = mask.height
        guard var alpha = bytes(of: mask.alpha, count: W * H), var shares = bytes(of: mask.shares, count: W * H * 4) else {
            throw Failure("the mask couldn't be read")
        }
        let r = undo.rect
        for y in 0 ..< r.h {
            let to = (r.y + y) * W + r.x
            alpha.replaceSubrange(to ..< to + r.w, with: undo.alpha[y * r.w ..< (y + 1) * r.w])
            shares.replaceSubrange(to * 4 ..< (to + r.w) * 4, with: undo.shares[y * r.w * 4 ..< (y + 1) * r.w * 4])
        }
        return try rebuilt(mask, alpha: alpha, shares: shares, summary: "Undone")
    }
}
