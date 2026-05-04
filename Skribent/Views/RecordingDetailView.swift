import SwiftUI
import UniformTypeIdentifiers

struct RecordingDetailView: View {
    @EnvironmentObject var state: AppState
    let recording: Recording

    @State private var artifact: RecordingArtifact?
    @StateObject private var player = AudioPlayerController()
    @State private var renamingClusterId: Int?
    @State private var renameDraft: String = ""
    @State private var exporterDoc: ExportDoc?
    @State private var exportType: UTType = .plainText
    @State private var reidentifyToast: String?
    @State private var confirmRegenerate = false
    @AppStorage("transcript.autoFollow") private var autoFollow: Bool = true

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            ProgressBanner(status: recording.status)
            if artifact != nil {
                TransportBar(player: player, progress: player.progress, autoFollow: $autoFollow)
            }
            speakerChips
            Divider()
            transcriptSection
        }
        .onAppear {
            reload()
            player.load(recording.audioURL)
        }
        .onChange(of: recording.id) {
            reload()
            player.pause()
            player.load(recording.audioURL)
        }
        .onChange(of: recording.status) { reload() }
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
                Menu {
                    Button("Export TXT") { exportTxt() }
                    Button("Export JSON") { exportJson() }
                    Button("Export audio (WAV)") { exportAudio() }
                        .disabled(!FileManager.default.fileExists(atPath: recording.audioURL.path))
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
                        knownSpeakers: state.speakers.speakers,
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
                        }
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
                speakerStore: state.speakers,
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
        artifact = state.recordings.loadArtifact(for: recording)
    }

    /// Collapse clusters with the same display name into a single chip and renumber unnamed
    /// clusters sequentially. Same speaker can be split across multiple clusters by the
    /// diarizer; this presents them as one chip whose actions apply to all underlying clusters.
    private func displayChips(for artifact: RecordingArtifact) -> [DisplayChip] {
        let names = artifact.displayNames(knownSpeakers: state.speakers.speakers)
        let pairs = artifact.clusterAssignments
            .compactMap { (k, v) -> (Int, StoredAssignment)? in Int(k).map { ($0, v) } }
            .sorted { $0.0 < $1.0 }

        var entries: [DisplayChip] = []
        var indexByName: [String: Int] = [:]
        for (cid, a) in pairs {
            let name = names[cid] ?? a.displayName
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

    private func applyRename(clusterId: Int, name: String) {
        guard let artifact = state.recordings.loadArtifact(for: recording),
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
