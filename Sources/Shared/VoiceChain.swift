import AVFoundation
import AudioToolbox
import Synchronization

/// 使用场景预设。
enum ListeningMode: String, CaseIterable, Identifiable {
    case classroom, discussion, conversation
    var id: String { rawValue }

    var title: String {
        switch self {
        case .classroom: "课堂"
        case .discussion: "讨论"
        case .conversation: "一对一"
        }
    }

    var detail: String {
        switch self {
        case .classroom: "远处单个讲者：提升远距离人声，压住翻书、空调、走动声"
        case .discussion: "多人轮流发言：各人音量拉平，保留一点环境感"
        case .conversation: "嘈杂环境面对面：最强降噪，没人说话时几乎静音"
        }
    }

    var preset: VoicePreset {
        switch self {
        case .classroom:
            VoicePreset(presenceGain: 4, compThreshold: -20, headRoom: 10,
                        attack: 0.005, release: 0.2, makeupGain: 2, agcRise: 4, agcFall: 12)
        case .discussion:
            VoicePreset(presenceGain: 2, compThreshold: -20, headRoom: 10,
                        attack: 0.005, release: 0.25, makeupGain: 2, agcRise: 10, agcFall: 20)
        case .conversation:
            VoicePreset(presenceGain: 3, compThreshold: -18, headRoom: 12,
                        attack: 0.003, release: 0.15, makeupGain: 0, agcRise: 6, agcFall: 15)
        }
    }
}

struct VoicePreset {
    var presenceGain: Float      // dB，2.5kHz 附近辅音清晰度
    var compThreshold: Float     // dB，压缩起点
    var headRoom: Float          // dB，压缩余量（越小压得越狠）
    var attack: Float            // s
    var release: Float           // s
    var makeupGain: Float        // dB
    var agcRise: Float           // dB/s，人声变小时自动增益的上升速度（多人讨论要快，单人讲课要稳）
    var agcFall: Float           // dB/s
}

/// 高通/临场感 EQ → Apple 语音隔离 → 自动增益 → 压缩 → 限幅器。
/// 平台无关，Mac 与 iPhone 共用。
final class VoiceChain {
    /// 用户音量上限（dB），再往上由限幅器兜底。
    static let maxVolumeDB: Float = 12

    let eq = AVAudioUnitEQ(numberOfBands: 2)
    let isolation = AVAudioUnitEffect(audioComponentDescription: .appleEffect(0x766F_6973)) // 'vois'
    let dynamics = AVAudioUnitEffect(audioComponentDescription: .appleEffect(kAudioUnitSubType_DynamicsProcessor))
    let limiter = AVAudioUnitEffect(audioComponentDescription: .appleEffect(kAudioUnitSubType_PeakLimiter))
    let agcNode: AVAudioUnitEffect = {
        AGCAudioUnit.registered
        return AVAudioUnitEffect(audioComponentDescription: AGCAudioUnit.componentDescription)
    }()
    var agc: AGCProcessor { (agcNode.auAudioUnit as! AGCAudioUnit).processor }

    /// 高通/临场感 EQ → Apple 隔离（仅 Apple 引擎）→ 自动增益 → 压缩 → 限幅
    var nodes: [AVAudioNode] { [eq, isolation, agcNode, dynamics, limiter] }

    init() {
        // 清晰度：2kHz 以上高架提升，补回远处传来衰减掉的辅音（课堂录音里高频比中频弱 10-15dB）。
        // 低频切除不在这里做，在收音端降噪之前做（见 HighPassFilter）。
        eq.bands[0].filterType = .highShelf
        eq.bands[0].frequency = 2000
        eq.bands[0].gain = 6
        eq.bands[0].bypass = false
        eq.bands[1].filterType = .parametric
        eq.bands[1].frequency = 2500
        eq.bands[1].bandwidth = 1.5
        eq.bands[1].bypass = false
        setIsolationParam(1, 1) // Sound to Isolate = "Voice"（比 High Quality Voice 延迟低、降噪强）
        // 关掉压缩器自带的扩展（噪声门）：噪声交给降噪引擎处理，门限只会把远处老师的字尾切掉
        setDynamics(kDynamicsProcessorParam_ExpansionRatio, 1)
        setLimiter(kLimiterParam_AttackTime, 0.002)
        setLimiter(kLimiterParam_DecayTime, 0.05)
    }

    func attach(to engine: AVAudioEngine) {
        nodes.forEach(engine.attach)
    }

    /// source → chain → destination，全程同一单声道格式。
    func connect(in engine: AVAudioEngine, from source: AVAudioNode, to destination: AVAudioNode, format: AVAudioFormat) {
        let chain = [source] + nodes + [destination]
        for (a, b) in zip(chain, chain.dropFirst()) {
            engine.connect(a, to: b, format: format)
        }
    }

