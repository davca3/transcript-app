import SwiftUI
import UniformTypeIdentifiers

struct RecordingDetailView: View {
    @EnvironmentObject var state: AppState
    @EnvironmentObject var recordings: RecordingStore
    @EnvironmentObject var speakers: SpeakerStore
    let recording: Recording

    @State private var artifact: RecordingArtifact?
    @StateObject private var player = AudioPlayerController()
    @State private var exporterDoc: ExportDoc?
    @State private var exportType: UTType = .plainText
    // Plain @State (not @AppStorage). AppStorage writes to NSUserDefaults synchronously and
    // posts a system notification that SwiftUI propagates as another view update — chained
    // with player.load() that fires inside the resulting transaction it produced
    // "Publishing changes from within view updates" warnings on every recording switch.
    @State private var autoFollow: Bool = true

    var body: some View {
        VStack(spacing: 0) {
            RecordingDetailHeader(
                recording: recording,
                hasArtifact: artifact != nil,
                isProcessing: isProcessing,
                hasAudio: hasAudio,
                onRegenerate: { state.regenerateTranscript(for: recording) },
                onRefine: { state.refineTranscript(for: recording) },
                onExportTxt: exportTxt,
                onExportJson: exportJson,
                onExportAudio: exportAudio
            )
            Divider()
            ProgressBanner(
                status: effectiveStatus,
                detail: state.processingDetail,
                onCancel: { state.cancelProcessing(for: recording) },
                isCancelling: state.cancellingIds.contains(recording.id),
                dismissibleFailure: true
            )
            // Show the player whenever the cleaned WAV exists on disk — independent of the
            // transcript artifact. This lets the user preview the enhanced recording (HPF +
            // loudness-normalized) even mid-processing or when transcription failed/produced
            // no segments.
            if hasAudio {
                TransportBar(player: player, progress: player.progress, autoFollow: $autoFollow)
            }
            if let artifact {
                SpeakerChipsSection(
                    recording: recording,
                    artifact: artifact,
                    currentTime: { player.progress.currentTime },
                    onSeek: { player.play(from: $0) }
                )
            }
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
            switch recording.status {
            case .done, .failed: reload()
            default: break
            }
        }
        // Pick up artifact changes from speaker rename/promote/unassign/merge — those write to
        // recordings.artifactsByRecording inside saveArtifact, so observing the dict gives us a
        // direct reactive path without forcing AppState-wide objectWillChange.
        .onChange(of: recordings.artifactsByRecording[recording.id]) {
            reload()
        }
        .fileExporter(
            isPresented: Binding(get: { exporterDoc != nil }, set: { if !$0 { exporterDoc = nil } }),
            document: exporterDoc,
            contentType: exportType,
            defaultFilename: defaultExportName()
        ) { _ in }
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

    private var isProcessing: Bool {
        if case .running = recording.status { return true }
        return false
    }

    private var hasAudio: Bool {
        FileManager.default.fileExists(atPath: recording.audioURL.path)
    }

    /// Banner status: when the pipeline is mid-flight, overlay the in-memory progress tick onto
    /// `recording.status`. The tick lives in `RecordingStore.processingProgress` and updates 4×/s
    /// without churning the recordings array (so list views don't re-render every 250 ms).
    private var effectiveStatus: Recording.ProcessingStatus {
        guard case .running = recording.status,
              let tick = recordings.processingProgress[recording.id] else {
            return recording.status
        }
        return .running(stage: tick.stage, progress: tick.progress)
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
