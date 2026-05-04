import SwiftUI

#if canImport(FluidAudio)
struct DiarizerStatusBanner: View {
    @ObservedObject var diarizer: FluidAudioDiarizer

    var body: some View {
        switch diarizer.state {
        case .idle:
            EmptyView()
        case .downloading:
            banner("Stahuji diarizační model… (první spuštění)")
        case .loadingIntoMemory:
            banner("Načítám diarizační model do paměti…")
        case .ready:
            EmptyView()
        case .failed(let msg):
            HStack(spacing: 10) {
                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.red)
                Text("Diarizace selhala: \(msg)").font(.caption).foregroundStyle(.secondary)
                Spacer()
            }
            .padding(.horizontal, 16).padding(.vertical, 8)
            .background(Color.red.opacity(0.10))
        }
    }

    @ViewBuilder
    private func banner(_ text: String) -> some View {
        HStack(spacing: 10) {
            ProgressView().controlSize(.small)
            Text(text).font(.caption).foregroundStyle(.secondary)
            Spacer()
        }
        .padding(.horizontal, 16).padding(.vertical, 8)
        .background(Color.purple.opacity(0.10))
    }
}
#endif
