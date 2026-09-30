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

/// Capture device -> ring buffer -> processing chain -> output device (hearing aids).
/// Input and output use two separate AVAudioEngines: on macOS a single engine cannot easily be bound to two different devices,
/// so a ring buffer bridges the two clocks.
final class LivePipeline {
    let chain = VoiceChain()
    let inputMeter = LevelMeter()
    let outputMeter = LevelMeter()
    private(set) var consumer: RingConsumer?
    /// Fixed latency of the devices and the algorithm, in seconds, excluding the ring buffer
    private(set) var baseLatency: Double = 0
    private(set) var isRunning = false
    /// The last 30 seconds of raw capture and of processed audio, for debugging
    private(set) var rawRecorder: RollingRecorder?
    private(set) var processedRecorder: RollingRecorder?

    /// Worker thread for frame-based denoising (DeepFilterNet/RNNoise); nil for the Apple engines or when denoising is off
    private(set) var worker: DenoiseWorker?
    private(set) var engine: DenoiseEngine = .off
    private var inEngine: AVAudioEngine?
    private var outEngine: AVAudioEngine?
    private var observers: [NSObjectProtocol] = []

    /// Called when either engine's configuration changes (device gone, sample rate switched); the owner decides whether to restart.
    var onConfigurationChange: (() -> Void)?

    func start(input: AudioDevice, output: AudioDevice, engine: DenoiseEngine, strength: Float) throws {
        stop()

        // Small IO buffer = low latency. Bluetooth devices usually refuse; failure is ignored
        AudioDevices.setBufferFrameSize(input.id, 256)
        AudioDevices.setBufferFrameSize(output.id, 256)

        // ---- Input side: inputNode -> sink, downmixed to mono and written to the ring buffer
        let inEngine = AVAudioEngine()
        try Self.bind(inEngine.inputNode, to: input)
        // After switching devices, outputFormat still carries the sample rate of the default output device (16 kHz hearing aids); connecting with it yields no data at all.
        // The sample rate and channel count of the hardware-side inputFormat must be used instead
        let hw = inEngine.inputNode.inputFormat(forBus: 0)
        guard hw.sampleRate > 0, hw.channelCount > 0,
              let hwFormat = AVAudioFormat(standardFormatWithSampleRate: hw.sampleRate, channels: hw.channelCount)
        else { throw PipelineError.badInputFormat }
        Log.write("Capture format \(hw.sampleRate) Hz x\(hw.channelCount), output device \(output.name) \(AudioDevices.sampleRate(output.id)) Hz")
        let sampleRate = hwFormat.sampleRate
        let channels = Int(hwFormat.channelCount)
        let interleaved = hwFormat.isInterleaved

        // Frame-based denoisers (DeepFilterNet/RNNoise) only accept 48 kHz. When capture is not 48 kHz it is upsampled by an integer factor (e.g. 16 kHz x3);
        // the buffers and the chain then run at 48 kHz, and the mixer converts to the output device's rate at the end.
        var upsampler: Upsampler?
        var pipelineRate = sampleRate
        if engine.isFrameBased, sampleRate != 48000 {
            guard let factor = Upsampler.factor(from: sampleRate) else { throw PipelineError.needs48k(sampleRate) }
            upsampler = Upsampler(factor: factor)
            pipelineRate = 48000
            Log.write("Capture is \(Int(sampleRate)) Hz; upsampling x\(factor) to 48 kHz before noise reduction")
        }
        let upFactor = upsampler?.factor ?? 1
        let upScratch = UnsafeMutablePointer<Float>.allocate(capacity: 16384 * upFactor)
        let ring = RingBuffer(capacity: Int(pipelineRate))
        let consumer = RingConsumer(ring: ring, sampleRate: pipelineRate)

        // Frame-based denoising: capture -> rawRing -> (worker thread denoises) -> ring; otherwise capture goes straight into ring
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

        // ---- Output side: source pulls from the ring buffer -> chain -> mixer (converts sample rate and channels) -> hearing aids
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
        // Tap at the limiter output: mono, at the capture sample rate, so it lines up with the raw recording for comparison
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

        // With an explicitly chosen input device the engine always posts one configuration-change notification at startup, yet keeps running.
        // A rebuild is only needed when the system really stopped an engine (device gone, sample rate changed); restarting otherwise triggers the notification again, in an endless loop.
        for (engine, side) in [(inEngine, "input"), (outEngine, "output")] {
            observers.append(NotificationCenter.default.addObserver(
                forName: .AVAudioEngineConfigurationChange, object: engine, queue: .main
            ) { [weak self] _ in
                guard let self else { return }
                let stopped = !(self.inEngine?.isRunning ?? false) || !(self.outEngine?.isRunning ?? false)
                Log.write("Configuration change on the \(side) side; \(stopped ? "an engine has stopped, rebuilding" : "engines still running, ignored")")
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
        // The chain nodes are reused by the next engine, so detach them from the old one first
        if let outEngine { chain.nodes.forEach(outEngine.detach) }
        // Once the engines have stopped the real-time threads no longer touch these, so they can be released
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

    /// Current ring buffer backlog in milliseconds.
    var bufferedMs: Double {
        guard let c = consumer else { return 0 }
        return Double(c.ring.fill) / c.sampleRate * 1000
    }

    /// Estimated end-to-end latency in seconds = fixed part + current backlog. Excludes processing inside the hearing aids.
    var liveLatency: Double {
        guard let c = consumer else { return 0 }
        return baseLatency + Double(c.ring.fill) / c.sampleRate
    }

    /// Saves the last 30 seconds as two WAV files: raw capture and processed (just before the hearing aids). Returns the folder.
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
