/// The finished raw renders kept so that going back to a frame shows it at once. It holds at
/// most `budget` bytes of pictures; the one shown least recently goes first. One render per
/// frame: a new one replaces the frame's old one.
public struct RenderCache<Picture> {
    public struct Entry {
        public let id: Int
        public let values: [String: Float]
        public let picture: Picture
        public let bytes: Int
    }

    public enum Miss: String {
        /// Never rendered since the folder was opened.
        case cold
        /// Rendered, then let go to keep within the budget.
        case evicted = "evicted (LRU)"
        /// Kept, but with other edits than the ones asked for.
        case edited = "kept with other edits"
    }

    public enum Lookup {
        case hit(Picture)
        case miss(Miss)
    }

    public let budget: Int
    /// Least recently shown first.
    public private(set) var entries: [Entry] = []
    /// Renders let go since this was last reset by the caller (for the regular summary).
    public var evictions = 0
    private var evicted = Set<Int>()

    public init(budget: Int) {
        self.budget = budget
    }

    public var bytes: Int { entries.reduce(0) { $0 + $1.bytes } }
    public var count: Int { entries.count }

    /// The frame's render with exactly these edits, now counted as the most recently shown;
    /// or why there is none.
    public mutating func lookup(_ id: Int, _ values: [String: Float]) -> Lookup {
        if let at = entries.firstIndex(where: { $0.id == id && $0.values == values }) {
            let entry = entries.remove(at: at)
            entries.append(entry)
            return .hit(entry.picture)
        }
        if entries.contains(where: { $0.id == id }) { return .miss(.edited) }
        return .miss(evicted.contains(id) ? .evicted : .cold)
    }

    /// The frame's render with exactly these edits, if kept, without counting it as shown.
    public func peek(_ id: Int, _ values: [String: Float]) -> Picture? {
        entries.first { $0.id == id && $0.values == values }?.picture
    }

    /// Keeps a render as the most recently shown, then lets the least recently shown go until
    /// the total is within the budget. The newest is always kept, even if it alone is larger.
    /// Returns what was let go, oldest first.
    @discardableResult
    public mutating func insert(_ id: Int, _ values: [String: Float], _ picture: Picture, bytes: Int) -> [Entry] {
        entries.removeAll { $0.id == id }
        entries.append(Entry(id: id, values: values, picture: picture, bytes: bytes))
        evicted.remove(id)
        var total = self.bytes
        var out: [Entry] = []
        while total > budget && entries.count > 1 {
            let gone = entries.removeFirst()
            total -= gone.bytes
            evicted.insert(gone.id)
            evictions += 1
            out.append(gone)
        }
        return out
    }

    /// Forgets everything, including which frames were let go (a new folder).
    public mutating func removeAll() {
        entries = []
        evicted = []
        evictions = 0
    }
}
