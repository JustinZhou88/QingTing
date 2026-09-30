import AVFoundation
import SwiftUI

@MainActor
final class AudioController: ObservableObject {
    @Published private(set) var inputs: [AudioDevice] = []
    @Published private(set) var outputs: [AudioDevice] = []
    @Published var inputUID: String = "" { didSet { settingsChanged(restart: true) } }
    @Published var outputUID: String = "" { didSet { settingsChanged(restart: true) } }
    // 每个参数只更新自己对应的那一处：拖滑块时不要连带重设整套预设
    @Published var mode: ListeningMode = .classroom {
        didSet { if !restoring { pipeline.chain.apply(mode.preset) }; settingsChanged() }
    }
    @Published var engine: DenoiseEngine = .deepFilter { didSet { settingsChanged(restart: true) } }
    @Published var strength: Double = 0.5 {
        didSet { if !restoring { pipeline.setStrength(Float(strength)) }; settingsChanged() }
    }
    @Published var volumeDB: Double = 0 {
        didSet { if !restoring { pipeline.chain.setVolume(Float(volumeDB)) }; settingsChanged() }
    }
    /// 自动调参：每秒分析最近 8 秒收音，自动设降噪强度和清晰度
    @Published var autoTune = true { didSet { settingsChanged() } }
    @Published private(set) var sceneSummary: String?

    @Published var clarityDB: Double = 6 {
        // 没在播放时直接生效；播放中由 updateMeters 里的 rampClarity 慢慢过渡，避免咔嗒声
        didSet { if !restoring { pipeline.chain.setClarity(Float(clarityDB), immediately: !isRunning) }; settingsChanged() }
    }
    @Published var autoGain = true {
        didSet { if !restoring { pipeline.chain.setAutoGain(autoGain) }; settingsChanged() }
    }
    @Published var bypass = false {
        didSet { if !restoring { pipeline.chain.setBypass(bypass) }; settingsChanged() }
    }

    @Published private(set) var isRunning = false
    @Published private(set) var errorMessage: String?
    @Published private(set) var inputDB: Float = -120
    @Published private(set) var outputDB: Float = -120
    @Published private(set) var inputWave = LevelHistory()
    @Published private(set) var outputWave = LevelHistory()
    @Published private(set) var latencyMs: Double = 0
    @Published private(set) var compressionDB: Float = 0
    @Published private(set) var glitches = 0
    @Published private(set) var agcGainDB: Float = 0

    let pipeline = LivePipeline()
    private var meterTimer: Timer?
    private var activity: NSObjectProtocol?
    private var restoring = true
    private let defaults = UserDefaults.standard

    init() {
        refreshDevices()
        if let m = defaults.string(forKey: "mode").flatMap(ListeningMode.init) { mode = m }
        if let e = defaults.string(forKey: "engine").flatMap(DenoiseEngine.init) { engine = e }
        if defaults.object(forKey: "strength") != nil { strength = defaults.double(forKey: "strength") }
        volumeDB = defaults.double(forKey: "volumeDB")
        if defaults.object(forKey: "autoGain") != nil { autoGain = defaults.bool(forKey: "autoGain") }
        if defaults.object(forKey: "clarityDB") != nil { clarityDB = defaults.double(forKey: "clarityDB") }
        if defaults.object(forKey: "autoTune") != nil { autoTune = defaults.bool(forKey: "autoTune") }
        // 收音端加了低切之后，同样的降噪效果只需要以前一半左右的强度，升级时重置一次
        if !defaults.bool(forKey: "migratedLowCut") {
            strength = 0.5
            defaults.set(true, forKey: "migratedLowCut")
        }
        // 加入自动音量后，旧版为了听清而拉高的音量会让限幅器一直在压，升级时重置一次
        if !defaults.bool(forKey: "migratedAGC") {
            volumeDB = 0
            defaults.set(true, forKey: "migratedAGC")
        }
        restoring = false
        applyProcessing()

        AudioDevices.onDeviceListChange { [weak self] in
            Task { @MainActor in self?.devicesChanged() }
        }
        pipeline.onConfigurationChange = { [weak self] in
            Task { @MainActor in self?.configurationChanged() }
        }
        Log.write("启动 App；收音=\(selectedInput?.name ?? "无") 输出=\(selectedOutput?.name ?? "无") 场景=\(mode.title) 引擎=\(engine.title) 降噪=\(Int(strength * 100))% 音量=\(volumeDB)dB")
    }

