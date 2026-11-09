#!/bin/bash
set -euo pipefail
project_root="$(cd "$(dirname "$0")/.." && pwd)"
fixture_root="$project_root/build/audio-fixtures"
mkdir -p "$fixture_root"
xcrun swiftc -swift-version 6 -parse-as-library -O -target "$(uname -m)-apple-macos26" -framework AppKit -framework AVFAudio \
    "$project_root/Tools/AudioFixture.swift" -o "$fixture_root/AudioFixture"
for variant in a b; do
    fixture_path="$fixture_root/Damper Test $variant.app"
    mkdir -p "$fixture_path/Contents/MacOS"
    cp "$fixture_root/AudioFixture" "$fixture_path/Contents/MacOS/AudioFixture"
    plist="$fixture_path/Contents/Info.plist"
    plutil -create xml1 "$plist"
    plutil -insert CFBundleIdentifier -string "io.github.tadassuksteris.damper.fixture.$variant" "$plist"
    plutil -insert CFBundleExecutable -string AudioFixture "$plist"
    plutil -insert CFBundleName -string "Damper Test $variant" "$plist"
    plutil -insert CFBundlePackageType -string APPL "$plist"
    plutil -insert LSUIElement -bool true "$plist"
    codesign --force --sign - "$fixture_path"
done
echo "Built quiet test fixtures in $fixture_root"
