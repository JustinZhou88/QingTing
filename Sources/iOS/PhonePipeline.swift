import AVFoundation

/// Which way the iPhone microphone faces (maps to an AVAudioSession data source)
enum MicPosition: String, CaseIterable, Identifiable {
    case back, front, bottom
    var id: String { rawValue }
    var title: String {
        switch self {
        case .back: "背面"
        case .front: "正面"
        case .bottom: "底部"
        }
    }
    var orientation: AVAudioSession.Orientation {
        switch self {
        case .back: .back
        case .front: .front
        case .bottom: .bottom
        }
    }
}

/// Microphone polar pattern
enum MicPattern: String, CaseIterable, Identifiable {
    case cardioid, omni
    var id: String { rawValue }
    var title: String { self == .cardioid ? "指向（心形）" : "全向" }
    var polar: AVAudioSession.PolarPattern { self == .cardioid ? .cardioid : .omnidirectional }
}

enum PhonePipelineError: LocalizedError {
    case noBuiltInMic
    case badFormat
    case unsafeOutput(String)
    case needs48k(Double)

    var errorDescription: String? {
        switch self {
        case .noBuiltInMic: "找不到 iPhone 内置麦克风"
        case .badFormat: "麦克风没有可用的音频格式"
        case let .unsafeOutput(name): "当前声音会从「\(name)」放出来，麦克风会收到它而啸叫。请先连上助听器（控制中心 → 听力）再开始"
        case let .needs48k(sr): "这个降噪引擎不支持 \(Int(sr))Hz 的收音（需要 48kHz 或它的整数分之一），请换 Apple 引擎"
        }
    }
}

/// iPhone pipeline: built-in microphone -> low cut -> (frame-based denoise thread) -> processing chain -> hearing aids.
/// Unlike the Mac version, capture and output share one AVAudioEngine and one hardware clock, so the buffer in between can be very small.
final class PhonePipeline {
    let chain = VoiceChain()
    let inputMeter = LevelMeter()
    let outputMeter = LevelMeter()
    private(set) var consumer: RingConsumer?
    private(set) var worker: DenoiseWorker?
    private(set) var rawRecorder: RollingRecorder?
    private(set) var processedRecorder: RollingRecorder?
    private(set) var baseLatency: Double = 0
    private(set) var micDescription = ""
    private var engine: AVAudioEngine?
    private var scratch: UnsafeMutablePointer<Float>?
    private var upScratch: UnsafeMutablePointer<Float>?

    // MARK: - Audio session

    /// Configures the session and selects the microphone. Returns a description of the microphone actually in effect.
    @discardableResult
    func configureSession(position: MicPosition, pattern: MicPattern) throws -> String {
        let session = AVAudioSession.sharedInstance()
        // playAndRecord: capture and play at the same time. Without defaultToSpeaker, audio is not forced to the speaker
        try session.setCategory(.playAndRecord, mode: .default, options: [.allowBluetoothA2DP])
        try session.setPreferredSampleRate(48000)
        try session.setPreferredIOBufferDuration(0.005)
        try session.setActive(true)

        // Capture level is low on a 13 mini (auto gain pinned at +24 dB). Raise the microphone input gain to maximum when the system allows it;
        // many devices do not expose this setting with a Bluetooth output, so the actual value is logged for troubleshooting.
        if session.isInputGainSettable {
            try? session.setInputGain(1.0)
        }
        Log.write(String(format: "Session sample rate %.0f Hz, input gain %.2f (%@)", session.sampleRate, session.inputGain,
                         session.isInputGainSettable ? "settable" : "not settable"))

        guard let mic = session.availableInputs?.first(where: { $0.portType == .builtInMic }) else {
            throw PhonePipelineError.noBuiltInMic
        }
        // Always use the iPhone's own microphone, never the one on the hearing aids or a headset
        try session.setPreferredInput(mic)
        for s in mic.dataSources ?? [] {
            Log.write("Microphone \(s.dataSourceName): supports \((s.supportedPolarPatterns ?? []).map(\.rawValue).joined(separator: "/"))")
        }
        if let source = mic.dataSources?.first(where: { $0.orientation == position.orientation }) {
            let supported = source.supportedPolarPatterns ?? []
            // For directional pickup, take cardioid, then subcardioid, whichever this microphone supports; if neither, it has to be omnidirectional
            let wanted: [AVAudioSession.PolarPattern] = pattern == .cardioid ? [.cardioid, .subcardioid] : [.omnidirectional]
            if let p = wanted.first(where: supported.contains) {
                try source.setPreferredPolarPattern(p)
            } else if supported.contains(.omnidirectional) {
                try source.setPreferredPolarPattern(.omnidirectional)
            }
            try mic.setPreferredDataSource(source)
            directionalAvailable = supported.contains(.cardioid) || supported.contains(.subcardioid)
        }
        let selected = session.currentRoute.inputs.first?.selectedDataSource
        let place = selected?.orientation.map(Self.orientationName) ?? selected?.dataSourceName
        let desc = [place, selected?.selectedPolarPattern.map(Self.patternName)].compactMap { $0 }.joined(separator: " · ")
        micDescription = desc.isEmpty ? "内置麦克风" : desc
        isDirectional = [.cardioid, .subcardioid].contains(selected?.selectedPolarPattern)
        return micDescription
    }

