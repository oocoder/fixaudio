import CoreAudio
import Foundation
import AudioToolbox
import AVFAudio

// MARK: - Helpers

func check(_ status: OSStatus, _ context: String) {
    if status != noErr {
        print("ERROR: \(context) failed: \(status) (\(fourCC(status)))")
        exit(1)
    }
}

func fourCC(_ code: OSStatus) -> String {
    let bytes: [UInt8] = [
        UInt8((code >> 24) & 0xFF),
        UInt8((code >> 16) & 0xFF),
        UInt8((code >> 8) & 0xFF),
        UInt8(code & 0xFF)
    ]
    return String(bytes: bytes, encoding: .ascii) ?? "\(code)"
}

func transportName(_ type: UInt32) -> String {
    switch type {
    case kAudioDeviceTransportTypeBuiltIn: return "Built-in"
    case kAudioDeviceTransportTypeUSB: return "USB"
    case kAudioDeviceTransportTypeBluetooth: return "Bluetooth"
    case kAudioDeviceTransportTypeBluetoothLE: return "BLE"
    case kAudioDeviceTransportTypeHDMI: return "HDMI"
    case kAudioDeviceTransportTypeThunderbolt: return "Thunderbolt"
    case kAudioDeviceTransportTypeVirtual: return "Virtual"
    case kAudioDeviceTransportTypeUnknown: return "Unknown"
    default: return "Other(\(type))"
    }
}

// MARK: - Device enumeration

struct InputDevice {
    let id: AudioDeviceID
    let name: String
    let transportType: UInt32
    var isBluetooth: Bool { transportType == kAudioDeviceTransportTypeBluetooth }
}

func listInputDevices() -> [InputDevice] {
    var size: UInt32 = 0
    var addr = AudioObjectPropertyAddress(
        mSelector: kAudioHardwarePropertyDevices,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain
    )
    guard AudioObjectGetPropertyDataSize(
        AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size
    ) == noErr else { return [] }

    let count = Int(size) / MemoryLayout<AudioDeviceID>.size
    var ids = [AudioDeviceID](repeating: 0, count: count)
    guard AudioObjectGetPropertyData(
        AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size, &ids
    ) == noErr else { return [] }

    var result: [InputDevice] = []
    for id in ids {
        var cfgSize: UInt32 = 0
        var cfgAddr = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreamConfiguration,
            mScope: kAudioDevicePropertyScopeInput,
            mElement: 0
        )
        guard AudioObjectGetPropertyDataSize(id, &cfgAddr, 0, nil, &cfgSize) == noErr,
              cfgSize > 0 else { continue }

        var nameBytes = [CChar](repeating: 0, count: 256)
        var nameSize: UInt32 = 256
        var nameAddr = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyDeviceName,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        AudioObjectGetPropertyData(id, &nameAddr, 0, nil, &nameSize, &nameBytes)
        let name = String(cString: nameBytes)

        var transport: UInt32 = 0
        var trSize: UInt32 = 4
        var trAddr = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyTransportType,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        AudioObjectGetPropertyData(id, &trAddr, 0, nil, &trSize, &transport)

        result.append(InputDevice(id: id, name: name, transportType: transport))
    }
    return result
}

// MARK: - Format printing

func printFormat(_ label: String, _ fmt: AudioStreamBasicDescription) {
    let isFloat = fmt.mFormatFlags & kAudioFormatFlagIsFloat != 0
    let kind = isFloat ? "float" : "int"
    print("  \(label): \(Int(fmt.mSampleRate)) Hz, \(fmt.mChannelsPerFrame) ch, \(fmt.mBitsPerChannel)-bit \(kind)")
}

// MARK: - AUHAL Capture

final class AUHALCapture {
    private var unit: AudioUnit?
    private let deviceID: AudioDeviceID
    private(set) var format = AudioStreamBasicDescription()
    private var extFile: ExtAudioFileRef?
    private var totalFrames: UInt64 = 0
    private let lock = NSLock()
    private var renderErrors = 0

    init(deviceID: AudioDeviceID) {
        self.deviceID = deviceID
    }

