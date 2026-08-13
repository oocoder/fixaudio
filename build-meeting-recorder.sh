#!/bin/sh

set -eu

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
OUTPUT_DIR="$SCRIPT_DIR/out"
OUTPUT="$OUTPUT_DIR/Meeting Recorder.app"
CONTENTS="$OUTPUT/Contents"

if ! command -v swift >/dev/null 2>&1; then
  echo "error: swift is required (install Xcode Command Line Tools)" >&2
  exit 1
fi

mkdir -p "$OUTPUT_DIR"
rm -rf "$OUTPUT"
mkdir -p "$CONTENTS/MacOS" "$CONTENTS/Resources"

# Build via Swift Package Manager (Package.swift at repo root).
swift build -c release

/bin/cp "$SCRIPT_DIR/.build/release/MeetingRecorder" "$CONTENTS/MacOS/MeetingRecorder"
/bin/cp "$SCRIPT_DIR/src/MeetingRecorder-Info.plist" "$CONTENTS/Info.plist"

# Optional per-machine signing configuration. This file is ignored by Git and
# should contain only a certificate name, never a private key or password.
LOCAL_SIGNING_CONFIG="$SCRIPT_DIR/.local-signing.env"
if [ -f "$LOCAL_SIGNING_CONFIG" ]; then
  . "$LOCAL_SIGNING_CONFIG"
fi
SIGNING_IDENTITY=${FIXAUDIO_SIGNING_IDENTITY:--}
/usr/bin/codesign --force --sign "$SIGNING_IDENTITY" "$OUTPUT"

echo "Built: $OUTPUT"