import SwiftUI

struct TransportBar: View {
    @ObservedObject var player: AudioPlayerController
    @ObservedObject var progress: ProgressTicker
    @Binding var autoFollow: Bool

    /// Local drag state. While the user is dragging, the Slider binds to this value (so it
    /// doesn't mutate `player.progress.currentTime` per drag delta during a render). On
    /// release (`onEditingChanged: false`) we commit via `player.seek`.
    @State private var dragValue: Double?

    var body: some View {
        HStack(spacing: 12) {
            Button {
                player.togglePlayPause()
            } label: {
                Image(systemName: player.isPlaying ? "pause.circle.fill" : "play.circle.fill")
                    .font(.title2)
            }
            .buttonStyle(.plain)
            .keyboardShortcut(.space, modifiers: [])

            Text(TimeInterval(dragValue ?? progress.currentTime).hms)
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
                .frame(width: 48, alignment: .trailing)

            Slider(
                value: Binding(
                    get: { dragValue ?? progress.currentTime },
                    set: { dragValue = $0 }   // pure @State write — no publish
                ),
                in: 0...max(player.duration, 0.001),
                onEditingChanged: { editing in
                    if !editing, let target = dragValue {
                        player.seek(to: target)
                        dragValue = nil
                    }
                }
            )

            Text(player.duration.hms)
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
                .frame(width: 48, alignment: .leading)

            Toggle(isOn: $autoFollow) {
                Text("Sledovat").font(.caption)
            }
            .toggleStyle(.checkbox)
            .help("Posouvá přepis podle aktuální pozice přehrávání. Vypne se, když ručně scrollneš.")
        }
        .padding(.horizontal, 16).padding(.vertical, 10)
        .background(Color.gray.opacity(0.06))
    }

}
