import SwiftUI
import AppKit

struct TranscriptView: View {
    let artifact: RecordingArtifact
    @ObservedObject var progress: ProgressTicker
    @ObservedObject var speakerStore: SpeakerStore
    @Binding var autoFollow: Bool
    let onPlayRange: (TimeInterval, TimeInterval) -> Void
    let onSeek: (TimeInterval) -> Void

    @State private var groups: [SegmentGroup] = []
    @State private var scrollPosition: UUID?
    @State private var lastAutoFollowTarget: UUID?

    var body: some View {
        let now = progress.currentTime
        let active = activeLocation(at: now)
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 14) {
                ForEach(groups) { group in
                    TranscriptGroupRow(
                        group: group,
                        isActive: active?.groupID == group.id,
                        activeSegmentIndex: active?.groupID == group.id ? active?.segmentIndex : nil,
                        onPlay: { onPlayRange(group.start, group.end) },
                        onSeek: onSeek
                    )
                    .id(group.id)
                    .padding(.horizontal, 16)
                }
            }
            .padding(.vertical, 16)
            .scrollTargetLayout()
        }
        .scrollPosition(id: $scrollPosition, anchor: .top)
        .onAppear { recomputeGroups() }
        .onChange(of: artifact) { _, _ in recomputeGroups() }
        .onChange(of: speakerStore.speakers) { _, _ in recomputeGroups() }
        .onChange(of: progress.currentTime) { _, now in
            guard autoFollow,
                  let id = activeGroupID(at: now),
                  id != scrollPosition else { return }
            withAnimation(.easeOut(duration: 0.25)) {
                scrollPosition = id
            }
            lastAutoFollowTarget = id
        }
        .onChange(of: scrollPosition) { _, newPos in
            // If the new scroll position differs from what auto-follow last set,
            // it must have been the user — turn auto-follow off.
            if let newPos, newPos != lastAutoFollowTarget {
                if autoFollow { autoFollow = false }
            }
        }
    }

    private func recomputeGroups() {
        // Build clusterId → name once, then cluster→speakerId reverse map for lookup per segment.
        let names = artifact.displayNames(knownSpeakers: speakerStore.speakers)
        var nameForSpeakerId: [UUID: String] = [:]
        for (key, a) in artifact.clusterAssignments {
            guard let cid = Int(key), let n = names[cid] else { continue }
            if let sid = a.speakerId {
                nameForSpeakerId[sid] = n
            } else {
                // Unnamed cluster: derive deterministic UUID
                nameForSpeakerId[UnnamedSpeakerID.make(clusterId: cid)] = n
            }
        }

        var out: [SegmentGroup] = []
        for seg in artifact.transcript.segments {
            let name = seg.speakerId.flatMap { nameForSpeakerId[$0] } ?? "Neznámý"
            let color = color(for: seg.speakerId)
            if var last = out.last, last.speakerName == name {
                last.segments.append(seg)
                out[out.count - 1] = last
            } else {
                out.append(SegmentGroup(speakerName: name, color: color, segments: [seg]))
            }
        }
        groups = out
    }

    private func activeGroupID(at t: TimeInterval) -> UUID? {
        groups.first(where: { $0.start <= t && t < $0.end })?.id
    }

    /// Find both the active group and the active segment within it. Linear scan; for typical
    /// meetings (≤ a few thousand segments) this is negligible at 10 Hz. `segmentIndex` is
    /// nil when the timestamp falls in a gap between segments (still highlights the group).
    private func activeLocation(at t: TimeInterval) -> (groupID: UUID, segmentIndex: Int?)? {
        for group in groups where group.start <= t && t < group.end {
            for (i, seg) in group.segments.enumerated() where seg.start <= t && t < seg.end {
                return (group.id, i)
            }
            return (group.id, nil)
        }
        return nil
    }

    private func color(for speakerId: UUID?) -> Color {
        let palette: [Color] = [.blue, .green, .orange, .purple, .pink, .teal, .indigo, .brown]
        guard let id = speakerId else { return .gray }
        var hash = 5381
        for b in id.uuidString.utf8 { hash = ((hash << 5) &+ hash) &+ Int(b) }
        return palette[abs(hash) % palette.count]
    }
}

private struct TranscriptGroupRow: View {
    let group: SegmentGroup
    let isActive: Bool
    let activeSegmentIndex: Int?
    let onPlay: () -> Void
    let onSeek: (TimeInterval) -> Void

    @State private var hoveredIndex: Int?

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 10) {
                Circle().fill(group.color).frame(width: 8, height: 8)
                Text(group.speakerName).font(.headline)

                Button {
                    onPlay()
                } label: {
                    Label(formatTime(group.start), systemImage: "play.circle.fill")
                        .labelStyle(.titleAndIcon)
                        .font(.caption.monospacedDigit())
                }
                .buttonStyle(.borderless)
                .help("Přehrát tuto pasáž (\(formatTime(group.start))–\(formatTime(group.end)))")

                Button {
                    copyToClipboard(group.text)
                } label: {
                    Image(systemName: "doc.on.doc").font(.caption)
                }
                .buttonStyle(.borderless)
                .help("Kopírovat text této pasáže")

                Spacer()
            }
            FlowLayout(spacing: 4, lineSpacing: 4) {
                ForEach(Array(group.segments.enumerated()), id: \.offset) { i, seg in
                    Text(seg.text)
                        .font(.body)
                        .padding(.horizontal, 4).padding(.vertical, 2)
                        .background(
                            RoundedRectangle(cornerRadius: 4)
                                .fill(spanBackground(index: i))
                        )
                        .contentShape(RoundedRectangle(cornerRadius: 4))
                        .onHover { hovering in
                            hoveredIndex = hovering ? i : (hoveredIndex == i ? nil : hoveredIndex)
                            if hovering { NSCursor.pointingHand.push() } else { NSCursor.pop() }
                        }
                        .onTapGesture { onSeek(seg.start) }
                        .help("Klikni pro skok na \(formatTime(seg.start))")
                }
            }
        }
        .padding(8)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(isActive ? Color.accentColor.opacity(0.06) : Color.clear)
        )
        .animation(.easeOut(duration: 0.15), value: isActive)
    }

    private func spanBackground(index: Int) -> Color {
        if index == activeSegmentIndex { return Color.accentColor.opacity(0.35) }
        if hoveredIndex == index { return Color.accentColor.opacity(0.15) }
        return .clear
    }

    private func copyToClipboard(_ s: String) {
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(s, forType: .string)
    }

    private func formatTime(_ t: TimeInterval) -> String {
        guard t.isFinite, t >= 0 else { return "0:00" }
        let h = Int(t) / 3600, m = (Int(t) % 3600) / 60, s = Int(t) % 60
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, s) : String(format: "%d:%02d", m, s)
    }
}

private struct SegmentGroup: Identifiable, Equatable {
    let id = UUID()
    let speakerName: String
    let color: Color
    var segments: [TranscriptSegment]

    var start: TimeInterval { segments.first?.start ?? 0 }
    var end: TimeInterval { segments.last?.end ?? 0 }
    var text: String { segments.map(\.text).joined(separator: " ") }
}
