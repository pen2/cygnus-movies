#!/bin/zsh
set -euo pipefail
cd "${0:A:h}"

mkdir -p .build
export CLANG_MODULE_CACHE_PATH="${CLANG_MODULE_CACHE_PATH:-$PWD/.build/clang-cache}"
export SWIFTPM_MODULECACHE_OVERRIDE="${SWIFTPM_MODULECACHE_OVERRIDE:-$PWD/.build/swiftpm-cache}"

universal=false
if [[ "${1:-}" == --universal ]]; then
    universal=true
    shift
fi
if $universal; then
    for arch in arm64 x86_64; do
        swift build -c release --arch "$arch" "$@"
    done
else
    swift build -c release "$@"
    binary_dir=$(swift build -c release --show-bin-path "$@")
fi
app="$PWD/dist/cygnus movies.app"
mkdir -p "$PWD/dist"
staging=$(mktemp -d "$PWD/dist/.build-app.XXXXXX")
bundle="$staging/cygnus movies.app"
previous="$staging/previous.app"
cleanup() {
    if [[ -e "$previous" && ! -e "$app" ]]; then
        if ! mv "$previous" "$app"; then
            print -u2 "Previous app kept at $previous"
            return
        fi
    fi
    rm -rf "$staging"
}
trap cleanup EXIT

mkdir -p "$bundle/Contents/MacOS" "$bundle/Contents/Resources"
cp -R Resources/{ja,en}.lproj "$bundle/Contents/Resources/"
cp Resources/AppIcon.icns "$bundle/Contents/Resources/"
cp Resources/StillTiming.mp4 "$bundle/Contents/Resources/"

cp LICENSE "$bundle/Contents/Resources/LICENSE.txt"
cp Info.plist "$bundle/Contents/Info.plist"
if $universal; then
    arm_dir=$(swift build -c release --arch arm64 --show-bin-path "$@")
    intel_dir=$(swift build -c release --arch x86_64 --show-bin-path "$@")
    /usr/bin/lipo -create "$arm_dir/CygnusMovies" "$intel_dir/CygnusMovies" \
        -output "$bundle/Contents/MacOS/CygnusMovies"
else
    cp "$binary_dir/CygnusMovies" "$bundle/Contents/MacOS/CygnusMovies"
fi
codesign --force --sign - "$bundle"
codesign --verify --strict "$bundle"

# Give Finder and Quick Look a new bundle identity instead of updating in place.
if [[ -e "$app" ]]; then
    mv "$app" "$previous"
fi
mv "$bundle" "$app"
printf '%s\n' "$app"
