import Dispatch
import Foundation

/// The diagnostics log's two files for one session of the app: a plain-text `.log` to read,
/// and a `.jsonl` twin with the same events, one JSON object per line, for scripts. Writes go
/// through one queue, so the two files always hold the same events in the same order.
public final class LogFiles {
    public enum Level: String {
        case info, warn, debug
    }

    /// The plain-text file; nil if it couldn't be created.
    public let textURL: URL?
    /// The JSON twin; nil if it couldn't be created.
    public let jsonURL: URL?
    private var text: FileHandle?
    private var json: FileHandle?
    private let queue = DispatchQueue(label: "log", qos: .utility)
    private let clock: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "HH:mm:ss.SSS"
        return f
    }()
    private let stamp: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    /// Opens a new pair of files in `folder`, named after `now`, and deletes the oldest pairs so
    /// that no more than `keep` sessions are kept.
    public init(folder: URL, keep: Int, now: Date = Date()) {
        let fm = FileManager.default
        try? fm.createDirectory(at: folder, withIntermediateDirectories: true)
        let old = ((try? fm.contentsOfDirectory(atPath: folder.path)) ?? []).filter { $0.hasSuffix(".log") }.sorted()
        if old.count >= keep {
            for name in old.prefix(old.count - keep + 1) {
                try? fm.removeItem(at: folder.appendingPathComponent(name))
                try? fm.removeItem(at: folder.appendingPathComponent(String(name.dropLast(4)) + ".jsonl"))
            }
        }
        let name = DateFormatter()
        name.locale = Locale(identifier: "en_US_POSIX")
        name.dateFormat = "yyyy-MM-dd HH.mm.ss"
        let base = "TrainCull \(name.string(from: now))"
        let textURL = folder.appendingPathComponent(base + ".log")
        let jsonURL = folder.appendingPathComponent(base + ".jsonl")
        if fm.createFile(atPath: textURL.path, contents: nil), let h = try? FileHandle(forWritingTo: textURL) {
            text = h
            self.textURL = textURL
        } else {
            self.textURL = nil
        }
        if fm.createFile(atPath: jsonURL.path, contents: nil), let h = try? FileHandle(forWritingTo: jsonURL) {
            json = h
            self.jsonURL = jsonURL
        } else {
            self.jsonURL = nil
        }
    }

    /// Writes one event to both files. `fields` are extra named values (numbers, names) for the
    /// JSON copy only, so a script needn't pick them out of the sentence.
    public func write(_ area: String, _ message: String, level: Level = .info, fields: [String: Any]? = nil, at now: Date = Date()) {
        queue.async {
            if let text = self.text {
                try? text.write(contentsOf: Data(self.textLine(area, message, at: now).utf8))
            }
            if let json = self.json, var data = self.jsonLine(area, message, level: level, fields: fields, at: now) {
                data.append(0x0A)
                try? json.write(contentsOf: data)
            }
        }
    }

    /// One line of the plain-text file, with its line break. A message of several lines (an
    /// error's own text can be) is kept on one, so each event stays one line in both files.
    func textLine(_ area: String, _ message: String, at now: Date) -> String {
        "\(clock.string(from: now))  \(area.padding(toLength: 8, withPad: " ", startingAt: 0)) \(LogFiles.oneLine(message))\n"
    }

    static func oneLine(_ message: String) -> String {
        message.split(omittingEmptySubsequences: false, whereSeparator: { $0.isNewline }).joined(separator: " ")
    }

    /// One line of the JSON twin, without its line break: time, level, area and message, and
    /// the fields if they can be written as JSON.
    func jsonLine(_ area: String, _ message: String, level: Level, fields: [String: Any]?, at now: Date) -> Data? {
        var event: [String: Any] = ["ts": stamp.string(from: now), "level": level.rawValue, "category": area, "message": message]
        if let fields = fields, JSONSerialization.isValidJSONObject(fields) { event["fields"] = fields }
        return try? JSONSerialization.data(withJSONObject: event, options: [.sortedKeys])
    }

    /// Waits until everything written so far is on disk.
    public func flush() {
        queue.sync {
            try? self.text?.synchronize()
            try? self.json?.synchronize()
        }
    }
}
