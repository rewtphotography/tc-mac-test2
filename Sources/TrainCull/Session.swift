import AppKit
import SwiftUI
import TraincullCore

/// One raw file in the open folder.
final class FrameItem: ObservableObject, Identifiable {
    let id: Int
    let url: URL
    let name: String
    let baseName: String
    var sidecarName: String?
    var info: RawInfo?
    /// The editing controls changed from their defaults, by control key.
    var adjust: [String: Float]
    @Published var rating: Int
    @Published var label: String?
    @Published var thumb: CGImage?
    @Published var failed: String?

    init(id: Int, url: URL, sidecarName: String?, values: SidecarValues?, adjust: [String: Float]) {
        self.adjust = adjust
        self.id = id
        self.url = url
        name = url.lastPathComponent
        baseName = url.deletingPathExtension().lastPathComponent
        self.sidecarName = sidecarName
        rating = values?.rating ?? 0
        label = values?.label
    }
}

struct Volume: Identifiable {
    let url: URL
    let name: String
    let detail: String
    let ejectable: Bool
    var id: URL { url }
}

/// The colour labels, in Bridge's default names. Bridge matches labels by text, not colour.
enum LabelColor: Int, CaseIterable {
    case red = 6, yellow, green, blue, purple

    var text: String {
        switch self {
        case .red: return "Select"
        case .yellow: return "Second"
        case .green: return "Approved"
        case .blue: return "Review"
        case .purple: return "To Do"
        }
    }

    var color: Color {
        switch self {
        case .red: return Color(red: 0.937, green: 0.267, blue: 0.267)
        case .yellow: return Color(red: 0.980, green: 0.800, blue: 0.082)
        case .green: return Color(red: 0.133, green: 0.773, blue: 0.369)
        case .blue: return Color(red: 0.231, green: 0.510, blue: 0.965)
        case .purple: return Color(red: 0.659, green: 0.333, blue: 0.969)
        }
    }

    /// The swatch for a label's text; an unknown label is drawn near-white.
    static func color(for label: String?) -> Color? {
        guard let label = label else { return nil }
        return allCases.first { $0.text == label }?.color ?? Color(red: 0.894, green: 0.894, blue: 0.906)
    }
}

/// One of the two large images: slot 0 is the single view and the left side of the
/// side-by-side view, slot 1 the right side.
final class HeroSlot {
    weak var view: HeroNSView?
    /// Goes up each time the slot is given another frame, so late results for an earlier one are dropped.
    var token = 0
    /// The frame the slot shows.
    var frame: Int?
    /// What the last click here zoomed to.
    var target: FaceResult?
}

/// Everything the window shows: the open folder, its frames, the selection and the hero image.
final class Session: ObservableObject {
    enum Pane { case folders, thumbnails }
    enum Filter: Equatable { case all, rated(Int), rejected }

    @Published var folder: URL?
    @Published var frames: [FrameItem] = []
    /// The frame ratings, labels and edits act on. In the side-by-side view it is the active image.
    @Published var selected = 0
    @Published var pane = Pane.folders
    @Published var status = ""
    @Published var message: String?
    /// For each large image: what it shows ("Preview", "Raw") and its zoom.
    @Published var heroStates = ["", ""]
    @Published var zoomTexts = ["Fit", "Fit"]
    /// The two frames shown side by side; nil in the single view.
    @Published var compare: ComparePair?
    /// Goes up when the thumbnail pane should scroll to the selected frame and flash it.
    @Published var revealTick = 0
    @Published var flashed: Int?
    /// "Exporting 3 / 12" while an export runs.
    @Published var exportStatus: String?
    @Published var recents: [URL] = []
    @Published var volumes: [Volume] = []
    @Published var ratedCount = 0
    @Published var rejectedCount = 0
    /// The frames shown in the thumbnail pane: all of them, or the ones a filter kept.
    @Published var visible: [FrameItem] = []
    @Published var filter = Filter.all
    @Published var minStars = 1
    /// Edit mode: the thumbnail pane makes way for the editing controls.
    @Published var editing = false {
        didSet { if !editing { thumbsWhileEditing = false; flushSave() } }
    }
    @Published var thumbsWhileEditing = false
    /// The current frame's changed controls, and what Apple's decoder uses by default for it.
    @Published var values: [String: Float] = [:]
    @Published var defaults: [String: Float] = [:]
    /// Apple's is…Supported flags for the current frame, and its decoders.
    @Published var supported: [String: Bool] = [:]
    @Published var decoderLine = DecoderLine.label("")
    /// White balance by point: the next click on the image picks the neutral point. Esc cancels.
    @Published var pickingNeutral = false {
        didSet { slots[0].view?.picksPoint = pickingNeutral }
    }

    let formats = Formats()
    /// The main window, so keys typed in another window (Diagnostics) are left alone.
    weak var window: NSWindow?
    private let slots = [HeroSlot(), HeroSlot()]
    private var generation = 0
    private var exportRun = 0
    private var flashToken = 0
    private var folderOpened = CFAbsoluteTimeGetCurrent()
    private var faces: [Int: DetectedFaces] = [:]
    private var chosenFace: [Int: Int] = [:]
    /// The render cache: at most this many bytes of finished pictures, least recently shown out
    /// first. A 61-megapixel render is about 240 MB, so three of those fit, six of 33 megapixels.
    static let renderCacheBytes = 900 << 20
    private var rawCache = RenderCache<CGImage>(budget: Session.renderCacheBytes)
    /// Frames whose camera settings have been written to the log this session.
    private var introduced = Set<Int>()
    /// What the user last did that calls for a new render, and how many draft requests arrived
    /// while a draft was still being made.
    private var renderTrigger = "selection"
    /// The single view's renderer: one Apple raw filter for the selected file, reused.
    private var renderer: PreviewRenderer?
    private var previewSeq = 0
    /// The newest request whose frame is on screen: an older frame is never shown after it.
    private var shownSeq = 0
    private var settleWork: DispatchWorkItem?
    private var viewportWork: DispatchWorkItem?
    /// What the renderer last put on screen: the whole picture, and a sharper part over it.
    private var shownWhole: (values: [String: Float], want: PreviewRenderer.Want, draft: Bool)?
    private var shownPart: (values: [String: Float], want: PreviewRenderer.Want, draft: Bool)?
    private var selectionStarted = CFAbsoluteTimeGetCurrent()
    private var firstRenderLogged = true
    private var lastKnownCreations = 0
    /// Frames thrown away because a newer one was already on screen.
    private var staleFrames = 0
    /// One slider drag, for its log line.
    private final class DragRecord {
        let key: String
        let start: Float
        let began = CFAbsoluteTimeGetCurrent()
        let meter = JobMeter()
        let replacedAtStart: Int
        let creationsAtStart: Int
        let staleAtStart: Int
        let tuning: PreviewTuning
        var frameMs: [Double] = []
        var released: CFAbsoluteTime?
        var settleStart: CFAbsoluteTime?
        var end: Float?

        init(key: String, start: Float, replaced: Int, creations: Int, stale: Int, tuning: PreviewTuning) {
            self.key = key
            self.start = start
            replacedAtStart = replaced
            creationsAtStart = creations
            staleAtStart = stale
            self.tuning = tuning
        }
    }
    private var drag: DragRecord?
    /// One change to a control, waiting for the frame that shows it so its line can be logged.
    private struct Change {
        let file: String
        let frame: Int
        let key: String
        let old: Float
        let new: Float
        let isDragEnd: Bool
        let cause: String
        let at: CFAbsoluteTime
        /// The edit this change is part of: the full render for this edit, or a later one, shows it.
        let editToken: Int
    }
    private var pendingChanges: [Change] = []
    /// A slider's value when its drag began, by control key.
    private var dragStart: [String: Float] = [:]
    private var fullSize: [Int: CGSize] = [:]
    private var editToken = 0
    private var valuesToken = 0
    private var saveToken = 0
    private var pendingSave: FrameItem?
    private let loadQueue: OperationQueue = {
        let q = OperationQueue()
        q.maxConcurrentOperationCount = max(2, ProcessInfo.processInfo.activeProcessorCount - 2)
        q.qualityOfService = .userInitiated
        return q
    }()
    private let heroQueue = DispatchQueue(label: "hero", qos: .userInteractive, attributes: .concurrent)
    private let rawQueue = DispatchQueue(label: "raw", qos: .userInitiated)
    private let sidecarQueue = DispatchQueue(label: "sidecars", qos: .userInitiated)
    private let exportQueue = DispatchQueue(label: "export", qos: .userInitiated)
    private var keyMonitor: Any?
    private var messageToken = 0
    private var loadedCount = 0

    var current: FrameItem? { frames.indices.contains(selected) ? frames[selected] : nil }

    /// The single view's large image.
    var singleView: HeroNSView? { slots[0].view }

    /// The single view's settled picture of the current frame with its current edits, once it is
    /// on screen (never a draft, nothing still to come): the picture and the part of the frame it
    /// covers, in full-size pixels. Nil until then.
    func settledPreview() -> (image: CGImage, rect: CGRect)? {
        guard compare == nil, current != nil, heroStates[0] == "Raw", settleWork == nil, viewportWork == nil,
              renderer?.isIdle ?? true, shownSeq == previewSeq, let view = slots[0].view else { return nil }
        return view.shownPicture
    }

