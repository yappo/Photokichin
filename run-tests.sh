#!/bin/zsh
set -euo pipefail

app_dir="${0:A:h}"
test_dir="$app_dir/.test-build"
rm -rf "$test_dir"
mkdir -p "$test_dir"
export CLANG_MODULE_CACHE_PATH="$test_dir/ModuleCache"

source_files=()
for source in "$app_dir"/Sources/*.swift; do
    [[ "$source" == "$app_dir/Sources/PhotokichinApp.swift" ]] && continue
    source_files+=("$source")
done
test_files=("$app_dir"/Tests/*.swift)

swiftc \
  -parse-as-library \
  "${source_files[@]}" \
  "${test_files[@]}" \
  -o "$test_dir/PhotokichinTests" \
  -framework SwiftUI \
  -framework AppKit \
  -framework ImageIO \
  -framework ImageCaptureCore \
  -framework DiskArbitration \
  -framework UniformTypeIdentifiers \
  -lsqlite3 \
  -D PHOTOKICHIN_TESTING \
  -O

"$test_dir/PhotokichinTests"
