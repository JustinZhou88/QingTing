import AVFoundation
import AudioToolbox

enum PipelineError: LocalizedError {
    case setDevice(String, OSStatus)
    case badInputFormat
    case needs48k(Double)

    var errorDescription: String? {
        switch self {
        case let .setDevice(name, st): "无法打开设备「\(name)」(错误 \(st))"
        case .badInputFormat: "输入设备没有可用的音频格式"
        case let .needs48k(sr): "这个降噪引擎不支持 \(Int(sr))Hz 的收音（需要 48kHz 或它的整数分之一），请换 Apple 引擎或换收音设备"
        }
    }
}

/// 收音设备 → 环形缓冲 → 处理链 → 输出设备（助听器）。
/// 输入、输出用两个独立的 AVAudioEngine：macOS 上单个引擎不好同时绑定两个不同设备，
/// 中间用环形缓冲衔接两边的时钟。
final class LivePipeline {
    let chain = VoiceChain()
    let inputMeter = LevelMeter()
    let outputMeter = LevelMeter()
    private(set) var consumer: RingConsumer?
    /// 设备 + 算法的固定延迟（秒），不含环形缓冲
    private(set) var baseLatency: Double = 0
    private(set) var isRunning = false
    /// 最近 30 秒的原始收音和处理后声音，调试用
    private(set) var rawRecorder: RollingRecorder?
    private(set) var processedRecorder: RollingRecorder?

    /// 帧式降噪（DeepFilterNet/RNNoise）的工作线程；Apple 引擎或不降噪时为 nil
    private(set) var worker: DenoiseWorker?
    private(set) var engine: DenoiseEngine = .off
    private var inEngine: AVAudioEngine?
    private var outEngine: AVAudioEngine?
    private var observers: [NSObjectProtocol] = []

    /// 任一引擎配置变化（设备断开、采样率切换）时回调，由上层决定是否重启。
    var onConfigurationChange: (() -> Void)?

