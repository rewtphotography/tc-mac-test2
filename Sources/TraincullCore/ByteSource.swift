import Foundation

public struct ReadPastEnd: Error, CustomStringConvertible {
    public let description: String
}

/// Random-access reads from one file.
public protocol ByteSource {
    var size: Int64 { get }

    /// Reads exactly `length` bytes at `offset`; throws if the file is shorter.
    func read(_ offset: Int64, _ length: Int) throws -> [UInt8]
}

/// In-memory source, used by tests.
public final class ArrayByteSource: ByteSource {
    private let data: [UInt8]

    public init(_ data: [UInt8]) { self.data = data }

    public var size: Int64 { Int64(data.count) }

    public func read(_ offset: Int64, _ length: Int) throws -> [UInt8] {
        if offset < 0 || length < 0 || offset + Int64(length) > Int64(data.count) {
            throw ReadPastEnd(description: "read past end: \(offset)+\(length)")
        }
        return Array(data[Int(offset) ..< Int(offset) + length])
    }
}

/// A window of another source starting at `base`: positions inside a maker note or an embedded TIFF.
public final class SubByteSource: ByteSource {
    private let parent: ByteSource
    private let base: Int64

    public init(_ parent: ByteSource, _ base: Int64) {
        self.parent = parent
        self.base = base
    }

    public var size: Int64 { max(parent.size - base, 0) }

    public func read(_ offset: Int64, _ length: Int) throws -> [UInt8] {
        if offset < 0 { throw ReadPastEnd(description: "read before start: \(offset)") }
        return try parent.read(base + offset, length)
    }
}

/// A file read through one handle, with the first bytes kept in memory so that parsing the
/// IFD tables and decoding the preview do not go back to the disk.
public final class FileByteSource: ByteSource {
    private let handle: FileHandle
    private var head: [UInt8] = []
    public let size: Int64

    public init(url: URL) throws {
        handle = try FileHandle(forReadingFrom: url)
        size = Int64(try handle.seekToEnd())
    }

    deinit { try? handle.close() }

    /// Reads the first `count` bytes in one go and keeps them.
    public func readHeader(_ count: Int) throws {
        let n = Int(min(Int64(count), size))
        try handle.seek(toOffset: 0)
        head = [UInt8](try handle.read(upToCount: n) ?? Data())
    }

    public func read(_ offset: Int64, _ length: Int) throws -> [UInt8] {
        if offset < 0 || length < 0 || offset + Int64(length) > size {
            throw ReadPastEnd(description: "read past end: \(offset)+\(length)")
        }
        if offset + Int64(length) <= Int64(head.count) {
            return Array(head[Int(offset) ..< Int(offset) + length])
        }
        try handle.seek(toOffset: UInt64(offset))
        let d = try handle.read(upToCount: length) ?? Data()
        if d.count != length { throw ReadPastEnd(description: "short read: \(offset)+\(length)") }
        return [UInt8](d)
    }
}
