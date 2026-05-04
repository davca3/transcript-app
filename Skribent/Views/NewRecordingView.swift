import SwiftUI
import UniformTypeIdentifiers

struct NewRecordingView: View {
    @EnvironmentObject var state: AppState
    @Environment(\.dismiss) private var dismiss
    @State private var mode: Mode = .record
    @State private var title: String = "Nahrávka \(Self.dateFormatter.string(from: Date()))"
    @State private var importedURL: URL?
    @State private var showImporter = false

    @AppStorage("recorder.inputDeviceUID") private var inputDeviceUID: String = ""
    @AppStorage("recorder.captureSystemAudio") private var captureSystemAudio: Bool = false

    @State private var inputDevices: [AudioInputDevice] = []

    enum Mode: String, CaseIterable, Identifiable { case record = "Nahrát", file = "Importovat soubor"; var id: String { rawValue } }

    var body: some View {
        VStack(spacing: 16) {
            Text("Nová nahrávka").font(.title2).bold()

            Picker("", selection: $mode) {
                ForEach(Mode.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)

            TextField("Název", text: $title)
                .textFieldStyle(.roundedBorder)

            Group {
                switch mode {
                case .record:
                    VStack(spacing: 12) {
                        recorderSettings
                        RecorderView(
                            recorder: state.recorder,
                            title: title,
                            config: AudioRecorder.Config(
                                inputDeviceUID: inputDeviceUID.isEmpty ? nil : inputDeviceUID,
                                captureSystemAudio: captureSystemAudio
                            ),
                            onFinished: { url in
                                state.processNewRecording(sourceURL: url, title: title, kind: .microphone)
                                dismiss()
                            }
                        )
                    }
                case .file:
                    FileImportPanel(importedURL: $importedURL, showImporter: $showImporter)
                }
            }
            .frame(minHeight: 280)
            .onAppear { inputDevices = AudioDeviceManager.availableInputs() }

            HStack {
                Button("Zrušit") { dismiss() }.keyboardShortcut(.escape)
                Spacer()
                if mode == .file {
                    Button("Zpracovat") {
                        guard let url = importedURL else { return }
                        state.processNewRecording(sourceURL: url, title: title, kind: .imported)
                        dismiss()
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(importedURL == nil || title.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
        }
        .padding(24)
        .frame(width: 520)
    }

    @ViewBuilder
    private var recorderSettings: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Image(systemName: "mic.fill").foregroundStyle(.secondary)
                Text("Vstup:").font(.callout).foregroundStyle(.secondary)
                Picker("", selection: $inputDeviceUID) {
                    Text("Systémový default").tag("")
                    ForEach(inputDevices) { dev in
                        Text(dev.name).tag(dev.uid)
                    }
                }
                .labelsHidden()
                Button {
                    inputDevices = AudioDeviceManager.availableInputs()
                } label: { Image(systemName: "arrow.clockwise") }
                .buttonStyle(.borderless)
                .help("Obnovit seznam zařízení")
            }
            Toggle(isOn: $captureSystemAudio) {
                HStack(spacing: 4) {
                    Image(systemName: "speaker.wave.2.fill").foregroundStyle(.secondary)
                    Text("Nahrávat i zvuk z výstupu (systémové audio)")
                }
            }
            .toggleStyle(.checkbox)
            if captureSystemAudio {
                Text("Vyžaduje povolení v System Settings → Privacy & Security → Screen Recording.")
                    .font(.caption2).foregroundStyle(.tertiary)
            }
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.gray.opacity(0.05)))
    }

    private static let dateFormatter: DateFormatter = {
        let f = DateFormatter(); f.dateFormat = "d. M. yyyy HH:mm"; return f
    }()
}

private struct FileImportPanel: View {
    @Binding var importedURL: URL?
    @Binding var showImporter: Bool

    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: "waveform.path.badge.plus")
                .font(.system(size: 48, weight: .light))
                .foregroundStyle(.secondary)
            if let url = importedURL {
                Text(url.lastPathComponent).font(.body)
                Button("Vybrat jiný soubor") { showImporter = true }
            } else {
                Button("Vybrat audio soubor") { showImporter = true }
                    .buttonStyle(.borderedProminent)
                Text("Podporováno: m4a, mp3, wav, flac, aac, …").font(.caption).foregroundStyle(.tertiary)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(24)
        .background(RoundedRectangle(cornerRadius: 12).fill(Color.gray.opacity(0.08)))
        .fileImporter(
            isPresented: $showImporter,
            allowedContentTypes: [.audio, .mp3, .wav, .mpeg4Audio],
            allowsMultipleSelection: false
        ) { result in
            switch result {
            case .success(let urls):
                guard let url = urls.first else { return }
                _ = url.startAccessingSecurityScopedResource()
                importedURL = url
            case .failure: break
            }
        }
    }
}
