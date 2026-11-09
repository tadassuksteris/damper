#!/bin/bash
set -euo pipefail
project_root="$(cd "$(dirname "$0")/.." && pwd)"
configuration="${1:-debug}"
case "$configuration" in debug|release) ;; *) echo "Usage: $0 [debug|release] [swift build options]" >&2; exit 2 ;; esac
build_options=("${@:2}")
signing_identity="${DAMPER_SIGNING_IDENTITY:--}"
signing_options=()
# Optional: DAMPER_VERSION and DAMPER_BUILD_NUMBER set the version, and DAMPER_SPARKLE_PUBLIC_KEY
# turns on updates.
# Any real identity, by name or fingerprint, gets the hardened runtime and a timestamp for notarization.
if [[ "$signing_identity" != - ]]; then
    if [[ "$configuration" != release ]]; then
        echo "Signing with a certificate needs a release build, because debug builds contain the audio check: $0 release" >&2
        exit 2
    fi
    signing_options=(--options runtime --timestamp)
fi
cd "$project_root"
swift build --configuration "$configuration" ${build_options[@]+"${build_options[@]}"}
binary_directory="$(swift build --configuration "$configuration" ${build_options[@]+"${build_options[@]}"} --show-bin-path)"
application_path="$project_root/build/Damper.app"
mkdir -p "$application_path/Contents/MacOS" "$application_path/Contents/Resources"
cp "$binary_directory/Damper" "$application_path/Contents/MacOS/Damper.next"
if [[ "$configuration" == release ]]; then
    xcrun strip -Sx "$application_path/Contents/MacOS/Damper.next"
    if grep -aqF "$project_root" "$application_path/Contents/MacOS/Damper.next"; then
        echo "The release binary contains the build path $project_root." >&2
        rm -f "$application_path/Contents/MacOS/Damper.next"
        exit 1
    fi
fi
xcrun install_name_tool -add_rpath "@executable_path/../Frameworks" "$application_path/Contents/MacOS/Damper.next"
mv -f "$application_path/Contents/MacOS/Damper.next" "$application_path/Contents/MacOS/Damper"
info_plist="$application_path/Contents/Info.plist"
cp "$project_root/Resources/Info.plist" "$info_plist"
if [[ -n "${DAMPER_VERSION:-}" ]]; then /usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $DAMPER_VERSION" "$info_plist"; fi
if [[ -n "${DAMPER_BUILD_NUMBER:-}" ]]; then /usr/libexec/PlistBuddy -c "Set :CFBundleVersion $DAMPER_BUILD_NUMBER" "$info_plist"; fi
if [[ -n "${DAMPER_SPARKLE_PUBLIC_KEY:-}" ]]; then /usr/libexec/PlistBuddy -c "Add :SUPublicEDKey string $DAMPER_SPARKLE_PUBLIC_KEY" "$info_plist"; fi
frameworks="$application_path/Contents/Frameworks"
rm -rf "$frameworks"
mkdir -p "$frameworks"
ditto "$binary_directory/Sparkle.framework" "$frameworks/Sparkle.framework"
# Sparkle's license asks for its notice to go wherever copies of Sparkle go.
cp "$project_root/.build/artifacts/sparkle/Sparkle/LICENSE" "$application_path/Contents/Resources/Sparkle-LICENSE.txt"
if xcrun --find actool >/dev/null 2>&1; then
    xcrun actool "$project_root/Resources/AppIcon.icon" \
        --compile "$application_path/Contents/Resources" \
        --platform macosx --target-device mac --minimum-deployment-target 26.0 \
        --app-icon AppIcon --output-partial-info-plist "$project_root/build/icon-info.plist" \
        --output-format human-readable-text
else
    echo "actool is unavailable; building with the generic app icon. Full Xcode builds the layered icon." >&2
    /usr/libexec/PlistBuddy -c 'Delete :CFBundleIconFile' "$info_plist"
    /usr/libexec/PlistBuddy -c 'Delete :CFBundleIconName' "$info_plist"
fi
# The bundle is reused between builds, so drop a notarization ticket stapled to an earlier one.
rm -f "$application_path/Contents/CodeResources"
# Sparkle's parts are signed one at a time in this order, as its docs ask. --deep breaks them.
sparkle="$frameworks/Sparkle.framework/Versions/B"
sign_sparkle() { codesign --force --sign "$signing_identity" --options runtime ${signing_options[@]+"${signing_options[@]}"} "$@"; }
sign_sparkle "$sparkle/XPCServices/Installer.xpc"
sign_sparkle --preserve-metadata=entitlements "$sparkle/XPCServices/Downloader.xpc"
sign_sparkle "$sparkle/Autoupdate"
sign_sparkle "$sparkle/Updater.app"
sign_sparkle "$frameworks/Sparkle.framework"
codesign --force --sign "$signing_identity" ${signing_options[@]+"${signing_options[@]}"} \
    --entitlements "$project_root/Resources/Damper.entitlements" "$application_path"
codesign --verify --deep --strict "$application_path"
echo "$application_path"
