#!/bin/zsh
set -euo pipefail

# This command builds the same non-UI product sources as run-tests.sh with
# LLVM line instrumentation, runs every deterministic test, and prints a
# file-by-file report. Tests and the SwiftUI application entry point are not
# included in the reported total. The percentage is the proportion of product
# source lines executed by this test run; it is not a performance measurement,
# and this script intentionally has no minimum threshold yet.

app_dir="${0:A:h}"
coverage_dir="$(mktemp -d /private/tmp/Photokichin-coverage.XXXXXX)"
trap 'rm -rf "$coverage_dir"' EXIT
export CLANG_MODULE_CACHE_PATH="$coverage_dir/ModuleCache"

source_files=()
for source in "$app_dir"/Sources/*.swift; do
    [[ "$source" == "$app_dir/Sources/PhotokichinApp.swift" ]] && continue
    source_files+=("$source")
done
test_files=("$app_dir"/Tests/*.swift)
test_binary="$coverage_dir/PhotokichinTests"
core_library="$coverage_dir/libPhotokichinCore.dylib"

swiftc \
  -parse-as-library \
  "${source_files[@]}" \
  -emit-library \
  -emit-module \
  -module-name PhotokichinCore \
  -enable-testing \
  -emit-module-path "$coverage_dir/PhotokichinCore.swiftmodule" \
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
  -O \
  -profile-generate \
  -profile-coverage-mapping

swiftc \
  -parse-as-library \
  "${test_files[@]}" \
  -I "$coverage_dir" \
  -L "$coverage_dir" \
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
  -O \
  -profile-generate \
  -profile-coverage-mapping

export LLVM_PROFILE_FILE="$coverage_dir/PhotokichinTests-%m-%p.profraw"
"$test_binary"

profile_data="$coverage_dir/PhotokichinTests.profdata"
xcrun llvm-profdata merge -sparse "$coverage_dir"/*.profraw -o "$profile_data"

echo
echo "Coverage scope: product Sources except PhotokichinApp.swift; Tests excluded"
echo "Coverage meaning: executed product source lines in this deterministic test run"
xcrun llvm-cov report \
  "$test_binary" \
  -object "$core_library" \
  -instr-profile="$profile_data" \
  -ignore-filename-regex='/(Tests|PhotokichinApp\.swift)(/|$)'