    func start(outputURL: URL, duration: Int) {
        // 1. Create the HAL Output AudioUnit
        var desc = AudioComponentDescription(
            componentType: kAudioUnitType_Output,
            componentSubType: kAudioUnitSubType_HALOutput,
            componentManufacturer: kAudioUnitManufacturer_Apple,
            componentFlags: 0,
            componentFlagsMask: 0
        )
        guard let comp = AudioComponentFindNext(nil, &desc) else {
            print("ERROR: HALOutput component not found")
            exit(1)
        }
        var au: AudioUnit?
        check(AudioComponentInstanceNew(comp, &au), "AudioComponentInstanceNew")
        unit = au!

        // 2. Enable input (bus 1), disable output (bus 0)
        var on: UInt32 = 1
        check(AudioUnitSetProperty(au!, kAudioOutputUnitProperty_EnableIO,
              kAudioUnitScope_Input, 1, &on, 4), "EnableIO input")
        var off: UInt32 = 0
        check(AudioUnitSetProperty(au!, kAudioOutputUnitProperty_EnableIO,
              kAudioUnitScope_Output, 0, &off, 4), "DisableIO output")

        // 3. Set the target device
        var devID = deviceID
        check(AudioUnitSetProperty(au!, kAudioOutputUnitProperty_CurrentDevice,
              kAudioUnitScope_Global, 0, &devID, 4), "CurrentDevice")

        // 4. Read the device's actual input format
        var fmtSize: UInt32 = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        check(AudioUnitGetProperty(au!, kAudioUnitProperty_StreamFormat,
              kAudioUnitScope_Input, 1, &format, &fmtSize), "Get StreamFormat input")
        printFormat("Device format", format)

        // 4b. Set the format on the OUTPUT scope of element 1.
        //     This tells AUHAL what format to deliver to our callback.
        check(AudioUnitSetProperty(au!, kAudioUnitProperty_StreamFormat,
              kAudioUnitScope_Output, 1, &format, fmtSize), "Set StreamFormat output bus 1")

        // 5. Create a WAV output file (16-bit PCM, same rate/channels)
        var outFmt = AudioStreamBasicDescription(
            mSampleRate: format.mSampleRate,
            mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kAudioFormatFlagIsPacked | kAudioFormatFlagIsSignedInteger,
            mBytesPerPacket: UInt32(format.mChannelsPerFrame) * 2,
            mFramesPerPacket: 1,
            mBytesPerFrame: UInt32(format.mChannelsPerFrame) * 2,
            mChannelsPerFrame: format.mChannelsPerFrame,
            mBitsPerChannel: 16,
            mReserved: 0
        )
        var ef: ExtAudioFileRef?
        check(ExtAudioFileCreateWithURL(
            outputURL as CFURL, kAudioFileWAVEType,
            &outFmt, nil, AudioFileFlags.eraseFile.rawValue, &ef
        ), "ExtAudioFileCreateWithURL")

        var clientFmt = format
        check(ExtAudioFileSetProperty(
            ef!, kExtAudioFileProperty_ClientDataFormat,
            UInt32(MemoryLayout<AudioStreamBasicDescription>.size), &clientFmt
        ), "Set client format")
        extFile = ef

        // 6. Register the input callback
        let refCon = Unmanaged.passUnretained(self).toOpaque()
        var cb = AURenderCallbackStruct(
            inputProc: { refCon, flags, ts, bus, frames, _ in
                let cap = Unmanaged<AUHALCapture>.fromOpaque(refCon).takeUnretainedValue()
                return cap.render(flags, ts, bus, frames)
            },
            inputProcRefCon: refCon
        )
        check(AudioUnitSetProperty(au!, kAudioOutputUnitProperty_SetInputCallback,
              kAudioUnitScope_Global, 0, &cb, UInt32(MemoryLayout<AURenderCallbackStruct>.size)),
              "SetInputCallback")

        // 7. Initialize + start
        check(AudioUnitInitialize(au!), "AudioUnitInitialize")
        check(AudioOutputUnitStart(au!), "AudioOutputUnitStart")

        print("  Capturing for \(duration) seconds… (speak into the mic!)")

        Thread.sleep(forTimeInterval: TimeInterval(duration))

        // 8. Stop
        AudioOutputUnitStop(au!)
        AudioUnitUninitialize(au!)
        ExtAudioFileDispose(ef!)

        lock.lock()
        let frames = totalFrames
        let errors = renderErrors
        lock.unlock()

        print("  Stopped: \(frames) frames, \(errors) render errors")
        print("  File: \(outputURL.path)")
        let fileSize = (try? FileManager.default.attributesOfItem(atPath: outputURL.path)[.size] as? Int) ?? 0
        print("  Size: \(fileSize) bytes")
    }

