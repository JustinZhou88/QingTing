import Foundation

/// Appends to ~/Library/Logs/QingTing.log, for diagnosing problems such as "no sound".
enum Log {
    #if os(iOS)
    /// iPhone: stored in the app's Documents folder, visible in the Files app under On My iPhone > QingTing
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
