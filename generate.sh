#!/bin/bash
set -e
cd "$(dirname "$0")"
swift package \
  --disable-experimental-prebuilts \
  plugin \
  --allow-writing-to-package-directory \
  --allow-network-connections all:443 \
  swift-atproto
