import SwiftUI

/// Level history: one value is appended per meter refresh, keeping only the most recent `capacity` (20 Hz x 64 = about 3 s).
struct LevelHistory {
    static let capacity = 64
    private(set) var values: [Float] = Array(repeating: 0, count: LevelHistory.capacity)

    /// Maps dBFS linearly to 0...1: empty below -60 dB, full above -12 dB.
    /// No square root: it flattens loud passages, hiding the few dB of speech movement in the raw capture of a noisy classroom.
    mutating func append(dB: Float) {
        values.removeFirst()
        values.append(max(0, min(1, (dB + 60) / 48)))
    }

    mutating func reset() {
        values = Array(repeating: 0, count: LevelHistory.capacity)
    }
}

/// Scrolling waveform in the style of Voice Memos: bars symmetric around the center line, newest on the right, fading with age.
struct WaveformView: View {
    let levels: [Float]
    var color: Color = .accentColor
    var barWidth: CGFloat = 3
    var spacing: CGFloat = 2

    var body: some View {
        Canvas { context, size in
            let step = barWidth + spacing
            let count = min(levels.count, Int(size.width / step))
            guard count > 0 else { return }
            let recent = levels.suffix(count)
            let midY = size.height / 2
            for (i, level) in recent.enumerated() {
                let x = size.width - CGFloat(count - i) * step + spacing
                let h = max(barWidth, CGFloat(level) * size.height)
                let rect = CGRect(x: x, y: midY - h / 2, width: barWidth, height: h)
                // Older bars are fainter
                let age = Double(i) / Double(max(count - 1, 1))
                context.fill(Path(roundedRect: rect, cornerRadius: barWidth / 2),
                             with: .color(color.opacity(0.35 + 0.65 * age)))
            }
        }
        .accessibilityHidden(true)
    }
}

/// One labeled waveform row
struct WaveformRow: View {
    let label: String
    let levels: [Float]
    var color: Color = .accentColor

    var body: some View {
        HStack(spacing: 10) {
            Text(label).font(.caption).foregroundStyle(.secondary).frame(width: 28, alignment: .leading)
            WaveformView(levels: levels, color: color).frame(height: 28)
        }
    }
}
