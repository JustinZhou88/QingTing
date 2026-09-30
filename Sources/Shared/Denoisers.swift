import Foundation
import Synchronization

/// 可选的降噪引擎。
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

    /// 帧式引擎在收音侧的工作线程里处理；Apple 引擎是处理链里的 AU。
    var isFrameBased: Bool { [.deepFilter, .deepFilterLL, .rnnoise].contains(self) }

    /// 算法延迟（秒）：离线互相关实测（DF 30 / DF-LL 10 / RNNoise 20 / Apple 57 / 93 ms），
    /// 帧式引擎再加实时凑满一帧（10ms）的等待。
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

/// 固定帧长、48kHz 单声道的降噪器。process 只在工作线程调用。
protocol FrameDenoiser: AnyObject {
    var frameSize: Int { get }
    /// 降噪强度 0...1，可在任意线程设置，下一帧生效。
    func setStrength(_ s: Float)
    func process(_ input: UnsafeMutablePointer<Float>, _ output: UnsafeMutablePointer<Float>)
}

/// DeepFilterNet 3：强度映射到"最多衰减多少 dB"，所以人声不会被整段抹掉。
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

    /// 每个频点的增益每 10ms 最多下降多少 dB（libDF 清听补丁）。0 = 不平滑。
    /// 课堂录音实测 1 dB：100% 强度下断续 0.76→0.54 次/秒，降噪量只少 1.5 dB。
    nonisolated(unsafe) static var gainReleaseDB: Float = 1

    deinit { df_free(state) }

    /// 强度线性映射到"最多衰减多少 dB"，100% = 30 dB。
    /// 不用"不设上限"：那样模型判为纯噪声的帧会被整帧清零，远处老师的字一顿一顿（课堂录音实测断续 1.2 次/秒）。
    /// 下限 0.5 dB：低于 0.01 时 libDF 会直接输出原声、跳过 STFT，延迟突变 30ms 产生咔嗒声。
    static let maxAttenuationDB: Float = 30
    static func attenuationLimit(for s: Float) -> Float { max(0.5, min(1, s) * maxAttenuationDB) }

    func setStrength(_ s: Float) { pendingStrength.store(s.bitPattern, ordering: .relaxed) }

    func process(_ input: UnsafeMutablePointer<Float>, _ output: UnsafeMutablePointer<Float>) {
        // 强度每帧（10ms）最多变 0.005，变化分摊到多帧，避免衰减上限一步跳变
        let target = Float(bitPattern: pendingStrength.load(ordering: .relaxed))
        if appliedStrength < 0 { appliedStrength = target; df_set_atten_lim(state, Self.attenuationLimit(for: target)) }
        if target != appliedStrength {
            appliedStrength += max(-0.005, min(0.005, target - appliedStrength))
            df_set_atten_lim(state, Self.attenuationLimit(for: appliedStrength))
        }
        df_process_frame(state, input, output)
    }
}

/// RNNoise：输入输出按 16 位整数刻度；强度用干湿混合实现，干声按算法延迟对齐避免梳状失真。
final class RNNoiseDenoiser: FrameDenoiser {
    let frameSize = Int(rnnoise_get_frame_size())
    /// 输出相对输入的延迟（样本），离线互相关实测 20ms。
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

/// 收音回调只负责把原始声音写进 input 环；这个线程凑满一帧就降噪，写进 output 环。
/// 模型推理可能分配内存，放在独立线程里，不占用音频设备的实时线程。
final class DenoiseWorker: @unchecked Sendable {
    let input: RingBuffer
    let output: RingBuffer
    let denoiser: FrameDenoiser
    private let wake = DispatchSemaphore(value: 0)
    private let finished = DispatchSemaphore(value: 0)
    private let running = Atomic<Bool>(true)
    /// 最近一帧的处理耗时（微秒），用来确认跟得上实时
    let lastFrameMicros = Atomic<Int>(0)

    init(input: RingBuffer, output: RingBuffer, denoiser: FrameDenoiser) {
        self.input = input
        self.output = output
        self.denoiser = denoiser
    }

    func start() {
        let thread = Thread { [self] in loop() }
        thread.qualityOfService = .userInteractive
        thread.name = "清听降噪"
        thread.start()
    }

    /// 实时线程写完数据后调用。
    func signal() { wake.signal() }

    func stop() {
        running.store(false, ordering: .relaxed)
        wake.signal()
        finished.wait()
    }

    /// 把当前线程设成实时调度（和系统音频线程同一类）：每 10ms 需要最多约 4ms 的计算、8ms 内完成。
    /// 普通优先级线程在 iPhone 上会被搁置十几毫秒（真机日志：15 分钟 100 多次欠载），缓冲见底就是一次卡顿。
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
        if kr != KERN_SUCCESS { Log.write("降噪线程设实时优先级失败（\(kr)），继续用普通优先级") }
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
