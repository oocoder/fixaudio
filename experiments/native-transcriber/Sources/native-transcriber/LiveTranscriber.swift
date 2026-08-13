import Foundation
import AVFoundation
import MLXAudioCore
import MLXAudioSTT

/// Live mic transcription experiment.
///
/// Goal: keep the audio-capture tap light (low UI / realtime pressure). The
/// tap only copies samples into a MonoRingBuffer. A background loop polls the
/// buffer and runs Parakeet on each fixed-size chunk. If inference is slower
/// than realtime, chunks accumulate in the buffer rather than blocking the tap
/// or the UI — the "delay queue." This is the opposite of running ASR on the
/// realtime thread.
///
/// NOTE: this is an experiment. The exact audio-array type expected by
/// `generate(audio:)` (assumed [Float] mono here) and Swift 6 Sendable rules
/// may need small adjustments on first build with Swift 6.2 / Xcode 26.
enum LiveTranscriber {
    static func run() async {
        let chunkSeconds: Double = 6.0
        let engine = AVAudioEngine()
        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0 else {
            print("error: no input format")
            return
        }
        let chunkFrames = Int(format.sampleRate * chunkSeconds)
        let ring = MonoRingBuffer(chunkFrames: chunkFrames)

        print("loading parakeet-tdt-0.6b-v3…")
        let model: ParakeetModel
        do {
            model = try await ParakeetModel.fromPretrained("mlx-community/parakeet-tdt-0.6b-v3")
        } catch {
            print("error loading model: \(error.localizedDescription)")
            return
        }

        input.installTap(onBus: 0, bufferSize: 1024, format: format) { buffer, _ in
            ring.append(buffer)
        }

        engine.prepare()
        do {
            try engine.start()
            print("listening… (chunk \(chunkSeconds)s, ctrl-C to stop)")
        } catch {
            print("engine start failed: \(error.localizedDescription)")
            return
        }

        // Inference loop on a background Task (off the realtime tap).
        let inference = Task {
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 200_000_000)
                guard let chunk = ring.takeChunk() else { continue }
                let output = model.generate(audio: chunk)
                let text = output.text.trimmingCharacters(in: .whitespacesAndNewlines)
                print("[live] \(text.isEmpty ? "(…)" : text)")
            }
        }

        var stop = false
        let stopPtr = UnsafeMutablePointer<Bool>.allocate(capacity: 1)
        stopPtr.initialize(to: false)
        defer { stopPtr.deallocate() }
        signal(SIGINT) { _ in stop = true }
        while !stop { try? await Task.sleep(nanoseconds: 200_000_000) }

        inference.cancel()
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        print("stopped")
    }
}