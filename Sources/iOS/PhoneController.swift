import AVFoundation
import SwiftUI
import UIKit

/// 高频刷新的显示数据（电平、声纹、延迟、现场分析结果）
@MainActor
final class PhoneMeters: ObservableObject {
    @Published var sceneSummary: String?
    @Published var inputDB: Float = -120
    @Published var outputDB: Float = -120
    @Published var inputWave = LevelHistory()
    @Published var outputWave = LevelHistory()
    @Published var latencyMs: Double = 0
    @Published var glitches = 0
    @Published var agcGainDB: Float = 0
}

@MainActor
final class PhoneController: ObservableObject {
    // 每个参数只更新自己对应的那一处：拖滑块时不要连带重设整套预设
    @Published var mode: ListeningMode = .classroom {
        didSet { if !restoring { pipeline.chain.apply(mode.preset) }; settingsChanged() }
    }
    @Published var engine: DenoiseEngine = .deepFilter { didSet { settingsChanged(restart: true) } }
    @Published var strength: Double = 0.5 {
        didSet { if !restoring { pipeline.setStrength(Float(strength)) }; settingsChanged() }
    }
    @Published var clarityDB: Double = 6 {
        didSet { if !restoring { pipeline.chain.setClarity(Float(clarityDB), immediately: !isRunning) }; settingsChanged() }
    }
    @Published var volumeDB: Double = 0 {
        didSet { if !restoring { pipeline.chain.setVolume(Float(volumeDB)) }; settingsChanged() }
    }
    @Published var autoTune = true { didSet { settingsChanged() } }
    @Published var autoGain = true {
        didSet { if !restoring { pipeline.chain.setAutoGain(autoGain) }; settingsChanged() }
    }
    @Published var bypass = false {
        didSet { if !restoring { pipeline.chain.setBypass(bypass) }; settingsChanged() }
    }
    @Published var micPosition: MicPosition = .back { didSet { settingsChanged(restart: true, reconfigure: true) } }
    @Published var micPattern: MicPattern = .omni { didSet { settingsChanged(restart: true, reconfigure: true) } }

    @Published private(set) var isRunning = false
    @Published private(set) var errorMessage: String?
    @Published private(set) var savedMessage: String?
    /// 每秒变化 20 次的显示数据单独放一个对象：只有声纹、诊断那几小块界面订阅它。
    /// 如果和设置项放在一起，运行时整页每秒重绘 20 次，选择器之类的控件会受干扰。
    let meters = PhoneMeters()
    private(set) var sceneSummary: String? { get { meters.sceneSummary } set { meters.sceneSummary = newValue } }
    private(set) var inputDB: Float { get { meters.inputDB } set { meters.inputDB = newValue } }
    private(set) var outputDB: Float { get { meters.outputDB } set { meters.outputDB = newValue } }
    private(set) var inputWave: LevelHistory { get { meters.inputWave } set { meters.inputWave = newValue } }
    private(set) var outputWave: LevelHistory { get { meters.outputWave } set { meters.outputWave = newValue } }
    private(set) var latencyMs: Double { get { meters.latencyMs } set { meters.latencyMs = newValue } }
    private(set) var glitches: Int { get { meters.glitches } set { if meters.glitches != newValue { meters.glitches = newValue } } }
    private(set) var agcGainDB: Float { get { meters.agcGainDB } set { meters.agcGainDB = newValue } }
    @Published private(set) var outputName = PhonePipeline.currentOutput.name
    @Published private(set) var outputIsBuiltIn = PhonePipeline.currentOutput.isBuiltIn
    @Published private(set) var micDescription = ""
    /// 选了指向收音、但当前麦克风做不到（真机上背面和底部麦克风只有全向）
    @Published private(set) var directionalUnavailable = false

    let pipeline = PhonePipeline()
    private let liveActivity = ListeningActivityController()
    private var meterTimer: Timer?
    private var tuneTimer: Timer?
    private var restoring = true
    private let defaults = UserDefaults.standard
    /// 被来电打断或助听器断开而停下的，条件恢复后自动继续
    private var resumeWhenAvailable = false

