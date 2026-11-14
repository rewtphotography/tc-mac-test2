import Darwin
import Foundation
import TraincullCore

/// Sidecar file operations on a real folder.
final class FileDirOps: DirOps {
    private let dir: URL

    init(_ dir: URL) { self.dir = dir }

    private func path(_ name: String) -> String { dir.appendingPathComponent(name).path }

    func exists(_ name: String) -> Bool { FileManager.default.fileExists(atPath: path(name)) }

    func readText(_ name: String) -> String? { try? String(contentsOfFile: path(name), encoding: .utf8) }

    func createAndWrite(_ name: String, _ bytes: [UInt8]) throws {
        let fd = open(path(name), O_WRONLY | O_CREAT | O_EXCL, 0o644)
        if fd < 0 { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        defer { close(fd) }
        var written = 0
        while written < bytes.count {
            let n = bytes.withUnsafeBytes { Darwin.write(fd, $0.baseAddress! + written, bytes.count - written) }
            if n <= 0 { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
            written += n
        }
        // fsync alone does not flush the drive's own cache on macOS; F_FULLFSYNC does.
        if fcntl(fd, F_FULLFSYNC) != 0 { fsync(fd) }
    }

    func rename(_ from: String, _ to: String) throws {
        if exists(to) { throw POSIXError(.EEXIST) }
        try FileManager.default.moveItem(atPath: path(from), toPath: path(to))
    }

    func delete(_ name: String) throws { try FileManager.default.removeItem(atPath: path(name)) }

    func replace(_ from: String, _ to: String) -> Bool { Darwin.rename(path(from), path(to)) == 0 }
}
