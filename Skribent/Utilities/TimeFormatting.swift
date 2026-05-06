import Foundation

extension TimeInterval {
    /// Compact playback timestamp: "M:SS" under an hour, "H:MM:SS" otherwise. Defensive on
    /// non-finite / negative values (returns "0:00") so it's safe to feed live player progress.
    var hms: String {
        guard isFinite, self >= 0 else { return "0:00" }
        let total = Int(self)
        let h = total / 3600, m = (total % 3600) / 60, s = total % 60
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, s) : String(format: "%d:%02d", m, s)
    }

    /// Always-padded "HH:MM:SS" for the recorder's elapsed time. No defensive branch — only used
    /// for `recorder.elapsed` which is always ≥ 0 and finite by construction.
    var hmsPadded: String {
        let total = Int(self)
        let h = total / 3600, m = (total % 3600) / 60, s = total % 60
        return String(format: "%02d:%02d:%02d", h, m, s)
    }

    /// Long-form duration for headers / metadata rows: "X min YY s".
    var humanDuration: String {
        let total = Int(self)
        let m = total / 60, s = total % 60
        return String(format: "%d min %02d s", m, s)
    }

    /// Compact "M:SS" for sidebar rows where horizontal space is tight.
    var compactDuration: String {
        let total = Int(self)
        let m = total / 60, s = total % 60
        return String(format: "%d:%02d", m, s)
    }

    /// Progress-banner ETA / elapsed label: "X s" under a minute, "M:SS min" longer. Returns
    /// "—" on non-finite / negative input (banner uses it for `etaSeconds()` results that can be
    /// nil-shaped — `—` is the visual placeholder we want).
    var bannerLabel: String {
        guard isFinite, self >= 0 else { return "—" }
        if self < 60 { return String(format: "%d s", Int(self.rounded())) }
        let total = Int(self)
        let m = total / 60, s = total % 60
        return String(format: "%d:%02d min", m, s)
    }
}
