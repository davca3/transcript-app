import SwiftUI

struct ProgressBanner: View {
    let status: Recording.ProcessingStatus

    var body: some View {
        switch status {
        case .pending:
            banner(text: "Čekám…", progress: 0.05, color: .blue)
        case .running(let stage, let p):
            banner(text: label(for: stage), progress: p, color: .blue)
        case .failed(let msg):
            HStack {
                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.red)
                Text(msg).font(.caption)
                Spacer()
            }
            .padding(.horizontal, 16).padding(.vertical, 8)
            .background(Color.red.opacity(0.08))
        case .done:
            EmptyView()
        }
    }

    @ViewBuilder
    private func banner(text: String, progress: Double, color: Color) -> some View {
        HStack(spacing: 10) {
            ProgressView(value: progress).progressViewStyle(.linear).tint(color)
                .frame(width: 160)
            Text(text).font(.caption).foregroundStyle(.secondary)
            Spacer()
        }
        .padding(.horizontal, 16).padding(.vertical, 8)
        .background(color.opacity(0.06))
    }

    private func label(for stage: Recording.ProcessingStatus.Stage) -> String {
        switch stage {
        case .decoding: return "Dekóduji audio…"
        case .transcribing: return "Přepisuji (Whisper)…"
        case .diarizing: return "Rozděluji mluvčí…"
        case .identifying: return "Rozpoznávám známé hlasy…"
        }
    }
}