    func start(input: AudioDevice, output: AudioDevice, engine: DenoiseEngine, strength: Float) throws {
        stop()

        // 小 IO 缓冲 = 低延迟；蓝牙设备通常不接受，忽略失败
        AudioDevices.setBufferFrameSize(input.id, 256)
        AudioDevices.setBufferFrameSize(output.id, 256)

        // ---- 输入端：inputNode → sink，下混成单声道写入环形缓冲
        let inEngine = AVAudioEngine()
        try Self.bind(inEngine.inputNode, to: input)
        // 换设备后 outputFormat 会残留默认输出设备（助听器 16k）的采样率，按它连接会收不到任何数据；
        // 必须用硬件侧 inputFormat 的采样率/声道数
        let hw = inEngine.inputNode.inputFormat(forBus: 0)
        guard hw.sampleRate > 0, hw.channelCount > 0,
              let hwFormat = AVAudioFormat(standardFormatWithSampleRate: hw.sampleRate, channels: hw.channelCount)
        else { throw PipelineError.badInputFormat }
        Log.write("收音格式 \(hw.sampleRate)Hz×\(hw.channelCount)，输出设备 \(output.name) \(AudioDevices.sampleRate(output.id))Hz")
        let sampleRate = hwFormat.sampleRate
        let channels = Int(hwFormat.channelCount)
        let interleaved = hwFormat.isInterleaved

        // 帧式降噪（DeepFilterNet/RNNoise）只认 48kHz。收音不是 48kHz 时按整数倍升采样（如 16kHz ×3），
        // 后面的缓冲、处理链都按 48kHz 跑，最后由混音器转成输出设备的采样率。
        var upsampler: Upsampler?
        var pipelineRate = sampleRate
        if engine.isFrameBased, sampleRate != 48000 {
            guard let factor = Upsampler.factor(from: sampleRate) else { throw PipelineError.needs48k(sampleRate) }
            upsampler = Upsampler(factor: factor)
            pipelineRate = 48000
            Log.write("收音是 \(Int(sampleRate))Hz，升采样 ×\(factor) 到 48kHz 再降噪")
        }
        let upFactor = upsampler?.factor ?? 1
        let upScratch = UnsafeMutablePointer<Float>.allocate(capacity: 16384 * upFactor)
        let ring = RingBuffer(capacity: Int(pipelineRate))
        let consumer = RingConsumer(ring: ring, sampleRate: pipelineRate)

        // 帧式降噪：收音 → rawRing →（工作线程降噪）→ ring；否则收音直接进 ring
        var worker: DenoiseWorker?
        if engine.isFrameBased {
            if let d = try engine.makeDenoiser() {
                d.setStrength(strength)
                worker = DenoiseWorker(input: RingBuffer(capacity: Int(pipelineRate)), output: ring, denoiser: d)
            }
        }
        let firstRing = worker?.input ?? ring
        let lowCut = HighPassFilter(cutoff: VoiceChain.lowCutHz, sampleRate: sampleRate)
        let scratch = UnsafeMutablePointer<Float>.allocate(capacity: 16384)
        let inputMeter = inputMeter
        let rawRecorder = RollingRecorder(seconds: 30, sampleRate: sampleRate)
        let processedRecorder = RollingRecorder(seconds: 30, sampleRate: pipelineRate)

        let sink = AVAudioSinkNode { _, frameCount, abl in
            let frames = min(Int(frameCount), 16384)
            let list = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: abl))
            if interleaved {
                guard let p = list[0].mData?.assumingMemoryBound(to: Float.self) else { return noErr }
                for i in 0..<frames {
                    var s: Float = 0
                    for c in 0..<channels { s += p[i * channels + c] }
                    scratch[i] = s / Float(channels)
                }
            } else {
                let n = list.count
                guard let first = list[0].mData?.assumingMemoryBound(to: Float.self) else { return noErr }
                scratch.update(from: first, count: frames)
                if n > 1 {
                    for b in 1..<n {
                        guard let p = list[b].mData?.assumingMemoryBound(to: Float.self) else { continue }
                        for i in 0..<frames { scratch[i] += p[i] }
                    }
                    let k = 1 / Float(n)
                    for i in 0..<frames { scratch[i] *= k }
                }
            }
            inputMeter.measure(scratch, count: frames)
            rawRecorder.write(scratch, count: frames)
            lowCut.process(scratch, count: frames)
            if let upsampler {
                upsampler.process(scratch, count: frames, into: upScratch)
                firstRing.write(upScratch, count: frames * upFactor)
            } else {
                firstRing.write(scratch, count: frames)
            }
            worker?.signal()
            return noErr
        }
        inEngine.attach(sink)
        inEngine.connect(inEngine.inputNode, to: sink, format: hwFormat)

        // ---- 输出端：source 从环形缓冲取数 → 处理链 → 混音器（自动转采样率/声道）→ 助听器
        let outEngine = AVAudioEngine()
        try Self.bind(outEngine.outputNode, to: output)
        let mono = AVAudioFormat(standardFormatWithSampleRate: pipelineRate, channels: 1)!
        let source = AVAudioSourceNode(format: mono) { _, _, frameCount, abl in
            let list = UnsafeMutableAudioBufferListPointer(abl)
            for buf in list {
                guard let p = buf.mData?.assumingMemoryBound(to: Float.self) else { continue }
                consumer.pull(into: p, count: Int(frameCount))
            }
            return noErr
        }
        outEngine.attach(source)
        chain.setEngine(engine)
        chain.setStrength(strength)
        chain.attach(to: outEngine)
        chain.connect(in: outEngine, from: source, to: outEngine.mainMixerNode, format: mono)

        let outputMeter = outputMeter
        // 在限幅器出口取样：单声道、与收音同采样率，正好和原始录音对齐比较
        chain.limiter.installTap(onBus: 0, bufferSize: 1024, format: nil) { buf, _ in
            guard let p = buf.floatChannelData?[0] else { return }
            outputMeter.measure(p, count: Int(buf.frameLength))
            processedRecorder.write(p, count: Int(buf.frameLength))
        }

        worker?.start()
        outEngine.prepare()
        inEngine.prepare()
        try outEngine.start()
        do {
            try inEngine.start()
        } catch {
            outEngine.stop()
            worker?.stop()
            throw error
        }

        // 显式指定输入设备后，引擎启动时总会发一次配置变化通知，但照常在跑。
        // 只有引擎真被系统停掉（设备断开、采样率变了）才需要重建，否则重启又会触发通知，无限循环。
        for (engine, side) in [(inEngine, "收音"), (outEngine, "输出")] {
            observers.append(NotificationCenter.default.addObserver(
                forName: .AVAudioEngineConfigurationChange, object: engine, queue: .main
            ) { [weak self] _ in
                guard let self else { return }
                let stopped = !(self.inEngine?.isRunning ?? false) || !(self.outEngine?.isRunning ?? false)
                Log.write("\(side)端配置变化通知，\(stopped ? "引擎已停，需要重建" : "引擎仍在运行，忽略")")
                if stopped { self.onConfigurationChange?() }
            })
        }

        self.inEngine = inEngine
        self.outEngine = outEngine
        self.consumer = consumer
        self.rawRecorder = rawRecorder
        self.processedRecorder = processedRecorder
        self.scratch = scratch
        self.upScratch = upScratch
        self.worker = worker
        self.engine = engine
        isRunning = true
        baseLatency = AudioDevices.latency(input.id, input: true)
            + AudioDevices.latency(output.id, input: false)
            + engine.latency
    }

    private var scratch: UnsafeMutablePointer<Float>?
    private var upScratch: UnsafeMutablePointer<Float>?

    func stop() {
        observers.forEach(NotificationCenter.default.removeObserver)
        observers.removeAll()
        if outEngine != nil { chain.limiter.removeTap(onBus: 0) }
        inEngine?.stop()
        outEngine?.stop()
        worker?.stop()
        worker = nil
        // 处理链节点要复用到下一个引擎，先从旧引擎摘下来
        if let outEngine { chain.nodes.forEach(outEngine.detach) }
        // 引擎停下后实时线程不再访问，此时再释放
        inEngine = nil
        outEngine = nil
        scratch?.deallocate()
        scratch = nil
        upScratch?.deallocate()
        upScratch = nil
        consumer = nil
        isRunning = false
        inputMeter.store(0)
        outputMeter.store(0)
    }

    func setStrength(_ s: Float) {
        chain.setStrength(s)
        worker?.denoiser.setStrength(s)
    }

    /// 当前环形缓冲积压（毫秒）。
    var bufferedMs: Double {
        guard let c = consumer else { return 0 }
        return Double(c.ring.fill) / c.sampleRate * 1000
    }

    /// 估算的端到端延迟（秒）= 固定部分 + 当前缓冲积压。不含助听器自身处理。
    var liveLatency: Double {
        guard let c = consumer else { return 0 }
        return baseLatency + Double(c.ring.fill) / c.sampleRate
    }

    /// 把最近 30 秒存成两个 wav：原始收音、处理后（送进助听器之前）。返回所在文件夹。
    func saveRecent(note: String) throws -> URL {
        guard let raw = rawRecorder, let processed = processedRecorder else { throw PipelineError.badInputFormat }
        let dir = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Documents/清听录音")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let stamp = Date().formatted(.iso8601.year().month().day().time(includingFractionalSeconds: false))
            .replacingOccurrences(of: ":", with: "")
        try raw.save(to: dir.appendingPathComponent("\(stamp)_原始.wav"))
        try processed.save(to: dir.appendingPathComponent("\(stamp)_处理后_\(note).wav"))
        return dir
    }

    private static func bind(_ node: AVAudioIONode, to device: AudioDevice) throws {
        guard let unit = node.audioUnit else { throw PipelineError.setDevice(device.name, -1) }
        var id = device.id
        let st = AudioUnitSetProperty(unit, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0,
                                      &id, UInt32(MemoryLayout<AudioDeviceID>.size))
        guard st == noErr else { throw PipelineError.setDevice(device.name, st) }
    }
}
