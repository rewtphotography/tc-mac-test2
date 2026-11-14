import Foundation

/// Two frames shown side by side. One of them is active: ratings, labels and the arrow keys
/// act on it alone, and the other stays where it is.
public struct ComparePair: Equatable {
    public enum Side: Int {
        case left = 0, right = 1

        public var other: Side { self == .left ? .right : .left }
    }

    public var left: Int
    public var right: Int
    public var active: Side

    public init(left: Int, right: Int, active: Side) {
        self.left = left
        self.right = right
        self.active = active
    }

    public func frame(_ side: Side) -> Int { side == .left ? left : right }

    public var activeFrame: Int {
        get { frame(active) }
        set { if active == .left { left = newValue } else { right = newValue } }
    }

    public var otherFrame: Int { frame(active.other) }

    /// The frame the active side moves to for a left (-1) or right (+1) arrow, among the frames
    /// the thumbnail pane shows. The frame on the other side is stepped over, so the two sides
    /// never show the same photo. Nil when there is nowhere to go.
    public func stepTarget(_ by: Int, in shown: [Int]) -> Int? {
        if by == 0 || shown.isEmpty { return nil }
        let direction = by > 0 ? 1 : -1
        guard var at = shown.firstIndex(of: activeFrame) else {
            // The active frame was filtered out: start from the first one shown.
            return shown.first { $0 != otherFrame }
        }
        while true {
            at += direction
            if !shown.indices.contains(at) { return nil }
            if shown[at] != otherFrame { return shown[at] }
        }
    }
}
