import CoreAudio
import Foundation

enum RecorderError: Error, LocalizedError {
    case permissionDenied
    case missingDevice(String)
    case coreAudio(String, OSStatus)
    case invalidFormat(String)
    case missingFFmpeg
    case exportFailed(String)

    var errorDescription: String? {
        switch self {
        case .permissionDenied:
            return "Microphone access is disabled. Enable Meeting Recorder in System Settings → Privacy & Security → Microphone."
        case .missingDevice(let name):
            return "The audio device “\(name)” is unavailable."
        case .coreAudio(let operation, let status):
            return "\(operation) failed with Core Audio status \(status)."
        case .invalidFormat(let name):
            return "\(name) did not provide a usable input format."
        case .missingFFmpeg:
            return "The final M4A mixer requires ffmpeg, but it was not found in /opt/homebrew/bin or /usr/local/bin."
        case .exportFailed(let message):
            return "Creating the M4A failed: \(message)"
        }
    }
}