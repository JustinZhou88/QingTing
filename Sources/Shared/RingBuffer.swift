import Synchronization

/// 单生产者/单消费者无锁环形缓冲：输入设备回调写，输出设备回调读。
/// 两个设备时钟不同步，消费端负责把积压控制在目标水位附近。
final class RingBuffer: @unchecked Sendable {
    let capacity: Int
    private let storage: UnsafeMutablePointer<Float>
    private let writeIndex = Atomic<Int>(0)
    private let readIndex = Atomic<Int>(0)
    /// 生产端单次写入的最大帧数，消费端据此估算安全水位。
    let maxWriteChunk = Atomic<Int>(0)

    init(capacity: Int) {
        self.capacity = capacity
        storage = .allocate(capacity: capacity)
        storage.initialize(repeating: 0, count: capacity)
    }

    deinit { storage.deallocate() }

    var fill: Int { writeIndex.load(ordering: .acquiring) - readIndex.load(ordering: .acquiring) }

    /// 生产端调用。缓冲满时丢弃放不下的新数据。
    func write(_ src: UnsafePointer<Float>, count: Int) {
        if count > maxWriteChunk.load(ordering: .relaxed) { maxWriteChunk.store(count, ordering: .relaxed) }
        let w = writeIndex.load(ordering: .relaxed)
        let r = readIndex.load(ordering: .acquiring)
        let n = min(count, capacity - (w - r))
        guard n > 0 else { return }
        let start = w % capacity
        let first = min(n, capacity - start)
        (storage + start).update(from: src, count: first)
        if n > first { storage.update(from: src + first, count: n - first) }
        writeIndex.store(w + n, ordering: .releasing)
    }

    /// 消费端调用，返回实际读到的帧数。
    @discardableResult
    func read(into dst: UnsafeMutablePointer<Float>, count: Int) -> Int {
        let r = readIndex.load(ordering: .relaxed)
        let w = writeIndex.load(ordering: .acquiring)
        let n = min(count, w - r)
        guard n > 0 else { return 0 }
        let start = r % capacity
        let first = min(n, capacity - start)
        dst.update(from: storage + start, count: first)
        if n > first { (dst + first).update(from: storage, count: n - first) }
        readIndex.store(r + n, ordering: .releasing)
        return n
    }

    /// 消费端调用：丢掉最旧的 count 帧（积压过多时追赶延迟）。
    func skip(_ count: Int) {
        let r = readIndex.load(ordering: .relaxed)
        let w = writeIndex.load(ordering: .acquiring)
        readIndex.store(r + min(count, w - r), ordering: .releasing)
    }

    func reset() {
        readIndex.store(writeIndex.load(ordering: .acquiring), ordering: .releasing)
    }
}

/// 输出回调里的取数逻辑：先攒够目标水位再出声，欠载时补零并重新攒，积压过多时跳帧。
final class RingConsumer: @unchecked Sendable {
    let ring: RingBuffer
    let sampleRate: Double
    let underruns = Atomic<Int>(0)
    let drops = Atomic<Int>(0)
    private var primed = false
    private var maxPull = 0

    init(ring: RingBuffer, sampleRate: Double) {
        self.ring = ring
        self.sampleRate = sampleRate
    }

    /// 目标积压帧数：一次最大取数 + 一次最大写入 + 2ms 余量。
    var targetFill: Int { maxPull + ring.maxWriteChunk.load(ordering: .relaxed) + Int(sampleRate * 0.002) + extraMargin }

    /// 自适应余量（样本）：每次欠载加 5ms（最多 40ms），连续 60 秒没有欠载再减 5ms。
    /// 上游偶尔迟到时用一点延迟换不卡顿，稳定后再把延迟收回来。
    private var extraMargin = 0
    private var framesSinceUnderrun = 0
    private let marginBits = Atomic<Int>(0)
    /// 当前余量（毫秒），给界面和日志用
    var marginMs: Double { Double(marginBits.load(ordering: .relaxed)) / sampleRate * 1000 }

    func pull(into dst: UnsafeMutablePointer<Float>, count: Int) {
        if count > maxPull { maxPull = count }
        framesSinceUnderrun += count
        if extraMargin > 0, framesSinceUnderrun > Int(sampleRate * 60) {
            extraMargin = max(0, extraMargin - Int(sampleRate * 0.005))
            framesSinceUnderrun = 0
            marginBits.store(extraMargin, ordering: .relaxed)
        }
        let target = targetFill
        let fill = ring.fill
        if !primed {
            guard fill >= target else {
                dst.update(repeating: 0, count: count)
                return
            }
            primed = true
        }
        // 超出目标 20ms 以上说明输入时钟比输出快，丢掉多余部分把延迟拉回来
        if fill > target + Int(sampleRate * 0.02) {
            ring.skip(fill - target)
            drops.add(1, ordering: .relaxed)
        }
        let got = ring.read(into: dst, count: count)
        if got < count {
            (dst + got).update(repeating: 0, count: count - got)
            primed = false
            underruns.add(1, ordering: .relaxed)
            extraMargin = min(extraMargin + Int(sampleRate * 0.005), Int(sampleRate * 0.04))
            framesSinceUnderrun = 0
            marginBits.store(extraMargin, ordering: .relaxed)
        }
    }
}
