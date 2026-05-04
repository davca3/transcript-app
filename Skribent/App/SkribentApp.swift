import SwiftUI

@main
struct SkribentApp: App {
    @StateObject private var state = AppState()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(state)
                .environmentObject(state.recordings)
                .environmentObject(state.speakers)
                .frame(minWidth: 980, minHeight: 600)
        }
        .windowStyle(.titleBar)
        .windowToolbarStyle(.unified)
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("Nová nahrávka") { NotificationCenter.default.post(name: .skribentNewRecording, object: nil) }
                    .keyboardShortcut("n", modifiers: [.command])
            }
        }
    }
}

extension Notification.Name {
    static let skribentNewRecording = Notification.Name("skribent.newRecording")
}
