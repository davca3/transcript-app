import SwiftUI

struct ContentView: View {
    @EnvironmentObject var state: AppState
    @State private var showNewRecording = false
    @State private var showSpeakerManagement = false

    var body: some View {
        NavigationSplitView {
            RecordingsListView(selection: $state.selectedRecordingId)
                .navigationSplitViewColumnWidth(min: 240, ideal: 280)
        } detail: {
            VStack(spacing: 0) {
                ModelStatusBanner(transcriber: state.transcriber)
                #if canImport(FluidAudio)
                DiarizerStatusBanner(diarizer: state.diarizer)
                #endif
                if let id = state.selectedRecordingId,
                   let rec = state.recordings.recordings.first(where: { $0.id == id }) {
                    RecordingDetailView(recording: rec)
                } else {
                    EmptyDetailView()
                }
            }
        }
        .toolbar {
            ToolbarItem(placement: .navigation) {
                Button {
                    showNewRecording = true
                } label: {
                    Label("Nová nahrávka", systemImage: "plus.circle.fill")
                }
                .help("Nová nahrávka (⌘N)")
            }
            ToolbarItem(placement: .primaryAction) {
                Button {
                    showSpeakerManagement = true
                } label: {
                    Label("Mluvčí", systemImage: "person.2.fill")
                }
                .help("Správa mluvčích")
            }
        }
        .sheet(isPresented: $showNewRecording) {
            NewRecordingView()
                .environmentObject(state)
        }
        .sheet(isPresented: $showSpeakerManagement) {
            SpeakerManagementView()
                .environmentObject(state)
        }
        .onReceive(NotificationCenter.default.publisher(for: .skribentNewRecording)) { _ in
            showNewRecording = true
        }
        .alert("Chyba", isPresented: Binding(
            get: { state.globalError != nil },
            set: { if !$0 { state.globalError = nil } })
        ) {
            Button("OK") { state.globalError = nil }
        } message: {
            Text(state.globalError ?? "")
        }
    }
}

private struct EmptyDetailView: View {
    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "waveform")
                .font(.system(size: 56, weight: .ultraLight))
                .foregroundStyle(.secondary)
            Text("Vyber nahrávku nebo vytvoř novou")
                .font(.title3).foregroundStyle(.secondary)
            Text("⌘N pro novou nahrávku").font(.caption).foregroundStyle(.tertiary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
