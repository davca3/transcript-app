import SwiftUI

struct ProgressBanner: View {
    let status: Recording.ProcessingStatus
    /// Optional secondary detail line (e.g. "3.4 GB z 7.0 GB" during model download). Rendered
    /// as a small caption under the progress bar. nil = no extra line.
    var detail: String? = nil
    /// Optional cancel handler. When provided + status is `.running`, the banner shows a
    /// "Zrušit" button that calls this closure. The actual task cancellation is handled by
    /// the caller (typically `AppState.cancelProcessing(for:)`).
    var onCancel: (() -> Void)? = nil
    /// True between the moment the user clicks "Zrušit" and the task actually unwinding to a
    /// terminal status. Swaps the cancel button for a small spinner + "Ruším…" so the user
    /// sees the click was registered even when cancellation takes a few seconds (e.g. waiting
    /// for the next `Task.checkCancellation()` checkpoint inside Whisper / pyannote).
    var isCancelling: Bool = false
    /// When true, the failed-status banner shows an X button that hides it for the rest of
    /// the view's lifetime in this status. Reset automatically whenever `status` changes (so
    /// a fresh failure after a re-run shows again).
    var dismissibleFailure: Bool = false

    @State private var failureDismissed: Bool = false

    /// Reset point: when status flips into .running we capture Date.now and use it for
    /// elapsed/ETA derivation. We also track the previous progress so jumping backwards
    /// (shouldn't happen, but defensive) doesn't yank the ETA into negative territory.
    @State private var startedAt: Date?
    @State private var ticker = Date()  // forces a periodic re-render so elapsed/ETA labels move

