#if TC_ALPHA_DEBUG
import AppKit
import CryptoKit
import SwiftUI
import TraincullCore
import UniformTypeIdentifiers

/// The Debug menu: the only place the app reaches this folder (one `.commands` line in
/// TrainCullApp, behind TC_ALPHA_DEBUG).
struct DebugCommands: Commands {
    let session: Session

    init(session: Session) {
        self.session = session
        DebugTools.installLaunchHooks(session)
    }

    var body: some Commands {
        CommandMenu("Debug") {
            Button("Run Test Script…") { DebugTools.pickAndRunScript(session) }
            Button("Export Debug Package") { DebugTools.manualExport(session) }
            Divider()
            Button("Reset Manual Export Counter") { DebugTools.resetCounter() }
        }
    }
}

enum DebugTools {
    static let counterKey = "TCDebugManualCase"
    private static var busy = false
    private static var hooksInstalled = false
    /// While the automated build drives the tools: no Finder windows, no dialogs.
    private static var automated = false

    private static func say(_ title: String, _ text: String) {
        guard !automated else { return }
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = text
        alert.runModal()
    }

    // MARK: Test scripts

    static func pickAndRunScript(_ session: Session) {
        guard !busy else { return say("A debug run is already going", "Wait for it to finish, or cancel it.") }
        guard let folder = session.folder else { return say("No folder is open", "Open the folder the script's files are in, then run the script.") }
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.json]
        panel.allowsMultipleSelection = false
        panel.message = "Choose a TrainCull test script (.json)"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return say("The script can't be read", url.path) }
        runScript(text, folder: folder, session: session, ask: true) { _ in }
    }

    /// Checks a script and the size of what it will write: nothing is rendered yet.
    static func check(_ text: String, folder: URL) -> (DebugValidation, [Int: Int], Int) {
        let validation = DebugScriptReader.validate(text) { FileManager.default.fileExists(atPath: folder.appendingPathComponent($0).path) }
        var estimates: [Int: Int] = [:], total = 0
        var sizes: [String: CGSize] = [:]
        if let script = validation.script {
            for c in script.cases {
                if sizes[c.file] == nil { sizes[c.file] = Imaging.rawSize(folder.appendingPathComponent(c.file)) ?? .zero }
                let size = sizes[c.file] ?? .zero
                estimates[c.number] = DebugEstimate.zip(c, width: Int(size.width), height: Int(size.height))
            }
            total = estimates.values.reduce(0, +) + sizes.values.map { DebugEstimate.frame(Int($0.width), Int($0.height)) }.reduce(0, +)
        }
        return (validation, estimates, total)
    }

    static func runScript(_ text: String, folder: URL, session: Session, ask: Bool, done: @escaping (DebugRunner.RunResult?) -> Void) {
        let (validation, estimates, total) = check(text, folder: folder)
        let script = validation.script
        var lines: [String] = []
        if let s = script { lines.append("Script \(String(format: "%02d", s.scriptNumber)) · \(s.name) · \(s.cases.count) case(s)") }
        lines += (script?.index ?? []).map { "  \($0)" }
        if !validation.errors.isEmpty { lines.append("Errors (the script can't run):"); lines += validation.errors.map { "  ✕ \($0)" } }
        if !validation.warnings.isEmpty { lines.append("Warnings:"); lines += validation.warnings.map { "  ! \($0)" } }
        if let s = script {
            lines.append("Estimated sizes:")
            lines += s.cases.map { "  \(DebugNames.zip(DebugScript.testId(s.scriptNumber, $0.number))): \(DebugEstimate.plain(estimates[$0.number] ?? 0))" }
            lines.append("  Whole run, with baselines: \(DebugEstimate.plain(total))")
        }
        Log.note("debug", "script checked: \(validation.errors.count) error(s), \(validation.warnings.count) warning(s)",
                 fields: ["errors": validation.errors, "warnings": validation.warnings, "estimatedBytes": total])
        if ask {
            let alert = NSAlert()
            alert.messageText = validation.canRun ? "Run this test script?" : "This test script can't run"
            alert.informativeText = "It renders into a new folder in \(DebugRunner.root.path). Sidecars and the open photo are not touched."
            let view = NSScrollView(frame: NSRect(x: 0, y: 0, width: 520, height: 260))
            let textView = NSTextView(frame: view.bounds)
            textView.string = lines.joined(separator: "\n")
            textView.isEditable = false
            textView.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
            view.documentView = textView
            view.hasVerticalScroller = true
            alert.accessoryView = view
            if validation.canRun { alert.addButton(withTitle: "Run") }
            alert.addButton(withTitle: "Cancel")
            guard validation.canRun, alert.runModal() == .alertFirstButtonReturn, let s = script else { return done(nil) }
            start(s, folder: folder, estimates: estimates, extras: [:], session: session, done: done)
        } else {
            guard validation.canRun, let s = script else { return done(nil) }
            start(s, folder: folder, estimates: estimates, extras: [:], session: session, done: done)
        }
    }

    /// Runs off the main thread with a progress window that can cancel it.
    private static func start(_ script: DebugScript, folder: URL, estimates: [Int: Int], extras: [Int: DebugRunner.Extra],
                              session: Session, done: @escaping (DebugRunner.RunResult?) -> Void) {
        busy = true
        let progress = automated ? nil : DebugProgress(title: "Script \(String(format: "%02d", script.scriptNumber))")
        DispatchQueue.global(qos: .userInitiated).async {
            let result = try? DebugRunner.run(script, photos: folder, extras: extras, estimates: estimates,
                                              cancelled: { progress?.isCancelled ?? false },
                                              progress: { done, all, what in DispatchQueue.main.async { progress?.update(done, all, what) } })
            DispatchQueue.main.async {
                busy = false
                progress?.close()
                if let r = result {
                    if !automated { NSWorkspace.shared.activateFileViewerSelecting([r.folder]) }
                } else {
                    say("The run couldn't start", "The folder \(DebugRunner.root.path) can't be written to.")
                }
                done(result)
            }
        }
    }

    // MARK: Manual export

    static func resetCounter() {
        UserDefaults.standard.set(0, forKey: counterKey)
        Log.note("debug", "manual export counter reset")
        say("Manual export counter reset", "The next debug package is 0001.")
    }

    /// Export Debug Package: the current photo with its current edits, as script 00, plus what
    /// the preview itself shows. Waits for the full-resolution preview first, never a draft.
    static func manualExport(_ session: Session, done: @escaping (Bool) -> Void = { _ in }) {
        guard !busy else { say("A debug run is already going", "Wait for it to finish."); return done(false) }
        guard let folder = session.folder, let item = session.current, let view = session.singleView else {
            say("No photo is open", "Select a photo in the single view first.")
            return done(false)
        }
        let next = UserDefaults.standard.integer(forKey: counterKey) + 1
        guard next <= 99 else {
            say("The manual export counter is at 99", "Choose Debug ▸ Reset Manual Export Counter to start again at 0001.")
            return done(false)
        }
        busy = true
        let waiting = CFAbsoluteTimeGetCurrent()
        func attempt() {
            guard let preview = session.settledPreview(), session.current === item else {
                if CFAbsoluteTimeGetCurrent() - waiting > 60 {
                    busy = false
                    Log.warn("debug export: the full-resolution preview didn't arrive within 60 s")
                    say("The preview isn't ready", "The full-resolution preview didn't finish; try again in a moment.")
                    return done(false)
                }
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { attempt() }
                return
            }
            busy = false
            export(session, folder: folder, item: item, view: view, preview: preview, number: next, done: done)
        }
        attempt()
    }

    private static func export(_ session: Session, folder: URL, item: FrameItem, view: HeroNSView, preview: CGImage, number: Int, done: @escaping (Bool) -> Void) {
        // The preview pipeline's own picture (Display P3) of what is on screen, at the size shown.
        let visible = view.visibleSpaceRect
        let k = view.screenPixelsPerPicturePixel
        let zoomed = view.isZoomed
        let width = max(1, Int((visible.width * k).rounded())), height = max(1, Int((visible.height * k).rounded()))
        guard let screen = try? DebugRender.redraw(preview, from: visible, width: width, height: height) else {
            say("The preview couldn't be captured", "")
            return done(false)
        }
        // The case, written as a script would write it.
        var set: [String] = []
        var setValues: [(key: String, value: DebugValue)] = []
        for c in RawPanel.controls {
            guard let v = item.adjust[c.key] else { continue }
            let key: String
            switch c.key {
            case "saturation": key = "tc.saturation"
            case "vibrance": key = "tc.vibrance"
            default: key = c.appleProperty
            }
            switch c.kind {
            case .toggle:
                set.append("\"\(key)\": \(v >= 0.5)"); setValues.append((key, .bool(v >= 0.5)))
            case .decoder:
                set.append("\"\(key)\": \"\(Int(v))\""); setValues.append((key, .decoder(String(Int(v)))))
            default:
                set.append("\"\(key)\": \(v)"); setValues.append((key, .number(Double(v))))
            }
        }
        let size = CGSize(width: max(view.space.width, 1), height: max(view.space.height, 1))
        let crop: [Double]? = zoomed ? [visible.minX / size.width, visible.minY / size.height, visible.width / size.width, visible.height / size.height] : nil
        var raw = "{ \"case\": \(number), \"file\": \"\(item.name)\", \"set\": { \(set.joined(separator: ", ")) }"
        if let crop = crop { raw += ", \"crop\": [\(crop.map { String($0) }.joined(separator: ", "))]" }
        raw += " }"
        let c = DebugCase(number: number, file: item.name, set: setValues, crop: crop, fullResTIFF: false, allowOutOfRange: true, raw: raw)
        let text = "{ \"scriptNumber\": 0, \"name\": \"manual export\", \"index\": [\"00\(String(format: "%02d", number)): \(item.name), manual export\"], \"cases\": [\(raw)] }"
        let script = DebugScript(scriptNumber: 0, name: "manual export", index: ["manual export"], cases: [c], text: text)
        let estimate = DebugEstimate.zip(c, width: Int(size.width), height: Int(size.height), screen: true)
        Log.note("debug", "manual export 00\(String(format: "%02d", number)) of \(item.name): \(zoomed ? "zoomed in, the visible part cropped" : "fitted") · screen \(width)×\(height)",
                 fields: ["visible": [visible.minX, visible.minY, visible.width, visible.height], "zoomed": zoomed])
        start(script, folder: folder, estimates: [number: estimate], extras: [number: DebugRunner.Extra(screen: screen, visible: visible)], session: session) { result in
            let ok = result?.results.first?.status == "done"
            if ok {
                UserDefaults.standard.set(number, forKey: counterKey)
                if number == 99 { say("The manual export counter reached 99", "Choose Debug ▸ Reset Manual Export Counter before the next one.") }
            } else {
                say("The debug package wasn't written", result?.results.first?.status ?? "The run couldn't start.")
            }
            done(ok)
        }
    }

    // MARK: The automated build's launch check

    /// -TCDebugResetCounter YES, -TCDebugScript <file>, -TCDebugExports <n>, -TCDebugZoomedExports <n>:
    /// once the folder is open and the preview settled, run them in that order.
    static func installLaunchHooks(_ session: Session) {
        guard !hooksInstalled else { return }
        hooksInstalled = true
        let d = UserDefaults.standard
        let script = d.string(forKey: "TCDebugScript")
        let exports = d.integer(forKey: "TCDebugExports"), zoomedExports = d.integer(forKey: "TCDebugZoomedExports")
        if d.bool(forKey: "TCDebugResetCounter") { d.set(0, forKey: counterKey) }
        guard script != nil || exports > 0 || zoomedExports > 0 else { return }
        automated = true
        func whenSettled(_ then: @escaping () -> Void) {
            if session.folder != nil, session.settledPreview() != nil { return then() }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { whenSettled(then) }
        }
        func exportsInTurn(_ n: Int, _ then: @escaping () -> Void) {
            guard n > 0 else { return then() }
            manualExport(session) { _ in exportsInTurn(n - 1, then) }
        }
        DispatchQueue.main.async {
            whenSettled {
                let afterScript = {
                    exportsInTurn(exports) {
                        guard zoomedExports > 0, let view = session.singleView else { return Log.note("debug", "launch check finished") }
                        let centre = P(Double(view.space.width) * 0.3, Double(view.space.height) * 0.3)
                        view.zoom(to: FaceResult(method: .point, anchor: centre, eyeSpan: nil), animated: false)
                        DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
                            exportsInTurn(zoomedExports) { Log.note("debug", "launch check finished") }
                        }
                    }
                }
                guard let path = script, let folder = session.folder, let text = try? String(contentsOfFile: path, encoding: .utf8) else { return afterScript() }
                // Isolation check: the panel's values and every sidecar, before and after.
                func sidecars() -> [String: String] {
                    let names = (try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []
                    var out: [String: String] = [:]
                    for n in names where n.lowercased().hasSuffix(".xmp") {
                        if let data = try? Data(contentsOf: folder.appendingPathComponent(n)) {
                            out[n] = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
                        }
                    }
                    return out
                }
                let valuesBefore = session.values, sidecarsBefore = sidecars(), imageBefore = session.settledPreview()
                runScript(text, folder: folder, session: session, ask: false) { result in
                    let valuesAfter = session.values, sidecarsAfter = sidecars()
                    let sameImage = imageBefore != nil && session.settledPreview() === imageBefore
                    Log.note("debug", "isolation: panel values \(valuesAfter == valuesBefore ? "unchanged" : "CHANGED") · sidecars \(sidecarsAfter == sidecarsBefore ? "unchanged" : "CHANGED") · image on screen \(sameImage ? "unchanged" : "CHANGED")",
                             fields: ["valuesBefore": valuesBefore.mapValues { Double($0) }, "valuesAfter": valuesAfter.mapValues { Double($0) },
                                      "sidecarsBefore": sidecarsBefore, "sidecarsAfter": sidecarsAfter, "imageUnchanged": sameImage,
                                      "runFolder": result?.folder.path ?? NSNull()])
                    afterScript()
                }
            }
        }
    }
}

