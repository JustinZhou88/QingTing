import CoreAudio
import Foundation

struct AudioDevice: Identifiable, Hashable {
    let id: AudioDeviceID
    let uid: String
    let name: String
    let inputChannels: Int
    let outputChannels: Int
    let transport: UInt32

    var isBuiltIn: Bool { transport == kAudioDeviceTransportTypeBuiltIn }
    var isBluetooth: Bool {
        transport == kAudioDeviceTransportTypeBluetooth || transport == kAudioDeviceTransportTypeBluetoothLE
    }
    var looksLikeHearingAid: Bool {
        name.contains("助听") || name.localizedCaseInsensitiveContains("hearing")
    }
    var looksLikeIPhone: Bool { name.localizedCaseInsensitiveContains("iPhone") }
}

/// Thin wrapper around the CoreAudio HAL.
enum AudioDevices {
    static func all() -> [AudioDevice] {
        let ids: [AudioDeviceID] = array(AudioObjectID(kAudioObjectSystemObject), kAudioHardwarePropertyDevices)
        return ids.compactMap { id in
            guard let uid = string(id, kAudioDevicePropertyDeviceUID) else { return nil }
            // Private aggregate devices that AVAudioEngine creates for itself; not offered to the user
            if uid.hasPrefix("CADefaultDeviceAggregate") || (string(id, kAudioObjectPropertyName) ?? "").hasPrefix("CADefaultDeviceAggregate") {
                return nil
            }
            return AudioDevice(
                id: id, uid: uid,
                name: string(id, kAudioObjectPropertyName) ?? uid,
                inputChannels: channelCount(id, scope: kAudioObjectPropertyScopeInput),
                outputChannels: channelCount(id, scope: kAudioObjectPropertyScopeOutput),
                transport: scalar(id, kAudioDevicePropertyTransportType) ?? 0)
        }
    }

    static var defaultOutputID: AudioDeviceID? { scalar(AudioObjectID(kAudioObjectSystemObject), kAudioHardwarePropertyDefaultOutputDevice) }
    static var defaultInputID: AudioDeviceID? { scalar(AudioObjectID(kAudioObjectSystemObject), kAudioHardwarePropertyDefaultInputDevice) }

    /// One-way latency on the device side in seconds: hardware latency + safety offset + stream latency + one IO buffer.
    static func latency(_ id: AudioDeviceID, input: Bool) -> Double {
        let scope = input ? kAudioObjectPropertyScopeInput : kAudioObjectPropertyScopeOutput
        let rate: Float64 = scalar(id, kAudioDevicePropertyNominalSampleRate) ?? 48000
        let device: UInt32 = scalar(id, kAudioDevicePropertyLatency, scope: scope) ?? 0
        let safety: UInt32 = scalar(id, kAudioDevicePropertySafetyOffset, scope: scope) ?? 0
        let buffer: UInt32 = scalar(id, kAudioDevicePropertyBufferFrameSize) ?? 0
        let streams: [AudioStreamID] = array(id, kAudioDevicePropertyStreams, scope: scope)
        let stream: UInt32 = streams.first.flatMap { scalar($0, kAudioStreamPropertyLatency) } ?? 0
        return Double(device + safety + stream + buffer) / rate
    }

    /// Shrinks the device IO buffer as far as possible to cut latency. Bluetooth devices may refuse; failure is ignored.
    @discardableResult
    static func setBufferFrameSize(_ id: AudioDeviceID, _ frames: UInt32) -> Bool {
        var addr = address(kAudioDevicePropertyBufferFrameSize)
        var value = frames
        return AudioObjectSetPropertyData(id, &addr, 0, nil, UInt32(MemoryLayout<UInt32>.size), &value) == noErr
    }

    static func sampleRate(_ id: AudioDeviceID) -> Double {
        scalar(id, kAudioDevicePropertyNominalSampleRate) ?? 0
    }

    /// Called on the main thread when devices come and go (e.g. hearing aids disconnecting or reconnecting).
    static func onDeviceListChange(_ handler: @escaping () -> Void) {
        var addr = address(kAudioHardwarePropertyDevices)
        AudioObjectAddPropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &addr, .main) { _, _ in handler() }
    }

    // MARK: - Property access

    private static func address(_ selector: AudioObjectPropertySelector,
                                scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: kAudioObjectPropertyElementMain)
    }

    private static func scalar<T>(_ id: AudioObjectID, _ selector: AudioObjectPropertySelector,
                                  scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal) -> T? {
        var addr = address(selector, scope: scope)
        var size = UInt32(MemoryLayout<T>.size)
        let p = UnsafeMutableRawPointer.allocate(byteCount: Int(size), alignment: MemoryLayout<T>.alignment)
        defer { p.deallocate() }
        guard AudioObjectGetPropertyData(id, &addr, 0, nil, &size, p) == noErr else { return nil }
        return p.load(as: T.self)
    }

    private static func array<T>(_ id: AudioObjectID, _ selector: AudioObjectPropertySelector,
                                 scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal) -> [T] {
        var addr = address(selector, scope: scope)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(id, &addr, 0, nil, &size) == noErr, size > 0 else { return [] }
        return [T](unsafeUninitializedCapacity: Int(size) / MemoryLayout<T>.stride) { buf, count in
            count = 0
            if AudioObjectGetPropertyData(id, &addr, 0, nil, &size, buf.baseAddress!) == noErr {
                count = Int(size) / MemoryLayout<T>.stride
            }
        }
    }

    private static func string(_ id: AudioObjectID, _ selector: AudioObjectPropertySelector) -> String? {
        var addr = address(selector)
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        var ref: Unmanaged<CFString>?
        guard AudioObjectGetPropertyData(id, &addr, 0, nil, &size, &ref) == noErr, let ref else { return nil }
        return ref.takeRetainedValue() as String
    }

    private static func channelCount(_ id: AudioObjectID, scope: AudioObjectPropertyScope) -> Int {
        var addr = address(kAudioDevicePropertyStreamConfiguration, scope: scope)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(id, &addr, 0, nil, &size) == noErr, size > 0 else { return 0 }
        let raw = UnsafeMutableRawPointer.allocate(byteCount: Int(size), alignment: MemoryLayout<AudioBufferList>.alignment)
        defer { raw.deallocate() }
        guard AudioObjectGetPropertyData(id, &addr, 0, nil, &size, raw) == noErr else { return 0 }
        let list = UnsafeMutableAudioBufferListPointer(raw.assumingMemoryBound(to: AudioBufferList.self))
        return list.reduce(0) { $0 + Int($1.mNumberChannels) }
    }
}
