#!/bin/zsh
set -euo pipefail

app_dir="${0:A:h}"
build_dir="$app_dir/build"
app_bundle="$build_dir/Photokichin.app"
contents_dir="$app_bundle/Contents"
macos_dir="$contents_dir/MacOS"

rm -rf "$build_dir"
mkdir -p "$macos_dir" "$contents_dir/Resources"

export CLANG_MODULE_CACHE_PATH="$build_dir/ModuleCache"

swiftc \
  -parse-as-library \
  "$app_dir"/Sources/*.swift \
  -o "$macos_dir/Photokichin" \
  -framework SwiftUI \
  -framework AppKit \
  -framework ImageIO \
  -framework DiskArbitration \
  -framework UniformTypeIdentifiers \
  -lsqlite3 \
  -O

cp "$app_dir/Resources/Info.plist" "$contents_dir/Info.plist"
cp "$app_dir/Resources/Photokichin.icns" "$contents_dir/Resources/Photokichin.icns"
codesign --force --deep --sign - "$app_bundle" >/dev/null

echo "Built: $app_bundle"
