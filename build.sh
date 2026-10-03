#!/bin/bash
set -euo pipefail

cd "$(dirname "$0")"
rm -rf dist
mkdir -p build/arm64 build/x86_64 dist
sdk_path="$(xcrun --sdk macosx --show-sdk-path)"

for architecture in arm64 x86_64; do
    xcrun swiftc -swift-version 5 -O -sdk "$sdk_path" -target "$architecture-apple-macos12.3" \
        -disable-autolinking-runtime-compatibility \
        -import-objc-header Sources/VirtualDisplay.h Sources/*.swift \
        -o "build/$architecture/WiredDisplay" \
        -framework AppKit -framework ScreenCaptureKit -framework VideoToolbox \
        -framework AVFoundation -framework CoreMedia -framework CoreVideo \
        -framework SystemConfiguration -framework CoreGraphics

    app="dist/WiredDisplay-$architecture.app"
    mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"
    cp "build/$architecture/WiredDisplay" "$app/Contents/MacOS/WiredDisplay"
    cp Info.plist "$app/Contents/Info.plist"
    cp LICENSE-TargetBridge.txt "$app/Contents/Resources/"
    xattr -cr "$app" 2>/dev/null || true
    codesign --force --sign - --identifier "local.wired-display.$architecture" "$app"
    xattr -cr "$app" 2>/dev/null || true
    xattr -d com.apple.FinderInfo "$app" 2>/dev/null || true
    xattr -d com.apple.fileprovider.fpfs#P "$app" 2>/dev/null || true
    xattr -d com.apple.provenance "$app" 2>/dev/null || true
    codesign --verify --deep --strict "$app"
    ditto -c -k --sequesterRsrc --keepParent "$app" "dist/WiredDisplay-$architecture.zip"
done

echo "Built dist/WiredDisplay-arm64.zip and dist/WiredDisplay-x86_64.zip"
