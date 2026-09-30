import ActivityKit
import Foundation

/// 管理「正在收听」实时活动（灵动岛 + 锁屏横幅）的开始、更新和结束。
@MainActor
final class ListeningActivityController {
    private var activity: Activity<ListeningAttributes>?
    private var lastUpdate = Date.distantPast
    /// 灵动岛里显示多少根竖条
    static let barCount = 24
    /// 收起状态的竖条数
    static let recentCount = 5

    init() {
        // 上次异常退出留下的活动清掉
        for stale in Activity<ListeningAttributes>.activities {
            Task { await stale.end(nil, dismissalPolicy: .immediate) }
        }
    }

    /// 已经在显示时不重开（换引擎、换麦克风导致的重启不应该把计时清零）。
    func start(outputName: String, strength: Int) {
        guard activity == nil else { return }
        guard ActivityAuthorizationInfo().areActivitiesEnabled else {
            Log.write("实时活动被系统关闭（设置 → 清听 → 实时活动），不显示灵动岛")
            return
        }
        let state = ListeningAttributes.ContentState(
            outputName: outputName, levels: Array(repeating: 0, count: Self.barCount),
            recent: Array(repeating: 0, count: Self.recentCount), strength: strength)
        do {
            activity = try Activity.request(attributes: ListeningAttributes(startedAt: .now),
                                            content: ActivityContent(state: state, staleDate: nil))
        } catch {
            Log.write("实时活动启动失败：\(error.localizedDescription)")
        }
    }

    /// 每秒更新一次。系统不允许第三方 App 在灵动岛里连续动画，只能靠更新数据让声纹变化；
    /// 小组件那边用 1 秒的过渡动画把两次快照接起来，看上去是连续的。更新再密容易被系统限流。
    /// wave：20Hz 的电平历史（约 3 秒），从旧到新。
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

    /// 把电平历史压成 count 根竖条：每根取对应时间片的平均值，再把对比度拉大。
    /// 取最大值会让每根都接近满格（说话时 0.2 秒内总有一个峰），看不出轻重；
    /// 灵动岛里竖条只有十几个点高，需要比 App 里更夸张的起伏才看得清。
    static func downsample(_ values: [Float], to count: Int) -> [Float] {
        guard !values.isEmpty else { return Array(repeating: 0, count: count) }
        return (0..<count).map { i in
            let a = i * values.count / count, b = min(values.count, max(a + 1, (i + 1) * values.count / count))
            let mean = values[a..<b].reduce(0, +) / Float(b - a)
            // 真机上送出的人声多在 -45…-22dBFS：-45 以下算安静，-21 以上满格，中间按 1.5 次方展开
            let x = max(0, min(1, (mean - 0.3) / 0.5))
            return powf(x, 1.5)
        }
    }
}
