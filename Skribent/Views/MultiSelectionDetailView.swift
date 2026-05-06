import SwiftUI

/// Shown in the detail pane when the sidebar has more than one recording selected. Mirrors the
/// Finder/Mail "X items selected" pattern: count + aggregate stats + bulk actions. Single-select
/// users never see this — `ContentView.SelectedRecordingDetail` switches between this, the
/// per-recording detail, and the empty state based on `selection.count`.
struct MultiSelectionDetailView: View {
    @EnvironmentObject var state: AppState
    @EnvironmentObject var recordings: RecordingStore
    let ids: Set<UUID>
    /// Parent's selection binding so we can drop the deleted ids after a bulk delete (without
    /// this the sidebar would still show the now-orphan selection until the user clicks elsewhere).
    @Binding var selection: Set<UUID>

    @State private var confirmDelete = false

    var body: some View {
        let selected = recordings.recordings.filter { ids.contains($0.id) }

        VStack(spacing: 24) {
            VStack(spacing: 8) {
                Image(systemName: "checkmark.circle")
                    .font(.system(size: 56, weight: .ultraLight))
                    .foregroundStyle(.secondary)
                Text("\(selected.count) \(czechRecordingsWord(count: selected.count)) vybráno")
                    .font(.title3)
            }

            VStack(alignment: .leading, spacing: 6) {
                statRow(label: "Celková délka:", value: totalDuration(selected).humanDuration)
                if let range = dateRange(selected) {
                    statRow(label: "Datum:", value: range)
                }
            }
            .padding(.horizontal, 20).padding(.vertical, 14)
            .frame(minWidth: 280)
            .background(RoundedRectangle(cornerRadius: 10).fill(Color.surface))

            HStack(spacing: 12) {
                Button(role: .destructive) {
                    confirmDelete = true
                } label: {
                    Label("Smazat \(selected.count) \(czechRecordingsWord(count: selected.count))", systemImage: "trash")
                }
                .buttonStyle(.borderedProminent)
                .tint(.red)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .confirmationDialog(
            "Smazat vybrané nahrávky?",
            isPresented: $confirmDelete,
            titleVisibility: .visible
        ) {
            Button("Smazat \(selected.count) \(czechRecordingsWord(count: selected.count))", role: .destructive) {
                state.deleteRecordings(ids)
                selection.subtract(ids)
            }
            Button("Zrušit", role: .cancel) {}
        } message: {
            Text("Audio i přepisy budou nenávratně smazány. Známé hlasy v DB zůstanou nedotčené.")
        }
    }

    @ViewBuilder
    private func statRow(label: String, value: String) -> some View {
        HStack {
            Text(label).foregroundStyle(.secondary)
            Spacer()
            Text(value).monospacedDigit()
        }
        .font(.callout)
    }

    private func totalDuration(_ recs: [Recording]) -> TimeInterval {
        recs.reduce(0) { $0 + $1.duration }
    }

    private func dateRange(_ recs: [Recording]) -> String? {
        guard let first = recs.map(\.createdAt).min(),
              let last = recs.map(\.createdAt).max() else { return nil }
        let f = DateFormatter()
        f.dateStyle = .medium
        f.timeStyle = .none
        f.locale = Locale(identifier: "cs_CZ")
        let firstStr = f.string(from: first)
        if Calendar.current.isDate(first, inSameDayAs: last) { return firstStr }
        return "\(firstStr) – \(f.string(from: last))"
    }

    /// Czech 1/2-4/5+ plural form for "nahrávka". Avoids the awkward "1 nahrávek vybráno".
    private func czechRecordingsWord(count: Int) -> String {
        switch count {
        case 1: return "nahrávka"
        case 2...4: return "nahrávky"
        default: return "nahrávek"
        }
    }
}
