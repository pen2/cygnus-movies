#!/bin/zsh
set -euo pipefail
cd "${0:A:h}/.."
export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"
folder=$(mktemp -d /tmp/cygnus-video-layers.XXXXXX)
trap 'rm -rf "$folder"' EXIT
ffmpeg -v error -f lavfi -i color=c=blue:s=320x180 -frames:v 1 "$folder/blue.png"
ffmpeg -v error -f lavfi -i testsrc2=s=160x90:r=30:d=3 -f lavfi -i sine=frequency=880:sample_rate=44100:duration=3 \
    -c:v libx264 -preset ultrafast -c:a aac -shortest "$folder/motion.mov"
ffmpeg -v error -i "$folder/motion.mov" -c copy -metadata:s:v:0 rotate=90 "$folder/rotated.mov"
mkdir -p "$folder/Check.app/Contents/MacOS" "$folder/Check.app/Contents/Resources"
cp Resources/StillTiming.mp4 "$folder/Check.app/Contents/Resources/"
cp Info.plist "$folder/Check.app/Contents/Info.plist"
/usr/libexec/PlistBuddy -c 'Set :CFBundleExecutable check' "$folder/Check.app/Contents/Info.plist"
arch=$(/usr/bin/uname -m)
xcrun swiftc -swift-version 5 -parse-as-library -O -target "$arch-apple-macosx13.0" \
    -module-cache-path .build/clang-cache \
    Sources/CygnusMovies/{Project,Editor,Export,Media,AudioPreparation,VisualLayer,LayerRendering,Compositor,Localization,TimelineInteraction,TemporaryMedia,PreviewActions}.swift \
    Tests/TimelineVideoLayerCheck.swift -o "$folder/Check.app/Contents/MacOS/check"
"$folder/Check.app/Contents/MacOS/check" "$folder"
