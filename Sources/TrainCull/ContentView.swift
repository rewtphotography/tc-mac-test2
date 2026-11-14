import SwiftUI
import UniformTypeIdentifiers

enum Theme {
    static let background = Color(red: 0.043, green: 0.043, blue: 0.047)
    static let surface = Color(red: 0.094, green: 0.094, blue: 0.106)
    static let line = Color(red: 0.153, green: 0.153, blue: 0.165)
    static let text = Color(red: 0.957, green: 0.957, blue: 0.961)
    static let muted = Color(red: 0.631, green: 0.631, blue: 0.667)
    static let accent = Color(red: 0.961, green: 0.773, blue: 0.259)
    static let reject = Color(red: 1.0, green: 0.541, blue: 0.298)
}

struct ContentView: View {
    @ObservedObject var session: Session
    @AppStorage("leftPaneWidth") private var leftWidth = 300.0

    var body: some View {
        HStack(spacing: 0) {
            // In edit mode the thumbnail pane makes way for the controls; the button at the top
            // left brings it back for a quick look.
            if !session.editing || session.thumbsWhileEditing {
                LeftPane(session: session)
                    .frame(width: leftWidth)
                    .transition(.move(edge: .leading))
                ResizeHandle(width: $leftWidth)
            }
            HeroArea(session: session)
                .frame(minWidth: 420, maxWidth: .infinity, maxHeight: .infinity)
            if session.editing {
                Divider().overlay(Theme.line)
                EditPane(session: session)
                    .frame(width: 300)
                    .transition(.move(edge: .trailing))
            }
        }
        .clipped()
        .animation(.easeInOut(duration: 0.22), value: session.editing)
        .animation(.easeInOut(duration: 0.22), value: session.thumbsWhileEditing)
        .frame(minWidth: 900, minHeight: 560)
        .background(Theme.background)
        .foregroundStyle(Theme.text)
        .preferredColorScheme(.dark)
        .toolbar {
            ToolbarItem(placement: .navigation) {
                if session.editing {
                    Button { session.thumbsWhileEditing.toggle() } label: {
                        Image(systemName: "sidebar.left")
                    }
                    .help("Show or hide the thumbnails while editing")
                }
            }
            ToolbarItem(placement: .primaryAction) {
                Toggle(isOn: $session.editing) {
                    Label("Edit", systemImage: "slider.horizontal.3").labelStyle(.titleAndIcon)
                }
                .toggleStyle(.button)
                .disabled(session.current == nil)
                .help("Edit this photo with Apple's raw controls")
            }
        }
        .dropDestination(for: URL.self) { urls, _ in
            guard let url = urls.first else { return false }
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) else { return false }
            session.open(isDirectory.boolValue ? url : url.deletingLastPathComponent())
            return true
        }
    }
}

/// The draggable edge between the left pane and the image.
struct ResizeHandle: View {
    @Binding var width: Double
    @State private var start: Double?

    var body: some View {
        Theme.line
            .frame(width: 1)
            .padding(.horizontal, 2)
            .contentShape(Rectangle())
            .onHover { inside in
                if inside { NSCursor.resizeLeftRight.push() } else { NSCursor.pop() }
            }
            .gesture(DragGesture(minimumDistance: 1, coordinateSpace: .global)
                .onChanged { drag in
                    if start == nil { start = width }
                    width = min(max((start ?? width) + Double(drag.translation.width), 220), 800)
                }
                .onEnded { _ in start = nil })
    }
}

// MARK: Left pane: folders, or the open folder's thumbnails

struct LeftPane: View {
    @ObservedObject var session: Session

    var body: some View {
        VStack(spacing: 0) {
            Picker("", selection: $session.pane) {
                Text("Folders").tag(Session.Pane.folders)
                Text("Thumbnails").tag(Session.Pane.thumbnails)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .padding(10)
            Divider().overlay(Theme.line)
            if session.pane == .folders {
                FolderList(session: session)
            } else {
                ThumbnailPane(session: session)
            }
            Divider().overlay(Theme.line)
            Group {
                if session.status.isEmpty && !session.frames.isEmpty {
                    FilterBar(session: session)
                } else {
                    Text(session.status.isEmpty ? " " : session.status).foregroundStyle(Theme.muted)
                }
            }
            .font(.system(size: 11))
            .lineLimit(1)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
        }
        .background(Theme.surface.opacity(0.6))
    }
}

/// The counts at the bottom of the left pane. Click one to show only those frames; click it
/// again, or the frame count, to show everything. Double-click the rated count to choose stars.
struct FilterBar: View {
    @ObservedObject var session: Session
    @State private var choosingStars = false

    private var ratedActive: Bool { if case .rated = session.filter { return true } else { return false } }

