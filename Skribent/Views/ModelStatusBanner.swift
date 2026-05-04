import SwiftUI

struct ModelStatusBanner: View {
    @ObservedObject var transcriber: WhisperKitTranscriber

    var body: some View {
        switch transcriber.state {
        case .idle:
            // Hidden during the brief idle window; download/load banners take over within 500ms
            // if needed, otherwise we go straight to .ready (cache hit) without showing anything.
            EmptyView()
        case .downloading(let p):
            banner {
                ProgressView(value: p)
                    .progressViewStyle(.linear)
                    .frame(width: 200)
                    .tint(.orange)
                Text("Stahuji Whisper model… \(Int(p * 100)) %")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                if p < 0.001 {
                    Text("(první spuštění, ~600 MB)")
                        .font(.caption2).foregroundStyle(.tertiary)
                }
            }
        case .loadingIntoMemory:
            banner {
                ProgressView().controlSize(.small)
                Text("Načítám model do paměti a zahřívám Neural Engine…")
                    .font(.caption).foregroundStyle(.secondary)
            }
        case .ready:
            EmptyView()
        case .failed(let msg):
            HStack(spacing: 10) {
                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.red)
                Text("Whisper model selhal: \(msg)").font(.caption).foregroundStyle(.secondary)
                Spacer()
            }
            .padding(.horizontal, 16).padding(.vertical, 8)
            .background(Color.red.opacity(0.10))
        }
    }

    @ViewBuilder
    private func banner<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        HStack(spacing: 10) {
            content()
            Spacer()
        }
        .padding(.horizontal, 16).padding(.vertical, 8)
        .background(Color.orange.opacity(0.10))
    }
}
