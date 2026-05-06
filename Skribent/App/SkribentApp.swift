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
                .frame(minWidth: AppLayout.windowMinWidth, minHeight: AppLayout.windowMinHeight)
        }
        .windowStyle(.titleBar)
        .windowToolbarStyle(.unified)
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("Nová nahrávka") { NotificationCenter.default.post(name: .skribentNewRecording, object: nil) }
                    .keyboardShortcut("n", modifiers: [.command])
            }
        }

        Settings {
            SettingsView()
        }
    }
}

extension Notification.Name {
    static let skribentNewRecording = Notification.Name("skribent.newRecording")
}

/// macOS Settings window (⌘,). Currently only exposes the ANE toggle, but lives here as the
/// canonical home for app-wide preferences.
struct SettingsView: View {
    @AppStorage(WhisperKitTranscriber.useANEDefaultsKey) private var useANE: Bool = false

    var body: some View {
        Form {
            Section {
                Toggle("Použít Apple Neural Engine", isOn: $useANE)
                Text(useANE
                     ? "Inference o ~5–15 % rychlejší. **Při prvním spuštění s ANE bude Apple kompilovat model 5–15 minut** — během toho bude aplikace vypadat zaseknutá. Nezavírejte ji."
                     : "Whisper běží na CPU+GPU. Inference je o málo pomalejší, ale aplikace startuje okamžitě.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } header: {
                Text("Akcelerace přepisu")
            } footer: {
                Text("Změna se projeví po restartu aplikace.")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
        }
        .formStyle(.grouped)
        .frame(width: 480, height: 240)
    }
}
