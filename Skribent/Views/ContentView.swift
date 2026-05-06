import SwiftUI

struct ContentView: View {
    @EnvironmentObject var state: AppState
    @EnvironmentObject var recordings: RecordingStore
    @State private var showNewRecording = false
    @State private var showSpeakerManagement = false

    /// Local mirror of the sidebar's selection. SwiftUI's `List(selection:)` on macOS is backed
    /// by NSOutlineView, whose `outlineViewSelectionDidChange` notification is dispatched inside
    /// `Update.ensure { ... }` — i.e. *inside* a SwiftUI view-update transaction. If the binding
    /// wrote straight into AppState's `@Published`, the resulting `objectWillChange.send()`
    /// would happen during the update and trigger "Publishing changes from within view updates"
    /// (confirmed via `OutlineListCoordinator → Binding.wrappedValue.set → AppState` stack).
    /// `@State` writes go through SwiftUI's internal storage (no Combine), so they're safe
    /// inside that callback. Two `onChange` handlers sync the singular case (size==1) back and
    /// forth with `state.selectedRecordingId` *outside* the update transaction, so programmatic
    /// selection changes (e.g. `processNewRecording` selecting a freshly created recording)
    /// still work.
    @State private var sidebarSelection: Set<UUID> = []

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
                SelectedRecordingDetail(selection: $sidebarSelection)
            }
        }
        .onAppear {
            if let id = state.selectedRecordingId { sidebarSelection = [id] }
        }
        .onChange(of: sidebarSelection) { _, new in
            // Mirror the singular case to AppState so programmatic flows can still observe a
            // primary selection. Multi-select clears the primary id — the detail pane uses
            // sidebarSelection directly to decide what to render.
            let primary: UUID? = new.count == 1 ? new.first : nil
            if state.selectedRecordingId != primary { state.selectedRecordingId = primary }
        }
        .onChange(of: state.selectedRecordingId) { _, new in
            if let id = new {
                if sidebarSelection != [id] { sidebarSelection = [id] }
            } else if sidebarSelection.count == 1 {
                // AppState cleared the primary id (e.g. a recording was deleted). Drop the
                // singular sidebar selection too. Multi-select stays untouched.
                sidebarSelection = []
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
///
/// Three states based on `selection.count`:
/// - 0: empty placeholder ("Vyber nahrávku…")
/// - 1: full per-recording detail (player + transcript + chips)
/// - 2+: multi-select summary with bulk delete
private struct SelectedRecordingDetail: View {
    @EnvironmentObject var recordings: RecordingStore
    @Binding var selection: Set<UUID>

    var body: some View {
        switch selection.count {
        case 0:
            EmptyDetailView()
        case 1:
            if let id = selection.first,
               let rec = recordings.recordings.first(where: { $0.id == id }) {
                // .id(rec.id) tears the detail down on each recording switch so the player /
                // artifact / autoFollow lifecycle is cleanly isolated per recording — the
                // previous view's @StateObject player and @State artifact don't leak into the
                // next one.
                RecordingDetailView(recording: rec).id(rec.id)
            } else {
                // Selection points at an id that no longer exists in the store (deleted in
                // another window / by an external process). Treat as empty.
                EmptyDetailView()
            }
        default:
            MultiSelectionDetailView(ids: selection, selection: $selection)
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
