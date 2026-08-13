import CoreAudio
import Foundation

/// Locates Core Audio devices by display name.
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