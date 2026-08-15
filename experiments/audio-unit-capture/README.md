# audio-unit-capture — AUHAL Direct Capture Experiment

## Goal

Test whether `AudioUnit` (AUHAL) direct capture works with Bluetooth headsets,
where `AVAudioEngine.installTap` crashes with "Input HW format and tap format
not matching."

## Why

The Meeting Recorder app uses `AVAudioEngine` for capture. When a Bluetooth
headset is selected as the mic, `installTap` crashes because:

1. AVAudioEngine creates an aggregate device (input + output combined).
2. The aggregate forces the Bluetooth headset into HFP mode (16 kHz mono).
3. The format mismatch between the aggregate and the tap format crashes.

AUHAL (`kAudioUnitSubType_HALOutput`) bypasses AVAudioEngine entirely:
- No aggregate device is created.
- No `installTap` — uses `AURenderCallback` instead.
- The device's actual format is read and used directly.

## Usage

```sh
# List input devices (Bluetooth devices are marked)
swift run audio-unit-capture

# Capture from device index 2 for 5 seconds
swift run audio-unit-capture 2 5 test.wav

# Capture from a Bluetooth headset
swift run audio-unit-capture 3 5 bluetooth-test.wav
```

## What success looks like

1. No crash (AVAudioEngine crashes with Bluetooth).
2. The WAV file contains audio (non-zero samples).
3. The format is reported correctly (16 kHz mono for Bluetooth HFP).
4. The file is playable.