import Foundation

/// How much memory the app has used while it has been open: the latest reading, the average
/// of all readings and the highest one. Readings are in bytes.
public struct MemoryStats: Equatable {
    public private(set) var samples = 0
    public private(set) var total = 0.0
    public private(set) var peak: UInt64 = 0
    public private(set) var last: UInt64 = 0

    public init() {}

    /// Takes one reading. Returns true when it is a new peak.
    @discardableResult
    public mutating func add(_ bytes: UInt64) -> Bool {
        samples += 1
        total += Double(bytes)
        last = bytes
        if bytes > peak {
            peak = bytes
            return true
        }
        return false
    }

    public var average: UInt64 { samples == 0 ? 0 : UInt64(total / Double(samples)) }

    /// "850 MB" or "1.2 GB", counted the way Activity Monitor counts (1 GB = 1,024 MB).
    public static func plain(_ bytes: UInt64) -> String {
        let mb = Double(bytes) / 1_048_576
        if mb < 1000 { return "\(Int(mb.rounded())) MB" }
        return String(format: "%.1f GB", locale: Locale(identifier: "en_US_POSIX"), mb / 1024)
    }

    /// "2 minutes", "1 hour 5 minutes".
    public static func duration(_ seconds: Double) -> String {
        let minutes = max(0, Int(seconds / 60))
        if minutes < 1 { return "less than a minute" }
        func unit(_ n: Int, _ name: String) -> String { "\(n) \(name)\(n == 1 ? "" : "s")" }
        if minutes < 60 { return unit(minutes, "minute") }
        let rest = minutes % 60
        return unit(minutes / 60, "hour") + (rest == 0 ? "" : " " + unit(rest, "minute"))
    }

    /// The plain-language summary shown in the Diagnostics window and written to the log.
    public func sentence(elapsed seconds: Double) -> String {
        if samples == 0 { return "No memory readings yet." }
        return "TrainCull is using \(MemoryStats.plain(last)) of memory right now. "
            + "Over this session (\(MemoryStats.duration(seconds))) it has averaged \(MemoryStats.plain(average)) "
            + "and peaked at \(MemoryStats.plain(peak))."
    }
}
