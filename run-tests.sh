#!/bin/zsh
set -euo pipefail

app_dir="${0:A:h}"
exec swift test --package-path "$app_dir" "$@"
