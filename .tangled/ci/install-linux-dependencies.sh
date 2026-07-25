#!/usr/bin/env bash

set -euo pipefail

export DEBIAN_FRONTEND=noninteractive

apt-get update
apt-get install --yes --no-install-recommends \
  build-essential \
  curl \
  libncurses5-dev \
  libsqlite3-dev \
  python3 \
  sqlite3 \
  zlib1g-dev
rm -rf /var/lib/apt/lists/*
