#!/bin/sh
# Test, build static aarch64 hrneo and package the ipk into keenetic/aarch64-k3.10.
# Usage: tools/build.sh <path-to-HydraRoute-checkout> <version>
set -eu
HR=$(cd "$1" && pwd)
VER=$2
ROOT=$(cd "$(dirname "$0")/.." && pwd)
docker build -q -t hrneo-build "$ROOT/tools/docker" >/dev/null
docker run --rm -v "$HR/Neo/source":/src -v "$ROOT":/release -w /src hrneo-build sh -euc "
  make clean
  make check
  make aarch64 CC_AARCH64=gcc VERSION=$VER
  ./build/hrneo-aarch64 --version
  /release/tools/build-ipk.sh /src build/hrneo-aarch64 $VER aarch64-3.10 /release/keenetic/aarch64-k3.10
"
