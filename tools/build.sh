#!/bin/sh
# Test, build static aarch64 hrneo and package the ipk into keenetic/aarch64-k3.10.
# Usage: tools/build.sh <path-to-HydraRoute-checkout> <version>
# Refuses uncommitted changes in Neo/source and writes <ipk>.source next to the
# package with the fork commit, the build image id and the binary's sha256, so a
# published package can be traced to its sources and rebuilt for comparison.
set -eu
HR=$(cd "$1" && pwd)
VER=$2
ROOT=$(cd "$(dirname "$0")/.." && pwd)
ARCH=aarch64-3.10
OUT="$ROOT/keenetic/aarch64-k3.10"

DIRTY=$(git -C "$HR" status --porcelain --untracked-files=all -- Neo/source ':(exclude)Neo/source/build')
if [ -n "$DIRTY" ]; then
    echo "Neo/source in $HR has uncommitted changes, commit them first:" >&2
    echo "$DIRTY" >&2
    exit 1
fi
COMMIT=$(git -C "$HR" rev-parse HEAD)
if [ "$(git -C "$HR" rev-parse -q --verify "refs/tags/v$VER^{commit}" || true)" != "$COMMIT" ]; then
    echo "warning: tag v$VER does not point at $COMMIT; tag and push it before publishing" >&2
fi

# Without a provenance attestation (which carries per-build data) the image id
# stays the same across cached rebuilds and changes when the toolchain does.
docker build -q --provenance=false -t hrneo-build "$ROOT/tools/docker" >/dev/null
IMAGE=$(docker image inspect -f '{{.Id}}' hrneo-build)
BIN_SHA=$(docker run --rm -v "$HR/Neo/source":/src -v "$ROOT":/release -w /src "$IMAGE" sh -euc "
  make clean >&2
  make check >&2
  make aarch64 CC_AARCH64=gcc VERSION=$VER >&2
  ./build/hrneo-aarch64 --version >&2
  /release/tools/build-ipk.sh /src build/hrneo-aarch64 $VER $ARCH /release/keenetic/aarch64-k3.10 >&2
  sha256sum build/hrneo-aarch64 | cut -d' ' -f1
")
printf 'version %s\ncommit %s\nimage %s\nbinary %s\n' "$VER" "$COMMIT" "$IMAGE" "$BIN_SHA" \
    > "$OUT/hrneo_${VER}_$ARCH.ipk.source"
echo "$OUT/hrneo_${VER}_$ARCH.ipk"
cat "$OUT/hrneo_${VER}_$ARCH.ipk.source"
