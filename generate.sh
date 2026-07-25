#!/bin/bash
set -e
cd "$(dirname "$0")"
swift package \
  --disable-experimental-prebuilts \
  plugin \
  --allow-writing-to-package-directory \
  --allow-network-connections all:443 \
  swift-atproto

# Bobbin currently emits both modern and legacy blob-link representations for
# pull records. Keep reads on SwiftTangled's compatibility decoder while using
# the generated pull type for PDS writes.
unknown_value="Sources/TangledLexicons/UnknownATPValue.swift"
temporary_file="${unknown_value}.tmp"
trap 'rm -f "$temporary_file"' EXIT
awk '!/"sh.tangled.repo.pull": Sh.Tangled.RepoPull.self,/ &&
     !/"sh.tangled.feed.comment": Sh.Tangled.FeedComment.self,/' \
  "$unknown_value" > "$temporary_file"
mv "$temporary_file" "$unknown_value"