    private var ratedText: String {
        if case let .rated(stars) = session.filter, stars > 1 {
            return String(repeating: "★", count: stars) + (stars < 5 ? " and up" : " only") + " · \(session.visible.count)"
        }
        return "★ \(session.ratedCount) rated"
    }

    var body: some View {
        HStack(spacing: 6) {
            Text("\(session.frames.count) frames")
                .foregroundStyle(session.filter == .all ? Theme.text : Theme.muted)
                .onTapGesture { session.setFilter(.all) }
                .help("Show all frames")
            Text("·").foregroundStyle(Theme.muted)
            Text(ratedText)
                .foregroundStyle(ratedActive ? Theme.accent : Theme.muted)
                .onTapGesture(count: 2) { choosingStars = true }
                .onTapGesture { session.toggleRated() }
                .help("Click to show only rated frames. Double-click to choose how many stars.")
                .popover(isPresented: $choosingStars, arrowEdge: .top) {
                    VStack(alignment: .leading, spacing: 2) {
                        ForEach((1 ... 5).reversed(), id: \.self) { stars in
                            Button {
                                session.filterRated(atLeast: stars)
                                choosingStars = false
                            } label: {
                                Text(String(repeating: "★", count: stars) + (stars < 5 ? " and up" : " only"))
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .padding(.vertical, 4)
                        }
                    }
                    .padding(12)
                    .frame(width: 160)
                }
            Text("·").foregroundStyle(Theme.muted)
            Text("✕ \(session.rejectedCount) rejected")
                .foregroundStyle(session.filter == .rejected ? Theme.reject : Theme.muted)
                .onTapGesture { session.toggleRejected() }
                .help("Click to show only rejected frames")
        }
    }
}

struct FolderList: View {
    @ObservedObject var session: Session

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 4) {
                Button("Open Folder…") { session.pickFolder() }
                    .padding(.bottom, 10)
                if !session.recents.isEmpty {
                    SectionTitle("RECENT")
                    ForEach(session.recents, id: \.path) { url in
                        Button { session.open(url) } label: {
                            Text(url.lastPathComponent)
                                .lineLimit(1)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(.vertical, 4)
                                .padding(.horizontal, 6)
                                .background(session.folder?.path == url.path ? Theme.line : Color.clear)
                                .clipShape(RoundedRectangle(cornerRadius: 5))
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .help(url.path)
                    }
                }
                SectionTitle("DRIVES").padding(.top, 12)
                ForEach(session.volumes) { volume in
                    HStack(spacing: 6) {
                        Button { session.open(volume.url) } label: {
                            VStack(alignment: .leading, spacing: 1) {
                                Text(volume.name).lineLimit(1)
                                Text(volume.detail).font(.system(size: 11)).foregroundStyle(Theme.muted)
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        if volume.ejectable {
                            Button("Eject") { session.eject(volume) }
                                .controlSize(.small)
                        }
                    }
                    .padding(.vertical, 3)
                    .padding(.horizontal, 6)
                }
            }
            .padding(10)
        }
    }
}

struct SectionTitle: View {
    let text: String
    init(_ text: String) { self.text = text }

    var body: some View {
        Text(text)
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(Theme.muted)
            .padding(.horizontal, 6)
            .padding(.bottom, 2)
    }
}

struct ThumbnailPane: View {
    @ObservedObject var session: Session

    var body: some View {
        if session.frames.isEmpty {
            VStack(spacing: 10) {
                Text(session.folder == nil ? "No folder open" : session.status)
                    .foregroundStyle(Theme.muted)
                Button("Open Folder…") { session.pickFolder() }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if session.visible.isEmpty {
            VStack(spacing: 10) {
                Text("No frames match this filter").foregroundStyle(Theme.muted)
                Button("Show All Frames") { session.setFilter(.all) }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 120, maximum: 260), spacing: 6)], spacing: 6) {
                        ForEach(session.visible) { item in
                            ThumbCell(item: item, selected: item.id == session.selected)
                                .id(item.id)
                                .onTapGesture { session.select(item.id) }
                                .contextMenu {
                                    Button("Send to Photoshop") { session.sendToEditor([item]) }
                                }
                        }
                    }
                    .padding(8)
                }
                .onChange(of: session.selected) { _, new in proxy.scrollTo(new) }
            }
        }
    }
}

struct ThumbCell: View {
    @ObservedObject var item: FrameItem
    let selected: Bool

