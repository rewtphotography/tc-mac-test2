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
    /// Masked adjustments. Kept for the session only while the masking test runs; not saved.
    var local = LocalEdits()
    /// Goes up whenever the frame's mask, its local adjustments or the mask view change, so a
    /// kept render is known to be out of date.
    var localStamp = 0

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
    /// Masking: the chosen quality, what the large image shows, the area the sliders act on,
    /// the current frame's local adjustments, and what is going on.
    /// Changing the tier of a photo that has a mask refines its edge again from what is
    /// already known about its subject; the model is not run again.
    /// Off is the mask (masking spec v4); the hair tiers are a debug comparison.
    @Published var maskTier = MatteTier.off {
        didSet { if maskTier != oldValue && currentMask != nil { makeMask(fresh: false, trigger: "tier changed to \(maskTier.name)") } }
    }
    @Published var maskView = MaskView.photo
    @Published var localArea = LocalArea.subject
    @Published var local = LocalEdits()
    @Published var maskStatus: String?
    @Published var maskBusy = false
    @Published var maskTick = 0
    /// How readily soft pieces are left out of the subject (the masking spec's Focus strictness).
    @Published var focusStrictness = FocusStrictness.moderate
    /// Debug: Apple's Vision masks instead of BiRefNet, and which processors the model runs on.
    @Published var legacyVision = false
    @Published var modelUnits = ModelUnits.gpu {
        didSet {
            if modelUnits != oldValue {
                BiRefNetModel.shared.setUnits(modelUnits)
                BiRefNetModel.matting.setUnits(modelUnits)
            }
        }
    }
    /// Debug: each step of the edge on its own switch, to see what it does (masking spec v5, 1.4).
    @Published var edgeSnap = true { didSet { if edgeSnap != oldValue { edgeStepChanged("edge snap", edgeSnap) } } }
    @Published var decontamination = true { didSet { if decontamination != oldValue { edgeStepChanged("decontamination", decontamination) } } }
    @Published var colourGuard = true { didSet { if colourGuard != oldValue { edgeStepChanged("colour guard", colourGuard) } } }
    @Published var edgeRecentre = true { didSet { if edgeRecentre != oldValue { edgeStepChanged("edge re-centre", edgeRecentre) } } }
    /// The mask tools: which is chosen, the brush, and the Clean Edge and Refine Hair settings.
    @Published var maskTool = MaskTool.none { didSet { if maskTool != oldValue { toolChanged() } } }
    /// The brush's radius, in pixels of the photo.
    @Published var brushSize: Double = 60 { didSet { if brushSize != oldValue { toolChanged() } } }
    @Published var cleanStrength: Double = 1
    @Published var cleanTightness: Double = 0
    @Published var hairMethod = HairMethod.auto
    @Published var hairContrast: Double = 0.5
    /// Low on purpose: on the owner's convention photos the matting model beat colour matting even
    /// where the backdrop was plain, so colour matting is left for a near-uniform one (a seamless).
    @Published var hairTexture: Double = 0.03
    /// How many tool operations the current frame's mask carries (for the Undo button).
    @Published var refineCount = 0
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
        didSet {
            if !editing { thumbsWhileEditing = false; flushSave() }
            if editing != oldValue {
                modelFollowsEditing()
                toolChanged()
            }
        }
    }
    @Published var thumbsWhileEditing = false
    /// The current frame's changed controls, and what Apple's decoder uses by default for it.
    @Published var values: [String: Float] = [:]
    @Published var defaults: [String: Float] = [:]

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
    private var rawCache: [(id: Int, values: [String: Float], stamp: Int, image: CGImage)] = []
    /// The masks of the last two frames that had one made. Each is about as large as a raw render.
    private var masks: [(id: Int, mask: MaskResult)] = []
    private var maskRun = 0
    private var maskJobs = 0
    /// For each frame with a mask: the mask as Make Mask left it, what the tools have done
    /// since, and what each replaced.
    private var refined: [Int: (automatic: MaskResult, ops: [RefineOp], undos: [RefineUndo])] = [:]
    /// Frames whose camera settings have been written to the log this session.
    private var introduced = Set<Int>()
    /// The render cache: at most this many bytes of finished pictures, least recently shown out first.
    static let renderCacheBytes = 900 << 20
    private var evicted = Set<Int>()
    private var evictions = 0
    /// What the user last did that calls for a new render, and how many requests arrived
    /// while a draft was still being made.
    private var renderTrigger = "selection"
    private var draftsSkipped = 0
    private let maskQueue = DispatchQueue(label: "mask", qos: .userInitiated)
    private var memoryPressure: DispatchSourceMemoryPressure?
    private var modelToken = 0
    /// How long the model stays loaded after Edit mode is left, in case it is entered again.
    static let modelLingers: TimeInterval = 120
    private var fullSize: [Int: CGSize] = [:]
    private var editToken = 0
    private var valuesToken = 0
    private var draftBusy = false
    private var saveToken = 0
    private var pendingSave: FrameItem?
    private let draftQueue = DispatchQueue(label: "draft", qos: .userInteractive)
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
            let renderBytes = self.rawCache.reduce(0) { $0 + $1.image.bytesPerRow * $1.image.height }
            let maskBytes = self.masks.reduce(0) { $0 + $1.mask.width * $1.mask.height * 6 }
            defer { self.evictions = 0 }
            let model: String = BiRefNetModel.shared.isLoaded ? "loaded" : "not loaded"
            let renders: String = "render \(self.rawCache.count) / \(MemoryStats.plain(UInt64(renderBytes))) · masks \(self.masks.count) / \(MemoryStats.plain(UInt64(maskBytes)))"
            return "summary · \(renders) · evictions \(self.evictions) · \(Masking.keptSummary) · model \(model)"
        }
        // Short of memory, the model and everything kept for remaking masks are let go; they
        // come back when next needed.
        let pressure = DispatchSource.makeMemoryPressureSource(eventMask: [.warning, .critical], queue: .main)
        pressure.setEventHandler { [weak self] in
            Log.warn("the Mac is short of memory (\(MemoryStats.plain(MemoryMonitor.footprint())) in use here): letting go of the model and the masking caches")
            self?.maskQueue.async {
                BiRefNetModel.shared.unload("memory pressure")
                BiRefNetModel.matting.unload("memory pressure")
                Masking.forgetAll("memory pressure")
            }
        }
        pressure.resume()
        memoryPressure = pressure
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
        rawCache = []
        evicted = []
        introduced = []
        Masking.forgetAll("another folder")
        masks = []
        refined = [:]
        maskTool = .none
        maskRun += 1
        maskBusy = false
        maskStatus = nil
        maskView = .photo
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
            let raws = after.filter { formats.isRaw($0) }.sorted { $0.caseInsensitiveCompare($1) == .orderedAscending }
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
                self.selectionChanged("programmatic (folder opened)")
                self.show(0)
                if UserDefaults.standard.bool(forKey: "TCCompare"), items.count > 1 { self.commandClick(1) }
                if UserDefaults.standard.bool(forKey: "TCEdit") { self.editing = true }
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
            view.onBox = { [weak self] rect, restore in
                guard let self = self else { return }
                let box = PixelRect(x: Int(rect.minX), y: Int(rect.minY), w: max(Int(rect.width), 1), h: max(Int(rect.height), 1))
                self.applyTool(RefineOp(tool: self.maskTool, box: box, stroke: nil, restore: restore))
            }
            view.onStroke = { [weak self] points, radius, restore in
                guard let self = self else { return }
                let stroke = RefineStroke(points: points.map { SIMD2(Float($0.x), Float($0.y)) }, radius: Float(radius))
                var op = RefineOp(tool: self.maskTool, box: nil, stroke: stroke, restore: restore)
                op.clean.strength = Float(self.cleanStrength)
                op.clean.tightness = Float(self.cleanTightness)
                self.applyTool(op)
            }
            toolChanged()
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
        if let pair = compare {
            if let target = pair.stepTarget(by, in: visible.map { $0.id }) { setActiveFrame(target, cause: "user.key (\(by < 0 ? "←" : "→"))") }
            return
        }
        let cause = "user.key (\(by < 0 ? "←" : "→"))"
        guard let at = visible.firstIndex(where: { $0.id == selected }) else {
            select(visible[0].id, cause: cause)
            return
        }
        select(visible[min(max(at + by, 0), visible.count - 1)].id, cause: cause)
    }

    /// The selected frame changed: the editing controls follow it. `cause` says who changed it,
    /// for the log: a click, a key, or the app itself (and then which part of it). Work that
    /// finishes in the background must never be a cause.
    private func selectionChanged(_ cause: String) {
        editToken += 1
        valuesToken += 1
        guard let item = current else {
            values = [:]
            defaults = [:]
            return
        }
        Log.note("select", "\(item.name) (\(item.id + 1) of \(frames.count)) · cause: \(cause)")
        if !introduced.contains(item.id), let shot = item.info?.shot {
            introduced.insert(item.id)
            Log.note("image", "\(item.name): \(shot.label())\(shot.lens.map { " · \($0)" } ?? "")")
        }
        values = item.adjust
        local = item.local
        if !maskBusy { maskStatus = currentMask?.summary }
        toolChanged()
        defaults = [:]
        let token = valuesToken
        let url = item.url
        heroQueue.async {
            let found = Adjust.defaults(url)
            DispatchQueue.main.async { if token == self.valuesToken { self.defaults = found } }
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
        let local = localRender(for: item)
        let stamp = renderKey(item)
        let started = CFAbsoluteTimeGetCurrent()

        if let at = rawCache.firstIndex(where: { $0.id == id && $0.values == adjust && $0.stamp == stamp }) {
            let cached = rawCache.remove(at: at)
            rawCache.append(cached) // most recently shown last
            view.show(cached.image, space: CGSize(width: cached.image.width, height: cached.image.height), newFrame: true, keepZoom: keepZoom)
            setState(index, "Raw")
            Log.note("cache", "render \(name) · hit")
            return
        }
        if let stale = rawCache.first(where: { $0.id == id }) {
            Log.note("cache", "render \(name) · miss: keyChanged (\(stale.values != adjust ? "edits" : "local adjustments or mask view"))")
        } else {
            Log.note("cache", "render \(name) · miss: \(evicted.contains(id) ? "evicted (LRU)" : "cold")")
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
            let size = Imaging.rawSize(url) ?? CGSize(width: big.width, height: big.height)
            Log.note("image", "\(name): embedded preview \(big.width)×\(big.height) after \(Log.seconds(since: started))")
            DispatchQueue.main.async {
                self.fullSize[id] = size
                guard token == slot.token else { return }
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
            self.rawQueue.async {
                var stillWanted = false
                DispatchQueue.main.sync { stillWanted = token == slot.token }
                guard stillWanted else { return }
                let rendering = CFAbsoluteTimeGetCurrent()
                let raw = Imaging.renderRaw(url, adjust, local: local)
                let image = raw ?? Imaging.fullJpeg(url, formats)
                if let image = image {
                    Log.note("image", "\(name): \(raw != nil ? "raw render" : "embedded JPEG (no raw render)") \(image.width)×\(image.height) in \(Log.seconds(since: rendering)), \(Log.seconds(since: started)) after selecting")
                } else {
                    Log.note("image", "\(name): neither the raw nor its embedded JPEG could be shown")
                }
                MemoryMonitor.mark("rendering \(name)")
                DispatchQueue.main.async {
                    guard let image = image else {
                        if token == slot.token { self.setState(index, "Preview only") }
                        return
                    }
                    if raw != nil { self.cache(id, adjust, stamp, image) }
                    guard token == slot.token, item.adjust == adjust, self.renderKey(item) == stamp else { return }
                    slot.view?.show(image, space: CGSize(width: image.width, height: image.height), newFrame: false)
                    self.setState(index, raw != nil ? "Raw" : "Embedded JPEG")
                }
            }
        }
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
    func commandClick(_ id: Int) {
        guard frames.indices.contains(id) else { return }
        if let pair = compare {
            if id != pair.left && id != pair.right { setActiveFrame(id, cause: "user.click (⌘)") }
            return
        }
        guard current != nil, id != selected else { return }
        flushSave()
        if editing { editing = false }
        Log.note("compare", "started: \(frames[selected].name) | \(frames[id].name)")
        // Both sides start fitted, so their zoom is linked from the first click.
        slots[0].view?.fit(animated: false)
        compare = ComparePair(left: selected, right: id, active: .right)
        selected = id
        selectionChanged("user.click (⌘, side by side)")
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
        if compare != nil { endCompare() }
        editing.toggle()
        Log.note("edit", editing ? "edit mode on" : "edit mode off")
    }

    private func cache(_ id: Int, _ values: [String: Float], _ stamp: Int, _ image: CGImage) {
        rawCache.removeAll { $0.id == id }
        rawCache.append((id, values, stamp, image))
        evicted.remove(id)
        var bytes = rawCache.reduce(0) { $0 + $1.image.bytesPerRow * $1.image.height }
        while bytes > Session.renderCacheBytes && rawCache.count > 1 {
            let out = rawCache.removeFirst()
            bytes -= out.image.bytesPerRow * out.image.height
            evicted.insert(out.id)
            evictions += 1
        }
        fullSize[id] = CGSize(width: image.width, height: image.height)
    }

    /// What a kept render of a frame is filed under besides its edits: 0 when nothing local
    /// shows in it, so that making a mask or looking at one does not throw the plain render away.
    private func renderKey(_ item: FrameItem) -> Int { localRender(for: item) == nil ? 0 : item.localStamp }

    /// The value a control shows: the changed one, else the file's default.
    func value(_ control: Control) -> Float { values[control.key] ?? defaults[control.key] ?? control.neutral }

    func isChanged(_ control: Control) -> Bool { values[control.key] != nil }

    func setValue(_ control: Control, _ new: Float) {
        guard let item = current else { return }
        renderTrigger = "\(control.title) drag"
        let span = control.range.upperBound - control.range.lowerBound
        if let d = defaults[control.key], abs(d - new) <= span * 0.0005 {
            values[control.key] = nil
        } else {
            values[control.key] = new
        }
        edited(item)
    }

    func reset(_ control: Control) {
        guard let item = current, values[control.key] != nil else { return }
        values[control.key] = nil
        edited(item)
    }

    func resetAll() {
        guard let item = current, !values.isEmpty else { return }
        values = [:]
        edited(item)
    }

    private func edited(_ item: FrameItem) {
        item.adjust = values
        rerender(item)
        pendingSave = item
        saveToken += 1
        let save = saveToken
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { if save == self.saveToken { self.flushSave() } }
    }

    /// Redraws the single view after a change to the frame's edits: a quick draft at once, the
    /// full-size render once the sliders have been still for a moment.
    private func rerender(_ item: FrameItem) {
        editToken += 1
        startDraft()
        let token = editToken
        let frame = heroToken
        let url = item.url, id = item.id, adjust = item.adjust
        let local = localRender(for: item), stamp = renderKey(item)
        let trigger = renderTrigger
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
            guard token == self.editToken, frame == self.heroToken else { return }
            self.rawQueue.async {
                var wanted = false
                DispatchQueue.main.sync { wanted = token == self.editToken && frame == self.heroToken }
                let start = CFAbsoluteTimeGetCurrent()
                guard wanted, let image = Imaging.renderRaw(url, adjust, local: local) else { return }
                Log.note("image", "\(item.name): render\(local != nil ? " local-adj" : "") \(image.width)×\(image.height) (full) · trigger: \(trigger) · wall \(Log.seconds(since: start))")
                MemoryMonitor.mark("a full render of \(item.name)")
                DispatchQueue.main.async {
                    self.cache(id, adjust, stamp, image)
                    guard token == self.editToken, frame == self.heroToken else { return }
                    self.hero?.show(image, space: CGSize(width: image.width, height: image.height), newFrame: false)
                    self.setState(0, "Raw")
                }
            }
        }
    }

    /// A quick, smaller render for live feedback. One runs at a time; when it finishes and the
    /// sliders have moved on, the next one starts from the latest values.
    private func startDraft() {
        if draftBusy { draftsSkipped += 1 }
        guard !draftBusy, let item = current, let hero = hero else { return }
        draftBusy = true
        let coalesced = draftsSkipped
        draftsSkipped = 0
        let trigger = renderTrigger
        let drafting = CFAbsoluteTimeGetCurrent()
        let token = editToken
        let frame = heroToken
        let url = item.url, adjust = item.adjust
        let local = localRender(for: item)
        let size = fullSize[item.id]
        var scale: Float = 0.25
        if let size = size, size.width > 0 {
            let pixels = max(hero.bounds.width, hero.bounds.height) * (hero.window?.backingScaleFactor ?? 2)
            scale = Float(min(1, max(0.1, pixels / max(size.width, size.height))))
        }
        draftQueue.async {
            let image = Imaging.renderRaw(url, adjust, scale: scale, local: local)
            if let image = image {
                Log.debug("image", "\(item.name): draft\(local != nil ? " local-adj" : "") \(image.width)×\(image.height) (view, scale \(String(format: "%.2f", scale)))"
                    + " · trigger: \(trigger) · coalesced \(coalesced) · wall \(Log.seconds(since: drafting))")
            }
            DispatchQueue.main.async {
                self.draftBusy = false
                guard frame == self.heroToken else { return }
                if let image = image {
                    self.hero?.show(image, space: size ?? CGSize(width: image.width, height: image.height), newFrame: false)
                }
                if token != self.editToken { self.startDraft() }
            }
        }
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

    // MARK: Masks and local adjustments (a test of TrainCull as a finishing editor)

    var currentMask: MaskResult? { masks.first { $0.id == selected }?.mask }

    /// What a render of this frame must add: its mask with its local adjustments, when there
    /// is something to show.
    private func localRender(for item: FrameItem) -> LocalRender? {
        guard let mask = masks.first(where: { $0.id == item.id })?.mask else { return nil }
        let view = item.id == selected && compare == nil ? maskView : .photo
        if view == .photo && item.local.isNeutral { return nil }
        return LocalRender(mask: mask, edits: item.local, view: view, area: localArea)
    }

    /// The model is made ready when Edit mode is entered, kept while it lasts, and let go
    /// two minutes after it ends (masking spec v3, 2.3, and v4, phase 3).
    private func modelFollowsEditing() {
        guard BundledModels.hasBiRefNet else { return }
        modelToken += 1
        let token = modelToken
        if editing {
            maskQueue.async { BiRefNetModel.shared.prewarm() }
            return
        }
        // Kept for two minutes after leaving, so going straight back in costs nothing.
        DispatchQueue.main.asyncAfter(deadline: .now() + Session.modelLingers) { [weak self] in
            guard let self = self, token == self.modelToken, !self.editing else { return }
            self.maskQueue.async {
                BiRefNetModel.shared.unload("Edit mode left \(Int(Session.modelLingers)) s ago")
                BiRefNetModel.matting.unload("Edit mode left \(Int(Session.modelLingers)) s ago")
            }
        }
    }

    /// The selection rules as the panel has them set.
    private var subjectRules: SubjectRules {
        var rules = SubjectRules()
        rules.focusStrictness = focusStrictness.factor
        return rules
    }

    private var subjectSource: SubjectSource { legacyVision || !BundledModels.hasBiRefNet ? .vision : .birefnet }

    /// Makes the current frame's masks at the chosen quality. The work is a numbered job in
    /// the log, from request to completion. Finishing never changes which frame is selected.
    /// `fresh` forgets what was known about the photo's subject first (the Remake button);
    /// without it only the edge is refined again. A job asked for while another is running
    /// takes its place.
    func makeMask(fresh: Bool = true, trigger: String = "user (Make button)") {
        guard let item = current else { return }
        if compare != nil { endCompare() }
        let superseding = maskBusy
        maskBusy = true
        maskRun += 1
        maskJobs += 1
        let run = maskRun, job = maskJobs
        let tier = maskTier, source = subjectSource, rules = subjectRules, settings = edgeSettings
        let url = item.url, id = item.id, name = item.name
        let known = faces[id]
        maskStatus = "Starting…"
        let requested = CFAbsoluteTimeGetCurrent()
        let how: String = fresh ? "from scratch" : "from what is kept"
        let instead: String = superseding ? " · takes the place of the job still running" : ""
        Log.note("job", "#\(job) \(tier.name) \(name) · subject from \(source.name) · focus strictness \(focusStrictness.name) · trigger: \(trigger) · \(how)\(instead)")
        maskQueue.async {
            var gone = false
            DispatchQueue.main.sync { gone = run != self.maskRun }
            if gone {
                Log.note("job", "#\(job) superseded before it started")
                return
            }
            Log.note("job", "#\(job) started · queued \(Log.seconds(since: requested))")
            if fresh { Masking.forgetBase(url) }
            let meter = JobMeter()
            let working = CFAbsoluteTimeGetCurrent()
            let result = Result { () -> MaskResult in
                try Masking.make(url: url, tier: tier, faces: known, settings: settings, rules: rules, subject: source, progress: { text in
                    DispatchQueue.main.async { if run == self.maskRun { self.maskStatus = "\(text)…" } }
                }, partial: { first in
                    // The snapped edge, shown while the hair is still being refined.
                    Log.note("job", "#\(job) first result (Off) after \(Log.seconds(since: working))")
                    DispatchQueue.main.async {
                        guard run == self.maskRun else { return }
                        self.keep(first, for: item)
                        if self.selected == id {
                            self.renderTrigger = "first mask"
                            self.refreshLocal(item)
                        }
                    }
                }, cancelled: {
                    var stop = false
                    DispatchQueue.main.sync { stop = run != self.maskRun }
                    return stop
                })
            }
            let measured = meter.finish()
            var jobFields = meter.numbers
            jobFields["job"] = job
            jobFields["image"] = name
            jobFields["tier"] = tier.name
            Log.note("memory", "MaskJob#\(job) · \(measured.memory)", fields: jobFields)
            Log.note("load", "MaskJob#\(job) \(tier.name) \(name) · \(measured.load)")
            let took = Log.seconds(since: working)
            DispatchQueue.main.async {
                guard run == self.maskRun else {
                    Log.note("job", "#\(job) superseded after \(took)")
                    return
                }
                self.maskBusy = false
                let still = self.selected == id
                switch result {
                case let .success(mask):
                    Log.note("job", "#\(job) completed in \(took) · image selected at completion: \(still ? "yes" : "no (\(self.current?.name ?? "none"))")")
                    self.keep(mask, for: item)
                    // What the tools had done to the mask this one replaces is done again on it.
                    let again = self.refined[id]?.ops ?? []
                    self.refined[id] = (mask, [], [])
                    if !again.isEmpty {
                        Log.note("tool", "\(name): doing \(again.count) tool operation(s) again on the new mask")
                        for op in again { self.applyTool(op, to: item, trigger: "replay") }
                    }
                    if still { self.toolChanged() }
                    if still {
                        self.maskStatus = mask.summary + (Masking.blendsByChannel ? "" : " (plain blending)")
                        if self.localArea == .skin && mask.skin == nil { self.localArea = .subject }
                        self.renderTrigger = "mask made"
                        self.refreshLocal(item)
                    }
                case let .failure(error):
                    Log.note("job", "#\(job) failed after \(took): \(error)")
                    if still { self.maskStatus = "No mask: \(error)." }
                }
            }
        }
    }

    // MARK: Mask tools

    /// The edge engine's settings as the Debug switches have them.
    private var edgeSettings: MatteSettings {
        var settings = MatteSettings()
        settings.colourSnap = edgeSnap
        settings.decontaminate = decontamination
        settings.colourGuard = colourGuard
        settings.recentre = edgeRecentre
        return settings
    }

    private func edgeStepChanged(_ step: String, _ on: Bool) {
        Log.note("mask", "debug: \(step) \(on ? "on" : "off")")
        if currentMask != nil { makeMask(fresh: false, trigger: "\(step) switched \(on ? "on" : "off")") }
    }

    /// Hands the chosen tool, and what the tools have done to this frame, to the large image.
    private func toolChanged() {
        guard let view = slots[0].view else { return }
        let usable = currentMask != nil && compare == nil && editing
        if !usable && maskTool != .none {
            maskTool = .none
            return
        }
        switch maskTool {
        case .none: view.tool = .none
        case .edges: view.tool = .box
        case .hair, .clean: view.tool = .brush(radius: CGFloat(brushSize))
        }
        let ops = refined[selected]?.ops ?? []
        view.marks = maskTool == .none ? [] : ops.map { $0.mark }
        if refineCount != ops.count { refineCount = ops.count }
    }

    /// Runs one tool operation on a frame's mask, as a numbered job like making a mask.
    func applyTool(_ op: RefineOp, to given: FrameItem? = nil, trigger: String = "user") {
        guard op.tool != .none, let item = given ?? current, masks.contains(where: { $0.id == item.id }) else { return }
        maskJobs += 1
        let job = maskJobs
        let url = item.url, id = item.id, name = item.name
        let known = faces[id], rules = subjectRules, source = subjectSource
        var options = RefineOptions()
        options.settings = edgeSettings
        options.hairMethod = hairMethod
        options.contrastNeeded = Float(hairContrast)
        options.textureAllowed = Float(hairTexture)
        maskBusy = true
        maskStatus = "\(op.tool.name)…"
        let requested = CFAbsoluteTimeGetCurrent()
        let what = op.box.map { "box \($0.w)×\($0.h) at \($0.x),\($0.y)" } ?? "stroke of \(op.stroke?.points.count ?? 0) points, brush \(Int(op.stroke?.radius ?? 0)) px"
        Log.note("job", "#\(job) \(op.tool.name)\(op.restore ? " (restore)" : "") \(name) · \(what) · trigger: \(trigger)")
        maskQueue.async {
            // The mask as it is when this job's turn comes: earlier operations are in it.
            var mask: MaskResult?, automatic: MaskResult?
            DispatchQueue.main.sync {
                mask = self.masks.first { $0.id == id }?.mask
                automatic = self.refined[id]?.automatic
            }
            guard let now = mask, let base = automatic else {
                DispatchQueue.main.async { self.maskBusy = false }
                Log.note("job", "#\(job) dropped: the frame has no mask any more")
                return
            }
            let meter = JobMeter()
            let result = Result { () -> (mask: MaskResult, undo: RefineUndo) in
                try Masking.refine(url: url, mask: now, automatic: base, op: op, options: options, faces: known, rules: rules, subject: source,
                                   progress: { text in DispatchQueue.main.async { self.maskStatus = "\(text)…" } },
                                   partial: { quick in
                                       DispatchQueue.main.async {
                                           self.keep(quick, for: item)
                                           if self.selected == id {
                                               self.renderTrigger = "tool, first result"
                                               self.refreshLocal(item)
                                           }
                                       }
                                   })
            }
            let measured = meter.finish()
            var fields = meter.numbers
            fields["job"] = job
            fields["image"] = name
            fields["tool"] = op.tool.rawValue
            Log.note("memory", "ToolJob#\(job) · \(measured.memory)", fields: fields)
            DispatchQueue.main.async {
                self.maskBusy = false
                let still = self.selected == id
                switch result {
                case let .success(done):
                    Log.note("job", "#\(job) completed in \(Log.seconds(since: requested))")
                    self.keep(done.mask, for: item)
                    if var state = self.refined[id] {
                        state.ops.append(op)
                        state.undos.append(done.undo)
                        self.refined[id] = state
                    }
                    if still {
                        self.maskStatus = done.mask.summary
                        self.renderTrigger = "tool"
                        self.refreshLocal(item)
                        self.toolChanged()
                    }
                case let .failure(error):
                    Log.note("job", "#\(job) failed: \(error)")
                    // A quick result may have been shown; the mask goes back to what it was.
                    self.keep(now, for: item)
                    if still {
                        self.maskStatus = "\(op.tool.name) didn't work: \(error)."
                        self.refreshLocal(item)
                    }
                }
            }
        }
    }

    /// Takes back the last tool operation on the current frame.
    func undoTool() {
        guard let item = current, !maskBusy, var state = refined[item.id], let undo = state.undos.popLast(),
              let mask = masks.first(where: { $0.id == item.id })?.mask else { return }
        let op = state.ops.removeLast()
        do {
            let before = try Masking.undone(mask, undo)
            refined[item.id] = state
            keep(before, for: item)
            Log.note("tool", "\(item.name): \(op.tool.name) undone · \(state.ops.count) operation(s) left")
            maskStatus = "\(op.tool.name) undone."
            renderTrigger = "tool undone"
            refreshLocal(item)
            toolChanged()
        } catch {
            Log.warn("\(item.name): undo failed: \(error)")
        }
    }

    /// Holds a frame's mask: the last two frames' are kept.
    private func keep(_ mask: MaskResult, for item: FrameItem) {
        masks.removeAll { $0.id == item.id }
        masks.append((item.id, mask))
        if masks.count > 2 { masks.removeFirst() }
        // The tools' history goes with a mask that is no longer kept.
        for id in refined.keys where !masks.contains(where: { $0.id == id }) { refined[id] = nil }
        maskTick += 1
        item.localStamp += 1
    }

    /// Writes the current frame's mask debug bundle next to the raw and shows it in the Finder.
    func exportDebugBundle() {
        guard let item = current else { return }
        let url = item.url, known = faces[item.id]
        let rules = subjectRules, source = subjectSource, mask = currentMask
        let ops = refined[item.id]?.ops ?? []
        let switches = ["edge_snap": edgeSnap, "decontamination": decontamination, "colour_guard": colourGuard, "edge_recentre": edgeRecentre,
                        "legacy_vision": legacyVision]
        say("Writing the debug bundle for \(item.name)…")
        exportQueue.async {
            do {
                let folder = try Masking.debugBundle(url: url, faces: known, rules: rules, subject: source, mask: mask, ops: ops, switches: switches)
                DispatchQueue.main.async {
                    self.say("Saved \(folder.lastPathComponent) next to the raw.")
                    NSWorkspace.shared.activateFileViewerSelecting([folder])
                }
            } catch {
                Log.warn("\(item.name): debug bundle not written: \(error)")
                DispatchQueue.main.async { self.say("The debug bundle couldn't be written: \(error).") }
            }
        }
    }

    /// Redraws the current frame after its mask, view or local adjustments changed.
    private func refreshLocal(_ item: FrameItem) {
        guard item.id == selected, compare == nil else { return }
        rerender(item)
    }

    func setMaskView(_ view: MaskView) {
        guard view != maskView, let item = current else { return }
        maskView = view
        item.localStamp += 1
        renderTrigger = "mask view \(view.name)"
        Log.note("mask", "view: \(view.name)")
        refreshLocal(item)
    }

    func setLocalArea(_ area: LocalArea) {
        guard area != localArea, let item = current else { return }
        localArea = area
        if maskView != .photo {
            item.localStamp += 1
            refreshLocal(item)
        }
    }

    /// Changes one number of the chosen area's adjustment. `control` names it for the log.
    func setLocal(_ control: String, _ change: (inout LocalLayer) -> Void) {
        guard let item = current, currentMask != nil else { return }
        renderTrigger = "\(localArea.name).\(control) drag"
        change(&local.layers[localArea.rawValue])
        if item.local == local { return }
        item.local = local
        item.localStamp += 1
        refreshLocal(item)
    }

    func resetLocal() {
        setLocal("reset") { $0 = LocalLayer() }
    }

    func saveMaskPictures() {
        guard let item = current, let mask = currentMask else { return }
        let url = item.url
        exportQueue.async {
            do {
                let saved = try Export.maskPictures(mask, for: url)
                Log.note("mask", "\(item.name): saved \(saved.map { $0.lastPathComponent }.joined(separator: ", "))")
                DispatchQueue.main.async { self.say("Saved \(saved.count) mask pictures next to the raw.") }
            } catch {
                Log.note("mask", "\(item.name): mask pictures not saved: \(error)")
                DispatchQueue.main.async { self.say("The mask pictures couldn't be saved: \(error).") }
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
        let jobs = items.map { item -> (url: URL, name: String, adjust: [String: Float], shot: ShotInfo?, local: LocalRender?) in
            var local = localRender(for: item)
            if local?.edits.isNeutral == true { local = nil }
            return (item.url, item.name, item.adjust, item.info?.shot, local)
        }
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
                // Each export gives its memory back before the next one starts.
                autoreleasepool {
                    do {
                        let out: URL
                        switch kind {
                        case .jpeg: out = try Export.embeddedJpeg(job.url, formats)
                        case .tiff: out = try Export.developedTiff(job.url, job.adjust, shot: job.shot, local: job.local)
                        }
                        saved.append(out)
                        let size = (try? out.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
                        Log.note("export", "\(job.name) → \(out.lastPathComponent), \(MemoryStats.plain(UInt64(size))), \(Log.seconds(since: start))")
                    } catch {
                        failures += 1
                        lastError = "\(error)"
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

    // MARK: Keys

    /// Only the shortcuts the core actions need. Returns true when the key was used.
    private func handleKey(_ event: NSEvent) -> Bool {
        // While a mask tool is chosen: Command-Z takes its last operation back.
        if maskTool != .none, event.modifierFlags.intersection([.command, .control, .option, .shift]) == [.command],
           event.charactersIgnoringModifiers?.lowercased() == "z", NSApp.keyWindow === window, !(NSApp.keyWindow?.firstResponder is NSText) {
            undoTool()
            return true
        }
        if !event.modifierFlags.intersection([.command, .control, .option]).isEmpty { return false }
        if NSApp.keyWindow?.firstResponder is NSText { return false }
        if NSApp.keyWindow?.attachedSheet != nil || NSApp.modalWindow != nil { return false }
        // Keys typed in another window (Diagnostics) are not for the photos.
        if let window = window, NSApp.keyWindow !== window { return false }
        guard folder != nil, !frames.isEmpty else { return false }
        // With a brush chosen, [ and ] make it smaller and larger.
        if maskTool == .hair || maskTool == .clean, let key = event.charactersIgnoringModifiers, key == "[" || key == "]" {
            brushSize = min(max(brushSize * (key == "]" ? 1.2 : 1 / 1.2), 4), 600)
            return true
        }
        switch event.keyCode {
        case 123: step(-1); return true // left
        case 124: step(1); return true // right
        case 126, 125: // up, down: only where one large image fills the view
            if compare == nil { nudgeRating(event.keyCode == 126 ? 1 : -1) }
            return true
        case 53: // esc: back one level. Zoom, then full screen, then the side-by-side view.
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
