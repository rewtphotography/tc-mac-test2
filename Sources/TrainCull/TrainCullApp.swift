import SwiftUI

@main
struct TrainCullApp: App {
    @StateObject private var session = Session()

    var body: some Scene {
        Window("TrainCull", id: "main") {
            ContentView(session: session)
        }
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("Open Folder…") { session.pickFolder() }
                    .keyboardShortcut("o", modifiers: .command)
            }
        }
    }
}