    func apply(_ p: VoicePreset) {
        eq.bands[1].gain = p.presenceGain
        setDynamics(kDynamicsProcessorParam_Threshold, p.compThreshold)
        setDynamics(kDynamicsProcessorParam_HeadRoom, p.headRoom)
        setDynamics(kDynamicsProcessorParam_AttackTime, p.attack)
        setDynamics(kDynamicsProcessorParam_ReleaseTime, p.release)
        setDynamics(kDynamicsProcessorParam_OverallGain, p.makeupGain)
        agc.update { $0.riseDBPerSec = p.agcRise; $0.fallDBPerSec = p.agcFall }
    }

    /// 清晰度（2kHz 以上提升多少 dB）。只设目标，实际增益由 rampClarity() 慢慢靠过去：
    /// EQ 系数一步跳变会有瞬态，实测 1dB 一步的瑕疵只比人声低 19dB、说话时能听到"嗒"，
    /// 0.1dB 一步则低约 39dB。
    func setClarity(_ db: Float, immediately: Bool = false) {
        clarityTarget = max(0, min(Self.maxClarityDB, db))
        if immediately { eq.bands[0].gain = clarityTarget }
    }
    private var clarityTarget: Float = 6

    /// 每 50ms 调一次：最多变 0.1dB（即 2dB/秒）。
    func rampClarity() {
        let current = eq.bands[0].gain
        let diff = clarityTarget - current
        guard abs(diff) > 0.001 else { return }
        eq.bands[0].gain = current + max(-0.1, min(0.1, diff))
    }
    static let maxClarityDB: Float = 12
    /// 收音后、降噪前的低切频率
    static let lowCutHz = 250.0

    /// 自动音量（AGC）开关。
    func setAutoGain(_ on: Bool) {
        agc.setEnabled(on)
    }

    /// 降噪强度 0...1，对应语音隔离的干湿比。
    func setStrength(_ s: Float) {
        setIsolationParam(0, max(0, min(1, s)) * 100)
    }

    /// 音量（dB），进限幅器之前加，所以再大也不会削顶超过满刻度。
    func setVolume(_ db: Float) {
        setLimiter(kLimiterParam_PreGain, min(db, Self.maxVolumeDB))
    }

    private var appleIsolationOn = true
    private var bypassAll = false

    /// 选 Apple 引擎时启用语音隔离 AU，并切换其模式；选别的引擎时它直通。
    func setEngine(_ engine: DenoiseEngine) {
        appleIsolationOn = engine == .appleVoice || engine == .appleHQ
        setIsolationParam(1, engine == .appleHQ ? 0 : 1) // 0 = High Quality Voice, 1 = Voice
        updateBypass()
    }

    /// 原声对比：关掉 EQ/降噪/压缩，只保留限幅器保护听力。
    func setBypass(_ on: Bool) {
        bypassAll = on
        updateBypass()
    }

    private func updateBypass() {
        eq.bypass = bypassAll
        isolation.bypass = bypassAll || !appleIsolationOn
        agcNode.bypass = bypassAll
        dynamics.bypass = bypassAll
    }

    /// 当前压缩量（dB），用于界面显示。
    var compressionAmount: Float {
        var v: AudioUnitParameterValue = 0
        AudioUnitGetParameter(dynamics.audioUnit, kDynamicsProcessorParam_CompressionAmount, kAudioUnitScope_Global, 0, &v)
        return v
    }

    private func setIsolationParam(_ address: AUParameterAddress, _ v: Float) {
        isolation.auAudioUnit.parameterTree?.parameter(withAddress: address)?.value = v
    }

    private func setDynamics(_ id: AudioUnitParameterID, _ v: Float) {
        AudioUnitSetParameter(dynamics.audioUnit, id, kAudioUnitScope_Global, 0, v, 0)
    }

    private func setLimiter(_ id: AudioUnitParameterID, _ v: Float) {
        AudioUnitSetParameter(limiter.audioUnit, id, kAudioUnitScope_Global, 0, v, 0)
    }
}

extension AudioComponentDescription {
    static func appleEffect(_ subType: OSType) -> AudioComponentDescription {
        AudioComponentDescription(componentType: kAudioUnitType_Effect, componentSubType: subType,
                                  componentManufacturer: kAudioUnitManufacturer_Apple,
                                  componentFlags: 0, componentFlagsMask: 0)
    }
}

/// 实时线程里用的电平计：存 Float 的 bit pattern。
final class LevelMeter: @unchecked Sendable {
    private let bits = Atomic<UInt32>(0)
    /// 最近一块的 RMS（线性）
    var rms: Float { Float(bitPattern: bits.load(ordering: .relaxed)) }
    func store(_ v: Float) { bits.store(v.bitPattern, ordering: .relaxed) }

    func measure(_ p: UnsafePointer<Float>, count: Int) {
        var sum: Float = 0
        for i in 0..<count { sum += p[i] * p[i] }
        store(count > 0 ? (sum / Float(count)).squareRoot() : 0)
    }

    var dBFS: Float { 20 * log10(max(rms, 1e-6)) }
}
