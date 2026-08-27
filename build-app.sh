#!/bin/zsh
set -euo pipefail

script_dir=${0:A:h}
build_root=$(mktemp -d /private/tmp/striprotate-build.XXXXXX)
app_path="$build_root/Strip Rotate.app"

mkdir -p "$app_path/Contents/MacOS" "$app_path/Contents/Resources" "$script_dir/dist"

CLANG_MODULE_CACHE_PATH="$build_root/clang-cache" xcrun swiftc \
  -O \
  -swift-version 5 \
  -import-objc-header "$script_dir/Sources/PrivateDisplay/include/CGVirtualDisplayPrivate.h" \
  "$script_dir/Sources/StripRotate/main.swift" \
  -o "$app_path/Contents/MacOS/StripRotate" \
  -framework AppKit \
  -framework AVFoundation \
  -framework CoreGraphics \
  -framework CoreMedia \
  -framework CoreVideo \
  -framework QuartzCore \
  -framework ScreenCaptureKit \
  -framework ServiceManagement

cp "$script_dir/AppResources/Info.plist" "$app_path/Contents/Info.plist"
xattr -cr "$app_path"
# Keep a stable designated requirement across local rebuilds. Without this,
# ad-hoc signing defaults to the binary CDHash and macOS treats every build as
# a different app for privacy permissions.
codesign --force --deep --sign - \
  --requirements '=designated => identifier "tw.kayinsoong.StripRotate"' \
  "$app_path"
codesign --verify --deep --strict "$app_path"

(
  cd "$build_root"
  /usr/bin/zip -r -X -q "$script_dir/dist/Strip-Rotate-macOS.zip" "Strip Rotate.app"
)

echo "Built: $script_dir/dist/Strip-Rotate-macOS.zip"
