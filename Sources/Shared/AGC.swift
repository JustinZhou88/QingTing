import AVFoundation
import AudioToolbox
import Synchronization

/// Speech-aware automatic gain control: measures loudness only while speech is detected and slowly moves speech to a target level;
/// during pauses the gain is held, so the noise floor is not pumped up. Runs after noise reduction, and evens out level changes as the talker turns or walks around.
final class AGCProcessor: @unchecked Sendable {
    struct Settings {
        var targetDB: Float = -22      // Target speech level (dBFS RMS)
        var maxGainDB: Float = 24      // Maximum boost
        var minGainDB: Float = -12     // Maximum cut
        var riseDBPerSec: Float = 6    // How fast the gain rises when speech gets quieter
        var fallDBPerSec: Float = 15   // How fast the gain falls when speech gets louder (faster, to avoid harshness)
        var integrationSec: Float = 0.4 // Integration time of the speech loudness estimate
    }

    private let enabledFlag = Atomic<Bool>(true)
    private let settingsLock = Mutex(Settings())
    /// Current gain in dB, for display
    private let gainBits = Atomic<UInt32>(Float(0).bitPattern)

    var currentGainDB: Float { Float(bitPattern: gainBits.load(ordering: .relaxed)) }
    func setEnabled(_ on: Bool) { enabledFlag.store(on, ordering: .relaxed) }
    func update(_ change: (inout Settings) -> Void) { settingsLock.withLock { change(&$0) } }

    // ---- State below is only touched on the render thread
    private var sampleRate: Float = 48000
    private var power: Float = 1e-8         // Short-term power with a time constant of about 10 ms
    private var floorDB: Float = -60        // Noise floor tracker
    private var speechDB: Float = -26       // Speech loudness (about 400 ms integration, updated only while speaking)
    private var gainDB: Float = 0
    private var gain: Float = 1             // Linear gain after per-sample smoothing
    private var counter = 0
    private var active = Settings()

    func reset(sampleRate: Double) {
        self.sampleRate = Float(sampleRate)
        power = 1e-8
        floorDB = -60
        active = settingsLock.withLock { $0 }
        speechDB = active.targetDB
        gainDB = 0
        gain = 1
        counter = 0
    }

    /// Processes mono samples in place.
    func process(_ x: UnsafeMutablePointer<Float>, count: Int) {
        guard enabledFlag.load(ordering: .relaxed) else {
            // When disabled, smoothly return the gain to 0 dB
            for i in 0..<count {
                gain += (1 - gain) * 0.001
                x[i] *= gain
            }
            gainDB = 20 * log10(max(gain, 1e-6))
            return
        }
        let aPow = 1 - exp(-1 / (0.010 * sampleRate))
        let aGain = 1 - exp(-1 / (0.020 * sampleRate))
        let step = Int(sampleRate * 0.005)   // Update the control values every 5 ms
        let dt: Float = 0.005
        for i in 0..<count {
            let s = x[i]
            power += (s * s - power) * aPow
            counter += 1
            if counter >= step {
                counter = 0
                if let s = settingsLock.withLockIfAvailable({ $0 }) { active = s }
                let level = 10 * log10(max(power, 1e-12))
                // Noise floor: follows drops immediately, rises slowly (3 dB/s), so speech is not mistaken for the floor
                floorDB = level < floorDB ? floorDB + (level - floorDB) * 0.3 : floorDB + 3 * dt
                let speaking = level > floorDB + 9 && level > -70
                if speaking {
                    speechDB += (level - speechDB) * (dt / active.integrationSec)
                    let desired = min(active.maxGainDB, max(active.minGainDB, active.targetDB - speechDB))
                    if desired > gainDB {
                        gainDB = min(desired, gainDB + active.riseDBPerSec * dt)
                    } else {
                        gainDB = max(desired, gainDB - active.fallDBPerSec * dt)
                    }
                }
                // Nobody speaking: hold the gain
            }
            let target = powf(10, gainDB / 20)
            gain += (target - gain) * aGain
            x[i] = s * gain
        }
        gainBits.store(gainDB.bitPattern, ordering: .relaxed)
    }
}

