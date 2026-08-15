import CoreAudio
import Foundation

/// Locates Core Audio devices by display name and enumerates available mics.
enum AudioDevices {
    static func id(named wantedName: String) -> AudioDeviceID? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var byteCount: UInt32 = 0
        let system = AudioObjectID(kAudioObjectSystemObject)
        guard AudioObjectGetPropertyDataSize(system, &address, 0, nil, &byteCount) == noErr else {
            return nil
        }
        var devices = [AudioDeviceID](
            repeating: 0,
            count: Int(byteCount) / MemoryLayout<AudioDeviceID>.size
        )
        guard AudioObjectGetPropertyData(system, &address, 0, nil, &byteCount, &devices) == noErr else {
            return nil
        }
        return devices.first { name(of: $0) == wantedName }
    }

    /// Like id(named:) but returns only a device that actually has input
    /// channels. Bluetooth headsets expose two entries with the same name
    /// (A2DP output-only + HFP with a mic); id(named:) may pick the A2DP one,
    /// which can't be used as an input — this picks the one with input.
    static func inputID(named wantedName: String) -> AudioDeviceID? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var byteCount: UInt32 = 0
        let system = AudioObjectID(kAudioObjectSystemObject)
        guard AudioObjectGetPropertyDataSize(system, &address, 0, nil, &byteCount) == noErr else {
            return nil
        }
        var devices = [AudioDeviceID](
            repeating: 0,
            count: Int(byteCount) / MemoryLayout<AudioDeviceID>.size
        )
        guard AudioObjectGetPropertyData(system, &address, 0, nil, &byteCount, &devices) == noErr else {
            return nil
        }
        return devices.first { name(of: $0) == wantedName && hasInput($0) }
    }

    /// Names of currently-available **microphones only**: devices that actually
    /// have input CHANNELS (> 0), are not aggregates (aggregates reintroduce the
    /// Core Audio stall the recorder avoids, and "Meeting Recording" bundles
    /// BlackHole), and are not "BlackHole 2ch" (the remote side). Deduped by
    /// name — Bluetooth headsets expose multiple profiles with the same name.
    static func inputDeviceNames() -> [String] {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var byteCount: UInt32 = 0
        let system = AudioObjectID(kAudioObjectSystemObject)
        guard AudioObjectGetPropertyDataSize(system, &address, 0, nil, &byteCount) == noErr else {
            return []
        }
        var devices = [AudioDeviceID](
            repeating: 0,
            count: Int(byteCount) / MemoryLayout<AudioDeviceID>.size
        )
        guard AudioObjectGetPropertyData(system, &address, 0, nil, &byteCount, &devices) == noErr else {
            return []
        }
        var seen = Set<String>()
        var names: [String] = []
        for d in devices {
            guard hasInput(d), !isAggregate(d), let nm = name(of: d), nm != "BlackHole 2ch" else { continue }
            if !seen.contains(nm) { seen.insert(nm); names.append(nm) }
        }
        return names
    }

    /// True if the device has real input channels (not just an empty input
    /// stream config, which output-only devices like speakers report).
    private static func hasInput(_ device: AudioDeviceID) -> Bool {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreamConfiguration,
            mScope: kAudioDevicePropertyScopeInput,
            mElement: kAudioObjectPropertyElementMain
        )
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(device, &address, 0, nil, &size) == noErr, size > 0 else { return false }
        let layout = UnsafeMutableRawPointer.allocate(byteCount: Int(size), alignment: MemoryLayout<AudioBufferList>.alignment)
        defer { layout.deallocate() }
        guard AudioObjectGetPropertyData(device, &address, 0, nil, &size, layout) == noErr else { return false }
        let list = layout.assumingMemoryBound(to: AudioBufferList.self)
        var channels = 0
        for buffer in UnsafeMutableAudioBufferListPointer(list) {
            channels += Int(buffer.mNumberChannels)
        }
        return channels > 0
    }

    private static func isAggregate(_ device: AudioDeviceID) -> Bool {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioObjectPropertyClass,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var cls: AudioClassID = 0
        var size = UInt32(MemoryLayout<AudioClassID>.size)
        return AudioObjectGetPropertyData(device, &address, 0, nil, &size, &cls) == noErr
            && cls == kAudioAggregateDeviceClassID
    }

    private static func name(of device: AudioDeviceID) -> String? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioObjectPropertyName,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        let storageSize = MemoryLayout<Unmanaged<CFString>?>.size
        let storage = UnsafeMutableRawPointer.allocate(
            byteCount: storageSize,
            alignment: MemoryLayout<Unmanaged<CFString>?>.alignment
        )
        defer { storage.deallocate() }
        storage.initializeMemory(as: UInt8.self, repeating: 0, count: storageSize)
        var size = UInt32(storageSize)
        guard AudioObjectGetPropertyData(device, &address, 0, nil, &size, storage) == noErr,
              let value = storage.load(as: Unmanaged<CFString>?.self) else {
            return nil
        }
        return value.takeUnretainedValue() as String
    }
}