    var selectedInput: AudioDevice? { inputs.first { $0.uid == inputUID } }
    var selectedOutput: AudioDevice? { outputs.first { $0.uid == outputUID } }

    /// 同一台 Mac 的麦克风 + 扬声器会形成回授啸叫。
    var feedbackRisk: Bool {
        guard let i = selectedInput, let o = selectedOutput else { return false }
        return i.isBuiltIn && o.isBuiltIn
    }

    func toggle() { isRunning ? stop(reason: "用户点停止") : start() }

    func start() {
        errorMessage = nil
        Log.write("用户点开始；麦克风权限状态=\(AVCaptureDevice.authorizationStatus(for: .audio).rawValue)")
        Task {
            guard await AVCaptureDevice.requestAccess(for: .audio) else {
                fail("没有麦克风权限：请到 系统设置 → 隐私与安全性 → 麦克风 里允许「清听」")
                return
            }
            startNow()
        }
    }

    private func fail(_ message: String) {
        errorMessage = message
        Log.write("错误：\(message)")
    }

    private func startNow() {
        guard let input = selectedInput else { fail("请选择收音设备"); return }
        guard let output = selectedOutput else { fail("请选择输出设备（助听器）"); return }
        meterTimer?.invalidate()
        if let activity { ProcessInfo.processInfo.endActivity(activity) }
        do {
            try pipeline.start(input: input, output: output, engine: engine, strength: Float(strength))
            isRunning = true
            errorMessage = nil
            glitches = 0
            Log.write("已开始：\(input.name) → \(output.name)，引擎 \(engine.title)，固定延迟≈\(Int(pipeline.baseLatency * 1000))ms")
            // 防止 App Nap 和系统降频打断实时音频
            activity = ProcessInfo.processInfo.beginActivity(
                options: [.userInitiated, .latencyCritical, .idleSystemSleepDisabled], reason: "实时助听")
            meterTimer = Timer.scheduledTimer(withTimeInterval: 1.0 / 20, repeats: true) { [weak self] _ in
                Task { @MainActor in self?.updateMeters() }
            }
            tuneTimer?.invalidate()
            tuneTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
                Task { @MainActor in self?.autoTuneTick() }
            }
        } catch {
            pipeline.stop()
            fail("启动失败：\(error.localizedDescription)")
        }
    }

    func stop(reason: String) {
        Log.write("停止：\(reason)")
        resumeWhenAvailable = false
        pipeline.stop()
        meterTimer?.invalidate()
        meterTimer = nil
        tuneTimer?.invalidate()
        tuneTimer = nil
        sceneSummary = nil
        if let activity { ProcessInfo.processInfo.endActivity(activity) }
        activity = nil
        isRunning = false
        inputDB = -120
        outputDB = -120
        inputWave.reset()
        outputWave.reset()
    }

    @Published private(set) var savedMessage: String?

    func saveRecent() {
        let note = "\(engine.title)_\(mode.title)_降噪\(Int(strength * 100))_\(bypass ? "旁路" : "处理")"
        do {
            let dir = try pipeline.saveRecent(note: note)
            savedMessage = "已保存最近 30 秒到 文稿/清听录音"
            Log.write("保存录音：\(dir.path) \(note)")
            NSWorkspace.shared.activateFileViewerSelecting([dir])
        } catch {
            fail("保存失败：\(error.localizedDescription)")
        }
    }

    // MARK: - 自动调参

    private var tuneTimer: Timer?
    private let analysisQueue = DispatchQueue(label: "清听.现场分析", qos: .utility)
    private var analyzer: SceneAnalyzer?
    private var lastScene: SceneAnalyzer.Estimate?

    /// 每秒一次：后台分析最近 8 秒原始收音，参数朝目标平滑靠拢（时间常数约 4 秒），
    /// 没人说话时保持不动。
    private func autoTuneTick() {
        guard autoTune, !bypass, let recorder = pipeline.rawRecorder else { return }
        if analyzer?.sampleRate != recorder.sampleRate { analyzer = SceneAnalyzer(sampleRate: recorder.sampleRate) }
        guard let analyzer else { return }
        // 分析器只在这个串行队列里用
        nonisolated(unsafe) let a = analyzer
        analysisQueue.async { [weak self] in
            let estimate = a.analyze(recorder.recent(seconds: 8))
            Task { @MainActor in self?.applyAutoTune(estimate) }
        }
    }

    private func applyAutoTune(_ estimate: SceneAnalyzer.Estimate?) {
        guard autoTune, isRunning else { return }
        guard let e = estimate else {
            sceneSummary = "没检测到人声，参数保持不变"
            return
        }
        lastScene = e
        let target = SceneAnalyzer.params(for: e, agcGainDB: autoGain ? pipeline.chain.agc.currentGainDB : 0)
        let k = 0.25
        // 只有引擎是 DeepFilterNet/RNNoise/Apple 时强度才有意义；不降噪时不动它
        if engine != .off {
            let s = strength + (Double(target.strength) - strength) * k
            if abs(s - strength) > 0.005 { strength = (s * 100).rounded() / 100 }
        }
        let c = clarityDB + (Double(target.clarityDB) - clarityDB) * k
        if abs(c - clarityDB) > 0.05 { clarityDB = (c * 10).rounded() / 10 }
        sceneSummary = String(format: "现场：人声信噪比 %.0f dB，高频 %.0f dB → 降噪 %.0f%%、清晰度 +%.0f dB",
                              e.speechSNR, e.highSNR, target.strength * 100, target.clarityDB)
    }

    private var restartTimes: [Date] = []
    private var restartScheduled = false

    /// 音频设备配置变化（换设备、采样率变、蓝牙重连）。合并 0.3 秒内的连续通知再重启，
    /// 10 秒内重启超过 5 次说明在来回抖，停下报错而不是无限重启。
    private func configurationChanged() {
        guard isRunning, !restartScheduled else { return }
        restartScheduled = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
            guard let self else { return }
            restartScheduled = false
            let now = Date()
            restartTimes = restartTimes.filter { now.timeIntervalSince($0) < 10 } + [now]
            if restartTimes.count > 5 {
                stop(reason: "设备配置反复变化")
                fail("音频设备反复变化，已停止。请重新点开始。")
                return
            }
            restartIfRunning()
        }
    }

    private func restartIfRunning() {
        guard isRunning else { return }
        Log.write("重启音频链路")
        pipeline.stop()
        isRunning = false
        startNow()
        if !isRunning, errorMessage != nil {
            // 多半是设备刚断开，等它回来
            resumeWhenAvailable = true
        }
    }

    private var lastStatLog = Date.distantPast

    private func updateMeters() {
        pipeline.chain.rampClarity()
        if Date().timeIntervalSince(lastStatLog) > 3, let c = pipeline.consumer {
            lastStatLog = Date()
            if autoTune, let e = lastScene {
                Log.write(String(format: "现场 信噪比 %.1f 高频信噪比 %.1f 高频倾斜 %.1f 说话占比 %.0f%% → 降噪 %.0f%% 清晰度 %.1f",
                                 e.speechSNR, e.highSNR, e.tilt, e.speechFraction * 100, strength * 100, clarityDB))
            }
            Log.write(String(format: "运行中 收音 %.0f dBFS  送出 %.0f dBFS  积压 %.0f ms  欠载 %d  跳帧 %d  %@ %d%%  每帧 %dµs  旁路 %@",
                             pipeline.inputMeter.dBFS, pipeline.outputMeter.dBFS, pipeline.bufferedMs,
                             c.underruns.load(ordering: .relaxed), c.drops.load(ordering: .relaxed),
                             engine.title + String(format: " 自动增益%+.0fdB", pipeline.chain.agc.currentGainDB), Int(strength * 100),
                             pipeline.worker?.lastFrameMicros.load(ordering: .relaxed) ?? 0, bypass ? "开" : "关"))
        }
        inputDB = pipeline.inputMeter.dBFS
        outputDB = pipeline.outputMeter.dBFS
        inputWave.append(dB: inputDB)
        outputWave.append(dB: outputDB)
        latencyMs = pipeline.liveLatency * 1000
        compressionDB = pipeline.chain.compressionAmount
        agcGainDB = pipeline.chain.agc.currentGainDB
        if let c = pipeline.consumer {
            glitches = c.underruns.load(ordering: .relaxed) + c.drops.load(ordering: .relaxed)
        }
    }

    // MARK: - 设备

    func refreshDevices() {
        let all = AudioDevices.all()
        inputs = all.filter { $0.inputChannels > 0 }
        outputs = all.filter { $0.outputChannels > 0 }

        // 只在从没选过时自动挑；选过的设备暂时断开也保留选择，重连后接着用
        if inputUID.isEmpty {
            let saved = defaults.string(forKey: "inputUID")
            inputUID = (inputs.first { $0.uid == saved } ?? inputs.first { $0.isBuiltIn } ?? inputs.first)?.uid ?? ""
        }
        if outputUID.isEmpty {
            let saved = defaults.string(forKey: "outputUID")
            outputUID = (outputs.first { $0.uid == saved }
                ?? outputs.first { $0.looksLikeHearingAid }
                ?? outputs.first { $0.id == AudioDevices.defaultOutputID }
                ?? outputs.first)?.uid ?? ""
        }
    }

    /// 因设备断开而停下的，设备回来后自动恢复。
    private var resumeWhenAvailable = false

    private func devicesChanged() {
        refreshDevices()
        let available = selectedInput != nil && selectedOutput != nil
        if isRunning, !available {
            // 正在用的设备消失（比如助听器断开）：停下，别让声音跑到别的设备
            stop(reason: "设备断开")
            resumeWhenAvailable = true // stop() 会清掉，这里重新置上
            errorMessage = "设备已断开，重新连接后会自动继续"
        } else if resumeWhenAvailable, available {
            resumeWhenAvailable = false
            Log.write("设备已恢复，自动继续")
            startNow()
        }
    }

    // MARK: - 参数

    private func settingsChanged(restart: Bool = false) {
        guard !restoring else { return }
        defaults.set(inputUID, forKey: "inputUID")
        defaults.set(outputUID, forKey: "outputUID")
        defaults.set(mode.rawValue, forKey: "mode")
        defaults.set(engine.rawValue, forKey: "engine")
        defaults.set(strength, forKey: "strength")
        defaults.set(volumeDB, forKey: "volumeDB")
        defaults.set(autoGain, forKey: "autoGain")
        defaults.set(clarityDB, forKey: "clarityDB")
        defaults.set(autoTune, forKey: "autoTune")
        if restart { restartIfRunning() }
    }

    private func applyProcessing() {
        let chain = pipeline.chain
        chain.apply(mode.preset)
        pipeline.setStrength(Float(strength))
        chain.setVolume(Float(volumeDB))
        chain.setAutoGain(autoGain)
        chain.setClarity(Float(clarityDB), immediately: true)
        chain.setBypass(bypass)
    }
}
