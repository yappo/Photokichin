#!/bin/zsh
set -euo pipefail

app_dir="${0:A:h}"
test_dir="$app_dir/.test-build"
rm -rf "$test_dir"
mkdir -p "$test_dir"
export CLANG_MODULE_CACHE_PATH="$test_dir/ModuleCache"

swiftc \
  -parse-as-library \
  "$app_dir/Sources/SourceIdentity.swift" \
  "$app_dir/Sources/LabelModels.swift" \
  "$app_dir/Sources/Models.swift" \
  "$app_dir/Sources/PhotoScanner.swift" \
  "$app_dir/Sources/CatalogStore.swift" \
  "$app_dir/Sources/FileTransfer.swift" \
  "$app_dir/Tests/TestRunner.swift" \
  -o "$test_dir/PhotokichinTests" \
  -framework AppKit \
  -framework ImageIO \
  -framework UniformTypeIdentifiers \
  -lsqlite3 \
  -O

"$test_dir/PhotokichinTests"