    var body: some View {
        // Reading `ticker` here ties body re-evaluation to the 250 ms task loop below,
        // so the elapsed / ETA strings refresh as time passes (not just on state changes).
        let now = ticker
        return Group {
            switch status {
            case .pending:
                bar(label: "Čekám…", progress: 0.02, tint: .blue, eta: nil, elapsed: nil)
            case .running(let stage, let p):
                let elapsed = startedAt.map { now.timeIntervalSince($0) }
                let eta = etaSeconds(progress: p, elapsed: elapsed)
                let isIndeterminate = stage == .loadingModel
                bar(
                    label: stageLabel(stage),
                    progress: p,
                    indeterminate: isIndeterminate,
                    tint: .blue,
                    eta: isIndeterminate ? nil : eta,
                    elapsed: elapsed,
                    detail: detail
                )
            case .failed(let msg):
                if dismissibleFailure && failureDismissed {
                    EmptyView()
                } else {
                    HStack(spacing: 10) {
                        Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.red)
                        Text(msg).font(.caption)
                        Spacer()
                        if dismissibleFailure {
                            Button {
                                failureDismissed = true
                            } label: {
                                Image(systemName: "xmark")
                                    .font(.caption)
                            }
                            .buttonStyle(.borderless)
                            .foregroundStyle(.secondary)
                            .help("Skrýt upozornění")
                        }
                    }
                    .padding(.horizontal, 16).padding(.vertical, 8)
                    .background(Color.red.opacity(0.08))
                }
            case .done:
                EmptyView()
            }
        }
        .onChange(of: status) {
            // A status flip (re-run, success, fresh failure) re-arms the dismiss button so the
            // user always sees the latest state.
            failureDismissed = false
        }
        .onChange(of: isRunningOrPending) { _, running in
            if running, startedAt == nil { startedAt = Date() }
            if !running { startedAt = nil }
        }
        .onAppear {
            if isRunningOrPending, startedAt == nil { startedAt = Date() }
        }
        .task(id: isRunningOrPending) {
            // Drive a 250ms re-render so the elapsed/ETA strings refresh smoothly.
            // Cancellation check on BOTH ends — without it, after .task(id:) cancels us we'd
            // still write `ticker` once, racing with the next view update.
            while !Task.isCancelled, isRunningOrPending {
                try? await Task.sleep(nanoseconds: 250_000_000)
                guard !Task.isCancelled else { return }
                ticker = Date()
            }
        }
    }

    @ViewBuilder
    private func bar(
        label: String,
        progress: Double,
        indeterminate: Bool = false,
        tint: Color,
        eta: TimeInterval?,
        elapsed: TimeInterval?,
        detail: String? = nil
    ) -> some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 8) {
                    Text(label).font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    if !indeterminate {
                        Text("\(Int(progress * 100)) %")
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                    if let onCancel {
                        if isCancelling {
                            HStack(spacing: 6) {
                                ProgressView().controlSize(.small)
                                Text("Ruším…").font(.caption).foregroundStyle(.secondary)
                            }
                            .transition(.opacity)
                        } else {
                            Button(action: onCancel) {
                                Text("Zrušit")
                            }
                            .buttonStyle(.bordered)
                            .tint(.red)
                            .controlSize(.small)
                            .help("Zrušit probíhající operaci. Audio a stávající přepis zůstanou nedotčené.")
                        }
                    }
                }
                if indeterminate {
                    ProgressView().progressViewStyle(.linear).tint(tint)
                } else {
                    ProgressView(value: progress).progressViewStyle(.linear).tint(tint)
                }
                HStack(spacing: 8) {
                    if let elapsed {
                        Label(elapsed.bannerLabel, systemImage: "clock")
                            .font(.caption2.monospacedDigit())
                            .foregroundStyle(.tertiary)
                    }
                    if let detail {
                        Text(detail)
                            .font(.caption2.monospacedDigit())
                            .foregroundStyle(.tertiary)
                    }
                    Spacer()
                    if let eta {
                        Text("Zbývá ~\(eta.bannerLabel)")
                            .font(.caption2.monospacedDigit())
                            .foregroundStyle(.tertiary)
                    }
                }
            }
        }
        .padding(.horizontal, 16).padding(.vertical, 8)
        .background(tint.opacity(0.06))
    }

    // MARK: - Helpers

    private var isRunningOrPending: Bool {
        switch status {
        case .pending, .running: return true
        default: return false
        }
    }

    private func stageLabel(_ stage: Recording.ProcessingStatus.Stage) -> String {
        let base: String
        switch stage {
        case .decoding: base = "Dekóduji audio…"
        case .enhancing: base = "Vylepšuji zvuk…"
        case .transcribing: base = "Přepisuji řeč (Whisper)…"
        case .diarizing: base = "Rozděluji mluvčí (pyannote)…"
        case .identifying: base = "Rozpoznávám známé hlasy…"
        case .downloadingModel: base = "Stahuji Qwen 2.5 (~4 GB, jednorázově)…"
        case .loadingModel: base = "Načítám Qwen 2.5 do paměti…"
        case .refining: base = "Vylepšuji přepis (Qwen 2.5)…"
        }
        let s = stage.step
        return "Krok \(s.current) z \(s.total) · \(base)"
    }

    /// Linear extrapolation: ETA = elapsed × (1/progress − 1). Only meaningful once progress
    /// has crossed a small threshold; otherwise the number is wildly noisy.
    private func etaSeconds(progress: Double, elapsed: TimeInterval?) -> TimeInterval? {
        guard let elapsed, progress > 0.05, progress < 0.99 else { return nil }
        let total = elapsed / progress
        return Swift.max(0, total - elapsed)
    }

}

private extension Recording.ProcessingStatus.Stage {
    /// Position of this stage within its pipeline so the banner can show "Krok N z M".
    /// Process pipeline = 4 steps (transcribe + diarize fold into one — they run in parallel).
    /// Refine pipeline = 3 steps (download is conditionally skipped on warm cache; if it is,
    /// the user briefly sees "2 z 3" instead of "1 z 2" — acceptable since the actual ordering
    /// inside refine is unambiguous from the label).
    var step: (current: Int, total: Int) {
        switch self {
        case .decoding:         return (1, 4)
        case .enhancing:        return (2, 4)
        case .transcribing:     return (3, 4)
        case .diarizing:        return (3, 4)
        case .identifying:      return (4, 4)
        case .downloadingModel: return (1, 3)
        case .loadingModel:     return (2, 3)
        case .refining:         return (3, 3)
        }
    }
}
