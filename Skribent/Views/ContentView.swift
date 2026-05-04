import SwiftUI

struct ContentView: View {
    @EnvironmentObject var state: AppState
    @EnvironmentObject var recordings: RecordingStore
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
                SelectedRecordingDetail(selectedId: state.selectedRecordingId)
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

/// Owns the recordings observation so ContentView itself doesn't have to.
/// When `recordings` changes, only this small wrapper re-renders (and the detail it spawns),
/// not ContentView's toolbar/sheets/alerts.
private struct SelectedRecordingDetail: View {
    @EnvironmentObject var recordings: RecordingStore
    let selectedId: UUID?

    var body: some View {
        if let id = selectedId,
           let rec = recordings.recordings.first(where: { $0.id == id }) {
            // .id(rec.id) forces SwiftUI to fully tear down the previous detail and create
            // a fresh one on every recording switch. Without it, SwiftUI reuses the same
            // view instance and merely re-runs `.task(id:)`, which races with the in-flight
            // sidebar-selection update transaction and produces "Publishing changes from
            // within view updates" warnings (the @State writes inside the task body publish
            // before the prior transaction commits). Recreation isolates each recording's
            // @StateObject player + @State artifact lifecycle cleanly.
            RecordingDetailView(recording: rec).id(rec.id)
        } else {
            EmptyDetailView()
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
