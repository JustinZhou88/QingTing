import AVFoundation
import Synchronization

/// Rolling recorder: always keeps the last N seconds, overwriting older audio. The real-time thread only writes; the UI thread occasionally reads a snapshot to save it.
/// The writer keeps going while a snapshot is read, so the oldest few milliseconds may be overwritten; acceptable for debugging.
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

    /// Everything currently held, in chronological order.
    func snapshot() -> [Float] {
        let w = written.load(ordering: .acquiring)
        let n = min(w, capacity)
        return (0..<n).map { storage[(w - n + $0) % capacity] }
    }

    /// The most recent `seconds` seconds, in chronological order.
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
        file.close() // Close explicitly so the length in the WAV header is written correctly
    }
}
