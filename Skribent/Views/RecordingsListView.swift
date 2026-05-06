import SwiftUI

struct RecordingsListView: View {
    @EnvironmentObject var state: AppState
    @EnvironmentObject var recordings: RecordingStore
    @Binding var selection: Set<UUID>

    /// Set when the user picks "Přejmenovat" from the context menu (single-row case). Drives the
    /// rename alert below. `nil` while the alert is dismissed.
    @State private var renamingId: UUID?
    @State private var renameDraft: String = ""

    var body: some View {
        List(selection: $selection) {
            ForEach(recordings.recordings) { rec in
                RecordingRow(recording: rec).tag(rec.id)
            }
        }
        .listStyle(.sidebar)
        // `forSelectionType` is the macOS-native way to wire a selection-aware context menu —
        // SwiftUI hands us the set of ids the right-click should act on (which is either the
        // current multi-selection, or just the right-clicked row if it isn't part of one).
        .contextMenu(forSelectionType: UUID.self) { ids in
            if ids.count == 1, let id = ids.first {
                Button("Přejmenovat") {
                    renamingId = id
                    renameDraft = recordings.recordings.first(where: { $0.id == id })?.title ?? ""
                }
                Button("Smazat", role: .destructive) {
                    delete(ids: [id])
                }
            } else if ids.count > 1 {
                Button("Smazat \(ids.count) nahrávek", role: .destructive) {
                    delete(ids: ids)
                }
            }
        }
        .alert("Přejmenovat nahrávku",
               isPresented: Binding(get: { renamingId != nil }, set: { if !$0 { renamingId = nil } })) {
            TextField("Název", text: $renameDraft)
            Button("Uložit") {
                if let id = renamingId {
                    state.renameRecording(id, to: renameDraft)
                }
                renamingId = nil
            }
            Button("Zrušit", role: .cancel) { renamingId = nil }
        }
    }

    private func delete(ids: Set<UUID>) {
        state.deleteRecordings(ids)
        // Drop any deleted ids out of the current selection so the multi-select state stays
        // consistent with what's actually on disk / in the index.
        selection.subtract(ids)
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
                Text(recording.duration.compactDuration)
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
}
