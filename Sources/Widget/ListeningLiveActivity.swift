import ActivityKit
import AppIntents
import SwiftUI
import WidgetKit

@main
struct QingTingWidgets: WidgetBundle {
    var body: some Widget {
        ListeningLiveActivity()
    }
}

/// 「正在收听」：灵动岛（收起/展开/最小）和锁屏横幅
struct ListeningLiveActivity: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: ListeningAttributes.self) { context in
            LockScreenView(context: context)
                .activityBackgroundTint(Color.black.opacity(0.55))
                .activitySystemActionForegroundColor(.white)
        } dynamicIsland: { context in
            DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    HStack(spacing: 8) {
                        Image("Mascot").resizable().scaledToFit().frame(width: 36, height: 36)
                        Text("清听").font(.headline)
                    }
                    .padding(.leading, 4)
                }
                DynamicIslandExpandedRegion(.trailing) {
                    Text(context.attributes.startedAt, style: .timer)
                        .font(.title3.monospacedDigit())
                        .foregroundStyle(.tint)
                        .multilineTextAlignment(.trailing)
                        .frame(maxWidth: 80, alignment: .trailing)
                        .padding(.trailing, 4)
                }
                DynamicIslandExpandedRegion(.center) {
                    Text("送往 \(context.state.outputName)")
                        .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
                DynamicIslandExpandedRegion(.bottom) {
                    HStack(spacing: 14) {
                        WaveBars(levels: context.state.levels, barWidth: 4, spacing: 3)
                            .frame(height: 34)
                        Text("降噪 \(context.state.strength)%")
                            .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                            .fixedSize()
                        StopButton()
                    }
                    .padding(.horizontal, 6)
                }
            } compactLeading: {
                Image("Mascot").resizable().scaledToFit().frame(width: 24, height: 24)
            } compactTrailing: {
                WaveBars(levels: context.state.recent, barWidth: 3, spacing: 2)
                    .frame(width: 24, height: 18)
            } minimal: {
                Image("Mascot").resizable().scaledToFit()
            }
            .keylineTint(.cyan)
        }
    }
}

private struct LockScreenView: View {
    let context: ActivityViewContext<ListeningAttributes>

    var body: some View {
        HStack(spacing: 14) {
            Image("Mascot").resizable().scaledToFit().frame(width: 46, height: 46)
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text("正在收听").font(.headline)
                    Spacer()
                    Text(context.attributes.startedAt, style: .timer)
                        .font(.subheadline.monospacedDigit())
                        .multilineTextAlignment(.trailing)
                        .frame(maxWidth: 70, alignment: .trailing)
                }
                Text("送往 \(context.state.outputName) · 降噪 \(context.state.strength)%")
                    .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                WaveBars(levels: context.state.levels, barWidth: 4, spacing: 3).frame(height: 22)
            }
            StopButton()
        }
        .foregroundStyle(.white)
        .tint(.cyan)
        .padding(16)
    }
}

private struct StopButton: View {
    var body: some View {
        Button(intent: StopListeningIntent()) {
            Image(systemName: "stop.fill")
                .font(.system(size: 15, weight: .semibold))
                .frame(width: 38, height: 38)
                .background(.red, in: Circle())
                .foregroundStyle(.white)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("停止收听")
    }
}

/// 一排上下对称的竖条，均匀铺满可用宽度。实时活动里不能连续动画，所以是每次更新时的静态快照。
private struct WaveBars: View {
    let levels: [Float]
    let barWidth: CGFloat
    let spacing: CGFloat

    var body: some View {
        GeometryReader { geo in
            HStack(alignment: .center, spacing: 0) {
                ForEach(Array(levels.enumerated()), id: \.offset) { _, level in
                    Capsule()
                        .fill(.tint)
                        .frame(width: barWidth, height: max(barWidth, CGFloat(level) * geo.size.height))
                        .frame(maxWidth: .infinity)
                }
            }
            // 每秒一次数据更新，用接近 1 秒的过渡把竖条平滑推到新高度
            .animation(.easeInOut(duration: 0.9), value: levels)
            .frame(width: geo.size.width, height: geo.size.height, alignment: .center)
        }
    }
}
