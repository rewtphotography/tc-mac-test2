import CoreGraphics
import Foundation
import TraincullCore

/// Masks written to disk under memory pressure and read back when their frame is shown or
/// exported (spec v6 addendum: masks were being dropped after two photos, taking their tool
/// operations and local adjustments with them). Everything lives in one folder under
/// ~/Library/Caches/TrainCull, emptied when a folder is opened, when the app quits and
/// when it starts (after a crash).
enum MaskSpill {
    struct Failure: Error, CustomStringConvertible {
        let description: String
        init(_ message: String) { description = message }
    }

    /// What comes back from disk.
    struct Read {
        let mask: MaskResult
        let automatic: MaskResult
        let undos: [RefineUndo]
    }

    static var root: URL {
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory())
        return caches.appendingPathComponent("TrainCull", isDirectory: true).appendingPathComponent("masks", isDirectory: true)
    }

    /// A fresh folder for one frame's mask.
    static func folder(for id: Int) -> URL {
        root.appendingPathComponent("frame-\(id)-\(UUID().uuidString.prefix(8))", isDirectory: true)
    }

    /// Empties the cache folder. Returns how many masks were in it.
    @discardableResult
    static func clear() -> Int {
        let fm = FileManager.default
        let had = (try? fm.contentsOfDirectory(atPath: root.path).count) ?? 0
        if had > 0 { try? fm.removeItem(at: root) }
        return had
    }

    /// How much a folder holds on disk.
    static func size(of folder: URL) -> UInt64 {
        let fm = FileManager.default
        guard let names = try? fm.contentsOfDirectory(atPath: folder.path) else { return 0 }
        return names.reduce(0) { sum, name in
            sum + ((try? fm.attributesOfItem(atPath: folder.appendingPathComponent(name).path)[.size] as? NSNumber)?.uint64Value ?? 0)
        }
    }

    // MARK: Writing

    static func write(mask: MaskResult, automatic: MaskResult, undos: [RefineUndo], to folder: URL) throws {
        let fm = FileManager.default
        try fm.createDirectory(at: folder, withIntermediateDirectories: true)
        var meta: [String: Any] = [:]
        meta["mask"] = try write(mask, as: "mask", in: folder)
        if automatic === mask {
            meta["automaticIsMask"] = true
        } else {
            meta["automatic"] = try write(automatic, as: "automatic", in: folder)
        }
        meta["undos"] = try write(undos, as: "undo", in: folder)
        let json = try JSONSerialization.data(withJSONObject: meta, options: [.sortedKeys])
        try json.write(to: folder.appendingPathComponent("meta.json"), options: .atomic)
    }

    private static func write(_ mask: MaskResult, as name: String, in folder: URL) throws -> [String: Any] {
        var entry: [String: Any] = ["width": mask.width, "height": mask.height, "tier": mask.tier.rawValue, "summary": mask.summary]
        entry["alpha"] = try write(mask.alpha, "\(name)-alpha", folder)
        entry["shares"] = try write(mask.shares, "\(name)-shares", folder)
        entry["trimap"] = try write(mask.trimap, "\(name)-trimap", folder)
        entry["coarse"] = try write(mask.coarse, "\(name)-coarse", folder)
        if let skin = mask.skin { entry["skin"] = try write(skin, "\(name)-skin", folder) }
        if let debug = mask.debug { entry["debug"] = try write(debug, "\(name)-debug", folder) }
        entry["beforeHands"] = try write(mask.beforeHands, as: "\(name)-hand", in: folder)
        return entry
    }

    private static func write(_ undos: [RefineUndo], as name: String, in folder: URL) throws -> [[String: Any]] {
        var list: [[String: Any]] = []
        for (n, undo) in undos.enumerated() {
            let a = "\(name)\(n)-alpha.raw", s = "\(name)\(n)-shares.raw"
            try Data(undo.alpha).write(to: folder.appendingPathComponent(a))
            try Data(undo.shares).write(to: folder.appendingPathComponent(s))
            list.append(["x": undo.rect.x, "y": undo.rect.y, "w": undo.rect.w, "h": undo.rect.h, "alpha": a, "shares": s])
        }
        return list
    }

    /// A picture's bytes as they are, with what is needed to make the same picture again.
    private static func write(_ image: CGImage, _ name: String, _ folder: URL) throws -> [String: Any] {
        guard let data = image.dataProvider?.data else { throw Failure("a mask picture had no pixels to write") }
        let file = "\(name).raw"
        try (data as Data).write(to: folder.appendingPathComponent(file))
        let gray = image.colorSpace?.model == .monochrome
        return ["file": file, "w": image.width, "h": image.height, "bpc": image.bitsPerComponent, "bpp": image.bitsPerPixel,
                "bpr": image.bytesPerRow, "info": Int(image.bitmapInfo.rawValue), "gray": gray]
    }

    // MARK: Reading

    static func read(_ folder: URL) throws -> Read {
        let data = try Data(contentsOf: folder.appendingPathComponent("meta.json"))
        guard let meta = try JSONSerialization.jsonObject(with: data) as? [String: Any], let m = meta["mask"] as? [String: Any] else {
            throw Failure("the mask's description on disk couldn't be read")
        }
        let mask = try read(m, folder)
        var automatic = mask
        if meta["automaticIsMask"] as? Bool != true {
            guard let a = meta["automatic"] as? [String: Any] else { throw Failure("the automatic mask is missing on disk") }
            automatic = try read(a, folder)
        }
        let undos = try readUndos(meta["undos"], folder)
        return Read(mask: mask, automatic: automatic, undos: undos)
    }

    private static func read(_ entry: [String: Any], _ folder: URL) throws -> MaskResult {
        guard let w = entry["width"] as? Int, let h = entry["height"] as? Int,
              let a = entry["alpha"] as? [String: Any], let s = entry["shares"] as? [String: Any],
              let t = entry["trimap"] as? [String: Any], let c = entry["coarse"] as? [String: Any] else {
            throw Failure("a mask on disk is incomplete")
        }
        let tier = MatteTier(rawValue: entry["tier"] as? Int ?? 0) ?? .off
        let skin = try (entry["skin"] as? [String: Any]).map { try picture($0, folder) }
        let debug = try (entry["debug"] as? [String: Any]).map { try picture($0, folder) }
        return MaskResult(width: w, height: h, alpha: try picture(a, folder), shares: try picture(s, folder), skin: skin,
                          trimap: try picture(t, folder), coarse: try picture(c, folder), debug: debug, tier: tier,
                          summary: entry["summary"] as? String ?? "", beforeHands: try readUndos(entry["beforeHands"], folder))
    }

    private static func readUndos(_ value: Any?, _ folder: URL) throws -> [RefineUndo] {
        guard let list = value as? [[String: Any]] else { return [] }
        return try list.map { u in
            guard let x = u["x"] as? Int, let y = u["y"] as? Int, let w = u["w"] as? Int, let h = u["h"] as? Int,
                  let a = u["alpha"] as? String, let s = u["shares"] as? String else { throw Failure("an undo step on disk is incomplete") }
            let alpha = try Data(contentsOf: folder.appendingPathComponent(a)), shares = try Data(contentsOf: folder.appendingPathComponent(s))
            guard alpha.count == w * h, shares.count == w * h * 4 else { throw Failure("an undo step on disk is the wrong size") }
            return RefineUndo(rect: PixelRect(x: x, y: y, w: w, h: h), alpha: [UInt8](alpha), shares: [UInt8](shares))
        }
    }

    private static func picture(_ e: [String: Any], _ folder: URL) throws -> CGImage {
        guard let file = e["file"] as? String, let w = e["w"] as? Int, let h = e["h"] as? Int, let bpc = e["bpc"] as? Int,
              let bpp = e["bpp"] as? Int, let bpr = e["bpr"] as? Int, let info = e["info"] as? Int else {
            throw Failure("a mask picture on disk is described incompletely")
        }
        let data = try Data(contentsOf: folder.appendingPathComponent(file))
        guard data.count >= bpr * (h - 1) + w * bpp / 8, let provider = CGDataProvider(data: data as CFData) else {
            throw Failure("a mask picture on disk is the wrong size")
        }
        let gray = e["gray"] as? Bool ?? (bpp == 8)
        let space = gray ? CGColorSpaceCreateDeviceGray() : CGColorSpaceCreateDeviceRGB()
        guard let image = CGImage(width: w, height: h, bitsPerComponent: bpc, bitsPerPixel: bpp, bytesPerRow: bpr, space: space,
                                  bitmapInfo: CGBitmapInfo(rawValue: UInt32(info)), provider: provider, decode: nil,
                                  shouldInterpolate: true, intent: .defaultIntent) else {
            throw Failure("a mask picture on disk couldn't be made into a picture again")
        }
        return image
    }
}