    init() {
        if let m = defaults.string(forKey: "mode").flatMap(ListeningMode.init) { mode = m }
        if let e = defaults.string(forKey: "engine").flatMap(DenoiseEngine.init) { engine = e }
        if defaults.object(forKey: "strength") != nil { strength = defaults.double(forKey: "strength") }
        if defaults.object(forKey: "clarityDB") != nil { clarityDB = defaults.double(forKey: "clarityDB") }
        volumeDB = defaults.double(forKey: "volumeDB")
        if defaults.object(forKey: "autoTune") != nil { autoTune = defaults.bool(forKey: "autoTune") }
        if defaults.object(forKey: "autoGain") != nil { autoGain = defaults.bool(forKey: "autoGain") }
        if let p = defaults.string(forKey: "micPosition").flatMap(MicPosition.init) { micPosition = p }
        if let p = defaults.string(forKey: "micPattern").flatMap(MicPattern.init) { micPattern = p }
        // 真机数据：指向模式让收音变小变闷（13 mini 正面心形低 14dB、高频少 10dB）、延迟多约 30ms，
        // 没看到信噪比上的好处。默认改成背面全向，已有设置重置一次。
        if !defaults.bool(forKey: "migratedOmniMic") {
            micPosition = .back
            micPattern = .omni
            // 这里还在恢复设置的阶段，didSet 不会保存，要自己写回去，否则下次启动又读到旧值
            defaults.set(MicPosition.back.rawValue, forKey: "micPosition")
            defaults.set(MicPattern.omni.rawValue, forKey: "micPattern")
            defaults.set(true, forKey: "migratedOmniMic")
        }
        restoring = false
        applyProcessing()

        let nc = NotificationCenter.default
        nc.addObserver(forName: AVAudioSession.interruptionNotification, object: nil, queue: .main) { [weak self] n in
            let type = (n.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt).flatMap(AVAudioSession.InterruptionType.init)
            Task { @MainActor in self?.interrupted(began: type == .began) }
        }
        nc.addObserver(forName: AVAudioSession.routeChangeNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.routeChanged() }
        }
        nc.addObserver(forName: .stopListeningRequested, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in
                guard let self, self.isRunning else { return }
                self.stop(reason: "在灵动岛/锁屏上点了停止")
            }
        }
        nc.addObserver(forName: AVAudioSession.mediaServicesWereResetNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.restart(reason: "系统音频服务重置") }
        }
        nc.addObserver(forName: .AVAudioEngineConfigurationChange, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in
                guard let self, self.isRunning, !self.pipeline.isRunning else { return }
                self.restart(reason: "音频引擎被系统停止")
            }
        }
        Log.write("启动 App；引擎=\(engine.title) 场景=\(mode.title) 麦克风=\(micPosition.title)/\(micPattern.title) 输出=\(outputName)")
    }

    // MARK: - 启停

    func toggle() { isRunning ? stop(reason: "用户点停止") : start() }

    func start() {
        errorMessage = nil
        Task {
            guard await AVAudioApplication.requestRecordPermission() else {
                fail("没有麦克风权限：请到 设置 → 清听 里打开麦克风")
                return
            }
            startNow()
        }
    }

    private func startNow() {
        do {
            micDescription = try pipeline.configureSession(position: micPosition, pattern: micPattern)
            directionalUnavailable = micPattern == .cardioid && !pipeline.isDirectional
            outputName = PhonePipeline.currentOutput.name
            outputIsBuiltIn = PhonePipeline.currentOutput.isBuiltIn
            try pipeline.start(engineKind: engine, strength: Float(strength))
            isRunning = true
            errorMessage = nil
            glitches = 0
            Log.write("已开始：\(micDescription) → \(outputName)，引擎 \(engine.title)，固定延迟≈\(Int(pipeline.baseLatency * 1000))ms")
            liveActivity.start(outputName: outputName, strength: Int(strength * 100))
            meterTimer?.invalidate()
            meterTimer = Timer.scheduledTimer(withTimeInterval: 1.0 / 20, repeats: true) { [weak self] _ in
                Task { @MainActor in self?.updateMeters() }
            }
            tuneTimer?.invalidate()
            tuneTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
                Task { @MainActor in self?.autoTuneTick() }
            }
        } catch {
            pipeline.stop()
            isRunning = false
            fail(error.localizedDescription)
        }
    }

    func stop(reason: String) {
        Log.write("停止：\(reason)")
        resumeWhenAvailable = false
        liveActivity.end()
        demoTimer?.invalidate()
        demoTimer = nil
        pipeline.stop()
        meterTimer?.invalidate()
        meterTimer = nil
        tuneTimer?.invalidate()
        tuneTimer = nil
        sceneSummary = nil
        isRunning = false
        inputDB = -120
        outputDB = -120
        inputWave.reset()
        outputWave.reset()
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }

    private func restart(reason: String) {
        guard isRunning else { return }
        Log.write("重启：\(reason)")
        pipeline.stop()
        startNow()
    }

    private func fail(_ message: String) {
        errorMessage = message
        Log.write("错误：\(message)")
    }

    // MARK: - 演示模式（仅模拟器）

    private var demoTimer: Timer?

    /// 模拟器里没有助听器也不该开麦克风：用假的电平驱动界面和灵动岛，检查显示效果。
    /// 启动参数带 -demo 时生效；真机上这个方法什么都不做。
    func startDemoIfRequested() {
        #if targetEnvironment(simulator)
        guard CommandLine.arguments.contains("-demo") else { return }
        isRunning = true
        outputName = "我的助听器"
        outputIsBuiltIn = false
        latencyMs = 82
        liveActivity.start(outputName: outputName, strength: Int(strength * 100))
        // 切到主屏幕后还要继续喂数据才能看灵动岛的变化：申请一段后台时间（约 30 秒）
        var bg = UIBackgroundTaskIdentifier.invalid
        bg = UIApplication.shared.beginBackgroundTask { UIApplication.shared.endBackgroundTask(bg) }
        var t = 0.0
        demoTimer = Timer.scheduledTimer(withTimeInterval: 1.0 / 20, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                t += 0.05
                // 一句一句说话的样子：有起伏、有停顿
                let speaking = sin(t * 1.3) > -0.3
                let envelope = Float(abs(sin(t * 7.1)) * 0.6 + abs(sin(t * 3.3)) * 0.4)
                self.inputDB = -38 + envelope * 8
                self.outputDB = speaking ? -34 + envelope * 18 : -70
                self.inputWave.append(dB: self.inputDB)
                self.outputWave.append(dB: self.outputDB)
                self.liveActivity.update(outputName: self.outputName, wave: self.outputWave.values, strength: Int(self.strength * 100))
            }
        }
        #endif
    }

    // MARK: - 打断与路由

    /// 打断进行中（来电、闹钟、Siri 等）。这期间系统不允许重新激活音频会话。
    private var isInterrupted = false

    private func interrupted(began: Bool) {
        if began {
            isInterrupted = true
            if isRunning {
                stop(reason: "被打断（来电、闹钟等）")
                resumeWhenAvailable = true
                errorMessage = "被来电等打断，结束后会自动继续"
            }
        } else {
            isInterrupted = false
            if resumeWhenAvailable { resume(attempt: 1) }
        }
    }

    /// 自动恢复。打断刚结束时会话可能还激活不了，失败就隔 1 秒再试，最多 5 次。
    private func resume(attempt: Int) {
        guard resumeWhenAvailable, !isRunning, !isInterrupted else { return }
        guard !PhonePipeline.currentOutput.isBuiltIn else { return }   // 助听器还没回来，等路由变化
        Log.write("自动恢复（第 \(attempt) 次）")
        startNow()
        if isRunning {
            resumeWhenAvailable = false
        } else if attempt < 5 {
            errorMessage = "正在恢复…"
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in self?.resume(attempt: attempt + 1) }
        } else {
            resumeWhenAvailable = false
            errorMessage = "没能自动恢复，请点开始"
        }
    }

    /// 助听器断开时声音会自动切到 iPhone 扬声器——麦克风收到后会啸叫，必须立刻停。
    private func routeChanged() {
        let out = PhonePipeline.currentOutput
        outputName = out.name
        outputIsBuiltIn = out.isBuiltIn
        if isRunning, out.isBuiltIn {
            stop(reason: "输出变成了 \(out.name)")
            resumeWhenAvailable = true
            errorMessage = "助听器断开了，已停止以免扬声器啸叫；重新连上后会自动继续"
        } else if resumeWhenAvailable, !out.isBuiltIn, !isRunning, !isInterrupted {
            // 打断期间的路由变化不算数：那时激活会话必然失败（真机日志里就是这样丢掉了自动恢复）
            resume(attempt: 1)
        }
    }

    // MARK: - 录音

    func saveRecent() {
        let note = "\(engine.title)_\(micPosition.title)\(micPattern == .cardioid ? "指向" : "全向")_降噪\(Int(strength * 100))"
        do {
            _ = try pipeline.saveRecent(note: note)
            savedMessage = "已保存到「文件」→ 我的 iPhone → 清听 → 清听录音"
            Log.write("保存录音 \(note)")
        } catch {
            fail("保存失败：\(error.localizedDescription)")
        }
    }

    // MARK: - 自动调参（与 Mac 版同一套规则）

    private let analysisQueue = DispatchQueue(label: "清听.现场分析", qos: .utility)
    private var analyzer: SceneAnalyzer?
    private var lastScene: SceneAnalyzer.Estimate?

    private func autoTuneTick() {
        guard autoTune, !bypass, let recorder = pipeline.rawRecorder else { return }
        if analyzer?.sampleRate != recorder.sampleRate { analyzer = SceneAnalyzer(sampleRate: recorder.sampleRate) }
        guard let analyzer else { return }
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
        if engine != .off {
            let s = strength + (Double(target.strength) - strength) * k
            if abs(s - strength) > 0.005 { strength = (s * 100).rounded() / 100 }
        }
        let c = clarityDB + (Double(target.clarityDB) - clarityDB) * k
        if abs(c - clarityDB) > 0.05 { clarityDB = (c * 10).rounded() / 10 }
        sceneSummary = String(format: "人声信噪比 %.0f dB、高频 %.0f dB → 降噪 %.0f%%、清晰度 +%.0f dB",
                              e.speechSNR, e.highSNR, target.strength * 100, target.clarityDB)
    }

    // MARK: - 电平与日志

    private var lastStatLog = Date.distantPast

    private func updateMeters() {
        pipeline.chain.rampClarity()
        inputDB = pipeline.inputMeter.dBFS
        outputDB = pipeline.outputMeter.dBFS
        inputWave.append(dB: inputDB)
        outputWave.append(dB: outputDB)
        liveActivity.update(outputName: outputName, wave: outputWave.values, strength: Int(strength * 100))
        latencyMs = pipeline.liveLatency * 1000
        agcGainDB = pipeline.chain.agc.currentGainDB
        if let c = pipeline.consumer {
            glitches = c.underruns.load(ordering: .relaxed) + c.drops.load(ordering: .relaxed)
            if Date().timeIntervalSince(lastStatLog) > 3 {
                lastStatLog = Date()
                if autoTune, let e = lastScene {
                    Log.write(String(format: "现场 信噪比 %.1f 高频信噪比 %.1f 高频倾斜 %.1f 说话占比 %.0f%% → 降噪 %.0f%% 清晰度 %.1f",
                                     e.speechSNR, e.highSNR, e.tilt, e.speechFraction * 100, strength * 100, clarityDB))
                }
                Log.write(String(format: "运行中 收音 %.0f dBFS  送出 %.0f dBFS  积压 %.0f ms  欠载 %d  跳帧 %d  %@ %d%%  自动增益%+.0fdB  每帧 %dµs  延迟≈%.0fms",
                                 inputDB, outputDB, pipeline.bufferedMs,
                                 c.underruns.load(ordering: .relaxed), c.drops.load(ordering: .relaxed),
                                 engine.title + String(format: " 余量%.0fms", c.marginMs), Int(strength * 100), agcGainDB,
                                 pipeline.worker?.lastFrameMicros.load(ordering: .relaxed) ?? 0, latencyMs))
            }
        }
    }

    // MARK: - 参数

    private func settingsChanged(restart needsRestart: Bool = false, reconfigure: Bool = false) {
        guard !restoring else { return }
        defaults.set(mode.rawValue, forKey: "mode")
        defaults.set(engine.rawValue, forKey: "engine")
        defaults.set(strength, forKey: "strength")
        defaults.set(clarityDB, forKey: "clarityDB")
        defaults.set(volumeDB, forKey: "volumeDB")
        defaults.set(autoTune, forKey: "autoTune")
        defaults.set(autoGain, forKey: "autoGain")
        defaults.set(micPosition.rawValue, forKey: "micPosition")
        defaults.set(micPattern.rawValue, forKey: "micPattern")
        if needsRestart { restart(reason: reconfigure ? "换麦克风" : "换引擎") }
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
