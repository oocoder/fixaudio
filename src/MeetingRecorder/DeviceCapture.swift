import AVFoundation
import AudioToolbox
import CoreAudio
import Foundation

/// Captures a single Core Audio input device to a lossless .caf file via its own
/// AVAudioEngine. Opened as a plain input-only stream (no Voice Processing).
final class DeviceCapture {
    private let deviceName: String
    private let engine = AVAudioEngine()
    private let fileLock = NSLock()
    private var file: AVAudioFile?
    private(set) var peak: Float = 0
    private(set) var frameCount: AVAudioFramePosition = 0

    init(deviceName: String) {
        self.deviceName = deviceName
    }

    func start(writingTo url: URL) throws {
        guard let deviceID = AudioDevices.inputID(named: deviceName) else {
            throw RecorderError.missingDevice(deviceName)
        }

        // Capture the device raw, without Apple Voice Processing. Voice
        // Processing is a full-duplex acoustic echo canceller that needs a
        // valid echo reference (audio playing out the speakers). A capture-
        // only recorder provides none, so the AEC cancels the microphone's
        // own signal and deletes the local voice from the recording. The
        // physical microphone and BlackHole are therefore both opened as
        // plain input-only streams. Voice Isolation for the live call is
        // owned by the meeting application and the system mic modes in
        // Control Center, not by this recorder.
        let input = engine.inputNode
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

        let format = input.outputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0 else {
            throw RecorderError.invalidFormat(deviceName)
        }

        let captureFile = try AVAudioFile(forWriting: url, settings: format.settings)
        fileLock.lock()
        file = captureFile
        peak = 0
        frameCount = 0
        fileLock.unlock()

        input.installTap(onBus: 0, bufferSize: 1024, format: format) { [weak self] buffer, _ in
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

    func stop() {
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        fileLock.lock()
        file = nil
        fileLock.unlock()
    }
}