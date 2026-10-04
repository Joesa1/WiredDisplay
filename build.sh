#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")"
mkdir -p build/arm64 build/x86_64 dist
sdk_path="$(xcrun --sdk macosx --show-sdk-path)"
# Sign outside Desktop/iCloud: File Provider may reattach FinderInfo during signing.
staging="$(mktemp -d /private/tmp/wireddisplay-build.XXXXXX)"
trap 'rm -rf "$staging"' EXIT
for architecture in arm64 x86_64; do
    xcrun swiftc -swift-version 5 -O -sdk "$sdk_path" -target "$architecture-apple-macos12.3" \
        -disable-autolinking-runtime-compatibility \
        -import-objc-header Sources/VirtualDisplay.h Sources/*.swift \
        -o "build/$architecture/WiredDisplay" \
        -framework AppKit -framework ScreenCaptureKit -framework VideoToolbox \
        -framework AVFoundation -framework CoreMedia -framework CoreVideo \
        -framework SystemConfiguration -framework CoreGraphics -framework Network -framework WebKit
    app="$staging/Thunder Display.app"
    mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"
    cp -X "build/$architecture/WiredDisplay" "$app/Contents/MacOS/WiredDisplay"
    cp -X Info.plist "$app/Contents/Info.plist"
    cp -X LICENSE-TargetBridge.txt "$app/Contents/Resources/"
    cp -X Resources/mvp-ui-prototype.html "$app/Contents/Resources/"
    codesign --force --sign "${WIRED_SIGN_IDENTITY:--}" --identifier local.wired-display.app "$app"
    codesign --verify --deep --strict "$app"
    ditto -c -k --sequesterRsrc --keepParent "$app" "dist/ThunderDisplay-$architecture.zip"
    rm -rf "dist/Thunder Display.app"
    ditto --norsrc "$app" "dist/Thunder Display.app"
done
shasum -a 256 dist/ThunderDisplay-*.zip > dist/SHA256SUMS.txt
echo "Built arm64 and x86_64 packages. Two-Mac validation is still required."
