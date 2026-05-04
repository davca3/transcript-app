import SwiftUI

struct RecordingsListView: View {
    @EnvironmentObject var state: AppState
    @Binding var selection: UUID?

    var body: some View {
        List(selection: $selection) {
            ForEach(state.recordings.recordings) { rec in
                RecordingRow(recording: rec)
                    .tag(rec.id)
                    .contextMenu {
                        Button("Smazat", role: .destructive) {
                            state.recordings.delete(rec.id)
                            if selection == rec.id { selection = nil }
                        }
                    }
            }
        }
        .listStyle(.sidebar)
    }
}

private struct RecordingRow: View {
    let recording: Recording

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(recording.title).font(.body).lineLimit(1)
                Spacer()
                statusBadge
            }
            HStack(spacing: 8) {
                Image(systemName: recording.sourceKind == .microphone ? "mic.fill" : "doc.fill")
                    .font(.caption2).foregroundStyle(.tertiary)
                Text(recording.createdAt, style: .date)
                Text("•")
                Text(formatDuration(recording.duration))
            }
            .font(.caption).foregroundStyle(.secondary)
        }
        .padding(.vertical, 4)
    }

    @ViewBuilder
    private var statusBadge: some View {
        switch recording.status {
        case .pending:
            ProgressView().controlSize(.mini)
        case .running:
            ProgressView().controlSize(.mini)
        case .done:
            EmptyView()
        case .failed:
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.red).font(.caption)
        }
    }

    private func formatDuration(_ t: TimeInterval) -> String {
        let m = Int(t) / 60, s = Int(t) % 60
        return String(format: "%d:%02d", m, s)
    }
}
