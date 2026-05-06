import SwiftUI

/// Top section of the recording detail: title + meta + action buttons (regenerate, refine,
/// export menu). Pulled out of `RecordingDetailView` so the view's body stays scannable and the
/// header's confirm-dialog / re-identify alert don't share a parent body with the chips +
/// transcript sections.
struct RecordingDetailHeader: View {
    let recording: Recording
    let hasArtifact: Bool
    let isProcessing: Bool
    /// Whether the cleaned WAV exists on disk (controls "regenerate" + audio export buttons).
    let hasAudio: Bool

    let onRegenerate: () -> Void
    let onRefine: () -> Void
    let onExportTxt: () -> Void
    let onExportJson: () -> Void
    let onExportAudio: () -> Void

    @State private var confirmRegenerate = false

    var body: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(recording.title).font(.title2).bold()
                Text("\(recording.createdAt, style: .date) • \(recording.createdAt, style: .time) • \(recording.duration.humanDuration)")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            if hasAudio {
                Button {
                    confirmRegenerate = true
                } label: {
                    Label("Přegenerovat transcript", systemImage: "arrow.clockwise.circle")
                }
                .help("Spustí znovu transkripci a diarizaci na uložené nahrávce. Přepíše stávající přepis.")
                .disabled(isProcessing)
            }
            if hasArtifact {
                Button(action: onRefine) {
                    Label("Vyčistit přepis", systemImage: "wand.and.stars")
                }
                .help("Lokální Qwen 3.5 9B model (in-app, MLX) projde přepis a opraví zjevné chyby rozpoznávání pomocí kontextu. Zachovává anglické technické termy. První spuštění stáhne ~6 GB.")
                .disabled(isProcessing)
            }
            if hasArtifact || hasAudio {
                Menu {
                    if hasArtifact {
                        Button("Export TXT", action: onExportTxt)
                        Button("Export JSON", action: onExportJson)
                    }
                    if hasAudio {
                        Button("Export audio (WAV)", action: onExportAudio)
                    }
                } label: {
                    Label("Export", systemImage: "square.and.arrow.up")
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
            }
        }
        .padding(16)
        .confirmationDialog(
            "Pregenerovat přepis?",
            isPresented: $confirmRegenerate,
            titleVisibility: .visible
        ) {
            Button("Pregenerovat", role: .destructive, action: onRegenerate)
            Button("Zrušit", role: .cancel) {}
        } message: {
            Text("Aktuální přepis a přiřazení mluvčích v této nahrávce se přepíše. Známí mluvčí v DB se nezmění.")
        }
    }

}
