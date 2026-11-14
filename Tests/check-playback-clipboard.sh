#!/bin/zsh
set -euo pipefail
cd "${0:A:h}/.."
export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"
folder=$(mktemp -d /tmp/cygnus-playback-clipboard.XXXXXX)
trap 'rm -rf "$folder"' EXIT
mkdir -p "$folder/Check.app/Contents/MacOS" "$folder/Check.app/Contents/Resources"
cp Resources/StillTiming.mp4 "$folder/Check.app/Contents/Resources/"
cp Info.plist "$folder/Check.app/Contents/Info.plist"
/usr/libexec/PlistBuddy -c 'Set :CFBundleExecutable check' "$folder/Check.app/Contents/Info.plist"
arch=$(/usr/bin/uname -m)
xcrun swiftc -swift-version 5 -parse-as-library -O -target "$arch-apple-macosx13.0" \
    -module-cache-path .build/clang-cache \
    Sources/CygnusMovies/{Project,Editor,Export,Media,AudioPreparation,VisualLayer,LayerRendering,Compositor,Localization,TimelineInteraction,TemporaryMedia,PreviewActions}.swift \
    Tests/PlaybackClipboardCheck.swift -o "$folder/Check.app/Contents/MacOS/check"
"$folder/Check.app/Contents/MacOS/check" "$folder"
