import Foundation
import Synchronization

/// Selectable noise reduction engines.
enum DenoiseEngine: String, CaseIterable, Identifiable {
    case deepFilter, deepFilterLL, rnnoise, appleVoice, appleHQ, off
    var id: String { rawValue }

    var title: String {
        switch self {
        case .deepFilter: "DeepFilterNet"
        case .deepFilterLL: "DeepFilterNet 低延迟"
        case .rnnoise: "RNNoise"
        case .appleVoice: "Apple 语音隔离"
        case .appleHQ: "Apple 高品质语音"
        case .off: "不降噪"
        }
    }

    var detail: String {
        switch self {
        case .deepFilter: "通用人声增强，不区分远近，适合听远处的老师"
        case .deepFilterLL: "同上，去掉前瞻，延迟更低，效果略弱"
        case .rnnoise: "轻量，适合近距离说话；课堂实测会把远处老师的声音一起压坏，不推荐远场"
        case .appleVoice: "打电话用的那套：降噪最狠，但会把远处的人声也当背景压掉"
        case .appleHQ: "Apple 的温和版本，延迟较高"
        case .off: "只做均衡、压缩和限幅"
        }
    }

    /// Frame-based engines run on a worker thread on the capture side; the Apple engines are audio units in the chain.
    var isFrameBased: Bool { [.deepFilter, .deepFilterLL, .rnnoise].contains(self) }

    /// Algorithmic latency in seconds, measured offline by cross-correlation (DF 30 / DF-LL 10 / RNNoise 20 / Apple 57 / 93 ms),
    /// plus, for frame-based engines, the real-time wait to fill one 10 ms frame.
    var latency: Double {
        switch self {
        case .deepFilter: 0.040
        case .deepFilterLL: 0.020
        case .rnnoise: 0.030
        case .appleVoice: 0.057
        case .appleHQ: 0.093
        case .off: 0
        }
    }

    func makeDenoiser() throws -> FrameDenoiser? {
        switch self {
        case .deepFilter: try DeepFilterDenoiser(model: "DeepFilterNet3_onnx")
        case .deepFilterLL: try DeepFilterDenoiser(model: "DeepFilterNet3_ll_onnx")
        case .rnnoise: RNNoiseDenoiser()
        default: nil
        }
    }
}

enum DenoiserError: LocalizedError {
    case modelMissing(String)
    case createFailed(String)
    var errorDescription: String? {
        switch self {
        case let .modelMissing(m): "找不到模型文件 \(m)"
        case let .createFailed(m): "无法加载降噪模型 \(m)"
        }
    }
}

/// A denoiser with a fixed frame size working on 48 kHz mono. `process` is only called on the worker thread.
protocol FrameDenoiser: AnyObject {
    var frameSize: Int { get }
    /// Noise reduction strength 0...1. Can be set from any thread; takes effect on the next frame.
    func setStrength(_ s: Float)
    func process(_ input: UnsafeMutablePointer<Float>, _ output: UnsafeMutablePointer<Float>)
}

/// DeepFilterNet 3: strength maps to "maximum attenuation in dB", so speech is never wiped out entirely.
final class DeepFilterDenoiser: FrameDenoiser {
    let frameSize: Int
    private let state: OpaquePointer
    private let pendingStrength = Atomic<UInt32>(Float(1).bitPattern)
    private var appliedStrength: Float = -1

    init(model: String) throws {
        let url = Bundle.main.url(forResource: model, withExtension: "tar.gz")
            ?? URL(fileURLWithPath: CommandLine.arguments[0]).deletingLastPathComponent()
                .appendingPathComponent("../Resources/\(model).tar.gz").standardized
        guard FileManager.default.fileExists(atPath: url.path) else { throw DenoiserError.modelMissing(model) }
        guard let st = df_create(url.path, 100, nil) else { throw DenoiserError.createFailed(model) }
        state = st
        frameSize = Int(df_get_frame_length(st))
        df_set_gain_release(st, Self.gainReleaseDB)
    }

    /// Maximum drop of each frequency bin's gain per 10 ms, in dB (QingTing patch to libDF). 0 = no smoothing.
    /// Measured on classroom recordings at 1 dB: dropouts at 100% strength go from 0.76 to 0.54 per second, at a cost of only 1.5 dB of noise reduction.
    nonisolated(unsafe) static var gainReleaseDB: Float = 1

    deinit { df_free(state) }

    /// Strength maps linearly to "maximum attenuation in dB"; 100% = 30 dB.
    /// "Unlimited" is deliberately not offered: frames the model judges to be pure noise would be zeroed, making a distant talker sound choppy (1.2 dropouts per second on classroom recordings).
    /// Lower bound 0.5 dB: below 0.01 libDF passes the input straight through and skips the STFT, so latency jumps by 30 ms and clicks.
    static let maxAttenuationDB: Float = 30
    static func attenuationLimit(for s: Float) -> Float { max(0.5, min(1, s) * maxAttenuationDB) }

    func setStrength(_ s: Float) { pendingStrength.store(s.bitPattern, ordering: .relaxed) }