    /// Whether the current microphone supports a directional pattern, and whether one is actually in effect
    private(set) var directionalAvailable = true
    private(set) var isDirectional = false

    static func patternName(_ p: AVAudioSession.PolarPattern) -> String {
        switch p {
        case .cardioid: "心形指向"
        case .subcardioid: "宽心形指向"
        case .omnidirectional: "全向"
        case .stereo: "立体声"
        default: p.rawValue
        }
    }

    static func orientationName(_ o: AVAudioSession.Orientation) -> String {
        switch o {
        case .back: "背面"
        case .front: "正面"
        case .bottom: "底部"
        case .top: "顶部"
        default: o.rawValue
        }
    }

    /// Name of the current output device, and whether it is the iPhone's own speaker or receiver.
    /// The system name of built-in devices follows the system language (e.g. "Speaker" on an English system), so a fixed name is used for the UI.
    static var currentOutput: (name: String, isBuiltIn: Bool) {
        guard let out = AVAudioSession.sharedInstance().currentRoute.outputs.first else { return ("未连接", true) }
        switch out.portType {
        case .builtInSpeaker: return ("iPhone 扬声器", true)
        case .builtInReceiver: return ("iPhone 听筒", true)
        default: return (out.portName, false)
        }
    }

    // MARK: - Start and stop

