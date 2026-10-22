#!/bin/bash
set -euo pipefail
export PATH="$HOME/.cargo/bin:$PATH"
: "${SRCROOT:?Run this script as an Xcode build phase}"
: "${PLATFORM_NAME:?Missing Xcode platform}"
: "${BUILT_PRODUCTS_DIR:?Missing Xcode output directory}"
command -v cargo >/dev/null || { echo "error: Install Rust with rustup, then run ios/scripts/bootstrap-macos.sh"; exit 1; }
export CARGO_TARGET_DIR="$SRCROOT/Rust/target"
export IPHONEOS_DEPLOYMENT_TARGET="${IPHONEOS_DEPLOYMENT_TARGET:-17.0}"
profile=debug
flags=(--locked --manifest-path "$SRCROOT/Rust/Cargo.toml")
if [[ "${CONFIGURATION:-Debug}" == Release ]]; then profile=release; flags+=(--release); fi
libraries=()
for arch in ${ARCHS:-arm64}; do
    case "$PLATFORM_NAME:$arch" in
        iphoneos:arm64) target=aarch64-apple-ios ;;
        iphonesimulator:arm64) target=aarch64-apple-ios-sim ;;
        iphonesimulator:x86_64) target=x86_64-apple-ios ;;
        *) echo "error: Unsupported iOS platform/architecture: $PLATFORM_NAME $arch"; exit 1 ;;
    esac
    cargo build "${flags[@]}" --target "$target"
    libraries+=("$CARGO_TARGET_DIR/$target/$profile/libspotifast_ios_core.a")
done
mkdir -p "$BUILT_PRODUCTS_DIR"
if [[ ${#libraries[@]} == 1 ]]; then
    cp "${libraries[0]}" "$BUILT_PRODUCTS_DIR/libspotifast_ios_core.a"
else
    xcrun lipo -create "${libraries[@]}" -output "$BUILT_PRODUCTS_DIR/libspotifast_ios_core.a"
fi
