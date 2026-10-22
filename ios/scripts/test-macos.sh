#!/bin/bash
set -euo pipefail
root="$(cd "$(dirname "$0")/.." && pwd)"
cd "$root"
bash scripts/test-portable.sh
python3 scripts/check-dependencies.py
cargo fmt --manifest-path Rust/Cargo.toml -- --check
cargo clippy --locked --manifest-path Rust/Cargo.toml --all-targets -- -D warnings
cargo test --locked --manifest-path Rust/Cargo.toml
plutil -lint Config/Info.plist Spotifast/PrivacyInfo.xcprivacy Spotifast.xcodeproj/project.pbxproj
# SDK and app compilation, with signing disabled, needs no account credentials.
xcodebuild -project Spotifast.xcodeproj -scheme Spotifast -configuration Debug -sdk iphonesimulator -destination 'generic/platform=iOS Simulator' -derivedDataPath build/DerivedData CODE_SIGNING_ALLOWED=NO build
# The phone target has a different Rust slice/SDK and must compile separately.
# This builds an unsigned Release app; it does not install or provision a phone.
xcodebuild -project Spotifast.xcodeproj -scheme Spotifast -configuration Release -sdk iphoneos -destination 'generic/platform=iOS' -derivedDataPath build/DerivedData CODE_SIGNING_ALLOWED=NO build
# Select any installed iPhone simulator explicitly, e.g. SIMULATOR='iPhone 16'.
if [[ -n "${SIMULATOR:-}" ]]; then
    results="${RESULT_BUNDLE:-build/SpotifastTests-$(date -u +%Y%m%dT%H%M%SZ).xcresult}"
    xcodebuild -project Spotifast.xcodeproj -scheme Spotifast -configuration Debug -destination "platform=iOS Simulator,name=$SIMULATOR" -derivedDataPath build/DerivedData -resultBundlePath "$results" CODE_SIGNING_ALLOWED=NO test
    echo "XCTest report and native layout render attachments: $root/$results"
else
    echo "App built. Set SIMULATOR to an installed iPhone simulator name to run XCTest."
fi
