import SwiftUI

struct SpeakerChip: View {
    let assignment: StoredAssignment
    let knownSpeakers: [Speaker]
    let onRename: () -> Void
    let onMerge: (UUID) -> Void
    let onUnassign: () -> Void
    let onJumpToNext: () -> Void

    var body: some View {
        Menu {
            Button {
                onJumpToNext()
            } label: {
                Label("Skoč na další pasáž", systemImage: "forward.end.fill")
            }
            Divider()
            Button("Přejmenovat…") { onRename() }
            if assignment.speakerId != nil {
                Button("Odebrat jméno (zpět na Speaker N)") { onUnassign() }
            }
            if !mergeCandidates.isEmpty {
                Divider()
                Section("Sloučit s mluvčím") {
                    ForEach(mergeCandidates) { s in
                        Button(s.name) { onMerge(s.id) }
                    }
                }
            }
        } label: {
            HStack(alignment: .center, spacing: 6) {
                Image(systemName: assignment.speakerId == nil ? "person.crop.circle.dashed" : "person.crop.circle.fill")
                    .imageScale(.small)
                Text(assignment.displayName)
                    .lineLimit(1)
            }
            .padding(.horizontal, 10).padding(.vertical, 6)
            .background(
                Capsule().fill(assignment.speakerId == nil ? Color.gray.opacity(0.18) : Color.accentColor.opacity(0.18))
            )
            .overlay(
                Capsule().stroke(Color.secondary.opacity(0.2), lineWidth: 0.5)
            )
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
    }

    private var mergeCandidates: [Speaker] {
        knownSpeakers.filter { $0.id != assignment.speakerId }
    }
}
