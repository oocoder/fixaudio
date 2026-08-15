import AVFoundation
import AudioToolbox
import CoreAudio
import Foundation

/// Captures a single Core Audio input device to a lossless .caf file.
///
/// Two capture paths:
/// - **AVAudioEngine** (default): uses `installTap` on `inputNode`. Works for
///   wired and built-in mics. Crashes on Bluetooth headsets because the
///   aggregate device forces HFP 16 kHz, causing a tap-format mismatch.
/// - **AUHAL** (`useAUHAL: true`): uses `kAudioUnitSubType_HALOutput` with an
///   `AURenderCallback`. No aggregate device, no `installTap` — works with
///   Bluetooth headsets. Verified in `experiments/audio-unit-capture/`.
final class DeviceCapture {
    private let deviceName: String
    private let useSystemDefault: Bool
    private let useAUHAL: Bool

    // AVAudioEngine path
    private let engine = AVAudioEngine()
    private var file: AVAudioFile?

    // AUHAL path
    private var unit: AudioUnit?
    private var extFile: ExtAudioFileRef?
    private var auhalFormat = AudioStreamBasicDescription()

    // Shared
    private let fileLock = NSLock()
    private(set) var peak: Float = 0
    private(set) var frameCount: AVAudioFramePosition = 0

    init(deviceName: String, useSystemDefault: Bool = false, useAUHAL: Bool = false) {
        self.deviceName = deviceName
        self.useSystemDefault = useSystemDefault
        self.useAUHAL = useAUHAL
    }

    func start(writingTo url: URL) throws {
        if useAUHAL {
            try startAUHAL(writingTo: url)
        } else {
            try startAVAudioEngine(writingTo: url)
        }
    }

    func stop() {
        if useAUHAL {
            stopAUHAL()
        } else {
            stopAVAudioEngine()
        }
    }

    // MARK: - AVAudioEngine path

    private func startAVAudioEngine(writingTo url: URL) throws {
        let input = engine.inputNode
        let captureFormat: AVAudioFormat

        if !useSystemDefault {
            guard let deviceID = AudioDevices.inputID(named: deviceName) else {
                throw RecorderError.missingDevice(deviceName)
            }
            guard let audioUnit = input.audioUnit else {
                throw RecorderError.invalidFormat(deviceName)
            }
            var selectedDevice = deviceID
            let status = AudioUnitSetProperty(
                audioUnit,
                kAudioOutputUnitProperty_CurrentDevice,
                kAudioUnitScope_Global,
                0,
                &selectedDevice,
                UInt32(MemoryLayout<AudioDeviceID>.size)
            )
            guard status == noErr else {
                throw RecorderError.coreAudio("Selecting \(deviceName)", status)
            }
            // After CurrentDevice, set the audioUnit's input element format
            // to the device's actual format. The inputNode's format is stale
            // (still the system default's), so installTap would crash.
            var devAsbd = AudioStreamBasicDescription()
            var devFmtSize = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
            var devFmtAddr = AudioObjectPropertyAddress(
                mSelector: kAudioDevicePropertyStreamFormat,
                mScope: kAudioDevicePropertyScopeInput,
                mElement: 0
            )
            guard AudioObjectGetPropertyData(deviceID, &devFmtAddr, 0, nil, &devFmtSize, &devAsbd) == noErr,
                  let devFormat = AVAudioFormat(streamDescription: &devAsbd) else {
                throw RecorderError.invalidFormat(deviceName)
            }
            _ = AudioUnitSetProperty(
                audioUnit, kAudioUnitProperty_StreamFormat,
                kAudioUnitScope_Input, 1,
                &devAsbd, UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
            )
            captureFormat = devFormat
        } else {
            captureFormat = input.outputFormat(forBus: 0)
        }

        guard captureFormat.sampleRate > 0, captureFormat.channelCount > 0 else {
            throw RecorderError.invalidFormat(deviceName)
        }

        let captureFile = try AVAudioFile(forWriting: url, settings: captureFormat.settings)
        fileLock.lock()
        file = captureFile
        peak = 0
        frameCount = 0
        fileLock.unlock()

        input.installTap(onBus: 0, bufferSize: 1024, format: captureFormat) { [weak self] buffer, _ in
            guard let self else { return }
            self.fileLock.lock()
            defer { self.fileLock.unlock() }
            guard let file = self.file else { return }
            do {
                try file.write(from: buffer)
                self.frameCount += AVAudioFramePosition(buffer.frameLength)
                if let channels = buffer.floatChannelData {
                    for channel in 0..<Int(buffer.format.channelCount) {
                        for frame in 0..<Int(buffer.frameLength) {
                            self.peak = max(self.peak, abs(channels[channel][frame]))
                        }
                    }
                }
            } catch {
                NSLog("Meeting Recorder write error for %@: %@", self.deviceName, error.localizedDescription)
            }
        }

        engine.prepare()
        do {
            try engine.start()
        } catch {
            input.removeTap(onBus: 0)
            fileLock.lock()
            file = nil
            fileLock.unlock()
            throw error
        }
    }

    private func stopAVAudioEngine() {
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        fileLock.lock()
        file = nil
        fileLock.unlock()
    }

    // MARK: - AUHAL path (for Bluetooth headsets)

