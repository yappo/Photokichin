#!/bin/zsh
set -euo pipefail

app_dir="${0:A:h}"
build_dir="$app_dir/build"
app_bundle="$build_dir/Photokichin.app"
contents_dir="$app_bundle/Contents"
macos_dir="$contents_dir/MacOS"

rm -rf "$build_dir"
mkdir -p "$macos_dir" "$contents_dir/Resources"

swift build \
  --package-path "$app_dir" \
  -c release \
  --product Photokichin

swiftpm_bin_dir="$(swift build --package-path "$app_dir" -c release --show-bin-path)"
cp "$swiftpm_bin_dir/Photokichin" "$macos_dir/Photokichin"

cp "$app_dir/Resources/Info.plist" "$contents_dir/Info.plist"
cp "$app_dir/Resources/Photokichin.icns" "$contents_dir/Resources/Photokichin.icns"
codesign --force --deep --sign - "$app_bundle" >/dev/null

echo "Built: $app_bundle"
