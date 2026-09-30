import AVFoundation
import AudioToolbox
import Synchronization

/// 语音自动增益（AGC）：只在检测到人声时测量响度，把人声慢慢拉到目标电平；
/// 停顿时增益保持不动，不会把底噪放大。放在降噪之后，解决老师转身、走动造成的忽大忽小。
final class AGCProcessor: @unchecked Sendable {
    struct Settings {
        var targetDB: Float = -22      // 人声目标电平（dBFS RMS）
        var maxGainDB: Float = 24      // 最多放大
        var minGainDB: Float = -12     // 最多衰减
        var riseDBPerSec: Float = 6    // 声音变小时增益上升速度
        var fallDBPerSec: Float = 15   // 声音变大时增益下降速度（快一点，避免刺耳）
        var integrationSec: Float = 0.4 // 人声响度的积分时间
    }

    private let enabledFlag = Atomic<Bool>(true)
    private let settingsLock = Mutex(Settings())
    /// 当前增益（dB），给界面显示
    private let gainBits = Atomic<UInt32>(Float(0).bitPattern)

    var currentGainDB: Float { Float(bitPattern: gainBits.load(ordering: .relaxed)) }
    func setEnabled(_ on: Bool) { enabledFlag.store(on, ordering: .relaxed) }
    func update(_ change: (inout Settings) -> Void) { settingsLock.withLock { change(&$0) } }

    // ---- 以下状态只在渲染线程访问
    private var sampleRate: Float = 48000
    private var power: Float = 1e-8         // 约 10ms 时间常数的短时功率
    private var floorDB: Float = -60        // 底噪跟踪
    private var speechDB: Float = -26       // 人声响度（约 400ms 积分，只在说话时更新）
    private var gainDB: Float = 0
    private var gain: Float = 1             // 逐样本平滑后的线性增益
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

    /// 原地处理单声道样本。
    func process(_ x: UnsafeMutablePointer<Float>, count: Int) {
        guard enabledFlag.load(ordering: .relaxed) else {
            // 关闭时把增益平滑地回到 0dB
            for i in 0..<count {
                gain += (1 - gain) * 0.001
                x[i] *= gain
            }
            gainDB = 20 * log10(max(gain, 1e-6))
            return
        }
        let aPow = 1 - exp(-1 / (0.010 * sampleRate))
        let aGain = 1 - exp(-1 / (0.020 * sampleRate))
        let step = Int(sampleRate * 0.005)   // 每 5ms 更新一次控制量
        let dt: Float = 0.005
        for i in 0..<count {
            let s = x[i]
            power += (s * s - power) * aPow
            counter += 1
            if counter >= step {
                counter = 0
                if let s = settingsLock.withLockIfAvailable({ $0 }) { active = s }
                let level = 10 * log10(max(power, 1e-12))
                // 底噪：下降立刻跟上，上升很慢（3dB/s），这样人声不会被当成底噪
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
                // 没人说话：增益保持
            }
            let target = powf(10, gainDB / 20)
            gain += (target - gain) * aGain
            x[i] = s * gain
        }
        gainBits.store(gainDB.bitPattern, ordering: .relaxed)
    }
}

/// 把 AGCProcessor 包成进程内 AU，这样能像系统效果器一样插进 AVAudioEngine 的处理链。
final class AGCAudioUnit: AUAudioUnit {
    static let componentDescription = AudioComponentDescription(
        componentType: kAudioUnitType_Effect,
        componentSubType: 0x7161_6763,      // 'qagc'
        componentManufacturer: 0x5154_6E67, // 'QTng'
        componentFlags: 0, componentFlagsMask: 0)

    /// 进程内注册，只需一次。
    static let registered: Void = {
        AUAudioUnit.registerSubclass(AGCAudioUnit.self, as: componentDescription, name: "清听: AGC", version: 1)
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
        // 渲染块里不能碰 self 的可变属性，先把缓冲指针取出来
        let getScratch = { [unowned self] in (self.scratch, self.scratchCapacity) }
        return { _, timestamp, frameCount, _, outputData, _, pullInputBlock in
            guard let pullInputBlock else { return kAudioUnitErr_NoConnection }
            let list = UnsafeMutableAudioBufferListPointer(outputData)
            // 下游没给缓冲时用自己的
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
            // 单声道链路；多声道时各声道用同一个处理器会互相干扰，这里只处理第一个并复制
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
