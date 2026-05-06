import SwiftUI

struct ContentView: View {
    @EnvironmentObject var state: AppState
    @EnvironmentObject var recordings: RecordingStore
    @State private var showNewRecording = false
    @State private var showSpeakerManagement = false

    /// Local mirror of `state.selectedRecordingId`. SwiftUI's `List(selection:)` on macOS
    /// is backed by NSOutlineView, whose `outlineViewSelectionDidChange` notification is
    /// dispatched inside `Update.ensure { ... }` — i.e. *inside* a SwiftUI view-update
    /// transaction. If the binding writes straight into AppState's `@Published`
    /// `selectedRecordingId`, the resulting `objectWillChange.send()` happens during the
    /// update and triggers "Publishing changes from within view updates" — confirmed via
    /// stack trace from `OutlineListCoordinator → Binding.wrappedValue.set → AppState`.
    /// `@State` writes go through SwiftUI's internal storage (no Combine), so they're
    /// safe inside that callback. Two `onChange` handlers below sync this back and forth
    /// with AppState *outside* the update transaction, so programmatic selection changes
    /// (e.g. `processNewRecording` selecting a freshly created recording) still work.
    @State private var sidebarSelection: UUID?

    var body: some View {
        NavigationSplitView {
            RecordingsListView(selection: $sidebarSelection)
                .navigationSplitViewColumnWidth(min: AppLayout.sidebarMinWidth, ideal: AppLayout.sidebarIdealWidth)
        } detail: {
            VStack(spacing: 0) {
                ModelStatusBanner(transcriber: state.transcriber)
                #if canImport(FluidAudio)
                DiarizerStatusBanner(diarizer: state.diarizer)
                #endif
                SelectedRecordingDetail(selectedId: sidebarSelection)
            }
        }
        .onAppear { sidebarSelection = state.selectedRecordingId }
        .onChange(of: sidebarSelection) { _, new in
            if state.selectedRecordingId != new { state.selectedRecordingId = new }
        }
        .onChange(of: state.selectedRecordingId) { _, new in
            if sidebarSelection != new { sidebarSelection = new }
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
            // .id(rec.id) tears the detail down on each recording switch so the player /
            // artifact / autoFollow lifecycle is cleanly isolated per recording — the
            // previous view's @StateObject player and @State artifact don't leak into the
            // next one.
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
