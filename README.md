# Meeting Recorder for macOS

Meeting Recorder is a small native menu-bar app that records both sides of an
online meeting into a transcription-ready M4A file.

It captures the physical microphone and BlackHole independently instead of
wrapping them in a macOS aggregate input device. This avoids a Core Audio issue
where meeting software and QuickTime can stall an aggregate device when they
open its subdevices in a particular order.

## Features

- Records a physical microphone and meeting audio into one stereo M4A.
- Uses Apple Voice Processing by default.
- Opens Apple's Standard, Voice Isolation, and Wide Spectrum selector.
- Keeps voices centered in both ears.
- Can pass a finished recording to a user-selected transcription script.
- Runs as a native Swift menu-bar app with no analytics or network access.

## Requirements

- macOS 13 or later on Apple silicon.
- Xcode Command Line Tools (`swiftc`).
- [BlackHole 2ch](https://github.com/ExistentialAudio/BlackHole), installed
  separately.
- `ffmpeg`, installed separately (Homebrew paths are detected automatically).
- An external microphone named `External Microphone`.

The current prototype uses these fixed Core Audio device names. Device selection
is planned for a future release.

## Audio setup

In Audio MIDI Setup, create a Multi-Output Device named `Meeting Output` with:

1. Your headphones as the primary output.
2. BlackHole 2ch as the second output with drift correction enabled.
3. A 48 kHz sample rate for both devices.

In the meeting application select:

- Microphone: `External Microphone`
- Speaker: `Meeting Output`

Do not select BlackHole as the meeting microphone; doing so can send meeting
audio back to participants.

## Build and run

```sh
./build-meeting-recorder.sh
open "out/Meeting Recorder.app"
```

The build is ad-hoc signed by default. To use a stable signing identity:

```sh
FIXAUDIO_SIGNING_IDENTITY="Apple Development: Your Name (TEAMID)" \
  ./build-meeting-recorder.sh
```

Keep the bundle identifier and signing identity stable so macOS can retain the
microphone permission between builds.

## Record and transcribe

1. Start the meeting and confirm its microphone meter responds.
2. Choose **Start Meeting Recording…** from the menu-bar app.
3. Choose **Stop and Save Recording** when finished.
4. Choose **Transcribe Last Recording**.

On first use, the app asks you to select an executable transcription script.
The script receives the M4A path as its first argument, runs with the recording
directory as its working directory, and is remembered in local preferences.

## Privacy

Audio stays on the Mac. Meeting Recorder has no telemetry, analytics, or network
client. It launches `ffmpeg` locally to create the M4A and only runs a
transcription script when the user explicitly requests it.

Record meetings only with the knowledge and consent required by the laws and
policies that apply to you and the participants.

See [OUTLINE.md](OUTLINE.md) for the system architecture and known limitations.

## License

[MIT](LICENSE)