    private func render(
        _ flags: UnsafeMutablePointer<AudioUnitRenderActionFlags>,
        _ ts: UnsafePointer<AudioTimeStamp>,
        _ bus: UInt32,
        _ frames: UInt32
    ) -> OSStatus {
        let bufSize = Int(frames) * Int(format.mBytesPerFrame)
        let ptr = malloc(bufSize)!
        defer { free(ptr) }

        // Pre-fill with 0.5 to test if AudioUnitRender writes to our buffer
        let fp = ptr.assumingMemoryBound(to: Float.self)
        for i in 0..<min(Int(frames), 64) { fp[i] = 0.5 }

        var bl = AudioBufferList(
            mNumberBuffers: 1,
            mBuffers: AudioBuffer(
                mNumberChannels: format.mChannelsPerFrame,
                mDataByteSize: UInt32(bufSize),
                mData: ptr
            )
        )

        if totalFrames == 0 {
            print("  before: [\(fp[0]), \(fp[1]), \(fp[2]), \(fp[3])]")
            print("  ABL size=\(MemoryLayout<AudioBufferList>.size) stride=\(MemoryLayout<AudioBufferList>.stride)")
        }

        let st = AudioUnitRender(unit!, flags, ts, bus, frames, &bl)

        if totalFrames == 0 {
            print("  after:  [\(fp[0]), \(fp[1]), \(fp[2]), \(fp[3])]")
            print("  render status: \(st) bus=\(bus) frames=\(frames)")
        }

        if st == noErr {
            ExtAudioFileWrite(extFile!, frames, &bl)
            lock.lock()
            totalFrames += UInt64(frames)
            lock.unlock()
        } else {
            lock.lock()
            renderErrors += 1
            lock.unlock()
            if renderErrors <= 3 {
                print("  AudioUnitRender error: \(st) (\(fourCC(st)))")
            }
        }
        return st
    }
}

// MARK: - Main

// Request mic permission first
let permSem = DispatchSemaphore(value: 0)
var micGranted = false
if #available(macOS 14.0, *) {
    AVAudioApplication.requestRecordPermission { granted in
        micGranted = granted
        permSem.signal()
    }
    permSem.wait()
    print("Mic permission: \(micGranted ? "granted" : "DENIED")")
    if !micGranted {
        print("ERROR: Microphone permission denied.")
        print("Grant it in System Settings > Privacy & Security > Microphone.")
        exit(1)
    }
}

let devices = listInputDevices()
if devices.isEmpty {
    print("No input devices found.")
    exit(1)
}

print("Input devices:")
for (i, d) in devices.enumerated() {
    let bt = d.isBluetooth ? " ← Bluetooth" : ""
    print("  \(i): \(d.name)  [\(transportName(d.transportType))]\(bt)")
}

let args = CommandLine.arguments
if args.count < 2 {
    print("""

    Usage:
      audio-unit-capture <device-index> [seconds] [output.wav]

    Example:
      audio-unit-capture 2 5 bluetooth-test.wav
    """)
    exit(0)
}

guard let idx = Int(args[1]), idx < devices.count else {
    print("Invalid device index: \(args[1])")
    exit(1)
}

let duration = args.count > 2 ? (Int(args[2]) ?? 5) : 5
let outPath = args.count > 3 ? args[3] : "capture.wav"
let outURL = URL(fileURLWithPath: outPath).standardizedFileURL

let dev = devices[idx]
print("\nTarget: \(dev.name) [\(transportName(dev.transportType))]")
if dev.isBluetooth {
    print("  ⚠️  Bluetooth device — AVAudioEngine crashes here; testing AUHAL…")
}
print("")

let cap = AUHALCapture(deviceID: dev.id)
cap.start(outputURL: outURL, duration: duration)

print("\n✅ Done — playback the WAV to verify audio was captured.")