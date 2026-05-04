import SwiftUI

struct SpeakerManagementView: View {
    @EnvironmentObject var state: AppState
    @Environment(\.dismiss) private var dismiss

    @State private var renamingId: UUID?
    @State private var renameDraft: String = ""
    @State private var confirmResetAll = false

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Známí mluvčí").font(.title2).bold()
                Spacer()
                if !state.speakers.speakers.isEmpty {
                    Button("Smazat všechny", role: .destructive) { confirmResetAll = true }
                }
                Button("Hotovo") { dismiss() }.keyboardShortcut(.defaultAction)
            }
            .padding(20)

            Divider()

            if state.speakers.speakers.isEmpty {
                VStack(spacing: 12) {
                    Image(systemName: "person.2.slash").font(.system(size: 40, weight: .light))
                        .foregroundStyle(.secondary)
                    Text("Zatím žádný pojmenovaný mluvčí").foregroundStyle(.secondary)
                    Text("Pojmenuj mluvčího v detailu nahrávky a objeví se tady.")
                        .font(.caption).foregroundStyle(.tertiary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List {
                    ForEach(state.speakers.speakers) { s in
                        HStack {
                            Image(systemName: "person.crop.circle.fill").foregroundStyle(.tint)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(s.name).font(.body)
                                Text("\(s.embeddings.count) vzork\(s.embeddings.count == 1 ? "ek" : "ů") • aktualizováno \(s.updatedAt, style: .date)")
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer()
                            Button {
                                renamingId = s.id; renameDraft = s.name
                            } label: { Image(systemName: "pencil") }
                            .buttonStyle(.borderless)
                            Button(role: .destructive) {
                                state.speakers.delete(s.id)
                            } label: { Image(systemName: "trash") }
                            .buttonStyle(.borderless)
                        }
                        .padding(.vertical, 4)
                    }
                }
            }
        }
        .frame(width: 480, height: 480)
        .alert("Smazat všechny mluvčí?", isPresented: $confirmResetAll) {
            Button("Smazat", role: .destructive) {
                for s in state.speakers.speakers { state.speakers.delete(s.id) }
            }
            Button("Zrušit", role: .cancel) {}
        } message: {
            Text("Použij, pokud máš v DB staré nekompatibilní vzorky (např. po změně diarizačního modelu). Stávající přepisy zůstanou, jen se ztratí auto-rozpoznávání.")
        }
        .alert("Přejmenovat",
               isPresented: Binding(get: { renamingId != nil }, set: { if !$0 { renamingId = nil } })) {
            TextField("Jméno", text: $renameDraft)
            Button("Uložit") {
                if let id = renamingId, !renameDraft.trimmingCharacters(in: .whitespaces).isEmpty {
                    state.renameKnown(speakerId: id, to: renameDraft)
                }
                renamingId = nil
            }
            Button("Zrušit", role: .cancel) { renamingId = nil }
        }
    }
}
