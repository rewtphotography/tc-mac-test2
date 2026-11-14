import Foundation

/// File operations by name inside one folder. The crash-safe write logic lives in `Sidecars`
/// once; the app supplies the real file system and tests supply an in-memory folder.
public protocol DirOps {
    func exists(_ name: String) -> Bool
    func readText(_ name: String) -> String?

    /// Creates a new file (the name must be free), writes it and flushes it to the disk.
    func createAndWrite(_ name: String, _ bytes: [UInt8]) throws

    /// Renames `from` to `to`; `to` must not exist.
    func rename(_ from: String, _ to: String) throws
    func delete(_ name: String) throws

    /// Atomically replaces `to` with `from` if the volume can; false means unsupported.
    func replace(_ from: String, _ to: String) -> Bool
}

/// A port of the Android app's `card/Sidecars.kt`.
public enum Sidecars {
    public static let tmp = ".tmp"
    public static let bak = ".bak"

    /// Writes `text` to `xmpName` so that pulling the drive at any moment leaves a complete
    /// sidecar under some name: write a temp file first, then swap it in. `recover` cleans up
    /// after an interrupted swap.
    public static func write(_ d: DirOps, _ xmpName: String, _ text: String) throws {
        let tmpName = xmpName + tmp
        let bakName = xmpName + bak
        if d.exists(tmpName) { try d.delete(tmpName) }
        try d.createAndWrite(tmpName, Array(text.utf8))
        if !d.exists(xmpName) {
            try d.rename(tmpName, xmpName)
            return
        }
        if d.replace(tmpName, xmpName) { return }
        // No atomic replace: old → .bak, temp → .xmp, drop .bak.
        if d.exists(bakName) { try d.delete(bakName) }
        try d.rename(xmpName, bakName)
        try d.rename(tmpName, xmpName)
        try d.delete(bakName)
    }

    private static func hasSuffix(_ name: String, _ suffix: String) -> Bool {
        name.lowercased().hasSuffix(suffix.lowercased())
    }

    /// Repairs leftovers from an interrupted `write`. `names` are all file names in the folder.
    /// Returns a description of each repair, for the diagnostics log.
    @discardableResult
    public static func recover(_ d: DirOps, _ names: [String]) -> [String] {
        var actions: [String] = []
        var bases: [String] = []
        for n in names {
            var base: String?
            if hasSuffix(n, ".xmp" + tmp) {
                base = String(n.dropLast(tmp.count))
            } else if hasSuffix(n, ".xmp" + bak) {
                base = String(n.dropLast(bak.count))
            }
            if let b = base, !bases.contains(b) { bases.append(b) }
        }
        for xmp in bases {
            let tmpName = xmp + tmp
            let bakName = xmp + bak
            if d.exists(xmp) {
                if d.exists(tmpName) { try? d.delete(tmpName) }
                if d.exists(bakName) { try? d.delete(bakName) }
                actions.append("\(xmp): removed leftover temp files")
            } else if d.exists(tmpName), d.readText(tmpName).map(Xmp.isComplete) == true {
                guard (try? d.rename(tmpName, xmp)) != nil else { continue }
                if d.exists(bakName) { try? d.delete(bakName) }
                actions.append("\(xmp): restored from completed temp file")
            } else if d.exists(bakName) {
                guard (try? d.rename(bakName, xmp)) != nil else { continue }
                if d.exists(tmpName) { try? d.delete(tmpName) }
                actions.append("\(xmp): restored previous version")
            } else if d.exists(tmpName) {
                try? d.delete(tmpName)
                actions.append("\(xmp): removed incomplete temp file")
            }
        }
        return actions
    }
}

/// What a sidecar says: star rating (0 if none) and colour label text (nil if none).
public struct SidecarValues: Equatable {
    public var rating: Int
    public var label: String?

    public init(rating: Int, label: String?) {
        self.rating = rating
        self.label = label
    }
}

public struct SidecarError: Error, CustomStringConvertible {
    public let description: String
}

/// Reads and writes ratings and colour labels through any `DirOps`.
public enum Ratings {
    public static func read(_ d: DirOps, sidecarName: String?) -> SidecarValues? {
        guard let name = sidecarName, let text = d.readText(name) else { return nil }
        return SidecarValues(rating: Xmp.readRating(text) ?? 0, label: Xmp.readLabel(text))
    }

    /// Writes `rating` and `label` together, changing nothing else in an existing sidecar.
    /// Returns the sidecar's name, or nil if nothing needed writing and no sidecar exists.
    public static func write(_ d: DirOps, baseName: String, sidecarName: String?, _ values: SidecarValues) throws -> String? {
        let existingName = sidecarName.flatMap { d.exists($0) ? $0 : nil }
        if existingName == nil && values.rating == 0 && values.label == nil { return nil } // no sidecar and nothing to say
        let existing = existingName.flatMap { d.readText($0) }
        if existingName != nil && existing == nil {
            throw SidecarError(description: "\(existingName!): couldn't be read; left untouched")
        }
        guard let text = Xmp.withRating(existing, values.rating).flatMap({ Xmp.withLabel($0, values.label) }) else {
            throw SidecarError(description: "\(existingName ?? baseName): no rdf:Description to hold a rating; left untouched")
        }
        let name = existingName ?? (baseName + ".xmp")
        if text == existing { return name }
        try Sidecars.write(d, name, text)
        return name
    }
}

/// One field to set in a sidecar besides the rating and label; a nil value removes it.
public struct SidecarField {
    public let namespace: Xmp.Namespace
    public let name: String
    public let value: String?

    public init(_ namespace: Xmp.Namespace, _ name: String, _ value: String?) {
        self.namespace = namespace
        self.name = name
        self.value = value
    }
}

/// Writes adjustment values to a sidecar, changing nothing else in it.
public enum Edits {
    /// Returns the sidecar's name, or nil when there is no sidecar and nothing to write.
    public static func write(_ d: DirOps, baseName: String, sidecarName: String?, values: SidecarValues,
                             fields: [SidecarField]) throws -> String? {
        let existingName = sidecarName.flatMap { d.exists($0) ? $0 : nil }
        if existingName == nil && fields.allSatisfy({ $0.value == nil }) { return nil }
        let existing = existingName.flatMap { d.readText($0) }
        if existingName != nil && existing == nil {
            throw SidecarError(description: "\(existingName!): couldn't be read; left untouched")
        }
        var text = existing ?? Xmp.newSidecar(values.rating, values.label)
        for f in fields {
            guard let next = Xmp.withField(text, f.namespace, f.name, f.value) else {
                throw SidecarError(description: "\(existingName ?? baseName): no rdf:Description to hold the edits; left untouched")
            }
            text = next
        }
        let name = existingName ?? (baseName + ".xmp")
        if text == existing { return name }
        try Sidecars.write(d, name, text)
        return name
    }
}