    func start(engineKind: DenoiseEngine, strength: Float, allowBuiltInOutput: Bool = false) throws {
        stop()
        let output = Self.currentOutput
        if output.isBuiltIn, !allowBuiltInOutput { throw PhonePipelineError.unsafeOutput(output.name) }

        let engine = AVAudioEngine()
        let hw = engine.inputNode.inputFormat(forBus: 0)
        guard hw.sampleRate > 0, hw.channelCount > 0,
              let hwFormat = AVAudioFormat(standardFormatWithSampleRate: hw.sampleRate, channels: hw.channelCount)
        else { throw PhonePipelineError.badFormat }
        let sampleRate = hw.sampleRate
        let channels = Int(hw.channelCount)
        Log.write("Capture format \(sampleRate) Hz x\(channels), microphone \(micDescription), output \(output.name)")

        // Frame-based denoisers (DeepFilterNet/RNNoise) only accept 48 kHz. When capture is not 48 kHz it is upsampled by an integer factor (e.g. 16 kHz x3);
        // the buffers and the chain then run at 48 kHz, and the mixer converts to the output device's rate at the end.
        var upsampler: Upsampler?
        var pipelineRate = sampleRate
        if engineKind.isFrameBased, sampleRate != 48000 {
            guard let factor = Upsampler.factor(from: sampleRate) else { throw PhonePipelineError.needs48k(sampleRate) }
            upsampler = Upsampler(factor: factor)
            pipelineRate = 48000
            Log.write("Capture is \(Int(sampleRate)) Hz; upsampling x\(factor) to 48 kHz before noise reduction")
        }
        let upFactor = upsampler?.factor ?? 1
        let upScratch = UnsafeMutablePointer<Float>.allocate(capacity: 16384 * upFactor)
        let ring = RingBuffer(capacity: Int(pipelineRate))
        let consumer = RingConsumer(ring: ring, sampleRate: pipelineRate)
        var worker: DenoiseWorker?
        if engineKind.isFrameBased {
            if let d = try engineKind.makeDenoiser() {
                d.setStrength(strength)
                worker = DenoiseWorker(input: RingBuffer(capacity: Int(pipelineRate)), output: ring, denoiser: d)
            }
        }
        let firstRing = worker?.input ?? ring
        let lowCut = HighPassFilter(cutoff: VoiceChain.lowCutHz, sampleRate: sampleRate)
        let rawRecorder = RollingRecorder(seconds: 30, sampleRate: sampleRate)
        let processedRecorder = RollingRecorder(seconds: 30, sampleRate: pipelineRate)
        let scratch = UnsafeMutablePointer<Float>.allocate(capacity: 16384)
        let inputMeter = inputMeter

        // Capture: downmix to mono -> meter/recorder -> low cut -> ring buffer (or the denoise thread)
        let sink = AVAudioSinkNode { _, frameCount, abl in
            let frames = min(Int(frameCount), 16384)
            let list = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: abl))
            guard let first = list[0].mData?.assumingMemoryBound(to: Float.self) else { return noErr }
            scratch.update(from: first, count: frames)
            if list.count > 1 {
                for b in 1..<list.count {
                    guard let p = list[b].mData?.assumingMemoryBound(to: Float.self) else { continue }
                    for i in 0..<frames { scratch[i] += p[i] }
                }
                let k = 1 / Float(list.count)
                for i in 0..<frames { scratch[i] *= k }
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
        engine.attach(sink)
        engine.connect(engine.inputNode, to: sink, format: hwFormat)

        // Output: pull from the ring buffer -> chain -> mixer -> hearing aids
        let mono = AVAudioFormat(standardFormatWithSampleRate: pipelineRate, channels: 1)!
        let source = AVAudioSourceNode(format: mono) { _, _, frameCount, abl in
            for buf in UnsafeMutableAudioBufferListPointer(abl) {
                guard let p = buf.mData?.assumingMemoryBound(to: Float.self) else { continue }
                consumer.pull(into: p, count: Int(frameCount))
            }
            return noErr
        }
        engine.attach(source)
        chain.setEngine(engineKind)
        chain.setStrength(strength)
        chain.attach(to: engine)
        chain.connect(in: engine, from: source, to: engine.mainMixerNode, format: mono)
        let outputMeter = outputMeter
        chain.limiter.installTap(onBus: 0, bufferSize: 1024, format: nil) { buf, _ in
            guard let p = buf.floatChannelData?[0] else { return }
            outputMeter.measure(p, count: Int(buf.frameLength))
            processedRecorder.write(p, count: Int(buf.frameLength))
        }

        worker?.start()
        engine.prepare()
        do {
            try engine.start()
        } catch {
            worker?.stop()
            chain.limiter.removeTap(onBus: 0)
            chain.nodes.forEach(engine.detach)
            scratch.deallocate()
            upScratch.deallocate()
            throw error
        }

        self.engine = engine
        self.consumer = consumer
        self.worker = worker
        self.rawRecorder = rawRecorder
        self.processedRecorder = processedRecorder
        self.scratch = scratch
        self.upScratch = upScratch
        let session = AVAudioSession.sharedInstance()
        baseLatency = session.inputLatency + session.outputLatency + 2 * session.ioBufferDuration + engineKind.latency
        Log.write(String(format: "Session latency: input %.1f ms, output %.1f ms, IO buffer %.1f ms",
                         session.inputLatency * 1000, session.outputLatency * 1000, session.ioBufferDuration * 1000))
    }

    func stop() {
        guard let engine else { return }
        chain.limiter.removeTap(onBus: 0)
        engine.stop()
        worker?.stop()
        worker = nil
        chain.nodes.forEach(engine.detach)
        self.engine = nil
        scratch?.deallocate()
        scratch = nil
        upScratch?.deallocate()
        upScratch = nil
        consumer = nil
        inputMeter.store(0)
        outputMeter.store(0)
    }

    var isRunning: Bool { engine?.isRunning ?? false }

    func setStrength(_ s: Float) {
        chain.setStrength(s)
        worker?.denoiser.setStrength(s)
    }

    var bufferedMs: Double {
        guard let c = consumer else { return 0 }
        return Double(c.ring.fill) / c.sampleRate * 1000
    }

    var liveLatency: Double {
        guard let c = consumer else { return 0 }
        return baseLatency + Double(c.ring.fill) / c.sampleRate
    }

    /// Saves the last 30 seconds of raw capture and processed audio to Documents (visible in the Files app).
    func saveRecent(note: String) throws -> URL {
        guard let raw = rawRecorder, let processed = processedRecorder else { throw PhonePipelineError.badFormat }
        let dir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("清听录音")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let stamp = Date().formatted(.iso8601.year().month().day().time(includingFractionalSeconds: false))
            .replacingOccurrences(of: ":", with: "")
        try raw.save(to: dir.appendingPathComponent("\(stamp)_原始.wav"))
        try processed.save(to: dir.appendingPathComponent("\(stamp)_处理后_\(note).wav"))
        return dir
    }
}
