#!/bin/zsh
set -euo pipefail
cd "${0:A:h}/.."
export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"
folder=$(mktemp -d /tmp/cygnus-timeline-transfer.XXXXXX)
trap 'rm -rf "$folder"' EXIT
arch=$(/usr/bin/uname -m)
xcrun swiftc -swift-version 5 -parse-as-library -O -target "$arch-apple-macosx13.0" \
    -module-cache-path .build/clang-cache \
    Sources/CygnusMovies/{Project,Editor,Export,Media,AudioPreparation,VisualLayer,LayerRendering,Compositor,Localization,TimelineInteraction,TemporaryMedia,PreviewActions}.swift \
    Tests/TimelineTransferCheck.swift -o "$folder/check"
"$folder/check" "$folder"
