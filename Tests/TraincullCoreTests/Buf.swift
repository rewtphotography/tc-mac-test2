import Foundation

/// A fixed-size byte buffer with a position and a byte order, for building synthetic test
/// files in code. No sample raws are ever stored in the repository.
final class Buf {
    var bytes: [UInt8]
    var pos = 0
    let little: Bool

    init(_ size: Int, little: Bool) {
        bytes = [UInt8](repeating: 0, count: size)
        self.little = little
    }

    @discardableResult func position(_ p: Int) -> Buf { pos = p; return self }
    @discardableResult func put(_ b: UInt8) -> Buf { bytes[pos] = b; pos += 1; return self }
    @discardableResult func put(_ s: String) -> Buf { for b in Array(s.utf8) { put(b) }; return self }
    @discardableResult func put(_ a: [UInt8]) -> Buf { for b in a { put(b) }; return self }

    @discardableResult func putShort(_ v: Int) -> Buf {
        let lo = UInt8(v & 0xFF), hi = UInt8((v >> 8) & 0xFF)
        return little ? put(lo).put(hi) : put(hi).put(lo)
    }

    @discardableResult func putInt(_ v: Int) -> Buf {
        let b = (0 ..< 4).map { UInt8((v >> (8 * $0)) & 0xFF) }
        return little ? put(b) : put(b.reversed())
    }

    @discardableResult func putInt(at: Int, _ v: Int) -> Buf {
        let saved = pos
        pos = at
        putInt(v)
        pos = saved
        return self
    }

    /// One 12-byte IFD entry.
    func entry(_ tag: Int, _ type: Int, _ count: Int, _ value: Int) {
        putShort(tag).putShort(type).putInt(count)
        if type == 3 && count == 1 { putShort(value).putShort(0) } else { putInt(value) }
    }
}
