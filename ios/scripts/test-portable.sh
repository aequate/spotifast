#!/bin/bash
set -euo pipefail
root="$(cd "$(dirname "$0")/.." && pwd)"
cd "$root"
swift --version
# The official Swift parser can read all native sources on Linux too. Imports
# are resolved only by the later Apple SDK build; this is not an iOS compile.
swiftc -frontend -parse Spotifast/*.swift
swiftc -frontend -parse Tests/*.swift
swiftc -frontend -parse UITests/*.swift
mkdir -p build
# SwiftPM emits XCTest XML through its parallel runner. Keep concurrency low
# and retain the textual output as well as the report used by CI artifacts.
swift test --scratch-path build/swift-portable --parallel --num-workers 2 --xunit-output build/portable-tests.xml 2>&1 | tee build/portable-tests.log
test -s build/portable-tests.xml
