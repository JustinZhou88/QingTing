import Synchronization

/// Lock-free single-producer/single-consumer ring buffer: the input device callback writes, the output device callback reads.
/// The two devices run on different clocks, so the consumer keeps the backlog near a target level.
final class RingBuffer: @unchecked Sendable {
    let capacity: Int
    private let storage: UnsafeMutablePointer<Float>
    private let writeIndex = Atomic<Int>(0)
    private let readIndex = Atomic<Int>(0)
    /// Largest single write by the producer, in frames. The consumer uses it to estimate a safe fill level.
    let maxWriteChunk = Atomic<Int>(0)

    init(capacity: Int) {
        self.capacity = capacity
        storage = .allocate(capacity: capacity)
        storage.initialize(repeating: 0, count: capacity)
    }

    deinit { storage.deallocate() }

    var fill: Int { writeIndex.load(ordering: .acquiring) - readIndex.load(ordering: .acquiring) }

    /// Called by the producer. When the buffer is full, new data that does not fit is dropped.
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

    /// Called by the consumer. Returns the number of frames actually read.
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

    /// Called by the consumer: drop the oldest `count` frames (to catch up when the backlog is too large).
    func skip(_ count: Int) {
        let r = readIndex.load(ordering: .relaxed)
        let w = writeIndex.load(ordering: .acquiring)
        readIndex.store(r + min(count, w - r), ordering: .releasing)
    }

    func reset() {
        readIndex.store(writeIndex.load(ordering: .acquiring), ordering: .releasing)
    }
}

/// Pull logic for the output callback: wait until the target fill is reached before producing sound, zero-fill and re-prime on underrun, skip frames when the backlog is too large.
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

    /// Target backlog in frames: one maximum pull + one maximum write + 2 ms of headroom.
    var targetFill: Int { maxPull + ring.maxWriteChunk.load(ordering: .relaxed) + Int(sampleRate * 0.002) + extraMargin }

    /// Adaptive margin in samples: +5 ms on every underrun (up to 40 ms), -5 ms after 60 s without one.
    /// Trades a little latency for no dropouts when upstream is occasionally late, then gives the latency back once things are stable.
    private var extraMargin = 0
    private var framesSinceUnderrun = 0
    private let marginBits = Atomic<Int>(0)
    /// Current margin in milliseconds, for the UI and the log
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
        // More than 20 ms above target means the input clock is faster than the output clock: drop the excess to pull latency back
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
