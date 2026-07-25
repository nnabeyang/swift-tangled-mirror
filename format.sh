#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "$0")"

find . -type d \( \
  -name "DerivedData" \
  -o -name ".build" \
  -o -name ".swiftpm" \
  -o -name ".git" \
\) -prune -o -type f -name "*.swift" \
  -exec xcrun swift-format format --parallel --in-place {} +
