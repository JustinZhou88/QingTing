import ActivityKit
import AppIntents
import Foundation

/// 「正在收听」实时活动的数据。App 和小组件扩展都要编译这个文件。
struct ListeningAttributes: ActivityAttributes {
    struct ContentState: Codable, Hashable {
        /// 送往哪个设备（助听器名）
        var outputName: String
        /// 最近约 3 秒送出声音的电平，0...1，从旧到新（展开状态和锁屏用）
        var levels: [Float]
        /// 最近 1 秒的电平，每根对应 0.2 秒（收起状态用）
        var recent: [Float]
        /// 降噪强度（百分比）
        var strength: Int
    }

    /// 开始时间，用来显示已收听时长
    var startedAt: Date
}

extension Notification.Name {
    /// 灵动岛/锁屏上点了停止
    static let stopListeningRequested = Notification.Name("qingting.stopListeningRequested")
}

/// 灵动岛和锁屏上的「停止」按钮。LiveActivityIntent 在 App 进程里执行，所以能直接让收音停下。
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
