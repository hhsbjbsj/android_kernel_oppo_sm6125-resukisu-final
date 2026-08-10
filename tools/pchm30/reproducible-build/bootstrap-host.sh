#!/usr/bin/env bash
set -Eeuo pipefail

sudo apt-get update
sudo apt-get install -y \
  build-essential make git curl wget ca-certificates \
  python3 python3-pip python3-venv python3-jinja2 \
  bc bison flex libssl-dev libelf-dev libncurses-dev \
  device-tree-compiler cpio gzip xz-utils zstd rsync \
  unzip zip tar openssl coreutils binutils file

echo
for x in make git python3 nproc nm readelf objcopy sha256sum openssl file; do
  command -v "$x" || true
done
