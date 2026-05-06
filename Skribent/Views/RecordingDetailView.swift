import SwiftUI
import UniformTypeIdentifiers

struct RecordingDetailView: View {
    @EnvironmentObject var state: AppState
    @EnvironmentObject var recordings: RecordingStore
    @EnvironmentObject var speakers: SpeakerStore
    let recording: Recording

    @State private var artifact: RecordingArtifact?
    @StateObject private var player = AudioPlayerController()
    @State private var renamingClusterId: Int?
    @State private var renameDraft: String = ""
    @State private var exporterDoc: ExportDoc?
    @State private var exportType: UTType = .plainText
    @State private var reidentifyToast: String?
    @State private var confirmRegenerate = false
    // Plain @State (not @AppStorage). AppStorage writes to NSUserDefaults synchronously and
    // posts a system notification that SwiftUI propagates as another view update — chained
    // with player.load() that fires inside the resulting transaction it produced
    // "Publishing changes from within view updates" warnings on every recording switch.
    @State private var autoFollow: Bool = true

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            ProgressBanner(
                status: recording.status,
                detail: state.processingDetail,
                onCancel: { state.cancelProcessing(for: recording) },
                isCancelling: state.cancellingIds.contains(recording.id),
                dismissibleFailure: true
            )
            // Show the player whenever the cleaned WAV exists on disk — independent of the
            // transcript artifact. This lets the user preview the enhanced recording (HPF +
            // loudness-normalized) even mid-processing or when transcription failed/produced
            // no segments.
            if FileManager.default.fileExists(atPath: recording.audioURL.path) {
                TransportBar(player: player, progress: player.progress, autoFollow: $autoFollow)
            }
            speakerChips
            Divider()
            transcriptSection
        }
        .task {
            // View is keyed by `.id(recording.id)` in SelectedRecordingDetail, so a recording
            // switch destroys this view and creates a new one — `.task` (no id) runs exactly
            // once per recording. We still bounce off the runloop before any state writes:
            // SwiftUI may begin the task body inside the same MainActor work item that
            // committed the appearance, and synchronous publishes there trigger
            // "Publishing changes from within view updates."
            await runLoopBounce()
            reload()
            autoFollow = true
            player.pause()
            player.load(recording.audioURL)
        }
        .onChange(of: recording.status) {
            if case .done = recording.status { reload() }
            if case .failed = recording.status { reload() }
        }
        .fileExporter(
            isPresented: Binding(get: { exporterDoc != nil }, set: { if !$0 { exporterDoc = nil } }),
            document: exporterDoc,
            contentType: exportType,
            defaultFilename: defaultExportName()
        ) { _ in }
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(recording.title).font(.title2).bold()
                Text("\(recording.createdAt, style: .date) • \(recording.createdAt, style: .time) • \(formatDuration(recording.duration))")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            if FileManager.default.fileExists(atPath: recording.audioURL.path) {
                Button {
                    confirmRegenerate = true
                } label: {
                    Label("Přegenerovat transcript", systemImage: "arrow.clockwise.circle")
                }
                .help("Spustí znovu transkripci a diarizaci na uložené nahrávce. Přepíše stávající přepis.")
                .disabled(isProcessing)
            }
            if artifact != nil {
                Button {
                    state.refineTranscript(for: recording)
                } label: {
                    Label("Vyčistit přepis", systemImage: "wand.and.stars")
                }
                .help("Lokální Qwen 2.5 7B model (in-app, MLX) projde přepis a opraví zjevné chyby rozpoznávání pomocí kontextu. Zachovává anglické technické termy. První spuštění stáhne ~4 GB.")
                .disabled(isProcessing)
            }
            if artifact != nil || FileManager.default.fileExists(atPath: recording.audioURL.path) {
                Menu {
                    if artifact != nil {
                        Button("Export TXT") { exportTxt() }
                        Button("Export JSON") { exportJson() }
                    }
                    if FileManager.default.fileExists(atPath: recording.audioURL.path) {
                        Button("Export audio (WAV)") { exportAudio() }
                    }
                } label: {
                    Label("Export", systemImage: "square.and.arrow.up")
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
            }
        }
        .padding(16)
        .confirmationDialog(
            "Pregenerovat přepis?",
            isPresented: $confirmRegenerate,
            titleVisibility: .visible
        ) {
            Button("Pregenerovat", role: .destructive) {
                state.regenerateTranscript(for: recording)
            }
            Button("Zrušit", role: .cancel) {}
        } message: {
            Text("Aktuální přepis a přiřazení mluvčích v této nahrávce se přepíše. Známí mluvčí v DB se nezmění.")
        }
        .alert("Hotovo", isPresented: Binding(
            get: { reidentifyToast != nil }, set: { if !$0 { reidentifyToast = nil } })
        ) {
            Button("OK") { reidentifyToast = nil }
        } message: {
            Text(reidentifyToast ?? "")
        }
    }

    // MARK: - Speaker chips

    @ViewBuilder
    private var speakerChips: some View {
        if let artifact {
            let chips = displayChips(for: artifact)
            FlowLayout(spacing: 8, lineSpacing: 8) {
                ForEach(chips, id: \.displayName) { chip in
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
                            reload()
                        },
                        onUnassign: {
                            for cid in chip.clusterIds {
                                state.unassignCluster(in: recording, clusterId: cid)
                            }
                            reload()
                        },
                        onJumpToNext: { jumpToNext(chip: chip) }
                    )
                }
                Button {
                    let n = state.reidentifyUnnamed(in: recording)
                    reidentifyToast = n > 0 ? "Rozpoznáno \(n) mluvčích z DB" : "Žádný unnamed cluster nematchoval DB"
                    reload()
                } label: {
                    HStack(alignment: .center, spacing: 6) {
                        Image(systemName: "person.crop.circle.badge.questionmark")
                            .imageScale(.small)
                        Text("Znovu rozpoznat")
                    }
                    .padding(.horizontal, 10).padding(.vertical, 6)
                    .background(Capsule().fill(Color.gray.opacity(0.10)))
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
        }
    }

    // MARK: - Transcript

    @ViewBuilder
    private var transcriptSection: some View {
        if let artifact {
            TranscriptView(
                artifact: artifact,
                progress: player.progress,
                speakerStore: speakers,
                autoFollow: $autoFollow,
                onPlayRange: { start, end in
                    player.play(from: start, until: end)
                },
                onSeek: { t in
                    player.play(from: t)
                }
            )
        } else if case .failed(let msg) = recording.status {
            VStack(spacing: 8) {
                Image(systemName: "exclamationmark.triangle.fill").font(.largeTitle).foregroundStyle(.red)
                Text("Zpracování selhalo").font(.headline)
                Text(msg).font(.caption).foregroundStyle(.secondary).multilineTextAlignment(.center)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            ProgressView("Zpracovávám…").frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    // MARK: - Actions

    private func reload() {
        artifact = recordings.loadArtifact(for: recording)
    }

    /// Collapse clusters with the same display name into a single chip and renumber unnamed
    /// clusters sequentially. Drops "ghost" clusters that no transcript segment references
    /// (artifacts produced by older pipeline runs before that filter was added).
    private func displayChips(for artifact: RecordingArtifact) -> [DisplayChip] {
        // Build speakerId → clusterIds map so we can mark which clusters are referenced.
        var clustersForSpeakerId: [UUID: [Int]] = [:]
        for (key, a) in artifact.clusterAssignments {
            guard let cid = Int(key) else { continue }
            let sid = a.speakerId ?? UnnamedSpeakerID.make(clusterId: cid)
            clustersForSpeakerId[sid, default: []].append(cid)
        }
        var referenced = Set<Int>()
        for seg in artifact.transcript.segments {
            guard let sid = seg.speakerId, let cids = clustersForSpeakerId[sid] else { continue }
            for cid in cids { referenced.insert(cid) }
        }

        // Walk filtered, sorted clusters; renumber unnamed sequentially over THIS subset.
        let pairs = artifact.clusterAssignments
            .compactMap { (k, v) -> (Int, StoredAssignment)? in
                guard let cid = Int(k), referenced.contains(cid) else { return nil }
                return (cid, v)
            }
            .sorted { $0.0 < $1.0 }

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

    private var isProcessing: Bool {
        if case .running = recording.status { return true }
        return false
    }

    /// Find the next segment belonging to any of the chip's underlying clusters, after the
    /// current playback time. Wraps around to the chip's first segment if there's nothing later.
    private func jumpToNext(chip: DisplayChip) {
        guard let artifact else { return }

        // Resolve all UUIDs that segments could carry for this chip's clusters.
        var targetIds = Set<UUID>()
        for cid in chip.clusterIds {
            if let stored = artifact.assignment(for: cid), let sid = stored.speakerId {
                targetIds.insert(sid)
            } else {
                targetIds.insert(UnnamedSpeakerID.make(clusterId: cid))
            }
        }

        let now = player.progress.currentTime
        let segments = artifact.transcript.segments
        let next = segments.first(where: {
            guard let sid = $0.speakerId else { return false }
            return targetIds.contains(sid) && $0.start > now + 0.05  // small epsilon to skip current
        })
        let target = next ?? segments.first(where: {
            guard let sid = $0.speakerId else { return false }
            return targetIds.contains(sid)
        })
        if let target {
            player.play(from: target.start)
        }
    }

    private func applyRename(clusterId: Int, name: String) {
        guard let artifact = recordings.loadArtifact(for: recording),
              let stored = artifact.assignment(for: clusterId) else { return }
        if let speakerId = stored.speakerId {
            state.renameKnown(speakerId: speakerId, to: name)
        } else {
            state.promoteUnnamed(in: recording, clusterId: clusterId, newName: name)
        }
        reload()
    }

    private func exportTxt() {
        guard let artifact else { return }
        let text = Exporter.txt(artifact: artifact, recording: recording)
        exportType = .plainText
        exporterDoc = ExportDoc(text: text, type: .plainText)
    }

    private func exportJson() {
        guard let artifact else { return }
        do {
            let data = try Exporter.json(artifact: artifact, recording: recording)
            exportType = .json
            exporterDoc = ExportDoc(data: data, type: .json)
        } catch {
            state.globalError = error.localizedDescription
        }
    }

    private func exportAudio() {
        do {
            let data = try Data(contentsOf: recording.audioURL)
            exportType = .wav
            exporterDoc = ExportDoc(data: data, type: .wav)
        } catch {
            state.globalError = error.localizedDescription
        }
    }

    private func defaultExportName() -> String {
        let safe = recording.title.replacingOccurrences(of: "/", with: "_")
        let ext: String
        switch exportType {
        case .json: ext = ".json"
        case .wav: ext = ".wav"
        default: ext = ".txt"
        }
        return safe + ext
    }

    private func formatDuration(_ t: TimeInterval) -> String {
        let m = Int(t) / 60, s = Int(t) % 60
        return String(format: "%d min %02d s", m, s)
    }
}

private struct DisplayChip {
    var displayName: String
    var representative: StoredAssignment
    var clusterIds: [Int]
}

/// Suspends the current MainActor task until the next runloop pass — strictly stronger
/// than `Task.yield()`, which can resume inside the same MainActor work item that scheduled
/// the task. Used to defer state writes past an in-flight SwiftUI view update transaction.
@MainActor
private func runLoopBounce() async {
    await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
        DispatchQueue.main.async { cont.resume() }
    }
}

// MARK: - FileDocument adapter

struct ExportDoc: FileDocument {
    static var readableContentTypes: [UTType] = [.plainText, .json, .wav]
    var data: Data
    var type: UTType

    init(text: String, type: UTType) {
        self.data = Data(text.utf8); self.type = type
    }
    init(data: Data, type: UTType) { self.data = data; self.type = type }
    init(configuration: ReadConfiguration) throws {
        self.data = configuration.file.regularFileContents ?? Data()
        self.type = .plainText
    }
    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(regularFileWithContents: data)
    }
}
