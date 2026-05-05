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
                HStack(spacing: 10) {
                    Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.red)
                    Text(msg).font(.caption)
                    Spacer()
                }
                .padding(.horizontal, 16).padding(.vertical, 8)
                .background(Color.red.opacity(0.08))
            case .done:
                EmptyView()
            }
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
                        Button("Zrušit", action: onCancel)
                            .buttonStyle(.borderless)
                            .controlSize(.small)
                            .foregroundStyle(.red)
                            .help("Zrušit probíhající operaci. Audio a stávající přepis zůstanou nedotčené.")
                    }
                }
                if indeterminate {
                    ProgressView().progressViewStyle(.linear).tint(tint)
                } else {
                    ProgressView(value: progress).progressViewStyle(.linear).tint(tint)
                }
                HStack(spacing: 8) {
                    if let elapsed {
                        Label(format(elapsed), systemImage: "clock")
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
                        Text("Zbývá ~\(format(eta))")
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
        switch stage {
        case .decoding: return "Dekóduji audio…"
        case .enhancing: return "Vylepšuji zvuk…"
        case .transcribing: return "Přepisuji řeč (Whisper)…"
        case .diarizing: return "Rozděluji mluvčí (pyannote)…"
        case .identifying: return "Rozpoznávám známé hlasy…"
        case .downloadingModel: return "Stahuji Mistral Nemo (~7 GB, jednorázově)…"
        case .loadingModel: return "Načítám Mistral Nemo do paměti…"
        case .refining: return "Vylepšuji přepis (Mistral Nemo)…"
        }
    }

    /// Linear extrapolation: ETA = elapsed × (1/progress − 1). Only meaningful once progress
    /// has crossed a small threshold; otherwise the number is wildly noisy.
    private func etaSeconds(progress: Double, elapsed: TimeInterval?) -> TimeInterval? {
        guard let elapsed, progress > 0.05, progress < 0.99 else { return nil }
        let total = elapsed / progress
        return Swift.max(0, total - elapsed)
    }

    private func format(_ t: TimeInterval) -> String {
        guard t.isFinite, t >= 0 else { return "—" }
        if t < 60 { return String(format: "%d s", Int(t.rounded())) }
        let m = Int(t) / 60, s = Int(t) % 60
        return String(format: "%d:%02d min", m, s)
    }
}
