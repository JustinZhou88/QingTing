import SwiftUI

/// 电平历史：每次刷新电平表时追加一个值，只保留最近 capacity 个（20Hz × 64 ≈ 3 秒）。
struct LevelHistory {
    static let capacity = 64
    private(set) var values: [Float] = Array(repeating: 0, count: LevelHistory.capacity)

    /// dBFS 线性映射到 0...1：-60dB 以下为空，-12dB 以上为满。
    /// 不用开方：开方会把大声段压扁，嘈杂课堂里原始收音的几 dB 说话起伏就看不出来了。
    mutating func append(dB: Float) {
        values.removeFirst()
        values.append(max(0, min(1, (dB + 60) / 48)))
    }

    mutating func reset() {
        values = Array(repeating: 0, count: LevelHistory.capacity)
    }
}

/// 语音备忘录式的滚动声纹：竖条上下对称，最新的在最右边，越旧越淡。
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
                // 越旧越淡
                let age = Double(i) / Double(max(count - 1, 1))
                context.fill(Path(roundedRect: rect, cornerRadius: barWidth / 2),
                             with: .color(color.opacity(0.35 + 0.65 * age)))
            }
        }
        .accessibilityHidden(true)
    }
}

/// 带标题的一行声纹
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
