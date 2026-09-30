import AVFoundation
import AudioToolbox
import Synchronization

/// Listening scene presets.
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
    var presenceGain: Float      // dB, consonant clarity around 2.5 kHz
    var compThreshold: Float     // dB, where compression starts
    var headRoom: Float          // dB, compression headroom (smaller = harder compression)
    var attack: Float            // s
    var release: Float           // s
    var makeupGain: Float        // dB
    var agcRise: Float           // dB/s, how fast the auto gain rises when speech gets quieter (fast for group discussion, steady for a single lecturer)
    var agcFall: Float           // dB/s
}

/// Presence EQ -> Apple voice isolation -> auto gain -> compressor -> limiter.
/// Platform independent, shared by Mac and iPhone.
final class VoiceChain {
    /// Upper bound of the user volume in dB; anything beyond is caught by the limiter.
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

    /// Presence EQ -> Apple isolation (Apple engines only) -> auto gain -> compressor -> limiter
    var nodes: [AVAudioNode] { [eq, isolation, agcNode, dynamics, limiter] }

    init() {
        // Clarity: high shelf above 2 kHz that emphasizes consonants, which are hard to pick out in noise through hearing aids.
        // The low cut is not done here; it happens on the capture side before noise reduction (see HighPassFilter).
        eq.bands[0].filterType = .highShelf
        eq.bands[0].frequency = 2000
        eq.bands[0].gain = 6
        eq.bands[0].bypass = false
        eq.bands[1].filterType = .parametric
        eq.bands[1].frequency = 2500
        eq.bands[1].bandwidth = 1.5
        eq.bands[1].bypass = false
        setIsolationParam(1, 1) // Sound to Isolate = "Voice" (lower latency and stronger than High Quality Voice)
        // Disable the compressor's built-in expander (noise gate): noise is the denoiser's job, and a gate only chops off the ends of a distant talker's words
        setDynamics(kDynamicsProcessorParam_ExpansionRatio, 1)
        setLimiter(kLimiterParam_AttackTime, 0.002)
        setLimiter(kLimiterParam_DecayTime, 0.05)
    }

    func attach(to engine: AVAudioEngine) {
        nodes.forEach(engine.attach)
    }

    /// source -> chain -> destination, the same mono format throughout.
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

    /// Clarity (boost above 2 kHz, in dB). Only sets the target; rampClarity() moves the actual gain there slowly:
    /// a step change in EQ coefficients causes a transient. Measured: a 1 dB step leaves an artifact only 19 dB below the speech (an audible tick),
    /// while a 0.1 dB step is about 39 dB below.
    func setClarity(_ db: Float, immediately: Bool = false) {
        clarityTarget = max(0, min(Self.maxClarityDB, db))
        if immediately { eq.bands[0].gain = clarityTarget }
    }
    private var clarityTarget: Float = 6

    /// Call every 50 ms: changes by at most 0.1 dB (i.e. 2 dB/s).
    func rampClarity() {
        let current = eq.bands[0].gain
        let diff = clarityTarget - current
        guard abs(diff) > 0.001 else { return }
        eq.bands[0].gain = current + max(-0.1, min(0.1, diff))
    }
    static let maxClarityDB: Float = 12
    /// Low-cut frequency applied after capture and before noise reduction
    static let lowCutHz = 250.0

    /// Auto volume (AGC) switch.
    func setAutoGain(_ on: Bool) {
        agc.setEnabled(on)
    }

    /// Noise reduction strength 0...1, mapped to the wet/dry mix of the voice isolation unit.
    func setStrength(_ s: Float) {
        setIsolationParam(0, max(0, min(1, s)) * 100)
    }

    /// Volume in dB, applied before the limiter, so however loud it is set the output never clips past full scale.
    func setVolume(_ db: Float) {
        setLimiter(kLimiterParam_PreGain, min(db, Self.maxVolumeDB))
    }

    private var appleIsolationOn = true
    private var bypassAll = false

    /// Enables the voice isolation AU and sets its mode when an Apple engine is selected; bypasses it for other engines.
    func setEngine(_ engine: DenoiseEngine) {
        appleIsolationOn = engine == .appleVoice || engine == .appleHQ
        setIsolationParam(1, engine == .appleHQ ? 0 : 1) // 0 = High Quality Voice, 1 = Voice
        updateBypass()
    }

    /// Compare with original: turn off EQ, noise reduction and compression, keeping only the limiter to protect hearing.
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

    /// Current compression amount in dB, for display.
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

/// Level meter usable from the real-time thread: stores the bit pattern of a Float.
final class LevelMeter: @unchecked Sendable {
    private let bits = Atomic<UInt32>(0)
    /// RMS of the most recent block (linear)
    var rms: Float { Float(bitPattern: bits.load(ordering: .relaxed)) }
    func store(_ v: Float) { bits.store(v.bitPattern, ordering: .relaxed) }

    func measure(_ p: UnsafePointer<Float>, count: Int) {
        var sum: Float = 0
        for i in 0..<count { sum += p[i] * p[i] }
        store(count > 0 ? (sum / Float(count)).squareRoot() : 0)
    }

    var dBFS: Float { 20 * log10(max(rms, 1e-6)) }
}
