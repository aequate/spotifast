#!/bin/bash
set -euo pipefail
if [[ "$(uname -s)" != Darwin ]]; then echo "This script requires macOS and Xcode."; exit 1; fi
export PATH="$HOME/.cargo/bin:$PATH"
root="$(cd "$(dirname "$0")/.." && pwd)"
cd "$root"
xcodebuild -version
xcrun --sdk iphoneos --show-sdk-path
command -v rustup >/dev/null || { echo "Install Rust from https://rustup.rs, then rerun this script."; exit 1; }
rustup show active-toolchain
rustup target add aarch64-apple-ios aarch64-apple-ios-sim x86_64-apple-ios
cargo fetch --locked --manifest-path Rust/Cargo.toml
echo "Open $root/Spotifast.xcodeproj and select your signing team. See README.md."