    private func startAUHAL(writingTo url: URL) throws {
        guard let deviceID = AudioDevices.inputID(named: deviceName) else {
            throw RecorderError.missingDevice(deviceName)
        }

        // 1. Create the HAL Output AudioUnit
        var desc = AudioComponentDescription(
            componentType: kAudioUnitType_Output,
            componentSubType: kAudioUnitSubType_HALOutput,
            componentManufacturer: kAudioUnitManufacturer_Apple,
            componentFlags: 0,
            componentFlagsMask: 0
        )
        guard let comp = AudioComponentFindNext(nil, &desc) else {
            throw RecorderError.coreAudio("AUHAL component", -1)
        }
        var au: AudioUnit?
        try check(AudioComponentInstanceNew(comp, &au), "AudioComponentInstanceNew")
        unit = au!

        // 2. Enable input (bus 1), disable output (bus 0)
        var on: UInt32 = 1
        try check(AudioUnitSetProperty(au!, kAudioOutputUnitProperty_EnableIO,
              kAudioUnitScope_Input, 1, &on, 4), "EnableIO input")
        var off: UInt32 = 0
        try check(AudioUnitSetProperty(au!, kAudioOutputUnitProperty_EnableIO,
              kAudioUnitScope_Output, 0, &off, 4), "DisableIO output")

        // 3. Set the target device
        var devID = deviceID
        try check(AudioUnitSetProperty(au!, kAudioOutputUnitProperty_CurrentDevice,
              kAudioUnitScope_Global, 0, &devID, 4), "CurrentDevice")

        // 4. Read the device's input format
        var fmtSize: UInt32 = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        try check(AudioUnitGetProperty(au!, kAudioUnitProperty_StreamFormat,
              kAudioUnitScope_Input, 1, &auhalFormat, &fmtSize), "Get StreamFormat")

        guard auhalFormat.mSampleRate > 0, auhalFormat.mChannelsPerFrame > 0 else {
            throw RecorderError.invalidFormat(deviceName)
        }

        // 4b. Set format on the OUTPUT scope of element 1.
        //     Without this, AudioUnitRender returns -50 (paramErr).
        try check(AudioUnitSetProperty(au!, kAudioUnitProperty_StreamFormat,
              kAudioUnitScope_Output, 1, &auhalFormat, fmtSize), "Set StreamFormat output")

        // 5. Create ExtAudioFile (.caf, 32-bit float PCM — same as AVAudioFile path)
        var fileFmt = auhalFormat
        fileFmt.mFormatID = kAudioFormatLinearPCM
        fileFmt.mFormatFlags = kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked
        fileFmt.mBitsPerChannel = 32
        fileFmt.mBytesPerFrame = auhalFormat.mChannelsPerFrame * 4
        fileFmt.mBytesPerPacket = fileFmt.mBytesPerFrame
        fileFmt.mFramesPerPacket = 1

        var ef: ExtAudioFileRef?
        try check(ExtAudioFileCreateWithURL(
            url as CFURL, kAudioFileCAFType,
            &fileFmt, nil,
            AudioFileFlags.eraseFile.rawValue, &ef
        ), "ExtAudioFileCreateWithURL")

        var clientFmt = auhalFormat
        try check(ExtAudioFileSetProperty(
            ef!, kExtAudioFileProperty_ClientDataFormat,
            UInt32(MemoryLayout<AudioStreamBasicDescription>.size), &clientFmt
        ), "Set client format")
        extFile = ef

        fileLock.lock()
        peak = 0
        frameCount = 0
        fileLock.unlock()

        // 6. Register the input callback
        let refCon = Unmanaged.passUnretained(self).toOpaque()
        var cb = AURenderCallbackStruct(
            inputProc: { refCon, flags, ts, bus, frames, _ in
                let cap = Unmanaged<DeviceCapture>.fromOpaque(refCon).takeUnretainedValue()
                return cap.auhalRender(flags, ts, bus, frames)
            },
            inputProcRefCon: refCon
        )
        try check(AudioUnitSetProperty(au!, kAudioOutputUnitProperty_SetInputCallback,
              kAudioUnitScope_Global, 0, &cb, UInt32(MemoryLayout<AURenderCallbackStruct>.size)),
              "SetInputCallback")

        // 7. Initialize + start
        try check(AudioUnitInitialize(au!), "AudioUnitInitialize")
        try check(AudioOutputUnitStart(au!), "AudioOutputUnitStart")
    }

    private func auhalRender(
        _ flags: UnsafeMutablePointer<AudioUnitRenderActionFlags>,
        _ ts: UnsafePointer<AudioTimeStamp>,
        _ bus: UInt32,
        _ frames: UInt32
    ) -> OSStatus {
        let bufSize = Int(frames) * Int(auhalFormat.mBytesPerFrame)
        let ptr = malloc(bufSize)!
        defer { free(ptr) }

        var bl = AudioBufferList(
            mNumberBuffers: 1,
            mBuffers: AudioBuffer(
                mNumberChannels: auhalFormat.mChannelsPerFrame,
                mDataByteSize: UInt32(bufSize),
                mData: ptr
            )
        )

        let st = AudioUnitRender(unit!, flags, ts, bus, frames, &bl)
        if st == noErr {
            ExtAudioFileWrite(extFile!, frames, &bl)

            // Track peak and frame count
            let fp = ptr.assumingMemoryBound(to: Float.self)
            let n = Int(frames) * Int(auhalFormat.mChannelsPerFrame)
            fileLock.lock()
            frameCount += AVAudioFramePosition(frames)
            for i in 0..<n {
                let a = abs(fp[i])
                if a > peak { peak = a }
            }
            fileLock.unlock()
        } else {
            NSLog("Meeting Recorder AUHAL render error for %@: %d", deviceName, st)
        }
        return st
    }

private func stopAUHAL() {
        if let au = unit {
            AudioOutputUnitStop(au)
            AudioUnitUninitialize(au)
            AudioComponentInstanceDispose(au)
        }
        if let ef = extFile {
            ExtAudioFileDispose(ef)
        }
        unit = nil
        extFile = nil
    }

    private func check(_ status: OSStatus, _ context: String) throws {
        if status != noErr {
            throw RecorderError.coreAudio(context, status)
        }
    }
}