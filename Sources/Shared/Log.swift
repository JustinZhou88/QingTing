import Foundation

/// 追加写 ~/Library/Logs/QingTing.log，排查"没声音"之类的问题用。
enum Log {
    #if os(iOS)
    /// iPhone：放在 App 的「文稿」里，「文件」App → 我的 iPhone → 清听 能看到
    static let url = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("QingTing.log")
    #else
    static let url = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Logs/QingTing.log")
    #endif
    private static let queue = DispatchQueue(label: "qingting.log")

    static func write(_ message: String) {
        let line = "\(Date().formatted(.iso8601.time(includingFractionalSeconds: true))) \(message)\n"
        print(line, terminator: "")
        queue.async {
            guard let data = line.data(using: .utf8) else { return }
            if let h = try? FileHandle(forWritingTo: url) {
                h.seekToEndOfFile()
                h.write(data)
                try? h.close()
            } else {
                try? data.write(to: url)
            }
        }
    }
}
