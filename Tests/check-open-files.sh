#!/bin/zsh
set -euo pipefail
cd "${0:A:h}/.."
export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"
folder=$(mktemp -d /tmp/cygnus-open-files.XXXXXX)
trap 'rm -rf "$folder"' EXIT
for name in first.MP4 second.mov third.mp4 fourth.mp4; do
    cp Resources/StillTiming.mp4 "$folder/$name"
done
cp Resources/AppIcon-preview.png "$folder/image.png"
arch=$(/usr/bin/uname -m)
xcrun swiftc -swift-version 5 -parse-as-library -O -target "$arch-apple-macosx13.0" \
    -module-cache-path .build/clang-cache \
    Sources/CygnusMovies/{Project,Editor,Export,Media,VisualLayer,LayerRendering,Compositor,Localization,TimelineInteraction,AppDelegate,MovieHelpView}.swift \
    Tests/OpenFilesCheck.swift -o "$folder/check"
"$folder/check" "$folder"
