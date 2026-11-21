#!/bin/zsh
set -euo pipefail
cd "${0:A:h}/.."
export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"
folder=$(mktemp -d /tmp/cygnus-seek-waveform.XXXXXX)
trap 'rm -rf "$folder"' EXIT
# Synthetic long-GOP 29.97 fps video and 48 kHz PCM; no personal media.
ffmpeg -v error -f lavfi -i color=c=blue:s=160x90:r=30000/1001:d=1185 \
    -f lavfi -i sine=frequency=880:sample_rate=48000:duration=1185 \
    -c:v libx264 -preset ultrafast -g 60 -c:a pcm_s16be -shortest "$folder/long.mov"
arch=$(/usr/bin/uname -m)
xcrun swiftc -swift-version 5 -parse-as-library -O -target "$arch-apple-macosx13.0" \
    -module-cache-path .build/clang-cache \
    Sources/CygnusMovies/{Project,Editor,Export,Media,AudioPreparation,VisualLayer,LayerRendering,Compositor,Localization,TimelineInteraction,TemporaryMedia,PreviewActions}.swift \
    Tests/SeekWaveformTimingCheck.swift -o "$folder/check"
"$folder/check" "$folder"
