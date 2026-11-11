#!/bin/zsh
# Sign and notarize the existing build; replace it only after all checks pass.
set -euo pipefail
cd "${0:A:h}"

if [[ "${1:-}" == --help ]]; then
    print 'Usage: SIGNING_IDENTITY="Developer ID Application: … (…)" NOTARY_PROFILE="…" ./release-app.sh'
    print 'Build with ./build-app.sh first. Credentials must already be in the Keychain.'
    exit 0
fi
if (( $# )); then
    print -u2 'Unexpected arguments. Use --help for usage.'
    exit 1
fi
if [[ "${SIGNING_IDENTITY:-}" != 'Developer ID Application: '* ]]; then
    print -u2 'SIGNING_IDENTITY must name a Developer ID Application certificate.'
    exit 1
fi
if [[ -z "${NOTARY_PROFILE:-}" ]]; then
    print -u2 'Set NOTARY_PROFILE to your existing notarytool Keychain profile name.'
    exit 1
fi
export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"

app="$PWD/dist/cygnus movies.app"
if [[ ! -d "$app" ]]; then
    print -u2 'Build dist/cygnus movies.app with ./build-app.sh first.'
    exit 1
fi
if ! /usr/bin/security find-identity -v -p codesigning | /usr/bin/grep -Fq "\"$SIGNING_IDENTITY\""; then
    print -u2 'The specified signing identity and private key are not available.'
    exit 1
fi
/usr/bin/codesign --verify --deep --strict "$app"

version=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$app/Contents/Info.plist")
build=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$app/Contents/Info.plist")
archs=$(/usr/bin/lipo -archs "$app/Contents/MacOS/CygnusMovies")
case "$archs" in
    arm64) platform=arm64 ;;
    x86_64) platform=x86_64 ;;
    'x86_64 arm64'|'arm64 x86_64') platform=universal ;;
    *) print -u2 "Unexpected architectures: $archs"; exit 1 ;;
esac
name="cygnus-movies-${version}-macOS-${platform}"
logdir="$PWD/dist/notarization/${version}-${build}-$(date -u +%Y%m%dT%H%M%SZ)"
mkdir -p "$logdir"
staging=$(mktemp -d "$PWD/dist/.release-app.XXXXXX")
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

/usr/bin/ditto "$app" "$bundle"
# This bundle contains a single executable and no nested code or plug-ins.
/usr/bin/codesign --force --sign "$SIGNING_IDENTITY" --options runtime --timestamp "$bundle"
/usr/bin/codesign --verify --deep --strict --verbose=2 "$bundle"
/usr/bin/ditto -c -k --sequesterRsrc --keepParent "$bundle" "$staging/submission.zip"

# JSON includes the submission ID even if notarization is rejected.
submission_result=0
xcrun notarytool submit "$staging/submission.zip" \
    --keychain-profile "$NOTARY_PROFILE" --wait --output-format json \
    > "$logdir/submission.json" || submission_result=$?
submission_id=$(/usr/bin/plutil -extract id raw -o - "$logdir/submission.json")
xcrun notarytool log "$submission_id" --keychain-profile "$NOTARY_PROFILE" "$logdir/log.json"
notary_status=$(/usr/bin/plutil -extract status raw -o - "$logdir/submission.json")
if (( submission_result != 0 )) || [[ "$notary_status" != Accepted ]]; then
    print -u2 "Notarization did not succeed ($notary_status). See $logdir/log.json"
    exit 1
fi

xcrun stapler staple "$bundle"
xcrun stapler validate "$bundle"
/usr/bin/codesign --verify --deep --strict --verbose=2 "$bundle"
/usr/sbin/spctl --assess --type execute --verbose=2 "$bundle" 2>&1 | tee "$logdir/gatekeeper.txt"
/usr/bin/syspolicy_check distribution "$bundle" 2>&1 | tee "$logdir/distribution.txt"
/usr/bin/codesign -d --verbose=4 "$bundle" 2> "$logdir/signature.txt"

# Recreate the ZIP after stapling. A ZIP itself cannot carry a stapled ticket.
/usr/bin/ditto -c -k --sequesterRsrc --keepParent "$bundle" "$staging/$name.zip"
mkdir "$staging/check"
/usr/bin/ditto -x -k "$staging/$name.zip" "$staging/check"
xcrun stapler validate "$staging/check/cygnus movies.app"
/usr/bin/codesign --verify --deep --strict "$staging/check/cygnus movies.app"
/usr/sbin/spctl --assess --type execute --verbose=2 "$staging/check/cygnus movies.app"

mv "$app" "$previous"
mv "$bundle" "$app"
mv -f "$staging/$name.zip" "$PWD/dist/$name.zip"
(cd dist && /usr/bin/shasum -a 256 "$name.zip" > "$name.zip.sha256")
print "Release archive: $PWD/dist/$name.zip"
print "Verification logs: $logdir"
