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
core_library="$test_dir/libPhotokichinCore.dylib"
test_binary="$test_dir/PhotokichinTests"

swiftc \
  -parse-as-library \
  "${source_files[@]}" \
  -emit-library \
  -emit-module \
  -module-name PhotokichinCore \
  -enable-testing \
  -emit-module-path "$test_dir/PhotokichinCore.swiftmodule" \
  -o "$core_library" \
  -Xlinker -install_name \
  -Xlinker @rpath/libPhotokichinCore.dylib \
  -framework SwiftUI \
  -framework AppKit \
  -framework ImageIO \
  -framework ImageCaptureCore \
  -framework DiskArbitration \
  -framework UniformTypeIdentifiers \
  -lsqlite3 \
  -O

swiftc \
  -parse-as-library \
  "${test_files[@]}" \
  -I "$test_dir" \
  -L "$test_dir" \
  -lPhotokichinCore \
  -o "$test_binary" \
  -Xlinker -rpath \
  -Xlinker @executable_path \
  -framework SwiftUI \
  -framework AppKit \
  -framework ImageIO \
  -framework ImageCaptureCore \
  -framework DiskArbitration \
  -framework UniformTypeIdentifiers \
  -lsqlite3 \
  -O

"$test_binary"
