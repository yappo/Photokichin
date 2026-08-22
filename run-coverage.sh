#!/bin/zsh
set -euo pipefail

app_dir="${0:A:h}"

swift test \
  --package-path "$app_dir" \
  --enable-code-coverage \
  "$@"

echo
echo "SwiftPM coverage JSON:"
swift test --package-path "$app_dir" --show-codecov-path
