#!/bin/zsh
set -euo pipefail
cd "${0:A:h}/.."
export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"
# Fixtures are synthesized; no personal media is checked into this repository.
# FFmpeg/ffprobe are needed only for this regression test, never by the app.
folder=$(mktemp -d /tmp/cygnus-audio-sync.XXXXXX)
trap 'rm -rf "$folder"' EXIT
python3 Tests/audio-sync-fixtures.py "$folder"
arch=$(/usr/bin/uname -m)
xcrun swiftc -swift-version 5 -parse-as-library -O -target "$arch-apple-macosx13.0" \
    -module-cache-path .build/clang-cache \
    Sources/CygnusMovies/{Project,Editor,Export,Media,AudioPreparation,VisualLayer,LayerRendering,Compositor,Localization,TimelineInteraction,TemporaryMedia,PreviewActions}.swift \
    Tests/AudioSyncCheck.swift -o "$folder/check"
"$folder/check" "$folder"
python3 Tests/audio-sync-verify.py "$folder"
