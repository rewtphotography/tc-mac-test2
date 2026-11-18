import AppKit
import SwiftUI

@main
struct TrainCullApp: App {
    @StateObject private var session = Session()

    var body: some Scene {
        Window("TrainCull", id: "main") {
            ContentView(session: session)
        }
        .commands {
            // The About panel gives the alpha as well as the version.
            CommandGroup(replacing: .appInfo) {
                Button("About TrainCull") {
                    NSApplication.shared.orderFrontStandardAboutPanel(options: [
                        .applicationVersion: releaseName,
                        .version: "build \(buildNumber)",
                    ])
                }
            }
            CommandGroup(replacing: .newItem) {
                Button("Open Folder…") { session.pickFolder() }
                    .keyboardShortcut("o", modifiers: .command)
            }
            // No shortcuts here: a key is added only when a core action needs one.
            CommandGroup(replacing: .importExport) {
                Button("Extract Embedded JPEG") { session.exportCurrent(.jpeg) }
                    .disabled(session.current == nil || session.exportStatus != nil)
                Button("Export 16-bit TIFF") { session.exportCurrent(.tiff) }
                    .disabled(session.current == nil || session.exportStatus != nil)
                Divider()
                Button("Extract Embedded JPEGs of All Frames Shown…") { session.exportShown(.jpeg) }
                    .disabled(session.visible.isEmpty || session.exportStatus != nil)
                Button("Export 16-bit TIFFs of All Frames Shown…") { session.exportShown(.tiff) }
                    .disabled(session.visible.isEmpty || session.exportStatus != nil)
                Button("Stop Export") { session.stopExport() }
                    .disabled(session.exportStatus == nil)
            }
            CommandGroup(replacing: .help) {
                DiagnosticsMenuItem()
            }
        }

        Window("Diagnostics", id: "diagnostics") {
            DiagnosticsView()
        }
        .windowResizability(.contentSize)
    }
}

/// Help → Diagnostics: memory use in plain language and the log file.
struct DiagnosticsMenuItem: View {
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Button("Diagnostics") { openWindow(id: "diagnostics") }
    }
}