    func process(_ input: UnsafeMutablePointer<Float>, _ output: UnsafeMutablePointer<Float>) {
        // Strength changes by at most 0.005 per 10 ms frame, spreading a change over many frames so the attenuation limit never jumps
        let target = Float(bitPattern: pendingStrength.load(ordering: .relaxed))
        if appliedStrength < 0 { appliedStrength = target; df_set_atten_lim(state, Self.attenuationLimit(for: target)) }
        if target != appliedStrength {
            appliedStrength += max(-0.005, min(0.005, target - appliedStrength))
            df_set_atten_lim(state, Self.attenuationLimit(for: appliedStrength))
        }
        df_process_frame(state, input, output)
    }
}

/// RNNoise: input and output use 16-bit integer scale. Strength is a wet/dry mix, with the dry signal delayed to match the algorithm to avoid comb filtering.
final class RNNoiseDenoiser: FrameDenoiser {
    let frameSize = Int(rnnoise_get_frame_size())
    /// Delay of the output relative to the input, in samples: 20 ms, measured offline by cross-correlation.
    static let delay = 960
    private let state: OpaquePointer
    private let strength = Atomic<UInt32>(Float(1).bitPattern)
    private let scaled: UnsafeMutablePointer<Float>
    private let dryLine: UnsafeMutablePointer<Float>
    private var dryPos = 0

    init() {
        state = rnnoise_create(nil)
        scaled = .allocate(capacity: frameSize)
        dryLine = .allocate(capacity: Self.delay)
        dryLine.initialize(repeating: 0, count: Self.delay)
    }

    deinit {
        rnnoise_destroy(state)
        scaled.deallocate()
        dryLine.deallocate()
    }

    func setStrength(_ s: Float) { strength.store(s.bitPattern, ordering: .relaxed) }

    func process(_ input: UnsafeMutablePointer<Float>, _ output: UnsafeMutablePointer<Float>) {
        for i in 0..<frameSize { scaled[i] = input[i] * 32768 }
        rnnoise_process_frame(state, scaled, scaled)
        let wet = Float(bitPattern: strength.load(ordering: .relaxed))
        for i in 0..<frameSize {
            let dry = dryLine[dryPos]
            dryLine[dryPos] = input[i]
            dryPos = (dryPos + 1) % Self.delay
            output[i] = wet * scaled[i] / 32768 + (1 - wet) * dry
        }
    }
}

/// The capture callback only writes raw audio into the input ring; this thread denoises each full frame and writes it to the output ring.
/// Model inference may allocate memory, so it runs on its own thread instead of the audio device's real-time thread.
final class DenoiseWorker: @unchecked Sendable {
    let input: RingBuffer
    let output: RingBuffer
    let denoiser: FrameDenoiser
    private let wake = DispatchSemaphore(value: 0)
    private let finished = DispatchSemaphore(value: 0)
    private let running = Atomic<Bool>(true)
    /// Processing time of the most recent frame in microseconds, to confirm it keeps up with real time
    let lastFrameMicros = Atomic<Int>(0)

    init(input: RingBuffer, output: RingBuffer, denoiser: FrameDenoiser) {
        self.input = input
        self.output = output
        self.denoiser = denoiser
    }

    func start() {
        let thread = Thread { [self] in loop() }
        thread.qualityOfService = .userInteractive
        thread.name = "qingting.denoise"
        thread.start()
    }

    /// Called by the real-time thread after it has written data.
    func signal() { wake.signal() }

    func stop() {
        running.store(false, ordering: .relaxed)
        wake.signal()
        finished.wait()
    }

    /// Puts the current thread on real-time scheduling (the same class as system audio threads): up to about 4 ms of work every 10 ms, finished within 8 ms.
    /// A normal-priority thread gets parked for well over 10 ms on iPhone (device log: 100+ underruns in 15 minutes), and every empty buffer is an audible dropout.
    private static func makeCurrentThreadRealtime() {
        var tb = mach_timebase_info_data_t()
        mach_timebase_info(&tb)
        func ticks(_ ms: Double) -> UInt32 { UInt32(ms * 1_000_000 * Double(tb.denom) / Double(tb.numer)) }
        var policy = thread_time_constraint_policy_data_t(period: ticks(10), computation: ticks(4), constraint: ticks(8), preemptible: 1)
        let count = mach_msg_type_number_t(MemoryLayout<thread_time_constraint_policy_data_t>.size / MemoryLayout<integer_t>.size)
        let kr = withUnsafeMutablePointer(to: &policy) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                thread_policy_set(pthread_mach_thread_np(pthread_self()), thread_policy_flavor_t(THREAD_TIME_CONSTRAINT_POLICY), $0, count)
            }
        }
        if kr != KERN_SUCCESS { Log.write("Could not set real-time priority for the denoise thread (\(kr)); continuing at normal priority") }
    }

    private func loop() {
        Self.makeCurrentThreadRealtime()
        let n = denoiser.frameSize
        let a = UnsafeMutablePointer<Float>.allocate(capacity: n)
        let b = UnsafeMutablePointer<Float>.allocate(capacity: n)
        defer {
            a.deallocate()
            b.deallocate()
            finished.signal()
        }
        while running.load(ordering: .relaxed) {
            _ = wake.wait(timeout: .now() + .milliseconds(50))
            while input.fill >= n, running.load(ordering: .relaxed) {
                input.read(into: a, count: n)
                let t0 = DispatchTime.now().uptimeNanoseconds
                denoiser.process(a, b)
                lastFrameMicros.store(Int(DispatchTime.now().uptimeNanoseconds - t0) / 1000, ordering: .relaxed)
                output.write(b, count: n)
            }
        }
    }
}
