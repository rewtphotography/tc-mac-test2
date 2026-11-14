import AppKit
import Darwin
import Foundation
import SwiftUI
import TraincullCore

/// The diagnostics log: one plain-text file for each time the app is opened, kept in
/// ~/Library/Logs/TrainCull on this Mac. Nothing is ever sent anywhere. While the app is in
/// alpha it records freely: what was opened, how long each step took, what was saved and
/// every error, so a problem can be traced from the file alone.
final class Log {
    static let shared = Log()

    /// The file this session writes to; nil if it couldn't be created.
    let fileURL: URL?
    private let queue = DispatchQueue(label: "log", qos: .utility)
    private var handle: FileHandle?
    private let clock: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "HH:mm:ss.SSS"
        return f
    }()

    static let keptFiles = 10

    private init() {
        let fm = FileManager.default
        let folder = fm.urls(for: .libraryDirectory, in: .userDomainMask)[0].appendingPathComponent("Logs/TrainCull", isDirectory: true)
        try? fm.createDirectory(at: folder, withIntermediateDirectories: true)
        // Keep the last few sessions only.
        let old = ((try? fm.contentsOfDirectory(atPath: folder.path)) ?? []).filter { $0.hasSuffix(".log") }.sorted()
        if old.count >= Log.keptFiles {
            for name in old.prefix(old.count - Log.keptFiles + 1) { try? fm.removeItem(at: folder.appendingPathComponent(name)) }
        }
        let name = DateFormatter()
        name.locale = Locale(identifier: "en_US_POSIX")
        name.dateFormat = "yyyy-MM-dd HH.mm.ss"
        let url = folder.appendingPathComponent("TrainCull \(name.string(from: Date())).log")
        if fm.createFile(atPath: url.path, contents: nil), let h = try? FileHandle(forWritingTo: url) {
            handle = h
            fileURL = url
        } else {
            fileURL = nil
        }
    }

    /// Writes one line: the time, an area ("folder", "image", "save"…) and what happened.
    static func note(_ area: String, _ text: String) { shared.write(area, text) }

    /// Runs `work`, notes how long it took, and returns its result.
    static func timed<T>(_ area: String, _ what: String, _ work: () throws -> T) rethrows -> T {
        let start = CFAbsoluteTimeGetCurrent()
        defer { note(area, "\(what): \(seconds(since: start))") }
        return try work()
    }

    static func seconds(since start: CFAbsoluteTime) -> String {
        String(format: "%.3f s", locale: Locale(identifier: "en_US_POSIX"), CFAbsoluteTimeGetCurrent() - start)
    }

    private func write(_ area: String, _ text: String) {
        let now = Date()
        queue.async {
            guard let handle = self.handle else { return }
            let line = "\(self.clock.string(from: now))  \(area.padding(toLength: 8, withPad: " ", startingAt: 0)) \(text)\n"
            try? handle.write(contentsOf: Data(line.utf8))
        }
    }

    /// Waits until everything noted so far is on disk.
    func flush() {
        queue.sync { try? self.handle?.synchronize() }
    }

    /// The first lines of every log: which build, which Mac.
    func writeHeader() {
        let info = ProcessInfo.processInfo
        var size = 0
        sysctlbyname("hw.model", nil, &size, nil, 0)
        var model = [CChar](repeating: 0, count: max(size, 1))
        sysctlbyname("hw.model", &model, &size, nil, 0)
        Log.note("app", "\(appVersion) started")
        Log.note("app", "macOS \(info.operatingSystemVersionString), \(String(cString: model)), \(info.activeProcessorCount) cores, "
            + "\(MemoryStats.plain(info.physicalMemory)) of memory")
    }
}

/// Watches how much memory the app uses. The figure is the app's memory footprint, the same
/// number Activity Monitor shows in its Memory column.
final class MemoryMonitor: ObservableObject {
    static let shared = MemoryMonitor()

    @Published private(set) var stats = MemoryStats()
    let started = Date()
    private var timer: DispatchSourceTimer?
    private var ticks = 0
    private var loggedPeak: UInt64 = 0

    static func footprint() -> UInt64 {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size)
        let result = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        return result == KERN_SUCCESS ? UInt64(info.phys_footprint) : 0
    }

    /// Takes a reading every second, and writes a line to the log every fifteen.
    func start() {
        guard timer == nil else { return }
        let t = DispatchSource.makeTimerSource(queue: DispatchQueue.global(qos: .utility))
        t.schedule(deadline: .now() + 1, repeating: 1)
        t.setEventHandler { [weak self] in
            let bytes = MemoryMonitor.footprint()
            DispatchQueue.main.async { self?.take(bytes, why: nil) }
        }
        t.resume()
        timer = t
    }

    /// An extra reading at a moment worth knowing about, such as just after a raw render, so
    /// short peaks between the regular readings are not missed. Safe from any thread.
    static func mark(_ why: String) {
        let bytes = footprint()
        DispatchQueue.main.async { shared.take(bytes, why: why) }
    }

    private func take(_ bytes: UInt64, why: String?) {
        guard bytes > 0 else { return }
        stats.add(bytes)
        if let why = why {
            Log.note("memory", "\(MemoryStats.plain(bytes)) after \(why)")
        } else {
            ticks += 1
            if ticks % 15 == 0 { Log.note("memory", line) }
        }
        // A new high point, by more than 50 MB, is worth a line of its own.
        if stats.peak > loggedPeak + 50 * 1_048_576 {
            loggedPeak = stats.peak
            Log.note("memory", "new peak \(MemoryStats.plain(stats.peak))")
        }
    }

    private var line: String {
        "now \(MemoryStats.plain(stats.last)) · average \(MemoryStats.plain(stats.average)) · peak \(MemoryStats.plain(stats.peak))"
    }

    /// The plain-language summary.
    var sentence: String { stats.sentence(elapsed: Date().timeIntervalSince(started)) }
}

/// Help → Diagnostics: memory use in plain language, and the way to the log file.
struct DiagnosticsView: View {
    @ObservedObject private var memory = MemoryMonitor.shared
    @State private var copied = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Memory").font(.headline)
            Text(memory.sentence)
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
            Text("This Mac has \(MemoryStats.plain(ProcessInfo.processInfo.physicalMemory)). The figure is the one Activity Monitor shows for TrainCull.")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Divider().padding(.vertical, 4)
            Text("Log").font(.headline)
            Text("While TrainCull is in alpha it writes what it does, how long each step takes and any error to a text file on this Mac. Nothing is sent anywhere. To report a problem, send the file for the session it happened in.")
                .fixedSize(horizontal: false, vertical: true)
            HStack {
                Button("Show Log File") {
                    Log.shared.flush()
                    if let url = Log.shared.fileURL { NSWorkspace.shared.activateFileViewerSelecting([url]) }
                }
                .disabled(Log.shared.fileURL == nil)
                Button(copied ? "Copied" : "Copy Memory Summary") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString("\(appVersion). \(memory.sentence)", forType: .string)
                    copied = true
                }
            }
            .padding(.top, 2)
        }
        .padding(20)
        .frame(width: 460)
    }
}