/// Wraps AGCProcessor as an in-process audio unit so it can be inserted into the AVAudioEngine chain like a system effect.
final class AGCAudioUnit: AUAudioUnit {
    static let componentDescription = AudioComponentDescription(
        componentType: kAudioUnitType_Effect,
        componentSubType: 0x7161_6763,      // 'qagc'
        componentManufacturer: 0x5154_6E67, // 'QTng'
        componentFlags: 0, componentFlagsMask: 0)

    /// In-process registration; needed only once.
    static let registered: Void = {
        AUAudioUnit.registerSubclass(AGCAudioUnit.self, as: componentDescription, name: "QingTing: AGC", version: 1)
    }()

    let processor = AGCProcessor()
    private var inputBus: AUAudioUnitBus
    private var outputBus: AUAudioUnitBus
    private var _inputBusses: AUAudioUnitBusArray!
    private var _outputBusses: AUAudioUnitBusArray!
    private var scratch: UnsafeMutablePointer<Float>?
    private var scratchCapacity = 0

    override init(componentDescription: AudioComponentDescription, options: AudioComponentInstantiationOptions = []) throws {
        let format = AVAudioFormat(standardFormatWithSampleRate: 48000, channels: 1)!
        inputBus = try AUAudioUnitBus(format: format)
        outputBus = try AUAudioUnitBus(format: format)
        try super.init(componentDescription: componentDescription, options: options)
        _inputBusses = AUAudioUnitBusArray(audioUnit: self, busType: .input, busses: [inputBus])
        _outputBusses = AUAudioUnitBusArray(audioUnit: self, busType: .output, busses: [outputBus])
        maximumFramesToRender = 4096
    }

    override var inputBusses: AUAudioUnitBusArray { _inputBusses }
    override var outputBusses: AUAudioUnitBusArray { _outputBusses }
    override var canProcessInPlace: Bool { true }

    override func allocateRenderResources() throws {
        try super.allocateRenderResources()
        scratch?.deallocate()
        scratchCapacity = Int(maximumFramesToRender) * Int(outputBus.format.channelCount)
        scratch = .allocate(capacity: scratchCapacity)
        processor.reset(sampleRate: outputBus.format.sampleRate)
    }

    override func deallocateRenderResources() {
        super.deallocateRenderResources()
        scratch?.deallocate()
        scratch = nil
    }

    override var internalRenderBlock: AUInternalRenderBlock {
        let processor = processor
        // The render block must not touch mutable properties of self, so fetch the buffer pointer through a closure
        let getScratch = { [unowned self] in (self.scratch, self.scratchCapacity) }
        return { _, timestamp, frameCount, _, outputData, _, pullInputBlock in
            guard let pullInputBlock else { return kAudioUnitErr_NoConnection }
            let list = UnsafeMutableAudioBufferListPointer(outputData)
            // Use our own buffer when downstream did not provide one
            if list.first?.mData == nil {
                let (buf, cap) = getScratch()
                guard let buf else { return kAudioUnitErr_Uninitialized }
                let per = Int(frameCount)
                for i in 0..<list.count where (i + 1) * per <= cap {
                    list[i].mData = UnsafeMutableRawPointer(buf + i * per)
                    list[i].mDataByteSize = UInt32(per * MemoryLayout<Float>.size)
                }
            }
            var flags = AudioUnitRenderActionFlags()
            let status = pullInputBlock(&flags, timestamp, frameCount, 0, outputData)
            guard status == noErr else { return status }
            // The chain is mono; with several channels a shared processor would make them interfere, so process the first and copy it
            if let p = list.first?.mData?.assumingMemoryBound(to: Float.self) {
                processor.process(p, count: Int(frameCount))
                for i in 1..<max(1, list.count) {
                    list[i].mData?.assumingMemoryBound(to: Float.self).update(from: p, count: Int(frameCount))
                }
            }
            return noErr
        }
    }
}
