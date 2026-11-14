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

/// Everything the window shows: the open folder, its frames, the selection and the hero image.
final class Session: ObservableObject {
    enum Pane { case folders, thumbnails }
    enum Filter: Equatable { case all, rated(Int), rejected }

    @Published var folder: URL?
    @Published var frames: [FrameItem] = []
    @Published var selected = 0
    @Published var pane = Pane.folders
    @Published var status = ""
    @Published var message: String?
    @Published var heroState = ""
    @Published var zoomText = "Fit"
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

    let formats = Formats()
    private weak var hero: HeroNSView?
    private var generation = 0
    private var heroToken = 0
    private var faces: [Int: DetectedFaces] = [:]
    private var chosenFace: [Int: Int] = [:]
    private var rawCache: [(id: Int, values: [String: Float], image: CGImage)] = []
    private var fullSize: [Int: CGSize] = [:]
    private var editToken = 0
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
    private var keyMonitor: Any?
    private var messageToken = 0
    private var loadedCount = 0

    var current: FrameItem? { frames.indices.contains(selected) ? frames[selected] : nil }

    init() {
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
        }
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            (self?.handleKey(event) ?? false) ? nil : event
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
            say("\(volume.name) ejected. Safe to unplug.")
        } catch {
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

    private func close() {
        flushSave()
        visible = []
        filter = .all
        generation += 1
        heroToken += 1
        loadQueue.cancelAllOperations()
        folder = nil
        frames = []
        hero?.show(nil, space: .zero, newFrame: true)
        pane = .folders
        status = ""
        heroState = ""
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
        heroToken += 1
        let gen = generation
        loadQueue.cancelAllOperations()
        folder = url
        frames = []
        faces = [:]
        chosenFace = [:]
        rawCache = []
        selected = 0
        hero?.show(nil, space: .zero, newFrame: true)
        heroState = ""
        pane = .thumbnails
        status = "Scanning folder…"
        remember(url)
        let formats = self.formats
        DispatchQueue.global(qos: .userInitiated).async {
            let names = (try? FileManager.default.contentsOfDirectory(atPath: url.path)) ?? []
            let dir = FileDirOps(url)
            // Repair leftovers of an interrupted rating save before reading any sidecar.
            let repairs = Sidecars.recover(dir, names)
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
                self.showSelected()
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
                        if item.id == self.selected, self.hero?.space == .zero { self.showSelected() }
                    case let .failure(error):
                        item.failed = "\(error)"
                    }
                    self.loadedCount += 1
                    if self.loadedCount == total {
                        self.status = ""
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
        if !visible.contains(where: { $0.id == selected }), let first = visible.first { select(first.id) }
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
        message = text
        messageToken += 1
        let token = messageToken
        DispatchQueue.main.asyncAfter(deadline: .now() + 5) { [weak self] in
            if self?.messageToken == token { self?.message = nil }
        }
    }

    // MARK: The hero image

    func attach(_ view: HeroNSView) {
        hero = view
        view.targetFor = { [weak self] point in
            self?.zoomTarget(at: point) ?? FaceResult(method: .point, anchor: P(Double(point.x), Double(point.y)), eyeSpan: nil)
        }
        view.onZoom = { [weak self] fitted, percent in
            let text = fitted ? "Fit" : "\(percent)%"
            DispatchQueue.main.async { if self?.zoomText != text { self?.zoomText = text } }
        }
        if current != nil { showSelected() }
    }

    func select(_ index: Int) {
        guard frames.indices.contains(index), index != selected else { return }
        flushSave()
        selected = index
        showSelected()
    }

    /// Steps through the frames the thumbnail pane shows.
    func step(_ by: Int) {
        guard !visible.isEmpty else { return }
        guard let at = visible.firstIndex(where: { $0.id == selected }) else {
            select(visible[0].id)
            return
        }
        select(visible[min(max(at + by, 0), visible.count - 1)].id)
    }

    /// Shows the selected frame: the thumbnail at once, then the large embedded preview, then
    /// the raw rendered by Apple's decoder once the frame has been still for a moment.
    private func showSelected() {
        guard let item = current, let hero = hero else { return }
        heroToken += 1
        let token = heroToken
        let url = item.url
        let id = item.id
        let formats = self.formats
        let adjust = item.adjust
        values = adjust
        defaults = [:]
        editToken += 1
        heroQueue.async {
            let found = Adjust.defaults(url)
            DispatchQueue.main.async { if token == self.heroToken { self.defaults = found } }
        }

        if let cached = rawCache.first(where: { $0.id == id && $0.values == adjust }) {
            hero.show(cached.image, space: CGSize(width: cached.image.width, height: cached.image.height), newFrame: true)
            heroState = "Raw"
            return
        }
        if let t = item.thumb {
            hero.show(t, space: CGSize(width: t.width, height: t.height), newFrame: true)
        } else {
            hero.show(nil, space: .zero, newFrame: true)
        }
        heroState = "Preview"

        let needFaces = faces[id] == nil
        heroQueue.async {
            guard let (_, big) = try? Imaging.preview(url, formats, maxPixels: nil) else { return }
            let size = Imaging.rawSize(url) ?? CGSize(width: big.width, height: big.height)
            DispatchQueue.main.async {
                self.fullSize[id] = size
                guard token == self.heroToken else { return }
                self.hero?.show(big, space: size, newFrame: false)
            }
            if needFaces {
                let found = Imaging.detectFaces(big)
                DispatchQueue.main.async { self.faces[id] = found }
            }
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
            guard token == self.heroToken else { return }
            self.rawQueue.async {
                var stillWanted = false
                DispatchQueue.main.sync { stillWanted = token == self.heroToken }
                guard stillWanted else { return }
                let raw = Imaging.renderRaw(url, adjust)
                let image = raw ?? Imaging.fullJpeg(url, formats)
                DispatchQueue.main.async {
                    guard let image = image else {
                        if token == self.heroToken { self.heroState = "Preview only" }
                        return
                    }
                    if raw != nil { self.cache(id, adjust, image) }
                    guard token == self.heroToken, item.adjust == adjust else { return }
                    self.hero?.show(image, space: CGSize(width: image.width, height: image.height), newFrame: false)
                    self.heroState = raw != nil ? "Raw" : "Embedded JPEG (raw rendering isn't available for this camera on this Mac)"
                }
            }
        }
    }

    /// A click goes to face zoom on the face nearest the click; with no face, to the clicked point.
    private func zoomTarget(at point: CGPoint) -> FaceResult {
        let fallback = FaceResult(method: .point, anchor: P(Double(point.x), Double(point.y)), eyeSpan: nil)
        guard let item = current, let found = faces[item.id], !found.subjects.isEmpty,
              let space = hero?.space, space.width > 0, found.imageWidth > 0 else { return fallback }
        let k = Double(space.width) / found.imageWidth
        let subjects = found.subjects.map { $0.scaled(k) }
        func distance(_ s: Subject) -> Double {
            let dx = s.centerX - Double(point.x), dy = s.centerY - Double(point.y)
            return dx * dx + dy * dy
        }
        let index = subjects.indices.min { distance(subjects[$0]) < distance(subjects[$1]) } ?? 0
        chosenFace[item.id] = index
        return Framing.fromSubject(subjects[index])
    }

    /// Tab: the next face, when the frame has several.
    private func nextFace() {
        guard let item = current, let found = faces[item.id], found.subjects.count > 1,
              let hero = hero, hero.space.width > 0 else { return }
        let index = ((chosenFace[item.id] ?? -1) + 1) % found.subjects.count
        chosenFace[item.id] = index
        hero.zoom(to: Framing.fromSubject(found.subjects[index].scaled(Double(hero.space.width) / found.imageWidth)))
    }

    // MARK: Editing

    private func cache(_ id: Int, _ values: [String: Float], _ image: CGImage) {
        rawCache.removeAll { $0.id == id }
        rawCache.append((id, values, image))
        if rawCache.count > 3 { rawCache.removeFirst() }
        fullSize[id] = CGSize(width: image.width, height: image.height)
    }

    /// The value a control shows: the changed one, else the file's default.
    func value(_ control: Control) -> Float { values[control.key] ?? defaults[control.key] ?? control.neutral }

    func isChanged(_ control: Control) -> Bool { values[control.key] != nil }

    func setValue(_ control: Control, _ new: Float) {
        guard let item = current else { return }
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
        editToken += 1
        startDraft()
        let token = editToken
        let frame = heroToken
        let url = item.url, id = item.id, adjust = item.adjust
        // The full-size render waits until the sliders have been still for a moment.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
            guard token == self.editToken, frame == self.heroToken else { return }
            self.rawQueue.async {
                var wanted = false
                DispatchQueue.main.sync { wanted = token == self.editToken && frame == self.heroToken }
                guard wanted, let image = Imaging.renderRaw(url, adjust) else { return }
                DispatchQueue.main.async {
                    self.cache(id, adjust, image)
                    guard token == self.editToken, frame == self.heroToken else { return }
                    self.hero?.show(image, space: CGSize(width: image.width, height: image.height), newFrame: false)
                }
            }
        }
        pendingSave = item
        saveToken += 1
        let save = saveToken
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { if save == self.saveToken { self.flushSave() } }
    }

    /// A quick, smaller render for live feedback. One runs at a time; when it finishes and the
    /// sliders have moved on, the next one starts from the latest values.
    private func startDraft() {
        guard !draftBusy, let item = current, let hero = hero else { return }
        draftBusy = true
        let token = editToken
        let frame = heroToken
        let url = item.url, adjust = item.adjust
        let size = fullSize[item.id]
        var scale: Float = 0.25
        if let size = size, size.width > 0 {
            let pixels = max(hero.bounds.width, hero.bounds.height) * (hero.window?.backingScaleFactor ?? 2)
            scale = Float(min(1, max(0.1, pixels / max(size.width, size.height))))
        }
        draftQueue.async {
            let image = Imaging.renderRaw(url, adjust, scale: scale)
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
        let values = SidecarValues(rating: item.rating, label: item.label)
        let known = item.sidecarName
        let base = item.baseName
        sidecarQueue.async {
            let dir = FileDirOps(folder)
            let fresh = base + ".xmp"
            let sidecar = known ?? (dir.exists(fresh) ? fresh : nil)
            do {
                let name = try Edits.write(dir, baseName: base, sidecarName: sidecar, values: values, fields: fields)
                DispatchQueue.main.async { if let name = name { item.sidecarName = name } }
            } catch {
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

    // MARK: Ratings and labels

    /// 1–5 stars, 0 for none, -1 for reject. Written to the sidecar at once.
    func rate(_ rating: Int) {
        guard let item = current, item.rating != rating else { return }
        let old = SidecarValues(rating: item.rating, label: item.label)
        item.rating = rating
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
                let name = try Ratings.write(dir, baseName: base, sidecarName: sidecar, values)
                DispatchQueue.main.async { if let name = name { item.sidecarName = name } }
            } catch {
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
        if !event.modifierFlags.intersection([.command, .control, .option]).isEmpty { return false }
        if NSApp.keyWindow?.firstResponder is NSText { return false }
        if NSApp.keyWindow?.attachedSheet != nil || NSApp.modalWindow != nil { return false }
        guard folder != nil, !frames.isEmpty else { return false }
        switch event.keyCode {
        case 123: step(-1); return true // left
        case 124: step(1); return true // right
        case 126: nudgeRating(1); return true // up
        case 125: nudgeRating(-1); return true // down
        case 53: // esc
            if hero?.isZoomed == true { hero?.fit(); return true }
            return false
        case 48: nextFace(); return true // tab
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
