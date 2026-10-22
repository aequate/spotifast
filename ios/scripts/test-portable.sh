#!/bin/bash
set -euo pipefail
root="$(cd "$(dirname "$0")/.." && pwd)"
cd "$root"
swift --version
# The official Swift parser can read all native sources on Linux too. Imports
# are resolved only by the later Apple SDK build; this is not an iOS compile.
swiftc -frontend -parse Spotifast/*.swift
swiftc -frontend -parse Tests/*.swift
mkdir -p build
swift test --scratch-path build/swift-portable --xunit-output build/portable-tests.xml
