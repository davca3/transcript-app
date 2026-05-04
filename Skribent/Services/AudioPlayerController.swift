import Foundation
import AVFoundation
import Combine

/// Holds the play-head time. Lives separately from `AudioPlayerController` so the 10×/s
/// time tick doesn't republish the controller — otherwise every parent view that observes
/// the controller (e.g. `RecordingDetailView`) re-renders 10×/s and the whole UI stutters
/// during playback.
@MainActor
final class ProgressTicker: ObservableObject {
    @Published var currentTime: TimeInterval = 0
}

@MainActor
final class AudioPlayerController: ObservableObject {
    @Published private(set) var isPlaying = false
    @Published private(set) var duration: TimeInterval = 0
    let progress = ProgressTicker()

    private var player: AVAudioPlayer?
    private var stopAt: TimeInterval?
    private var timer: Timer?
    private var loadedURL: URL?

    /// Read-only convenience for callers that don't observe.
    var currentTime: TimeInterval { progress.currentTime }

    func load(_ url: URL) {
        guard loadedURL != url else { return }
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        do {
            let p = try AVAudioPlayer(contentsOf: url)
            p.prepareToPlay()
            self.player = p
            self.loadedURL = url
            self.duration = p.duration
            self.progress.currentTime = 0
        } catch {
            print("[AudioPlayer] load failed: \(error)")
            self.player = nil
        }
    }

    func play(from start: TimeInterval? = nil, until end: TimeInterval? = nil) {
        guard let p = player else { return }
        if let start { p.currentTime = start; progress.currentTime = start }
        stopAt = end
        p.play()
        isPlaying = true
        startTimer()
    }

    func togglePlayPause() {
        guard let p = player else { return }
        if p.isPlaying {
            pause()
        } else {
            stopAt = nil
            p.play()
            isPlaying = true
            startTimer()
        }
    }

    func pause() {
        player?.pause()
        isPlaying = false
        stopTimer()
    }

    func seek(to t: TimeInterval) {
        guard let p = player else { return }
        let clamped = max(0, min(t, p.duration))
        p.currentTime = clamped
        progress.currentTime = clamped
    }

    private func startTimer() {
        stopTimer()
        timer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self, let p = self.player else { return }
                self.progress.currentTime = p.currentTime
                if let stopAt = self.stopAt, p.currentTime >= stopAt {
                    self.pause()
                } else if !p.isPlaying && self.isPlaying {
                    self.isPlaying = false
                    self.stopTimer()
                }
            }
        }
    }

    private func stopTimer() {
        timer?.invalidate()
        timer = nil
    }
}
