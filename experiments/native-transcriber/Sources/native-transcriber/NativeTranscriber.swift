import Foundation

@main
struct NativeTranscriber {
    static func main() async {
        let args = CommandLine.arguments
        if args.contains("--version") || args.contains("-v") {
            print("native-transcriber \(appVersion)")
            return
        }
        guard args.count > 1 else { printHelp(); return }
        switch args[1] {
        case "transcribe":
            guard args.count > 2 else
            { print("usage: native-transcriber transcribe <audio.m4a>"); return }
            await FileTranscriber.transcribe(path: args[2])
        case "live":
            await LiveTranscriber.run()
        case "-h", "--help":
            printHelp()
        default:
            print("unknown command: \(args[1])")
            printHelp()
        }
    }

    static func printHelp() {
        print("""
        native-transcriber \(appVersion) — native MLX ASR + diarization experiment

        Usage:
          native-transcriber transcribe <audio.m4a>   Transcribe + diarize a file
          native-transcriber live                      Live mic transcription (chunked)
          native-transcriber --version

        Requires Swift 6.2 / Xcode 26 (macOS 26) on Apple Silicon.
        Models auto-download from HuggingFace on first run (~GBs).
        """)
    }
}