/// A small window with the run's progress and a Cancel button.
final class DebugProgress: NSObject {
    private let panel: NSPanel
    private let label = NSTextField(labelWithString: "Starting…")
    private let bar = NSProgressIndicator()
    private(set) var isCancelled = false

    init(title: String) {
        panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 380, height: 110), styleMask: [.titled], backing: .buffered, defer: false)
        super.init()
        panel.title = title
        bar.isIndeterminate = false
        bar.minValue = 0
        let cancel = NSButton(title: "Cancel", target: self, action: #selector(cancelPressed))
        let stack = NSStackView(views: [label, bar, cancel])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.edgeInsets = NSEdgeInsets(top: 14, left: 16, bottom: 14, right: 16)
        bar.widthAnchor.constraint(equalToConstant: 348).isActive = true
        panel.contentView = stack
        panel.center()
        panel.makeKeyAndOrderFront(nil)
    }

    @objc private func cancelPressed() {
        isCancelled = true
        label.stringValue = "Cancelling after the current case…"
    }

    func update(_ done: Int, _ all: Int, _ what: String) {
        bar.maxValue = Double(max(all, 1))
        bar.doubleValue = Double(done)
        if !isCancelled { label.stringValue = "\(done) of \(all) · \(what)" }
    }

    func close() { panel.orderOut(nil) }
}
#endif
