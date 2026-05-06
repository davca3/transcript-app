import SwiftUI

/// Speaker-chip row + rename / merge / unassign / re-identify interactions for one recording.
/// Pulled out of `RecordingDetailView` so the chip layout, `displayChips` derivation, and
/// rename alert don't share a parent body with the player + transcript section.
struct SpeakerChipsSection: View {
    @EnvironmentObject var state: AppState
    @EnvironmentObject var speakers: SpeakerStore
    let recording: Recording
    let artifact: RecordingArtifact
    /// Player time used by the "jump to next turn" button. Closure form so the parent doesn't
    /// have to expose its `AudioPlayerController` to this subview.
    let currentTime: () -> TimeInterval
    let onSeek: (TimeInterval) -> Void

    @State private var renamingClusterId: Int?
    @State private var renameDraft: String = ""
    @State private var reidentifyToast: String?
    /// Memoized chips. Recomputed only when the artifact or the live speaker DB changes —
    /// SwiftUI re-evaluates `body` on a parent player tick / autoFollow flip and we don't want
    /// to re-walk segments + clusterAssignments on every one of those.
    @State private var cachedChips: [DisplayChip] = []

    var body: some View {
        FlowLayout(spacing: 8, lineSpacing: 8) {
            ForEach(cachedChips, id: \.displayName) { chip in
                SpeakerChip(
                    assignment: chip.representative,
                    knownSpeakers: speakers.speakers,
                    onRename: {
                        renamingClusterId = chip.clusterIds.first
                        renameDraft = chip.displayName
                    },
                    onMerge: { speakerId in
                        for cid in chip.clusterIds {
                            state.mergeCluster(in: recording, clusterId: cid, into: speakerId)
                        }
                    },
                    onUnassign: {
                        for cid in chip.clusterIds {
                            state.unassignCluster(in: recording, clusterId: cid)
                        }
                    },
                    onJumpToNext: { jumpToNext(chip: chip) }
                )
            }
            Button {
                let n = state.reidentifyUnnamed(in: recording)
                reidentifyToast = n > 0 ? "Rozpoznáno \(n) mluvčích z DB" : "Žádný unnamed cluster nematchoval DB"
            } label: {
                HStack(alignment: .center, spacing: 6) {
                    Image(systemName: "person.crop.circle.badge.questionmark").imageScale(.small)
                    Text("Znovu rozpoznat")
                }
                .padding(.horizontal, 10).padding(.vertical, 6)
                .background(Capsule().fill(Color.surfaceMuted))
                .overlay(Capsule().stroke(Color.secondary.opacity(0.2), lineWidth: 0.5))
            }
            .buttonStyle(.plain)
            .help("Projde unnamed mluvčí v této nahrávce a zkusí je matchnout proti DB.")
        }
        .padding(.horizontal, 16).padding(.vertical, 8)
        .alert("Pojmenovat mluvčího",
               isPresented: Binding(get: { renamingClusterId != nil }, set: { if !$0 { renamingClusterId = nil } })) {
            TextField("Jméno", text: $renameDraft)
            Button("Uložit") {
                if let cid = renamingClusterId, !renameDraft.trimmingCharacters(in: .whitespaces).isEmpty {
                    applyRename(clusterId: cid, name: renameDraft)
                }
                renamingClusterId = nil
            }
            Button("Zrušit", role: .cancel) { renamingClusterId = nil }
        } message: {
            Text("Vzorek hlasu se uloží — příští nahrávky tuto osobu rozpoznají automaticky.")
        }
        .alert("Hotovo", isPresented: Binding(
            get: { reidentifyToast != nil }, set: { if !$0 { reidentifyToast = nil } })
        ) {
            Button("OK") { reidentifyToast = nil }
        } message: {
            Text(reidentifyToast ?? "")
        }
        .task(id: ChipCacheKey(artifact: artifact, speakers: speakers.speakers)) {
            cachedChips = displayChips(for: artifact)
        }
    }

    /// Collapse clusters with the same display name into a single chip and renumber unnamed
    /// clusters sequentially. Drops "ghost" clusters that no transcript segment references
    /// (artifacts produced by older pipeline runs before that filter was added).
    private func displayChips(for artifact: RecordingArtifact) -> [DisplayChip] {
        var clustersForSpeakerId: [UUID: [Int]] = [:]
        for (cid, a) in artifact.clusterAssignments {
            let sid = a.speakerId ?? UnnamedSpeakerID.make(clusterId: cid)
            clustersForSpeakerId[sid, default: []].append(cid)
        }
        var referenced = Set<Int>()
        for seg in artifact.transcript.segments {
            guard let sid = seg.speakerId, let cids = clustersForSpeakerId[sid] else { continue }
            for cid in cids { referenced.insert(cid) }
        }

        let pairs = artifact.clusterAssignments
            .filter { referenced.contains($0.key) }
            .sorted { $0.key < $1.key }

        var entries: [DisplayChip] = []
        var indexByName: [String: Int] = [:]
        var unnamedCounter = 1
        for (cid, a) in pairs {
            let name: String
            if let sid = a.speakerId, let live = speakers.speakers.first(where: { $0.id == sid }) {
                name = live.name
            } else if a.speakerId == nil {
                name = "Speaker \(unnamedCounter)"
                unnamedCounter += 1
            } else {
                name = a.displayName
            }
            if let idx = indexByName[name] {
                entries[idx].clusterIds.append(cid)
            } else {
                indexByName[name] = entries.count
                var rep = a
                rep.displayName = name
                entries.append(DisplayChip(displayName: name, representative: rep, clusterIds: [cid]))
            }
        }
        return entries
    }

    /// Find the next segment belonging to any of the chip's underlying clusters, after the
    /// current playback time. Wraps around to the chip's first segment if there's nothing later.
    private func jumpToNext(chip: DisplayChip) {
        var targetIds = Set<UUID>()
        for cid in chip.clusterIds {
            if let stored = artifact.assignment(for: cid), let sid = stored.speakerId {
                targetIds.insert(sid)
            } else {
                targetIds.insert(UnnamedSpeakerID.make(clusterId: cid))
            }
        }

        let now = currentTime()
        let segments = artifact.transcript.segments
        let next = segments.first(where: {
            guard let sid = $0.speakerId else { return false }
            return targetIds.contains(sid) && $0.start > now + 0.05
        })
        let target = next ?? segments.first(where: {
            guard let sid = $0.speakerId else { return false }
            return targetIds.contains(sid)
        })
        if let target {
            onSeek(target.start)
        }
    }

    private func applyRename(clusterId: Int, name: String) {
        guard let stored = artifact.assignment(for: clusterId) else { return }
        if let speakerId = stored.speakerId {
            state.renameKnown(speakerId: speakerId, to: name)
        } else {
            state.promoteUnnamed(in: recording, clusterId: clusterId, newName: name)
        }
    }
}

struct DisplayChip {
    var displayName: String
    var representative: StoredAssignment
    var clusterIds: [Int]
}

/// Cache invalidation key for `cachedChips`. Combines artifact identity + the live speakers DB
/// so renames in the DB invalidate the cache (a known cluster's display name pulls from the DB
/// at chip-build time). Avoids wiring two separate `.onChange` observers.
private struct ChipCacheKey: Hashable {
    let artifact: RecordingArtifact
    let speakers: [Speaker]
}
