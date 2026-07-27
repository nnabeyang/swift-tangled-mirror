#!/usr/bin/env bash

set -euo pipefail

REPOSITORY_ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
readonly REPOSITORY_ROOT

swift build --package-path "${REPOSITORY_ROOT}" --product tng
swift build --package-path "${REPOSITORY_ROOT}" --target ManualSiteGenerator

BIN_DIRECTORY="$(swift build --package-path "${REPOSITORY_ROOT}" --show-bin-path)"
readonly BIN_DIRECTORY

arguments=(
  --tool "${BIN_DIRECTORY}/tng"
  --source "${REPOSITORY_ROOT}/Documentation/Manual"
  --output "${REPOSITORY_ROOT}/docs"
)

if [[ "${1:-}" == "--check" ]]; then
  arguments+=(--check)
elif [[ $# -ne 0 ]]; then
  printf 'usage: %s [--check]\n' "$0" >&2
  exit 64
fi

"${BIN_DIRECTORY}/ManualSiteGenerator" "${arguments[@]}"
