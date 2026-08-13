import Foundation
import AVFoundation

/// Thread-safe mono sample buffer for the live experiment.
///
/// The realtime input tap only appends (under a lock — cheap for ~1024 frames);
/// a background loop drains fixed-size chunks for inference. This keeps ASR
/// off the realtime thread (the "delay queue" / low-UI-pressure design).
///
/// NOTE: `@unchecked Sendable` — we guarantee thread safety via the internal
/// lock. Under Swift 6 strict concurrency the tap closure and the inference
/// Task both capture this; if the compiler complains about capturing the
/// Parakeet model across the Task boundary, wrap model access behind a small
/// actor or `@unchecked Sendable` holder.
final class MonoRingBuffer: @unchecked Sendable {
    private var samples: [Float] = []
    private let lock = NSLock()
    let chunkFrames: Int

    init(chunkFrames: Int) { self.chunkFrames = chunkFrames }

    func append(_ buffer: AVAudioPCMBuffer) {
        guard let data = buffer.floatChannelData else { return }
        let frames = Int(buffer.frameLength)
        let channels = Int(buffer.format.channelCount)
        lock.lock()
        defer { lock.unlock() }
        if channels == 1 {
            samples.append(contentsOf: UnsafeBufferPointer(start: data[0], count: frames))
        } else {
            var mix = [Float](repeating: 0, count: frames)
            for c in 0..<channels {
                let p = UnsafeBufferPointer(start: data[c], count: frames)
                for i in 0..<frames { mix[i] += p[i] / Float(channels) }
            }
            samples.append(contentsOf: mix)
        }
    }

    /// Drain one chunk, or nil if not enough samples accumulated yet.
    func takeChunk() -> [Float]? {
        lock.lock()
        defer { lock.unlock() }
        guard samples.count >= chunkFrames else { return nil }
        let chunk = Array(samples.prefix(chunkFrames))
        samples.removeFirst(chunkFrames)
        return chunk
    }
}