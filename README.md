# Meeting Recorder for macOS

Meeting Recorder is a small native menu-bar app that records both sides of an
online meeting into a stereo M4A file.

It captures the physical microphone and BlackHole independently instead of
wrapping them in a macOS aggregate input device. This avoids a Core Audio issue
where meeting software and QuickTime can stall an aggregate device when they
open its subdevices in a particular order.

## Features

- Records a physical microphone and meeting audio into one stereo M4A.
- Captures the microphone and meeting audio as raw, independent input streams
  (no Apple Voice Processing on the capture path — see below).
- Keeps voices centered in both ears.
- Retains per-source captures (`<stem>-mic.caf`, `<stem>-remote.caf`) beside the
  M4A so transcription can use each side separately.
- Runs as a native Swift menu-bar app with no analytics or network access.

## Why the recorder does not use Apple Voice Processing

Apple Voice Processing (the Voice Processing IO unit) is a full-duplex
acoustic echo canceller plus voice/noise processor. It is designed for a live
call where the audio playing out the speakers is available as an echo
reference, so it can cancel speaker echo from the microphone and clean your
voice for the other participant.

A capture-only recorder has no playback path, so it cannot give Voice
Processing a valid echo reference. With no reference, the echo canceller goes
degenerate and cancels the microphone's own signal — i.e. it deletes your
voice from the recording while the separately captured remote track is
unaffected. For this reason the recorder opens both the physical microphone
and BlackHole as plain input-only streams.

Voice Isolation for the **live call** (so the other participant hears you more
clearly) is owned by the meeting application and the system microphone modes
in Control Center, not by this recorder. Control Center shows a Microphone
mode selector while the mic is in use; choose Voice Isolation there.

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

For a personal development machine, the build script also reads an ignored
`.local-signing.env` file containing `FIXAUDIO_SIGNING_IDENTITY`. This file is
machine-local configuration and must never be committed.

## Record

1. Start the meeting and confirm its microphone meter responds.
2. Choose **Start Meeting Recording…** from the menu-bar app.
3. Choose **Stop and Save Recording** when finished.

This recorder captures and mixes audio only. Transcription is handled
separately.

The recorder also keeps the per-source captures (`<stem>-mic.caf` = your
voice, `<stem>-remote.caf` = the remote side) next to the M4A. These are
lossless and the inputs transcription should use — diarizing the mixed M4A is
unreliable, so the per-source files give the clean `You` / `Remote` separation.

## Privacy

Audio stays on the Mac. Meeting Recorder has no telemetry, analytics, or network
client. It launches `ffmpeg` locally to create the M4A.

Record meetings only with the knowledge and consent required by the laws and
policies that apply to you and the participants.

See [OUTLINE.md](OUTLINE.md) for the system architecture and known limitations.

## License

[MIT](LICENSE)
