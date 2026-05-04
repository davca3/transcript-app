import SwiftUI

struct TransportBar: View {
    @ObservedObject var player: AudioPlayerController
    @ObservedObject var progress: ProgressTicker
    @Binding var autoFollow: Bool

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

            Text(formatTime(progress.currentTime))
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
                .frame(width: 48, alignment: .trailing)

            Slider(
                value: Binding(
                    get: { progress.currentTime },
                    set: { player.seek(to: $0) }
                ),
                in: 0...max(player.duration, 0.001)
            )

            Text(formatTime(player.duration))
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

    private func formatTime(_ t: TimeInterval) -> String {
        guard t.isFinite, t >= 0 else { return "0:00" }
        let h = Int(t) / 3600, m = (Int(t) % 3600) / 60, s = Int(t) % 60
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, s) : String(format: "%d:%02d", m, s)
    }
}