    var body: some View {
        VStack(spacing: 3) {
            ZStack {
                Theme.background
                if let thumb = item.thumb {
                    Image(decorative: thumb, scale: 1)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .opacity(item.rating < 0 ? 0.4 : 1)
                } else if item.failed != nil {
                    Text("⚠").font(.system(size: 22)).foregroundStyle(Theme.reject)
                }
                if item.rating < 0 {
                    Text("✕").font(.system(size: 26, weight: .bold)).foregroundStyle(Theme.reject)
                }
                if let color = LabelColor.color(for: item.label) {
                    VStack { color.frame(height: 4); Spacer() }
                }
            }
            .aspectRatio(1, contentMode: .fit)
            .clipShape(RoundedRectangle(cornerRadius: 4))
            .overlay(RoundedRectangle(cornerRadius: 4).stroke(selected ? Theme.accent : Color.clear, lineWidth: 2))
            HStack(spacing: 4) {
                Text(item.baseName).lineLimit(1).truncationMode(.middle)
                Spacer(minLength: 0)
                if item.rating > 0 {
                    Text(String(repeating: "★", count: item.rating)).foregroundStyle(Theme.accent)
                }
            }
            .font(.system(size: 10))
            .foregroundStyle(selected ? Theme.text : Theme.muted)
        }
        .contentShape(Rectangle())
        .help(item.failed.map { "\(item.name): \($0)" } ?? item.name)
    }
}

// MARK: The hero image and its bar

struct HeroArea: View {
    @ObservedObject var session: Session

    var body: some View {
        VStack(spacing: 0) {
            ZStack(alignment: .top) {
                HeroView(session: session)
                if session.folder == nil {
                    Welcome(session: session)
                }
                if let message = session.message {
                    Text(message)
                        .font(.system(size: 13))
                        .padding(.horizontal, 12)
                        .padding(.vertical, 8)
                        .background(Theme.surface)
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                        .padding(12)
                }
            }
            Divider().overlay(Theme.line)
            if let item = session.current {
                RatingBar(session: session, item: item)
            } else {
                Text(appVersion).font(.system(size: 11)).foregroundStyle(Theme.muted).padding(8)
            }
        }
    }
}

var appVersion: String {
    let info = Bundle.main.infoDictionary
    let version = info?["CFBundleShortVersionString"] as? String ?? "0.1.0"
    let build = info?["CFBundleVersion"] as? String ?? "dev"
    return "TrainCull \(version) alpha \(build)"
}

struct Welcome: View {
    @ObservedObject var session: Session

    var body: some View {
        VStack(spacing: 14) {
            Text("TrainCull").font(.system(size: 28, weight: .bold))
            Text("Open a folder of raw files, or drop one here.\nRatings are saved as .xmp files next to the raws.")
                .multilineTextAlignment(.center)
                .foregroundStyle(Theme.muted)
            Button("Open Folder…") { session.pickFolder() }
                .controlSize(.large)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

struct RatingBar: View {
    @ObservedObject var session: Session
    @ObservedObject var item: FrameItem

    var body: some View {
        HStack(spacing: 14) {
            HStack(spacing: 2) {
                ForEach(1 ... 5, id: \.self) { n in
                    Button { session.rate(item.rating == n ? 0 : n) } label: {
                        Text(n <= item.rating ? "★" : "☆")
                            .font(.system(size: 18))
                            .foregroundStyle(n <= item.rating ? Theme.accent : Theme.muted)
                    }
                    .buttonStyle(.plain)
                    .help("\(n) star\(n == 1 ? "" : "s") (key \(n))")
                }
            }
            Button { session.toggleReject() } label: {
                Text("✕ Reject")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(item.rating < 0 ? Theme.background : Theme.reject)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(item.rating < 0 ? Theme.reject : Color.clear)
                    .overlay(RoundedRectangle(cornerRadius: 6).stroke(Theme.reject, lineWidth: 1))
                    .clipShape(RoundedRectangle(cornerRadius: 6))
            }
            .buttonStyle(.plain)
            .help("Reject (key X)")
            HStack(spacing: 7) {
                ForEach(LabelColor.allCases, id: \.rawValue) { label in
                    Button { session.setLabel(label) } label: {
                        Circle()
                            .fill(label.color)
                            .frame(width: 16, height: 16)
                            .overlay(Circle().stroke(Theme.text, lineWidth: item.label == label.text ? 2 : 0).padding(-3))
                    }
                    .buttonStyle(.plain)
                    .help(label == .purple ? label.text : "\(label.text) (key \(label.rawValue))")
                }
            }
            if let text = item.label {
                Text(text).font(.system(size: 12)).foregroundStyle(Theme.muted)
            }
            Spacer(minLength: 8)
            VStack(alignment: .trailing, spacing: 2) {
                if let shot = item.info?.shot?.label(), !shot.isEmpty {
                    Text(shot).foregroundStyle(Theme.text)
                }
                Text("\(item.name) · \(item.id + 1) / \(session.frames.count) · \(session.heroState) · \(session.zoomText)")
                    .foregroundStyle(Theme.muted)
                    .truncationMode(.head)
            }
            .font(.system(size: 12))
            .lineLimit(1)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(Theme.surface.opacity(0.6))
    }
}
