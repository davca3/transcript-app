import SwiftUI

struct RecorderView: View {
    @EnvironmentObject var state: AppState
    @ObservedObject var recorder: AudioRecorder
    let title: String
    let config: AudioRecorder.Config
    let onFinished: (URL) -> Void

    var body: some View {
        VStack(spacing: 18) {
            Text(recorder.elapsed.hmsPadded)
                .font(.system(size: 40, weight: .light, design: .monospaced))

            LevelMeter(level: recorder.level)
                .frame(height: 48)

            HStack(spacing: 16) {
                if recorder.isFinalizing {
                    ProgressView("Mixuji audio…")
                } else if recorder.isRecording {
                    Button {
                        Task {
                            if let url = await recorder.stopAndFinalize() {
                                onFinished(url)
                            }
                        }
                    } label: {
                        Label("Stop a zpracovat", systemImage: "stop.circle.fill").font(.title3)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(.red)
                } else {
                    Button {
                        do {
                            try recorder.start(config)
                        } catch {
                            state.globalError = error.localizedDescription
                        }
                    } label: {
                        Label("Nahrávat", systemImage: "record.circle.fill").font(.title3)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(.red)
                }
            }
        }
        .padding(24)
        .background(RoundedRectangle(cornerRadius: 12).fill(Color.surface))
    }

}

private struct LevelMeter: View {
    let level: Float

    var body: some View {
        GeometryReader { geo in
            let count = 32
            let spacing: CGFloat = 4
            let barW = (geo.size.width - spacing * CGFloat(count - 1)) / CGFloat(count)
            HStack(spacing: spacing) {
                ForEach(0..<count, id: \.self) { i in
                    let threshold = Float(i) / Float(count)
                    let on = level > threshold
                    RoundedRectangle(cornerRadius: 2)
                        .fill(on ? color(for: i, count: count) : Color.surfaceBorder)
                        .frame(width: barW)
                }
            }
        }
    }

    private func color(for i: Int, count: Int) -> Color {
        let p = Double(i) / Double(count)
        if p > 0.85 { return .red }
        if p > 0.65 { return .orange }
        return .green
    }
}
