#!/bin/sh

set -eu

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
SOURCE="$SCRIPT_DIR/src/MeetingRecorder.swift"
OUTPUT_DIR="$SCRIPT_DIR/out"
OUTPUT="$OUTPUT_DIR/Meeting Recorder.app"
CONTENTS="$OUTPUT/Contents"
MODULE_CACHE="$OUTPUT_DIR/meeting-recorder-compiler-cache"

if ! command -v swiftc >/dev/null 2>&1; then
  echo "error: swiftc is required (install Xcode Command Line Tools)" >&2
  exit 1
fi

mkdir -p "$OUTPUT_DIR"
rm -rf "$OUTPUT"
mkdir -p "$CONTENTS/MacOS" "$CONTENTS/Resources" "$MODULE_CACHE"
CLANG_MODULE_CACHE_PATH="$MODULE_CACHE" SWIFT_MODULECACHE_PATH="$MODULE_CACHE" /usr/bin/swiftc \
  -O \
  -framework AppKit \
  -framework AVFoundation \
  -framework CoreAudio \
  -framework AudioToolbox \
  "$SOURCE" \
  -o "$CONTENTS/MacOS/MeetingRecorder"
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
