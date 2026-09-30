import AVFoundation
import Synchronization

/// 循环录音：始终保留最近 N 秒，旧的被覆盖。实时线程只写，界面线程偶尔读快照存盘。
/// 读快照时写端仍在写，最旧的几毫秒可能被覆盖，调试用途可以接受。
final class RollingRecorder: @unchecked Sendable {
    let sampleRate: Double
    private let capacity: Int
    private let storage: UnsafeMutablePointer<Float>
    private let written = Atomic<Int>(0)

    init(seconds: Double, sampleRate: Double) {
        self.sampleRate = sampleRate
        capacity = Int(seconds * sampleRate)
        storage = .allocate(capacity: capacity)
        storage.initialize(repeating: 0, count: capacity)
    }

    deinit { storage.deallocate() }

    func write(_ src: UnsafePointer<Float>, count: Int) {
        let w = written.load(ordering: .relaxed)
        for i in 0..<count { storage[(w + i) % capacity] = src[i] }
        written.store(w + count, ordering: .releasing)
    }

    /// 最近的全部内容，按时间顺序。
    func snapshot() -> [Float] {
        let w = written.load(ordering: .acquiring)
        let n = min(w, capacity)
        return (0..<n).map { storage[(w - n + $0) % capacity] }
    }

    /// 最近 seconds 秒，按时间顺序。
    func recent(seconds: Double) -> [Float] {
        let w = written.load(ordering: .acquiring)
        let n = min(w, capacity, Int(seconds * sampleRate))
        return (0..<n).map { storage[(w - n + $0) % capacity] }
    }

    func save(to url: URL) throws {
        let samples = snapshot()
        let format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 1)!
        guard let buf = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(max(samples.count, 1))) else { return }
        buf.frameLength = AVAudioFrameCount(samples.count)
        samples.withUnsafeBufferPointer { buf.floatChannelData![0].update(from: $0.baseAddress!, count: samples.count) }
        let file = try AVAudioFile(forWriting: url, settings: format.settings)
        try file.write(from: buf)
        file.close() // 显式收尾，确保 wav 头里的长度写对
    }
}
