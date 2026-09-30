import AVFoundation
import SwiftUI
import UIKit

/// Display data that refreshes at a high rate (levels, waveforms, latency, scene analysis result)
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
    // Each parameter updates only its own part of the chain: dragging a slider must not reapply the whole preset
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
    /// Display data that changes 20 times a second lives in its own object: only the waveform and diagnostics views observe it.
    /// If it shared an object with the settings, the whole page would redraw 20 times a second while running and interfere with controls such as pickers.
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
    /// Directional pickup was requested but the current microphone cannot do it (on real devices the back and bottom mics do not offer cardioid)
    @Published private(set) var directionalUnavailable = false

    let pipeline = PhonePipeline()
    private let liveActivity = ListeningActivityController()
    private var meterTimer: Timer?
    private var tuneTimer: Timer?
    private var restoring = true
    private let defaults = UserDefaults.standard
    /// Stopped by an interruption (phone call) or because the hearing aids disconnected; resumes automatically once conditions are back
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
        // Device data: directional modes make the capture quieter and duller (front cardioid on a 13 mini: 14 dB lower, 10 dB less treble) and add about 30 ms of latency,
        // with no SNR benefit observed. The default is now back + omnidirectional; existing settings are reset once.
        if !defaults.bool(forKey: "migratedOmniMic") {
            micPosition = .back
            micPattern = .omni
            // Settings are still being restored here, so didSet does not persist; write the values back explicitly or the old ones are read again at the next launch
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
                self.stop(reason: "stopped from the Dynamic Island or Lock Screen")
            }
        }
        nc.addObserver(forName: AVAudioSession.mediaServicesWereResetNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.restart(reason: "media services were reset") }
        }
        nc.addObserver(forName: .AVAudioEngineConfigurationChange, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in
                guard let self, self.isRunning, !self.pipeline.isRunning else { return }
                self.restart(reason: "the audio engine was stopped by the system")
            }
        }
        Log.write("App launched; engine=\(engine.rawValue) scene=\(mode.rawValue) mic=\(micPosition.rawValue)/\(micPattern.rawValue) output=\(outputName)")
    }

    // MARK: - Start and stop

    func toggle() { isRunning ? stop(reason: "stop pressed") : start() }

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
            Log.write("Started: \(micDescription) -> \(outputName), engine \(engine.rawValue), fixed latency ~\(Int(pipeline.baseLatency * 1000)) ms")
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
        Log.write("Stopped: \(reason)")
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
        Log.write("Restarting: \(reason)")
        pipeline.stop()
        startNow()
    }

    private func fail(_ message: String) {
        errorMessage = message
        Log.write("Error: \(message)")
    }

    // MARK: - Demo mode (simulator only)

    private var demoTimer: Timer?

    /// The simulator has no hearing aids and should not open the microphone: fake levels drive the UI and the Dynamic Island so the display can be checked.
    /// Active when launched with -demo; on a real device this method does nothing.
    func startDemoIfRequested() {
        #if targetEnvironment(simulator)
        guard CommandLine.arguments.contains("-demo") else { return }
        isRunning = true
        outputName = "我的助听器"
        outputIsBuiltIn = false
        latencyMs = 82
        liveActivity.start(outputName: outputName, strength: Int(strength * 100))
        // Data must keep flowing after switching to the home screen to see the Dynamic Island change, so request some background time (about 30 s)
        var bg = UIBackgroundTaskIdentifier.invalid
        bg = UIApplication.shared.beginBackgroundTask { UIApplication.shared.endBackgroundTask(bg) }
        var t = 0.0
        demoTimer = Timer.scheduledTimer(withTimeInterval: 1.0 / 20, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                t += 0.05
                // Looks like sentence-by-sentence speech: rises, falls and pauses
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

    // MARK: - Interruptions and routing

    /// An interruption is in progress (phone call, alarm, Siri...). The system refuses to reactivate the audio session during it.
    private var isInterrupted = false

    private func interrupted(began: Bool) {
        if began {
            isInterrupted = true
            if isRunning {
                stop(reason: "interrupted (phone call, alarm...)")
                resumeWhenAvailable = true
                errorMessage = "被来电等打断，结束后会自动继续"
            }
        } else {
            isInterrupted = false
            if resumeWhenAvailable { resume(attempt: 1) }
        }
    }

    /// Automatic resume. Right after an interruption ends the session may still fail to activate, so retry every second, up to 5 times.
    private func resume(attempt: Int) {
        guard resumeWhenAvailable, !isRunning, !isInterrupted else { return }
        guard !PhonePipeline.currentOutput.isBuiltIn else { return }   // Hearing aids are not back yet; wait for a route change
        Log.write("Auto resume (attempt \(attempt))")
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

    /// When the hearing aids disconnect, audio falls back to the iPhone speaker; the microphone would pick it up and howl, so stop at once.
    private func routeChanged() {
        let out = PhonePipeline.currentOutput
        outputName = out.name
        outputIsBuiltIn = out.isBuiltIn
        if isRunning, out.isBuiltIn {
            stop(reason: "output changed to \(out.name)")
            resumeWhenAvailable = true
            errorMessage = "助听器断开了，已停止以免扬声器啸叫；重新连上后会自动继续"
        } else if resumeWhenAvailable, !out.isBuiltIn, !isRunning, !isInterrupted {
            // Route changes during an interruption do not count: activating the session is bound to fail then (this is how auto resume got lost in a device log)
            resume(attempt: 1)
        }
    }

    // MARK: - Recording

    func saveRecent() {
        let note = "\(engine.title)_\(micPosition.title)\(micPattern == .cardioid ? "指向" : "全向")_降噪\(Int(strength * 100))"
        do {
            _ = try pipeline.saveRecent(note: note)
            savedMessage = "已保存到「文件」→ 我的 iPhone → 清听 → 清听录音"
            Log.write("Saved recording \(note)")
        } catch {
            fail("保存失败：\(error.localizedDescription)")
        }
    }

    // MARK: - Auto tuning (same rules as the Mac version)

    private let analysisQueue = DispatchQueue(label: "qingting.scene-analysis", qos: .utility)
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

    // MARK: - Levels and logging

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
                    Log.write(String(format: "scene snr %.1f hf-snr %.1f tilt %.1f speech %.0f%% -> strength %.0f%% clarity %.1f",
                                     e.speechSNR, e.highSNR, e.tilt, e.speechFraction * 100, strength * 100, clarityDB))
                }
                Log.write(String(format: "running in %.0f dBFS  out %.0f dBFS  backlog %.0f ms  underruns %d  skips %d  %@ %d%%  agc %+.0f dB  frame %d us  latency ~%.0f ms",
                                 inputDB, outputDB, pipeline.bufferedMs,
                                 c.underruns.load(ordering: .relaxed), c.drops.load(ordering: .relaxed),
                                 engine.rawValue + String(format: " margin %.0f ms", c.marginMs), Int(strength * 100), agcGainDB,
                                 pipeline.worker?.lastFrameMicros.load(ordering: .relaxed) ?? 0, latencyMs))
            }
        }
    }

    // MARK: - Settings

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
        if needsRestart { restart(reason: reconfigure ? "microphone changed" : "engine changed") }
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
