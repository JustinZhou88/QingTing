import ActivityKit
import Foundation

/// Starts, updates and ends the "listening" Live Activity (Dynamic Island + Lock Screen banner).
@MainActor
final class ListeningActivityController {
    private var activity: Activity<ListeningAttributes>?
    private var lastUpdate = Date.distantPast
    /// Number of bars shown in the Dynamic Island
    static let barCount = 24
    /// Number of bars in the compact presentation
    static let recentCount = 5

    init() {
        // Clear activities left behind by an abnormal exit
        for stale in Activity<ListeningAttributes>.activities {
            Task { await stale.end(nil, dismissalPolicy: .immediate) }
        }
    }

    /// Does not restart when already showing (a restart caused by switching engine or microphone must not reset the timer).
    func start(outputName: String, strength: Int) {
        guard activity == nil else { return }
        guard ActivityAuthorizationInfo().areActivitiesEnabled else {
            Log.write("Live Activities are turned off by the system (Settings > QingTing > Live Activities); the Dynamic Island will not show")
            return
        }
        let state = ListeningAttributes.ContentState(
            outputName: outputName, levels: Array(repeating: 0, count: Self.barCount),
            recent: Array(repeating: 0, count: Self.recentCount), strength: strength)
        do {
            activity = try Activity.request(attributes: ListeningAttributes(startedAt: .now),
                                            content: ActivityContent(state: state, staleDate: nil))
        } catch {
            Log.write("Could not start the Live Activity: \(error.localizedDescription)")
        }
    }

    /// Updates once a second. The system does not let third-party apps animate continuously in the Dynamic Island, so the waveform can only change through data updates;
    /// the widget joins consecutive snapshots with a 1 s transition so it looks continuous. Updating more often risks being throttled by the system.
    /// wave: level history at 20 Hz (about 3 s), oldest first.
    func update(outputName: String, wave: [Float], strength: Int) {
        guard let activity, Date().timeIntervalSince(lastUpdate) >= 1 else { return }
        lastUpdate = Date()
        let state = ListeningAttributes.ContentState(
            outputName: outputName, levels: Self.downsample(wave, to: Self.barCount),
            recent: Self.downsample(Array(wave.suffix(20)), to: Self.recentCount), strength: strength)
        Task { await activity.update(ActivityContent(state: state, staleDate: nil)) }
    }

    func end() {
        guard let activity else { return }
        self.activity = nil
        Task { await activity.end(nil, dismissalPolicy: .immediate) }
    }

    /// Reduces the level history to `count` bars: each bar is the mean of its time slice, with the contrast stretched.
    /// Taking the maximum makes every bar nearly full (there is always a peak within 0.2 s of speech), hiding loud versus soft;
    /// bars in the Dynamic Island are only a dozen or so points tall, so they need more exaggerated movement than in the app to be readable.
    static func downsample(_ values: [Float], to count: Int) -> [Float] {
        guard !values.isEmpty else { return Array(repeating: 0, count: count) }
        return (0..<count).map { i in
            let a = i * values.count / count, b = min(values.count, max(a + 1, (i + 1) * values.count / count))
            let mean = values[a..<b].reduce(0, +) / Float(b - a)
            // On a real device the speech sent out mostly sits at -45...-22 dBFS: quiet below -45, full at -21 and above, expanded with a power of 1.5 in between
            let x = max(0, min(1, (mean - 0.3) / 0.5))
            return powf(x, 1.5)
        }
    }
}