    /// The tuning in force and what the single view shows, for the debug tools.
    var previewState: [String: Any] {
        var out = PreviewTuning.current.fields
        out["shownKind"] = slots[0].view?.shownKind ?? ""
        out["status"] = heroStates[0]
        return out
    }

    /// The slot ratings and keys act on: the active side when comparing, else the single view.
    var activeSlot: Int { compare?.active.rawValue ?? 0 }
    var heroState: String { heroStates[activeSlot] }
    var zoomText: String { zoomTexts[activeSlot] }
    private var hero: HeroNSView? { slots[activeSlot].view }
    /// Editing happens in the single view only, so its token marks "still the same frame".
    private var heroToken: Int { slots[0].token }

    init() {
        Log.shared.writeHeader()
        MemoryMonitor.shared.start()
        recents = (UserDefaults.standard.stringArray(forKey: "recentFolders") ?? [])
            .map { URL(fileURLWithPath: $0) }
            .filter { FileManager.default.fileExists(atPath: $0.path) }
        refreshVolumes()
        let center = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.didMountNotification, NSWorkspace.didUnmountNotification, NSWorkspace.didRenameVolumeNotification] {
            center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in self?.refreshVolumes() }
        }
        NotificationCenter.default.addObserver(forName: NSApplication.willTerminateNotification, object: nil, queue: .main) { [weak self] _ in
            self?.flushSave()
            self?.sidecarQueue.sync {}
            Log.note("memory", MemoryMonitor.shared.sentence)
            Log.note("app", "quit")
            Log.shared.flush()
        }
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            (self?.handleKey(event) ?? false) ? nil : event
        }
        MemoryMonitor.shared.cacheSummary = { [weak self] in
            guard let self = self else { return nil }
            defer { self.rawCache.evictions = 0 }
            return "summary · render \(self.rawCache.count) / \(MemoryStats.plain(UInt64(self.rawCache.bytes))) of \(MemoryStats.plain(UInt64(Session.renderCacheBytes)))"
                + " · evictions since the last summary \(self.rawCache.evictions)"
        }
        // For the automated build's launch check: open a folder straight away, and optionally
        // show its first two frames side by side.
        if let path = UserDefaults.standard.string(forKey: "TCOpenFolder") {
            DispatchQueue.main.async { self.open(URL(fileURLWithPath: path)) }
        }
    }

    // MARK: Folders and drives

    func refreshVolumes() {
        let keys: [URLResourceKey] = [.volumeNameKey, .volumeTotalCapacityKey, .volumeIsEjectableKey, .volumeIsRemovableKey, .volumeIsInternalKey]
        let urls = FileManager.default.mountedVolumeURLs(includingResourceValuesForKeys: keys, options: [.skipHiddenVolumes]) ?? []
        volumes = urls.compactMap { url in
            guard let v = try? url.resourceValues(forKeys: Set(keys)) else { return nil }
            let size = ByteCountFormatter.string(fromByteCount: Int64(v.volumeTotalCapacity ?? 0), countStyle: .file)
            let ejectable = (v.volumeIsEjectable ?? false) || (v.volumeIsRemovable ?? false) || !(v.volumeIsInternal ?? true)
            return Volume(url: url, name: v.volumeName ?? url.lastPathComponent, detail: size, ejectable: ejectable)
        }
    }

    func eject(_ volume: Volume) {
        do {
            try NSWorkspace.shared.unmountAndEjectDevice(at: volume.url)
            if let f = folder, f.path.hasPrefix(volume.url.path) { close() }
            Log.note("folder", "ejected \(volume.name)")
            say("\(volume.name) ejected. Safe to unplug.")
        } catch {
            Log.note("folder", "couldn't eject \(volume.name): \(error)")
            say("\(volume.name) couldn't be ejected: \(error.localizedDescription)")
        }
        refreshVolumes()
    }

    func pickFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = "Open"
        panel.message = "Choose a folder of raw files"
        if panel.runModal() == .OK, let url = panel.url { open(url) }
    }

    /// Empties both large images and drops whatever was on its way to them.
    private func clearSlots() {
        compare = nil
        for (i, slot) in slots.enumerated() {
            slot.token += 1
            slot.frame = nil
            slot.target = nil
            slot.view?.show(nil, space: .zero, newFrame: true)
            setState(i, "")
        }
    }

    private func setState(_ index: Int, _ text: String) {
        if heroStates[index] != text { heroStates[index] = text }
    }

    private func close() {
        flushSave()
        exportRun += 1
        visible = []
        filter = .all
        generation += 1
        loadQueue.cancelAllOperations()
        folder = nil
        frames = []
        clearSlots()
        pane = .folders
        status = ""
        Log.note("folder", "closed")
    }

    /// Opens one folder. Only that folder is shown; subfolders are not entered.
    func open(_ url: URL) {
        flushSave()
        visible = []
        filter = .all
        fullSize = [:]
        values = [:]
        defaults = [:]
        generation += 1
        exportRun += 1
        let gen = generation
        loadQueue.cancelAllOperations()
        folder = url
        frames = []
        faces = [:]
        chosenFace = [:]
        rawCache.removeAll()
        introduced = []
        selected = 0
        clearSlots()
        pane = .thumbnails
        status = "Scanning folder…"
        remember(url)
        folderOpened = CFAbsoluteTimeGetCurrent()
        let opened = folderOpened
        Log.note("folder", "opening \(url.path)")
        let formats = self.formats
        DispatchQueue.global(qos: .userInitiated).async {
            let names = (try? FileManager.default.contentsOfDirectory(atPath: url.path)) ?? []
            let dir = FileDirOps(url)
            // Repair leftovers of an interrupted rating save before reading any sidecar.
            let repairs = Sidecars.recover(dir, names)
            for repair in repairs { Log.note("save", "repaired \(repair)") }
            // An export cut short (the app quit part-way) leaves a hidden, unfinished file.
            for n in names where n.hasPrefix(".") && n.hasSuffix(".exporting") {
                try? FileManager.default.removeItem(at: url.appendingPathComponent(n))
                Log.note("export", "removed the unfinished export \(n)")
            }
            let after = repairs.isEmpty ? names : ((try? FileManager.default.contentsOfDirectory(atPath: url.path)) ?? names)
            var sidecars: [String: String] = [:]
            for n in after where !n.hasPrefix(".") && n.lowercased().hasSuffix(".xmp") {
                sidecars[String(n.dropLast(4)).lowercased()] = n
            }
            // The launch check's made-up DNG: Apple's decoder opens it, but no recipe lists it.
            let dngToo = UserDefaults.standard.bool(forKey: "TCListDNG")
            let raws = after.filter { formats.isRaw($0) || (dngToo && !$0.hasPrefix(".") && $0.lowercased().hasSuffix(".dng")) }.sorted { $0.caseInsensitiveCompare($1) == .orderedAscending }
            let items: [FrameItem] = raws.enumerated().map { i, name in
                let fileURL = url.appendingPathComponent(name)
                let base = fileURL.deletingPathExtension().lastPathComponent
                let sidecar = sidecars[base.lowercased()]
                let text = sidecar.flatMap { dir.readText($0) }
                let values = text.map { SidecarValues(rating: Xmp.readRating($0) ?? 0, label: Xmp.readLabel($0)) }
                return FrameItem(id: i, url: fileURL, sidecarName: sidecar, values: values, adjust: text.map(Adjust.read) ?? [:])
            }
            let withSidecar = items.filter { $0.sidecarName != nil }.count
            Log.note("folder", "\(names.count) files, \(items.count) raw, \(withSidecar) with a sidecar; scanned in \(Log.seconds(since: opened))")
            DispatchQueue.main.async {
                guard gen == self.generation else { return }
                self.frames = items
                self.visible = items
                self.recount()
                if items.isEmpty {
                    self.status = "No raw files in this folder"
                    return
                }
                self.loadThumbnails(gen)
                self.renderTrigger = "selection"
                self.selectionChanged("programmatic (folder opened)")
                self.show(0)
                if UserDefaults.standard.bool(forKey: "TCCompare"), items.count > 1 { self.commandClick(1, cause: "programmatic (launch check)") }
                // For the automated build's launch check: Edit mode, to measure its memory.
                if UserDefaults.standard.bool(forKey: "TCEdit") { self.setEditing(true, cause: "programmatic (launch check)") }
                if UserDefaults.standard.bool(forKey: "TCScript") {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 4) { self.runLaunchScript() }
                }
            }
        }
    }

    private func remember(_ url: URL) {
        recents.removeAll { $0.path == url.path }
        recents.insert(url, at: 0)
        if recents.count > 12 { recents.removeLast(recents.count - 12) }
        UserDefaults.standard.set(recents.map { $0.path }, forKey: "recentFolders")
    }

    private func loadThumbnails(_ gen: Int) {
        let total = frames.count
        loadedCount = 0
        status = "Loading 0 / \(total)"
        let formats = self.formats
        for item in frames {
            loadQueue.addOperation { [weak self] in
                let result = Result { try Imaging.preview(item.url, formats, maxPixels: Imaging.thumbnailPixels) }
                DispatchQueue.main.async {
                    guard let self = self, gen == self.generation else { return }
                    switch result {
                    case let .success((info, image)):
                        item.info = info
                        item.thumb = image
                        // A large image still empty because this thumbnail hadn't loaded shows it
                        // now. Its preview and raw render are already on their way.
                        for slot in self.slots where slot.frame == item.id && slot.view?.space == .zero {
                            slot.view?.show(image, space: CGSize(width: image.width, height: image.height), newFrame: true)
                        }
                    case let .failure(error):
                        item.failed = "\(error)"
                        Log.note("image", "\(item.name): thumbnail failed: \(error)")
                    }
                    self.loadedCount += 1
                    if self.loadedCount == total {
                        self.status = ""
                        let failed = self.frames.filter { $0.failed != nil }.count
                        Log.note("folder", "\(total) thumbnails loaded \(Log.seconds(since: self.folderOpened)) after opening\(failed > 0 ? ", \(failed) failed" : "")")
                        MemoryMonitor.mark("loading \(total) thumbnails")
                    } else if self.loadedCount % 16 == 0 {
                        self.status = "Loading \(self.loadedCount) / \(total)"
                    }
                }
            }
        }
    }

    private func recount() {
        ratedCount = frames.filter { $0.rating > 0 }.count
        rejectedCount = frames.filter { $0.rating < 0 }.count
    }

    // MARK: Filter

    /// Shows all frames, only those rated at least so many stars, or only the rejects. The list
    /// is fixed when the filter is chosen, so a frame does not vanish the moment its rating changes.
    func setFilter(_ new: Filter) {
        filter = new
        switch new {
        case .all: visible = frames
        case let .rated(stars): visible = frames.filter { $0.rating >= stars }
        case .rejected: visible = frames.filter { $0.rating < 0 }
        }
        Log.note("filter", "\(new): \(visible.count) of \(frames.count) frames shown")
        // The side-by-side view keeps its two frames whatever the filter.
        if compare == nil, !visible.contains(where: { $0.id == selected }), let first = visible.first {
            select(first.id, cause: "programmatic (filter hid the selected frame)")
        }
        reveal()
    }

    /// Scrolls the thumbnail pane to the selected frame and flashes it, so it is easy to find
    /// again after a filter or a long scroll.
    func reveal() {
        revealTick += 1
        flashed = selected
        flashToken += 1
        let token = flashToken
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.7) { [weak self] in
            if self?.flashToken == token { self?.flashed = nil }
        }
    }

    func toggleRated() {
        if case .rated = filter { setFilter(.all) } else { setFilter(.rated(minStars)) }
    }

    func filterRated(atLeast stars: Int) {
        minStars = stars
        setFilter(.rated(stars))
    }

    func toggleRejected() { setFilter(filter == .rejected ? .all : .rejected) }

    func say(_ text: String) {
        Log.note("message", text)
        message = text
        messageToken += 1
        let token = messageToken
        DispatchQueue.main.asyncAfter(deadline: .now() + 5) { [weak self] in
            if self?.messageToken == token { self?.message = nil }
        }
    }

    // MARK: The large images

    func attach(_ view: HeroNSView, slot index: Int) {
        slots[index].view = view
        view.targetFor = { [weak self] point in
            self?.zoomTarget(at: point, slot: index)
                ?? FaceResult(method: .point, anchor: P(Double(point.x), Double(point.y)), eyeSpan: nil)
        }
        view.onZoom = { [weak self] fitted, percent in
            let text = fitted ? "Fit" : "\(percent)%"
            DispatchQueue.main.async {
                if let self = self, self.zoomTexts[index] != text { self.zoomTexts[index] = text }
            }
        }
        view.acceptsClick = { [weak self] in self?.clicked(index) ?? true }
        if index == 0 {
            view.picksPoint = pickingNeutral
            view.onPick = { [weak self] point in self?.pickNeutral(at: point) }
            view.onViewportChange = { [weak self] in self?.viewportChanged() }
        }
        view.onUserZoom = { [weak self] kind in self?.userZoomed(index, kind) }
        if frame(for: index) != nil { show(index) }
    }

    /// The frame a slot should show: the selected one in the single view, its side's frame when comparing.
    private func frame(for index: Int) -> FrameItem? {
        let id: Int
        if let pair = compare {
            id = pair.frame(index == 0 ? .left : .right)
        } else if index == 0 {
            id = selected
        } else {
            return nil
        }
        return frames.indices.contains(id) ? frames[id] : nil
    }

    /// A plain click on a thumbnail selects it. A command-click starts the side-by-side view,
    /// or replaces its active image; a plain click does nothing while comparing.
    func thumbnailClicked(_ id: Int, command: Bool) {
        if command {
            commandClick(id)
        } else if compare == nil {
            select(id)
        }
    }

    func select(_ index: Int, cause: String = "user.click") {
        guard compare == nil, frames.indices.contains(index), index != selected else { return }
        flushSave()
        selected = index
        selectionChanged(cause)
        renderTrigger = "selection"
        show(0)
    }

    /// Left and right arrows: through the frames the thumbnail pane shows. In the side-by-side
    /// view only the active image moves, and it steps over the frame on the other side.
    func step(_ by: Int) {
        guard !visible.isEmpty else { return }
        let cause = "user.key (\(by < 0 ? "←" : "→"))"
        if let pair = compare {
            if let target = pair.stepTarget(by, in: visible.map { $0.id }) { setActiveFrame(target, cause: cause) }
            return
        }
        guard let at = visible.firstIndex(where: { $0.id == selected }) else {
            select(visible[0].id, cause: cause)
            return
        }
        select(visible[min(max(at + by, 0), visible.count - 1)].id, cause: cause)
    }

    /// The selected frame changed: the editing controls follow it. `cause` says who changed it,
    /// for the log: a click, a key, or the app itself (and then which part of it).
    private func selectionChanged(_ cause: String) {
        editToken += 1
        valuesToken += 1
        guard let item = current else {
            values = [:]
            defaults = [:]
            return
        }
        Log.note("select", "\(item.name) (\(item.id + 1) of \(frames.count)) · cause: \(cause)",
                 fields: ["frame": item.name, "index": item.id + 1, "count": frames.count, "cause": cause])
        // The camera settings, the first time a frame is selected.
        if !introduced.contains(item.id), let shot = item.info?.shot {
            introduced.insert(item.id)
            Log.note("image", "\(item.name): \(shot.label())\(shot.lens.map { " · \($0)" } ?? "")")
        }
        flushPendingChanges("another frame was selected first")
        pickingNeutral = false
        values = item.adjust
        defaults = [:]
        supported = [:]
        decoderLine = .label("")
        let token = valuesToken
        let name = item.name, id = item.id
        // The renderer's own filter gives Apple's defaults: no other filter is made for them.
        rendererFor(item).facts { facts, size in
            if let facts = facts { Session.logFacts(facts, name) }
            if size.width > 0 { self.fullSize[id] = size }
            guard token == self.valuesToken else { return }
            self.defaults = facts?.defaults ?? [:]
            self.supported = facts?.supported ?? [:]
            self.decoderLine = facts.map { RawPanel.decoderLine($0.decoders) } ?? .label("")
        }
    }

    /// Shows a slot's frame: the thumbnail at once, then the large embedded preview, then the
    /// raw rendered by Apple's decoder once the frame has been still for a moment.
    private func show(_ index: Int, keepZoom: Bool = false) {
        let slot = slots[index]
        guard let item = frame(for: index), let view = slot.view else { return }
        slot.token += 1
        slot.frame = item.id
        slot.target = nil
        let token = slot.token
        let url = item.url
        let id = item.id
        let name = item.name
        let formats = self.formats
        let adjust = item.adjust
        let started = CFAbsoluteTimeGetCurrent()

        let single = index == 0 && compare == nil
        if single {
            settleWork?.cancel()
            settleWork = nil
            shownSeq = previewSeq // anything still on its way is for the frame before
            shownWhole = nil
            shownPart = nil
            selectionStarted = started
            firstRenderLogged = false
        }
        switch rawCache.lookup(id, adjust) {
        case let .hit(cached) where adequate(cached, id: id, single: single):
            let size = fullSize[id] ?? CGSize(width: cached.width, height: cached.height)
            view.show(cached, space: size, newFrame: true, keepZoom: keepZoom, kind: "Raw")
            setState(index, "Raw")
            if single {
                shownWhole = (adjust, .whole(viewLongEdge: CGFloat(max(cached.width, cached.height))), false)
                firstRenderLogged = true
                viewportChanged()
            }
            Log.note("cache", "render \(name) · hit", fields: ["frame": name, "result": "hit"])
            return
        case .hit:
            Log.note("cache", "render \(name) · miss: kept at a smaller size", fields: ["frame": name, "result": "miss", "reason": "smaller"])
        case let .miss(why):
            Log.note("cache", "render \(name) · miss: \(why.rawValue)", fields: ["frame": name, "result": "miss", "reason": why.rawValue])
        }
        if let t = item.thumb {
            view.show(t, space: CGSize(width: t.width, height: t.height), newFrame: true, keepZoom: keepZoom)
        } else {
            view.show(nil, space: .zero, newFrame: true)
        }
        setState(index, "Preview")

        let needFaces = faces[id] == nil
        heroQueue.async {
            guard let (_, big) = try? Imaging.preview(url, formats, maxPixels: nil) else {
                Log.note("image", "\(name): the embedded preview couldn't be read")
                return
            }
            Log.note("image", "\(name): embedded preview \(big.width)×\(big.height) after \(Log.seconds(since: started))")
            DispatchQueue.main.async {
                // The frame's size comes from the renderer's filter; no filter is made here for it.
                let size = self.fullSize[id] ?? CGSize(width: big.width, height: big.height)
                // Only while nothing better is up: a raw render may have arrived first.
                guard token == slot.token, self.heroStates[index] == "Preview" else { return }
                slot.view?.show(big, space: size, newFrame: false)
            }
            if needFaces {
                let detecting = CFAbsoluteTimeGetCurrent()
                let found = Imaging.detectFaces(big)
                Log.note("image", "\(name): \(found.subjects.count) face(s) found in \(Log.seconds(since: detecting))")
                DispatchQueue.main.async { self.faces[id] = found }
            }
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
            guard token == slot.token else { return }
            if index == 0 && self.compare == nil {
                self.renderTrigger = "selection"
                self.requestSettled(trigger: "selection")
                return
            }
            self.renderWhole(index, token: token, item: item, adjust: adjust, started: started)
        }
    }

    /// A full-resolution render with a fresh filter: the side-by-side view's way (no editing
    /// happens there).
    private func renderWhole(_ index: Int, token: Int, item: FrameItem, adjust: [String: Float], started: CFAbsoluteTime) {
        let slot = slots[index]
        let url = item.url, id = item.id, name = item.name, formats = self.formats
        do {
            self.rawQueue.async {
                var stillWanted = false
                DispatchQueue.main.sync { stillWanted = token == slot.token }
                guard stillWanted else { return }
                let rendering = CFAbsoluteTimeGetCurrent()
                let meter = JobMeter()
                let raw = Imaging.renderRaw(url, adjust)
                let image = raw ?? Imaging.fullJpeg(url, formats)
                let measured = meter.finish()
                if let image = image {
                    var fields = measured.fields
                    fields["frame"] = name
                    fields["trigger"] = "selection"
                    fields["width"] = image.width
                    fields["height"] = image.height
                    Log.note("image", "\(name): \(raw != nil ? "raw render" : "embedded JPEG (no raw render)") \(image.width)×\(image.height) in \(Log.seconds(since: rendering)), \(Log.seconds(since: started)) after selecting · trigger: selection",
                             fields: fields)
                    Log.note("job", "render \(name) · \(measured.text)", fields: fields)
                } else {
                    Log.note("image", "\(name): neither the raw nor its embedded JPEG could be shown")
                }
                MemoryMonitor.mark("rendering \(name)")
                DispatchQueue.main.async {
                    guard let image = image else {
                        if token == slot.token { self.setState(index, "Preview only") }
                        return
                    }
                    if raw != nil {
                        self.cache(id, adjust, image)
                        self.fullSize[id] = CGSize(width: image.width, height: image.height)
                    }
                    guard token == slot.token, item.adjust == adjust else { return }
                    slot.view?.show(image, space: CGSize(width: image.width, height: image.height), newFrame: false, kind: raw != nil ? "Raw" : "")
                    self.setState(index, raw != nil ? "Raw" : "Embedded JPEG")
                }
            }
        }
    }

    /// Whether a kept render is sharp enough for where it is going: the single view needs what
    /// its settled render would make, the side-by-side view full resolution.
    private func adequate(_ image: CGImage, id: Int, single: Bool) -> Bool {
        guard let full = fullSize[id] else { return !single ? false : true }
        let fullEdge = max(full.width, full.height)
        var needed = fullEdge
        if single, let w = wants(PreviewTuning.current), case let .whole(edge?) = w.settled { needed = min(edge, fullEdge) }
        return CGFloat(max(image.width, image.height)) >= needed * 0.98
    }

    /// A slot's faces, in pixels of what its view shows now.
    private func subjects(in index: Int) -> [Subject]? {
        guard let id = slots[index].frame, let found = faces[id], found.imageWidth > 0,
              let space = slots[index].view?.space, space.width > 0 else { return nil }
        let k = Double(space.width) / found.imageWidth
        return found.subjects.map { $0.scaled(k) }
    }

    private func nearest(_ subjects: [Subject], _ x: Double, _ y: Double) -> Int {
        func distance(_ s: Subject) -> Double {
            let dx = s.centerX - x, dy = s.centerY - y
            return dx * dx + dy * dy
        }
        return subjects.indices.min { distance(subjects[$0]) < distance(subjects[$1]) } ?? 0
    }

    /// A click goes to face zoom on the face nearest the click; with no face, to the clicked point.
    private func zoomTarget(at point: CGPoint, slot index: Int) -> FaceResult {
        var result = FaceResult(method: .point, anchor: P(Double(point.x), Double(point.y)), eyeSpan: nil)
        if let id = slots[index].frame, let found = subjects(in: index), !found.isEmpty {
            let face = nearest(found, Double(point.x), Double(point.y))
            chosenFace[id] = face
            result = Framing.fromSubject(found[face])
        }
        slots[index].target = result
        Log.note("zoom", "click → \(result.method.rawValue)")
        return result
    }

    /// The next face, when the frame has several: Tab in the single view, the Next Face button
    /// when comparing (where one face is enough: the button then zooms to it).
    func nextFace() {
        let index = activeSlot
        guard let id = slots[index].frame, let view = slots[index].view,
              let found = subjects(in: index), found.count > (compare == nil ? 1 : 0) else { return }
        let face = ((chosenFace[id] ?? -1) + 1) % found.count
        chosenFace[id] = face
        let result = Framing.fromSubject(found[face])
        slots[index].target = result
        Log.note("zoom", "face \(face + 1) of \(found.count)")
        view.zoom(to: result)
        userZoomed(index, .click)
    }

    // MARK: Side by side

    /// Command-click on a thumbnail: show it beside the current image, or, when already
    /// comparing, put it in place of the active image.
    func commandClick(_ id: Int, cause: String = "user.click (⌘)") {
        guard frames.indices.contains(id) else { return }
        if let pair = compare {
            if id != pair.left && id != pair.right { setActiveFrame(id, cause: cause) }
            return
        }
        guard current != nil, id != selected else { return }
        flushSave()
        if editing { editing = false }
        Log.note("compare", "started: \(frames[selected].name) | \(frames[id].name)")
        // Both sides start fitted, so their zoom is linked from the first click.
        slots[0].view?.fit(animated: false)
        settleWork?.cancel()
        settleWork = nil
        compare = ComparePair(left: selected, right: id, active: .right)
        // The left side may hold a view-sized render; side by side zooms want full resolution.
        if let left = frame(for: 0), let shown = slots[0].view?.shownPicture,
           CGFloat(shown.image.width) < (fullSize[left.id]?.width ?? 0) * 0.99 {
            renderWhole(0, token: slots[0].token, item: left, adjust: left.adjust, started: CFAbsoluteTimeGetCurrent())
        }
        selected = id
        selectionChanged("\(cause), side by side")
        // The right-hand view shows its frame as soon as the window has made it (`attach`).
        if slots[1].view != nil { show(1) }
    }

    /// Puts another frame on the active side.
    private func setActiveFrame(_ id: Int, cause: String) {
        guard var pair = compare, frames.indices.contains(id) else { return }
        pair.activeFrame = id
        compare = pair
        selected = id
        selectionChanged(cause)
        // A zoomed image stays zoomed on the same spot, to step through a burst at one zoom.
        show(pair.active.rawValue, keepZoom: true)
    }

    func setActiveSide(_ side: ComparePair.Side, cause: String = "user.click (other image)") {
        guard var pair = compare, pair.active != side else { return }
        pair.active = side
        compare = pair
        selected = pair.activeFrame
        selectionChanged(cause)
    }

    /// Back to the single view, which then shows the active image.
    func endCompare() {
        guard let pair = compare else { return }
        Log.note("compare", "ended on \(frames.indices.contains(pair.activeFrame) ? frames[pair.activeFrame].name : "?")")
        compare = nil
        selected = pair.activeFrame
        slots[1].token += 1
        slots[1].frame = nil
        slots[1].target = nil
        slots[1].view?.show(nil, space: .zero, newFrame: true)
        setState(1, "")
        if slots[0].frame != selected {
            show(0)
        } else {
            slots[0].view?.fit(animated: false)
        }
        selectionChanged("programmatic (left side by side)")
        reveal()
    }

    /// The first click on the inactive image only makes it active.
    private func clicked(_ index: Int) -> Bool {
        guard let pair = compare, pair.active.rawValue != index else { return true }
        setActiveSide(index == 0 ? .left : .right)
        return false
    }

    /// Image pixels per pixel of what a slot's view shows right now: above 1 while it still
    /// shows a small preview of a frame whose real size is known.
    private func coarseness(_ index: Int) -> CGFloat {
        guard let id = slots[index].frame, let space = slots[index].view?.space, space.width > 0 else { return 1 }
        var full = fullSize[id]
        if full == nil, let other = slots[1 - index].frame, let guess = fullSize[other] {
            // Not measured yet. Frames from one camera are the same size, turned or not.
            let sameWay = (guess.width >= guess.height) == (space.width >= space.height)
            full = sameWay ? guess : CGSize(width: guess.height, height: guess.width)
        }
        return (full?.width ?? space.width) / space.width
    }

    /// One image's zoom changed by a click or a pinch: the image beside it follows. A click
    /// brings it to the same percentage, centred on its own face (the one sitting where the
    /// clicked face sits) or else on the same spot of the frame. A pinch changes its zoom only.
    private func userZoomed(_ index: Int, _ kind: HeroNSView.UserZoom) {
        guard compare != nil, let mine = slots[index].view, let other = slots[1 - index].view else { return }
        let scale = mine.zoomScale.map { $0 / coarseness(index) * coarseness(1 - index) }
        switch kind {
        case .pinch:
            other.follow(scale: scale, face: nil, spot: nil, animated: false)
        case .click:
            other.follow(scale: scale, face: scale == nil ? nil : matchingFace(in: 1 - index, to: index), spot: mine.spot, animated: true)
        }
    }

    /// The face in one image that sits where the face just zoomed to sits in the other. Nil
    /// when that zoom wasn't to a face, or this image has none.
    private func matchingFace(in index: Int, to source: Int) -> FaceResult? {
        guard let target = slots[source].target, target.method != .point,
              let from = slots[source].view?.space, from.width > 0, from.height > 0,
              let to = slots[index].view?.space,
              let id = slots[index].frame, let found = subjects(in: index), !found.isEmpty else { return nil }
        let face = nearest(found, target.anchor.x / Double(from.width) * Double(to.width),
                           target.anchor.y / Double(from.height) * Double(to.height))
        chosenFace[id] = face
        let result = Framing.fromSubject(found[face])
        slots[index].target = result
        return result
    }

    // MARK: Editing

    /// The Edit button. Editing happens in the single view, so it leaves the side-by-side view first.
    func toggleEditing() {
        setEditing(!editing, cause: "user.click")
    }

    private func setEditing(_ on: Bool, cause: String) {
        guard on != editing else { return }
        if on, compare != nil { endCompare() }
        editing = on
        if !on { pickingNeutral = false }
        Log.note("edit", "edit mode \(on ? "on" : "off") · cause: \(cause)")
        // Entering Edit mode only swaps the thumbnails for sliders; this reading shows it costs nothing.
        if on { MemoryMonitor.mark("entering Edit mode") }
    }

    private func cache(_ id: Int, _ values: [String: Float], _ image: CGImage) {
        let bytes = image.bytesPerRow * image.height
        let out = rawCache.insert(id, values, image, bytes: bytes)
        for gone in out {
            let name = frames.indices.contains(gone.id) ? frames[gone.id].name : "frame \(gone.id + 1)"
            Log.note("cache", "render \(name) evicted (LRU), \(MemoryStats.plain(UInt64(gone.bytes))) · kept \(rawCache.count) / "
                + "\(MemoryStats.plain(UInt64(rawCache.bytes))) of \(MemoryStats.plain(UInt64(Session.renderCacheBytes)))",
                fields: ["frame": name, "bytes": gone.bytes, "kept": rawCache.count, "kept_bytes": rawCache.bytes])
        }
    }

    /// The value a control shows: the changed one, else the file's default.
    func value(_ control: Control) -> Float { values[control.key] ?? defaults[control.key] ?? control.neutral }

    func isChanged(_ control: Control) -> Bool { values[control.key] != nil }

    /// Greyed out with a red dot when Apple says the control isn't supported for this file.
    func state(_ control: Control) -> ControlState { RawPanel.state(control, supported: supported) }

    func setValue(_ control: Control, _ new: Float) {
        guard let item = current, state(control).enabled, !defaults.isEmpty else { return }
        let old = value(control)
        let dragging = dragStart[control.key] != nil
        renderTrigger = dragging ? "\(control.title) drag" : "\(control.title) set"
        let span = control.range.upperBound - control.range.lowerBound
        if let d = defaults[control.key], abs(d - new) <= span * 0.0005 {
            values[control.key] = nil
        } else {
            values[control.key] = new
        }
        edited(item)
        // A drag is logged once, when it ends; anything else at once.
        if !dragging { noteChange(control, old: old, new: value(control), isDragEnd: false, cause: "set") }
    }

    /// A slider's drag began or ended (a click on its track counts as a short drag).
    func dragChanged(_ control: Control, began: Bool) {
        if began {
            dragStart[control.key] = value(control)
            drag = DragRecord(key: control.key, start: value(control), replaced: renderer?.replaced ?? 0, creations: lastKnownCreations,
                              stale: staleFrames, tuning: PreviewTuning.current)
        } else if let old = dragStart.removeValue(forKey: control.key) {
            noteChange(control, old: old, new: value(control), isDragEnd: true, cause: "drag")
            if let d = drag, d.key == control.key {
                d.released = CFAbsoluteTimeGetCurrent()
                d.end = value(control)
                // The settle delay counts from the release.
                if compare == nil, current != nil { scheduleSettle() }
            }
        }
    }

    func reset(_ control: Control) {
        guard let item = current, values[control.key] != nil else { return }
        let old = value(control)
        renderTrigger = "\(control.title) reset"
        values[control.key] = nil
        edited(item)
        noteChange(control, old: old, new: value(control), isDragEnd: false, cause: "reset")
    }

    /// Every control, old and new, back to Apple's default for this file.
    func resetAll() {
        guard let item = current, !values.isEmpty else { return }
        let moved = Adjust.controls.filter { values[$0.key] != nil }.map { ($0, value($0)) }
        renderTrigger = "reset all"
        values = [:]
        edited(item)
        for (control, old) in moved { noteChange(control, old: old, new: value(control), isDragEnd: false, cause: "reset all") }
    }

    /// Turns the white-balance eyedropper on or off.
    func toggleNeutralPick() {
        guard editing, current != nil else { return }
        pickingNeutral.toggle()
        Log.note("edit", "white balance by point \(pickingNeutral ? "on: click a neutral point" : "cancelled")")
    }

    /// White balance by point: Apple works out the temperature and tint that make the clicked
    /// point neutral, and they become the frame's Temperature and Tint.
    func pickNeutral(at point: CGPoint) {
        guard pickingNeutral, let item = current, let temperature = Adjust.control("temperature"), let tint = Adjust.control("tint") else { return }
        pickingNeutral = false
        let url = item.url, adjust = item.adjust, frame = heroToken
        let started = CFAbsoluteTimeGetCurrent()
        rawQueue.async {
            let found = Imaging.neutral(at: point, url, adjust)
            DispatchQueue.main.async {
                guard frame == self.heroToken, self.current === item else { return }
                guard let found = found else {
                    Log.warn("\(item.name): white balance by point failed at \(Int(point.x)), \(Int(point.y))")
                    self.say("Apple's decoder couldn't set the white balance from that point.")
                    return
                }
                Log.note("edit", "\(item.name): white balance by point at \(Int(point.x)), \(Int(point.y)) (Core Image \(Int(found.location.x)), \(Int(found.location.y)))"
                    + " → \(Int(found.temperature.rounded())) K, tint \(String(format: "%+.1f", found.tint)) in \(Log.seconds(since: started))",
                    fields: ["file": item.name, "x": Double(point.x), "y": Double(point.y), "temperature": Double(found.temperature), "tint": Double(found.tint)])
                let oldT = self.value(temperature), oldTint = self.value(tint)
                self.renderTrigger = "white balance by point"
                self.values["temperature"] = found.temperature
                self.values["tint"] = found.tint
                self.edited(item)
                self.noteChange(temperature, old: oldT, new: found.temperature, isDragEnd: false, cause: "white balance by point")
                self.noteChange(tint, old: oldTint, new: found.tint, isDragEnd: false, cause: "white balance by point")
            }
        }
    }

    // MARK: The change log

    private func noteChange(_ control: Control, old: Float, new: Float, isDragEnd: Bool, cause: String) {
        guard let item = current else { return }
        pendingChanges.append(Change(file: item.name, frame: item.id, key: control.key, old: old, new: new, isDragEnd: isDragEnd,
                                     cause: cause, at: CFAbsoluteTimeGetCurrent(), editToken: editToken))
    }

    /// The full render for edit `token` is on screen: every change it shows gets its line.
    private func changesShown(frame: Int, token: Int, readBack: [String: Float], peak: Double) {
        let now = CFAbsoluteTimeGetCurrent()
        let shown = pendingChanges.filter { $0.frame == frame && $0.editToken <= token }
        pendingChanges.removeAll { $0.frame == frame && $0.editToken <= token }
        for change in shown { logChange(change, readBack: readBack[change.key], renderMs: (now - change.at) * 1000, peak: peak) }
    }

    /// Changes whose frame never reached the screen (another frame was chosen first).
    private func flushPendingChanges(_ why: String) {
        let left = pendingChanges
        pendingChanges = []
        for change in left { logChange(change, readBack: nil, renderMs: nil, peak: nil, note: why) }
    }

    private func logChange(_ c: Change, readBack: Float?, renderMs: Double?, peak: Double?, note: String? = nil) {
        guard let control = Adjust.control(c.key) else { return }
        let appleDefault = defaults[c.key]
        func json(_ v: Float?) -> Any { v.map { Double($0) } ?? NSNull() }
        let fields: [String: Any] = [
            "file": c.file, "control": control.title, "appleProperty": control.appleProperty,
            "oldValue": Double(c.old), "newValue": Double(c.new), "appleDefault": json(appleDefault), "readBackValue": json(readBack),
            "renderMs": renderMs.map { $0 as Any } ?? NSNull(), "peakMemoryMB": peak.map { $0 as Any } ?? NSNull(),
            "zoom": zoomTexts[0], "isDragEnd": c.isDragEnd, "cause": c.cause,
        ]
        let text = "\(c.file): \(control.title) \(control.show(c.old)) → \(control.show(c.new)) (\(c.cause))"
            + " · Apple default \(appleDefault.map(control.show) ?? "unknown")"
            + " · read back \(readBack.map { String(format: "%.3f", $0) } ?? "—")"
            + (renderMs.map { String(format: " · on screen after %.0f ms", $0) } ?? "")
            + (peak.map { String(format: " · peak %.0f MB", $0) } ?? "")
            + " · zoom \(zoomTexts[0])\(c.isDragEnd ? " · drag end" : "")\(note.map { " · \($0)" } ?? "")"
        Log.note("change", text, fields: fields)
    }

    /// One line per selected frame: every control's Apple default and supported flag.
    private static func logFacts(_ facts: RawFacts, _ name: String) {
        var controls: [String: Any] = [:]
        var parts: [String] = []
        for c in Adjust.controls where c.kind != .neutralPoint {
            let d = facts.defaults[c.key]
            let flag: Any = c.supportProperty.map { (facts.supported[$0] ?? false) as Any } ?? "n/a"
            controls[c.title] = ["appleProperty": c.appleProperty, "default": d.map { Double($0) as Any } ?? NSNull(), "supported": flag]
            let shown = d.map { String(format: "%.3f", $0) } ?? "?"
            parts.append("\(c.title) \(shown)\(c.supportProperty.map { facts.supported[$0] == false ? " (not supported)" : "" } ?? "")")
        }
        Log.note("raw", "\(name): decoder \(facts.decoder) of [\(facts.decoders.joined(separator: ", "))] · Apple's defaults: \(parts.joined(separator: " · "))",
                 fields: ["file": name, "decoder": facts.decoder, "decoders": facts.decoders, "controls": controls])
    }

    private func edited(_ item: FrameItem) {
        item.adjust = values
        editToken += 1
        requestDraft()
        scheduleSettle()
        pendingSave = item
        saveToken += 1
        let save = saveToken
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { if save == self.saveToken { self.flushSave() } }
    }

    // MARK: The single view's renders

    @discardableResult
    private func rendererFor(_ item: FrameItem) -> PreviewRenderer {
        let legacy = PreviewTuning.current.legacy
        if let r = renderer, r.url == item.url, r.legacy == legacy { return r }
        // The previous file's filter goes with its renderer.
        let r = PreviewRenderer(url: item.url, legacy: legacy)
        renderer = r
        lastKnownCreations = 0
        return r
    }

    /// What the single view wants drawn: while a slider moves, and once settled.
    private func wants(_ tuning: PreviewTuning) -> (draft: PreviewRenderer.Want, settled: PreviewRenderer.Want)? {
        guard let view = slots[0].view, view.bounds.width > 0 else { return nil }
        let px = view.pixelSize
        let fit = PreviewRenderer.Want.whole(viewLongEdge: max(px.width, px.height))
        if tuning.legacy { return (fit, .whole(viewLongEdge: nil)) }
        if view.isZoomed {
            let t = view.targetView
            guard tuning.visibleRegion, view.space.width > 0, view.space.height > 0, !t.rect.isEmpty else { return (fit, .whole(viewLongEdge: nil)) }
            // The part in view with a small margin, so a little panning stays sharp.
            let m = 0.05 * max(t.rect.width, t.rect.height)
            let r = t.rect.insetBy(dx: -m, dy: -m).intersection(CGRect(origin: .zero, size: view.space))
            let fraction = CGRect(x: r.minX / view.space.width, y: r.minY / view.space.height,
                                  width: r.width / view.space.width, height: r.height / view.space.height)
            let fullWidth = current.flatMap { fullSize[$0.id]?.width } ?? view.space.width
            let region = PreviewRenderer.Want.region(fraction, screenPixelsPerPixel: t.pixelsPerPicturePixel * view.space.width / fullWidth)
            return (region, region)
        }
        return (fit, tuning.viewSizeSettle ? fit : .whole(viewLongEdge: nil))
    }

    private func submitPreview(_ item: FrameItem, want: PreviewRenderer.Want, draft: Bool, quick: Bool, trigger: String) {
        let r = rendererFor(item)
        previewSeq += 1
        let request = PreviewRenderer.Request(seq: previewSeq, values: item.adjust, want: want, draft: draft,
                                              requested: CFAbsoluteTimeGetCurrent(), quick: quick)
        let token = heroToken, edit = editToken
        r.submit(request) { [weak self] frame in
            self?.previewArrived(frame, item: item, heroToken: token, editToken: edit, trigger: trigger)
        }
    }

    /// A quick frame while a slider moves: Apple's draft mode, at the view's size or for the part in view.
    private func requestDraft() {
        guard compare == nil, let item = current else { return }
        let tuning = PreviewTuning.current
        guard let w = wants(tuning) else { return }
        submitPreview(item, want: w.draft, draft: tuning.draftMode && !tuning.legacy, quick: true, trigger: renderTrigger)
    }

    /// The settled render, once the sliders have been still for the settle delay.
    private func scheduleSettle() {
        settleWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self = self else { return }
            self.settleWork = nil
            if let d = self.drag, d.released != nil, d.settleStart == nil { d.settleStart = CFAbsoluteTimeGetCurrent() }
            self.requestSettled(trigger: self.renderTrigger)
        }
        settleWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + PreviewTuning.current.settleDelay, execute: work)
    }

    private func requestSettled(trigger: String) {
        settleWork?.cancel()
        settleWork = nil
        guard compare == nil, let item = current, let w = wants(PreviewTuning.current) else { return }
        submitPreview(item, want: w.settled, draft: false, quick: false, trigger: trigger)
    }

    /// The single view's zoom, position or size changed: once it has been still a moment, the
    /// settled picture is made for the new view if what is on screen doesn't already fit it.
    private func viewportChanged() {
        guard compare == nil else { return }
        viewportWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            self?.viewportWork = nil
            self?.viewportSettled()
        }
        viewportWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25, execute: work)
    }

    private func viewportSettled() {
        guard compare == nil, let item = current, settleWork == nil, shownWhole != nil || shownPart != nil,
              let w = wants(PreviewTuning.current) else { return }
        let values = item.adjust
        switch w.settled {
        case .whole:
            if shownPart != nil {
                slots[0].view?.clearDetail()
                shownPart = nil
            }
            if let s = shownWhole, !s.draft, s.values == values, s.want == w.settled { return }
        case .region:
            if let p = shownPart, !p.draft, p.values == values, p.want == w.settled { return }
        }
        requestSettled(trigger: "zoom or pan")
    }

    /// A frame from the renderer: shown only if nothing newer is on screen, for the frame still selected.
    private func previewArrived(_ frame: PreviewRenderer.Frame?, item: FrameItem, heroToken token: Int, editToken edit: Int, trigger: String) {
        guard let frame = frame else {
            if token == heroToken { Log.warn("\(item.name): a preview render failed · trigger: \(trigger)") }
            return
        }
        lastKnownCreations = frame.creations
        // "Draft" on screen means a quick frame while a slider moves, whether or not Apple's
        // draft mode made it.
        let draft = frame.request.quick
        guard token == heroToken, current === item, compare == nil, let view = slots[0].view, frame.request.seq > shownSeq else {
            staleFrames += 1
            return
        }
        shownSeq = frame.request.seq
        fullSize[item.id] = frame.fullSize
        let kind = draft ? "Draft" : "Raw"
        if frame.isWhole {
            view.show(frame.image, space: frame.fullSize, newFrame: false, kind: kind)
            shownWhole = (frame.request.values, frame.request.want, draft)
            shownPart = nil
        } else {
            var rect = frame.rect
            if view.space != frame.fullSize, view.space.width > 0 {
                let k = view.space.width / frame.fullSize.width
                rect = CGRect(x: rect.minX * k, y: rect.minY * k, width: rect.width * k, height: rect.height * k)
            }
            view.showDetail(frame.image, rect: rect, kind: kind)
            shownPart = (frame.request.values, frame.request.want, draft)
        }
        setState(0, kind)
        let tuning = PreviewTuning.current
        Log.debug("preview", "\(item.name): \(kind.lowercased()) frame #\(frame.request.seq) \(frame.image.width)×\(frame.image.height) · \(frame.request.want.text) · \(String(format: "%.0f", frame.renderMs)) ms",
                  fields: ["file": item.name, "seq": frame.request.seq, "draft": draft, "draftMode": frame.request.draft, "renderMs": frame.renderMs, "width": frame.image.width,
                           "height": frame.image.height, "want": frame.request.want.text, "scale": Double(frame.scale), "creations": frame.creations,
                           "tuning": tuning.fields])
        if draft {
            drag?.frameMs.append(frame.renderMs)
            return
        }
        if frame.isWhole { cache(item.id, frame.request.values, frame.image) }
        Log.note("image", "\(item.name): settled render \(frame.image.width)×\(frame.image.height) (\(frame.request.want.text)) in \(String(format: "%.0f", frame.renderMs)) ms · trigger: \(trigger)",
                 fields: ["file": item.name, "width": frame.image.width, "height": frame.image.height, "want": frame.request.want.text,
                          "renderMs": frame.renderMs, "trigger": trigger, "tuning": tuning.fields])
        changesShown(frame: item.id, token: edit, readBack: frame.readBack, peak: frame.peakBytes / 1_048_576)
        if !firstRenderLogged {
            firstRenderLogged = true
            let ms = (CFAbsoluteTimeGetCurrent() - selectionStarted) * 1000
            Log.note("render", "\(item.name): first raw render on screen \(String(format: "%.0f", ms)) ms after selecting · Apple raw filters made: \(frame.creations)",
                     fields: ["file": item.name, "timeToFirstRawRenderMs": ms, "filterCreations": frame.creations, "tuning": tuning.fields])
        }
        if let d = drag, d.released != nil, frame.request.values == item.adjust { finishDrag(d, settled: frame, item: item) }
    }

    /// One line per drag, once its settled render is on screen.
    private func finishDrag(_ d: DragRecord, settled: PreviewRenderer.Frame, item: FrameItem) {
        drag = nil
        let now = CFAbsoluteTimeGetCurrent()
        let ms = d.frameMs.sorted()
        func pct(_ p: Double) -> Double { ms.isEmpty ? 0 : ms[min(ms.count - 1, max(0, Int((p * Double(ms.count)).rounded(.up)) - 1))] }
        let measured = d.meter.finish()
        let peak = ((measured.fields["memory_peak"] as? Double) ?? 0) / 1_048_576
        let stale = staleFrames - d.staleAtStart
        let replaced = (renderer?.replaced ?? d.replacedAtStart) - d.replacedAtStart
        let released = d.released ?? now
        let control = Adjust.control(d.key)
        let fields: [String: Any] = [
            "file": item.name, "control": control?.title ?? d.key, "appleProperty": control?.appleProperty ?? d.key,
            "startValue": Double(d.start), "endValue": Double(d.end ?? d.start),
            "framesRendered": d.frameMs.count + stale, "framesShown": d.frameMs.count, "framesDropped": replaced + stale,
            "medianFrameMs": pct(0.5), "p95FrameMs": pct(0.95), "maxFrameMs": ms.last ?? 0,
            "releaseToSettleStartMs": d.settleStart.map { ($0 - released) * 1000 as Any } ?? NSNull(),
            "releaseToSettledMs": (now - released) * 1000,
            "peakMemoryMB": peak, "zoom": zoomTexts[0], "tuning": d.tuning.fields,
            "filterCreations": settled.creations - d.creationsAtStart,
            "outOfOrderShown": 0, "settledMatchesFinal": settled.request.values == item.adjust,
            "settledSize": [settled.image.width, settled.image.height], "settledWant": settled.request.want.text,
        ]
        Log.note("drag", "\(item.name): \(control?.title ?? d.key) \(d.start) → \(d.end ?? d.start) · \(d.frameMs.count) frames shown, \(replaced + stale) dropped"
            + String(format: " · median %.0f ms, p95 %.0f ms, max %.0f ms", pct(0.5), pct(0.95), ms.last ?? 0)
            + String(format: " · release to settled %.0f ms · peak %.0f MB", (now - released) * 1000, peak)
            + " · \(zoomTexts[0]) · \(d.tuning.text)", fields: fields)
    }

    /// Writes any edits still waiting to the sidecar now.
    func flushSave() {
        guard let item = pendingSave, let folder = folder else { return }
        pendingSave = nil
        saveToken += 1
        let fields = Adjust.fields(item.adjust)
        let changed = item.adjust.keys.sorted().joined(separator: ", ")
        let values = SidecarValues(rating: item.rating, label: item.label)
        let known = item.sidecarName
        let base = item.baseName
        sidecarQueue.async {
            let dir = FileDirOps(folder)
            let fresh = base + ".xmp"
            let sidecar = known ?? (dir.exists(fresh) ? fresh : nil)
            do {
                let name = try Edits.write(dir, baseName: base, sidecarName: sidecar, values: values, fields: fields)
                Log.note("save", "\(item.name): edits saved to \(name ?? sidecar ?? "no sidecar (nothing changed)") [\(changed)]")
                DispatchQueue.main.async { if let name = name { item.sidecarName = name } }
            } catch {
                Log.note("save", "\(item.name): edits NOT saved: \(error)")
                DispatchQueue.main.async { self.say("The edits for \(item.name) couldn't be saved. \(error)") }
            }
        }
    }

    /// Hands raw files to the editor. Photoshop opens them in Camera Raw.
    func sendToEditor(_ items: [FrameItem]) {
        guard !items.isEmpty else { return }
        flushSave()
        guard let app = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.adobe.Photoshop") else {
            say("Photoshop wasn't found on this Mac.")
            return
        }
        let urls = items.map { $0.url }
        Log.note("send", "to Photoshop: \(items.map { $0.name }.joined(separator: ", "))")
        // Let any save still on its way reach the disk first.
        sidecarQueue.async {
            DispatchQueue.main.async {
                NSWorkspace.shared.open(urls, withApplicationAt: app, configuration: NSWorkspace.OpenConfiguration()) { _, error in
                    if let error = error {
                        DispatchQueue.main.async { self.say("Photoshop couldn't open the file. \(error.localizedDescription)") }
                    }
                }
            }
        }
    }

    // MARK: Exports

    /// Extracts the embedded JPEG, or exports a developed 16-bit TIFF, for some frames: one at
    /// a time, each saved next to its raw under the raw's name.
    func export(_ kind: Export.Kind, _ items: [FrameItem]) {
        guard !items.isEmpty else { return }
        guard exportStatus == nil else {
            say("An export is already running.")
            return
        }
        flushSave()
        exportRun += 1
        let run = exportRun
        let total = items.count
        exportStatus = "Exporting 0 / \(total)"
        let formats = self.formats
        let jobs = items.map { (url: $0.url, name: $0.name, adjust: $0.adjust, shot: $0.info?.shot) }
        Log.note("export", "\(total) \(kind.noun)(s) requested")
        exportQueue.async {
            // Let any save still on its way reach the disk first.
            self.sidecarQueue.sync {}
            var saved: [URL] = []
            var failures = 0
            var lastError = ""
            var stopped = false
            for job in jobs {
                var wanted = false
                DispatchQueue.main.sync { wanted = run == self.exportRun }
                if !wanted {
                    stopped = true
                    break
                }
                let start = CFAbsoluteTimeGetCurrent()
                let meter = JobMeter()
                // Each export gives its memory back before the next one starts.
                autoreleasepool {
                    do {
                        let out: URL
                        switch kind {
                        case .jpeg: out = try Export.embeddedJpeg(job.url, formats)
                        case .tiff: out = try Export.developedTiff(job.url, job.adjust, shot: job.shot)
                        }
                        saved.append(out)
                        let size = (try? out.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
                        Log.note("export", "\(job.name) → \(out.lastPathComponent), \(MemoryStats.plain(UInt64(size))), \(Log.seconds(since: start))")
                        let measured = meter.finish()
                        var fields = measured.fields
                        fields["frame"] = job.name
                        fields["kind"] = kind.noun
                        fields["file_bytes"] = size
                        Log.note("job", "export \(job.name) (\(kind.noun)) · \(measured.text)", fields: fields)
                    } catch {
                        failures += 1
                        lastError = "\(error)"
                        _ = meter.finish()
                        Log.note("export", "\(job.name) failed: \(error)")
                    }
                }
                let done = saved.count + failures
                DispatchQueue.main.async { if run == self.exportRun { self.exportStatus = "Exporting \(done) / \(total)" } }
            }
            let summary: String
            if total == 1 {
                summary = saved.first.map { "Saved \($0.lastPathComponent) next to the raw." }
                    ?? "The \(kind.noun) for \(jobs[0].name) couldn't be exported: \(lastError)."
            } else {
                summary = (stopped ? "Export stopped. " : "")
                    + "Saved \(saved.count) \(kind.noun)\(saved.count == 1 ? "" : "s") next to the raws."
                    + (failures > 0 ? " \(failures) couldn't be exported; the log says why." : "")
            }
            DispatchQueue.main.async {
                self.exportStatus = nil
                self.say(summary)
            }
        }
    }

    func exportCurrent(_ kind: Export.Kind) {
        if let item = current { export(kind, [item]) }
    }

    /// Exports every frame the thumbnail pane shows, after asking: with a filter on, that is
    /// the way to export just the keepers.
    func exportShown(_ kind: Export.Kind) {
        let items = visible
        guard !items.isEmpty else { return }
        let count = NumberFormatter.localizedString(from: NSNumber(value: items.count), number: .decimal)
        let alert = NSAlert()
        if kind == .jpeg {
            alert.messageText = "Extract the embedded JPEG from all \(count) frames shown?"
            alert.informativeText = "Each JPEG is saved next to its raw file."
        } else {
            alert.messageText = "Export a 16-bit TIFF of all \(count) frames shown?"
            alert.informativeText = "Each TIFF is saved next to its raw file. They are large, often well over 100 MB each, and take a few seconds each."
        }
        alert.addButton(withTitle: kind == .jpeg ? "Extract" : "Export")
        alert.addButton(withTitle: "Cancel")
        if alert.runModal() == .alertFirstButtonReturn { export(kind, items) }
    }

    func stopExport() {
        guard exportStatus != nil else { return }
        exportRun += 1
        exportStatus = "Stopping the export…"
        Log.note("export", "stop requested")
    }

    // MARK: Ratings and labels

    /// 1–5 stars, 0 for none, -1 for reject. Written to the sidecar at once.
    func rate(_ rating: Int) {
        guard let item = current, item.rating != rating else { return }
        let old = SidecarValues(rating: item.rating, label: item.label)
        item.rating = rating
        Log.note("rate", "\(item.name): \(rating < 0 ? "reject" : "\(rating) star(s)")")
        save(item, old)
    }

    func toggleReject() { rate(current?.rating == -1 ? 0 : -1) }

    /// Up and down arrows: up from unrated sets 1, up at 5 does nothing, down at 1 clears.
    /// The arrows never step into reject.
    func nudgeRating(_ by: Int) {
        guard let r = current?.rating else { return }
        if by > 0 { rate(r < 1 ? 1 : min(r + 1, 5)) } else if r >= 1 { rate(r - 1) }
    }

    /// Sets a colour label; choosing the current one removes it.
    func setLabel(_ color: LabelColor?) {
        guard let item = current else { return }
        let text = color?.text
        let new = item.label == text ? nil : text
        guard new != item.label else { return }
        let old = SidecarValues(rating: item.rating, label: item.label)
        item.label = new
        Log.note("rate", "\(item.name): label \(new ?? "removed")")
        save(item, old)
    }

    private func save(_ item: FrameItem, _ old: SidecarValues) {
        guard let folder = folder else { return }
        let values = SidecarValues(rating: item.rating, label: item.label)
        let known = item.sidecarName
        let base = item.baseName
        recount()
        // One queue, so saves reach the disk in the order the keys were pressed.
        sidecarQueue.async {
            let dir = FileDirOps(folder)
            let fresh = base + ".xmp"
            let sidecar = known ?? (dir.exists(fresh) ? fresh : nil)
            do {
                let start = CFAbsoluteTimeGetCurrent()
                let name = try Ratings.write(dir, baseName: base, sidecarName: sidecar, values)
                Log.note("save", "\(item.name): rating saved to \(name ?? sidecar ?? "no sidecar (nothing to record)") in \(Log.seconds(since: start))")
                DispatchQueue.main.async { if let name = name { item.sidecarName = name } }
            } catch {
                Log.note("save", "\(item.name): rating NOT saved: \(error)")
                DispatchQueue.main.async {
                    item.rating = old.rating
                    item.label = old.label
                    self.recount()
                    self.say("The rating for \(item.name) couldn't be saved, so the previous one was put back. \(error)")
                }
            }
        }
    }

    // MARK: The launch check's script

    /// For the automated build only (`-TCScript YES` with the made-up DNG): twenty-odd changes
    /// across old and new controls, two of them drags, a white balance by point on the grey
    /// patch and a Reset All, each a moment apart so its render reaches the screen.
    private func runLaunchScript() {
        enum Step {
            case set(String, (Float) -> Float)
            case drag(String, [Float])
            case reset(String)
            case pick
            case resetAll
        }
        let steps: [Step] = [
            .set("exposure", { _ in 0.5 }), .drag("shadowBoost", [1.0, 1.2, 1.5]), .set("vibrance", { _ in -0.2 }),
            .set("baselineExposure", { $0 + 1 }), .set("temperature", { _ in 4500 }), .set("tint", { _ in 10 }),
            .set("gamutMapping", { 1 - $0 }), .set("lensCorrection", { 1 - $0 }), .drag("exposure", [0.6, 0.8, 1.0]),
            .set("saturation", { _ in 1.3 }), .set("vibrance", { _ in 0.3 }), .set("contrast", { _ in 0.5 }),
            .set("sharpness", { _ in 0.6 }), .set("detail", { _ in 1.5 }), .set("luminanceNoise", { _ in 0.5 }),
            .set("colorNoise", { _ in 0.5 }), .set("moire", { _ in 0.5 }), .set("boost", { _ in 0.6 }),
            .set("shadowBias", { _ in 0.5 }), .set("localToneMap", { _ in 0.5 }), .reset("exposure"), .pick, .resetAll,
        ]
        Log.note("script", "launch-check script: \(steps.count) steps")
        var at = 0.0
        for (n, step) in steps.enumerated() {
            DispatchQueue.main.asyncAfter(deadline: .now() + at) {
                switch step {
                case let .set(key, to):
                    guard let c = Adjust.control(key) else { return }
                    if !self.state(c).enabled {
                        Log.note("script", "step \(n + 1): \(c.title) skipped (not supported for this file)")
                        return
                    }
                    Log.note("script", "step \(n + 1): set \(c.title)")
                    self.setValue(c, to(self.value(c)))
                case let .drag(key, through):
                    guard let c = Adjust.control(key) else { return }
                    Log.note("script", "step \(n + 1): drag \(c.title) through \(through)")
                    self.dragChanged(c, began: true)
                    for (i, v) in through.enumerated() {
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1 * Double(i + 1)) {
                            self.setValue(c, v)
                            if i == through.count - 1 { self.dragChanged(c, began: false) }
                        }
                    }
                case let .reset(key):
                    guard let c = Adjust.control(key) else { return }
                    Log.note("script", "step \(n + 1): reset \(c.title)")
                    self.reset(c)
                case .pick:
                    guard let space = self.slots[0].view?.space, space.width > 0 else { return }
                    let patch = SyntheticDng.layout(width: Int(space.width), height: Int(space.height)).greyPatch
                    Log.note("script", "step \(n + 1): white balance by point on the grey patch")
                    self.pickingNeutral = true
                    self.pickNeutral(at: CGPoint(x: patch.centreX, y: patch.centreY))
                case .resetAll:
                    Log.note("script", "step \(n + 1): Reset All")
                    self.resetAll()
                }
            }
            at += 1.5
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + at + 1) { Log.note("script", "launch-check script finished") }
    }

    // MARK: Keys

    /// Only the shortcuts the core actions need. Returns true when the key was used.
    private func handleKey(_ event: NSEvent) -> Bool {
        if !event.modifierFlags.intersection([.command, .control, .option]).isEmpty { return false }
        if NSApp.keyWindow?.firstResponder is NSText { return false }
        if NSApp.keyWindow?.attachedSheet != nil || NSApp.modalWindow != nil { return false }
        // Keys typed in another window (Diagnostics) are not for the photos.
        if let window = window, NSApp.keyWindow !== window { return false }
        guard folder != nil, !frames.isEmpty else { return false }
        switch event.keyCode {
        case 123: step(-1); return true // left
        case 124: step(1); return true // right
        case 126, 125: // up, down: only where one large image fills the view
            if compare == nil { nudgeRating(event.keyCode == 126 ? 1 : -1) }
            return true
        case 53: // esc: back one level. The eyedropper, then zoom, then full screen, then the side-by-side view.
            if pickingNeutral {
                pickingNeutral = false
                Log.note("edit", "white balance by point cancelled (Esc)")
                return true
            }
            let views = compare == nil ? [slots[0].view] : slots.map { $0.view }
            if views.contains(where: { $0?.isZoomed == true }) {
                for view in views { view?.fit() }
                return true
            }
            if let window = window, window.styleMask.contains(.fullScreen) {
                window.toggleFullScreen(nil)
                return true
            }
            if compare != nil {
                endCompare()
                return true
            }
            return false
        case 48: // tab: the other image when comparing, else the next face
            if let pair = compare { setActiveSide(pair.active.other, cause: "user.key (tab)") } else { nextFace() }
            return true
        case 49: NSApp.keyWindow?.toggleFullScreen(nil); return true // space
        default: break
        }
        switch event.charactersIgnoringModifiers?.lowercased() {
        case "0": rate(0)
        case "1": rate(1)
        case "2": rate(2)
        case "3": rate(3)
        case "4": rate(4)
        case "5": rate(5)
        case "6": setLabel(.red)
        case "7": setLabel(.yellow)
        case "8": setLabel(.green)
        case "9": setLabel(.blue)
        case "x": toggleReject()
        default: return false
        }
        return true
    }
}
