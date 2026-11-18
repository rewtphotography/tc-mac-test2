@testable import TraincullCore
import XCTest

final class LogFilesTests: XCTestCase {
    private var folder: URL!

    override func setUp() {
        folder = FileManager.default.temporaryDirectory.appendingPathComponent("logfiles-\(UUID().uuidString)", isDirectory: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: folder)
    }

    /// Every line of the `.jsonl` twin is valid JSON and is the same event as the matching line
    /// of the `.log`: same order, time, area and message.
    func testJsonLinesMatchTheLog() throws {
        let log = LogFiles(folder: folder, keep: 20)
        let start = Date(timeIntervalSince1970: 1_790_000_000.125)
        let events: [(String, String, LogFiles.Level, [String: Any]?)] = [
            ("app", "TrainCull 0.2.0 alpha 1 started", .info, nil),
            ("select", "DSC01234.ARW (3 of 120) · cause: user.key (→)", .info, nil),
            ("cache", "render DSC01234.ARW · miss: evicted (LRU)", .info, ["frame": "DSC01234.ARW", "bytes": 251_658_240]),
            ("warn", "a \"quoted\" value, a back\\slash, a tab\tand an apostrophe's", .warn, nil),
            ("image", "draft 1200×800 · trigger: Exposure drag · coalesced 3", .debug, ["coalesced": 3, "scale": 0.25]),
            ("job", "render: unwritable fields are dropped", .info, ["date": Date()]),
            ("export", "DSC01235.ARW failed: an error's text\nover two lines", .info, nil),
        ]
        for (i, event) in events.enumerated() {
            log.write(event.0, event.1, level: event.2, fields: event.3, at: start.addingTimeInterval(Double(i) * 0.5))
        }
        log.flush()

        let textURL = try XCTUnwrap(log.textURL)
        let jsonURL = try XCTUnwrap(log.jsonURL)
        XCTAssertEqual(textURL.deletingPathExtension().lastPathComponent, jsonURL.deletingPathExtension().lastPathComponent)
        let lines = try String(contentsOf: textURL, encoding: .utf8).split(separator: "\n", omittingEmptySubsequences: false).dropLast()
        let jsonLines = try String(contentsOf: jsonURL, encoding: .utf8).split(separator: "\n", omittingEmptySubsequences: false).dropLast()
        XCTAssertEqual(lines.count, events.count)
        XCTAssertEqual(jsonLines.count, events.count)

        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let clock = DateFormatter()
        clock.locale = Locale(identifier: "en_US_POSIX")
        clock.dateFormat = "HH:mm:ss.SSS"
        for (i, (line, jsonLine)) in zip(lines, jsonLines).enumerated() {
            let object = try JSONSerialization.jsonObject(with: Data(jsonLine.utf8))
            let event = try XCTUnwrap(object as? [String: Any], "line \(i + 1) is not a JSON object")
            let area = try XCTUnwrap(event["category"] as? String)
            let message = try XCTUnwrap(event["message"] as? String)
            let level = try XCTUnwrap(event["level"] as? String)
            let ts = try XCTUnwrap(iso.date(from: try XCTUnwrap(event["ts"] as? String)))
            XCTAssertEqual(area, events[i].0)
            XCTAssertEqual(message, events[i].1)
            XCTAssertEqual(level, events[i].2.rawValue)
            XCTAssertEqual(ts.timeIntervalSince1970, start.timeIntervalSince1970 + Double(i) * 0.5, accuracy: 0.001)
            // The .log line says the same: its time, the area padded to eight, the message.
            // (A message of several lines is kept on one line there.)
            let flat = message.replacingOccurrences(of: "\n", with: " ")
            XCTAssertEqual(String(line), "\(clock.string(from: ts))  \(area.padding(toLength: 8, withPad: " ", startingAt: 0)) \(flat)")
        }
        let cache = try JSONSerialization.jsonObject(with: Data(jsonLines[2].utf8)) as? [String: Any]
        let fields = try XCTUnwrap(cache?["fields"] as? [String: Any])
        XCTAssertEqual(fields["bytes"] as? Int, 251_658_240)
        XCTAssertEqual(fields["frame"] as? String, "DSC01234.ARW")
        // Fields JSON can't hold are left out; the event is still written.
        let job = try JSONSerialization.jsonObject(with: Data(jsonLines[5].utf8)) as? [String: Any]
        XCTAssertNil(job?["fields"])
    }

    /// Twenty sessions are kept, each as a .log and its .jsonl.
    func testOldSessionsArePrunedInPairs() throws {
        let fm = FileManager.default
        try fm.createDirectory(at: folder, withIntermediateDirectories: true)
        for day in 1 ... 25 {
            let base = String(format: "TrainCull 2026-10-%02d 10.00.00", day)
            _ = fm.createFile(atPath: folder.appendingPathComponent(base + ".log").path, contents: Data())
            _ = fm.createFile(atPath: folder.appendingPathComponent(base + ".jsonl").path, contents: Data())
        }
        let log = LogFiles(folder: folder, keep: 20, now: Date(timeIntervalSince1970: 1_790_000_000))
        log.flush()
        let names = try fm.contentsOfDirectory(atPath: folder.path)
        XCTAssertEqual(names.filter { $0.hasSuffix(".log") }.count, 20)
        XCTAssertEqual(names.filter { $0.hasSuffix(".jsonl") }.count, 20)
        XCTAssertFalse(names.contains("TrainCull 2026-10-06 10.00.00.log"))
        XCTAssertFalse(names.contains("TrainCull 2026-10-06 10.00.00.jsonl"))
        XCTAssertTrue(names.contains("TrainCull 2026-10-07 10.00.00.jsonl"))
    }
}
