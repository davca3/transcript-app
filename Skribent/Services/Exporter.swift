import Foundation

enum Exporter {
    static func txt(artifact: RecordingArtifact, recording: Recording) -> String {
        var out = "# \(recording.title)\n"
        out += "Datum: \(formatted(recording.createdAt))\n"
        out += "Délka: \(formatDuration(recording.duration))\n"
        if let lang = artifact.transcript.detectedLanguage { out += "Jazyk: \(lang)\n" }
        out += "\n"

        var lastSpeakerId: UUID?
        for seg in artifact.transcript.segments {
            let name = displayName(for: seg.speakerId, artifact: artifact)
            if seg.speakerId != lastSpeakerId {
                out += "\n[\(formatTime(seg.start))] \(name):\n"
                lastSpeakerId = seg.speakerId
            }
            out += "  \(seg.text)\n"
        }
        return out
    }

    struct JSONExport: Codable {
        let title: String
        let createdAt: Date
        let duration: TimeInterval
        let language: String?
        let segments: [Segment]

        struct Segment: Codable {
            let start: TimeInterval
            let end: TimeInterval
            let text: String
            let speaker: String
            let speakerId: String?
        }
    }

    static func json(artifact: RecordingArtifact, recording: Recording) throws -> Data {
        let segments: [JSONExport.Segment] = artifact.transcript.segments.map { seg in
            JSONExport.Segment(
                start: seg.start,
                end: seg.end,
                text: seg.text,
                speaker: displayName(for: seg.speakerId, artifact: artifact),
                speakerId: seg.speakerId?.uuidString
            )
        }
        let payload = JSONExport(
            title: recording.title,
            createdAt: recording.createdAt,
            duration: recording.duration,
            language: artifact.transcript.detectedLanguage,
            segments: segments
        )
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        enc.dateEncodingStrategy = .iso8601
        return try enc.encode(payload)
    }

    // MARK: - Helpers

    private static func displayName(for speakerId: UUID?, artifact: RecordingArtifact) -> String {
        guard let speakerId else { return "Unknown" }
        // Named speaker: direct match.
        if let a = artifact.clusterAssignments.values.first(where: { $0.speakerId == speakerId }) {
            return a.displayName
        }
        // Unnamed: derive cluster id by matching the deterministic UnnamedSpeakerID.
        for (key, a) in artifact.clusterAssignments where a.speakerId == nil {
            if let cid = Int(key), UnnamedSpeakerID.make(clusterId: cid) == speakerId {
                return a.displayName
            }
        }
        return "Unknown"
    }

    private static func formatTime(_ t: TimeInterval) -> String {
        let h = Int(t) / 3600
        let m = (Int(t) % 3600) / 60
        let s = Int(t) % 60
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, s) : String(format: "%d:%02d", m, s)
    }

    private static func formatDuration(_ t: TimeInterval) -> String {
        let m = Int(t) / 60, s = Int(t) % 60
        return String(format: "%d min %02d s", m, s)
    }

    private static func formatted(_ date: Date) -> String {
        let f = DateFormatter()
        f.dateStyle = .medium; f.timeStyle = .short; f.locale = Locale(identifier: "cs_CZ")
        return f.string(from: date)
    }
}
