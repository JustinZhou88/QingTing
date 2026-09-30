import ActivityKit
import AppIntents
import Foundation

/// Data of the "listening" Live Activity. Compiled into both the app and the widget extension.
struct ListeningAttributes: ActivityAttributes {
    struct ContentState: Codable, Hashable {
        /// Device the audio is sent to (name of the hearing aids)
        var outputName: String
        /// Levels of the audio sent out over roughly the last 3 seconds, 0...1, oldest first (expanded presentation and Lock Screen)
        var levels: [Float]
        /// Levels over the last second, one bar per 0.2 s (compact presentation)
        var recent: [Float]
        /// Noise reduction strength (percent)
        var strength: Int
    }

    /// Start time, for showing how long listening has been running
    var startedAt: Date
}

extension Notification.Name {
    /// Stop was tapped in the Dynamic Island or on the Lock Screen
    static let stopListeningRequested = Notification.Name("qingting.stopListeningRequested")
}

/// The Stop button in the Dynamic Island and on the Lock Screen. A LiveActivityIntent runs in the app process, so it can stop capture directly.
struct StopListeningIntent: LiveActivityIntent {
    static let title: LocalizedStringResource = "停止收听"
    static let isDiscoverable = false

    func perform() async throws -> some IntentResult {
        await MainActor.run {
            NotificationCenter.default.post(name: .stopListeningRequested, object: nil)
        }
        return .result()
    }
}
