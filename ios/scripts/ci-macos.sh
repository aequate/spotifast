#!/bin/bash
set -euo pipefail
root="$(cd "$(dirname "$0")/.." && pwd)"
cd "$root"
mkdir -p build/logs build/artifacts
node scripts/generate-project.mjs --check
python3 scripts/check-dependencies.py
plutil -lint Config/Info.plist Config/Spotifast.entitlements Spotifast/PrivacyInfo.xcprivacy Spotifast.xcodeproj/project.pbxproj
xcodebuild -version | tee build/logs/xcode.txt
xcrun --sdk iphoneos --show-sdk-version | tee -a build/logs/xcode.txt
rustc --version | tee build/logs/rust.txt
common=(-project Spotifast.xcodeproj -scheme Spotifast -derivedDataPath build/DerivedData CODE_SIGNING_ALLOWED=NO)
case "${IOS_CI_TARGET:?Set IOS_CI_TARGET to simulator or device}" in
    simulator)
        xcodebuild "${common[@]}" -configuration Debug -sdk iphonesimulator -destination 'generic/platform=iOS Simulator' build 2>&1 | tee build/logs/simulator-build.log
        # Use the UUID, since different installed runtimes can repeat names.
        simulator=$(xcrun simctl list devices available -j | python3 -c 'import json,sys; d=json.load(sys.stdin); print(next(v["udid"] for k,vs in sorted(d["devices"].items(), reverse=True) if "iOS" in k for v in vs if v["name"].startswith("iPhone")))')
        xcrun simctl boot "$simulator" || true
        xcrun simctl bootstatus "$simulator" -b
        xcodebuild "${common[@]}" -configuration Debug -destination "platform=iOS Simulator,id=$simulator" -resultBundlePath build/SpotifastTests.xcresult -parallel-testing-enabled NO test 2>&1 | tee build/logs/simulator-tests.log
        ditto -c -k --keepParent build/DerivedData/Build/Products/Debug-iphonesimulator/Spotifast.app build/artifacts/Spotifast-simulator-unsigned.zip
        ;;
    device)
        xcodebuild "${common[@]}" -configuration Release -sdk iphoneos -destination 'generic/platform=iOS' build 2>&1 | tee build/logs/device-build.log
        ditto -c -k --keepParent build/DerivedData/Build/Products/Release-iphoneos/Spotifast.app build/artifacts/Spotifast-device-unsigned.zip
        ;;
    *) echo "Unknown IOS_CI_TARGET" >&2; exit 1 ;;
esac
