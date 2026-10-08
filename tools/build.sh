#!/bin/sh
# Test, build static aarch64 hrneo and package the ipk into keenetic/aarch64-k3.10.
# Usage: tools/build.sh <path-to-HydraRoute-checkout> <version>
# <version> may carry an opkg epoch (1:3.21.0-1le2): it goes into the package's
# Version only; the binary, the file name and the source tag use the rest.
# Refuses uncommitted changes in Neo/source and writes <ipk>.source next to the
# package with the fork commit, the build image id and the binary's sha256, so a
# published package can be traced to its sources and rebuilt for comparison.
# The binary must report the version it was built as, and the packaged binary
# must be the one whose sha256 is recorded.
set -eu
HR=$(cd "$1" && pwd)
VER=$2
UPVER=${VER#*:}
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
if [ "$(git -C "$HR" rev-parse -q --verify "refs/tags/v$UPVER^{commit}" || true)" != "$COMMIT" ]; then
    echo "warning: tag v$UPVER does not point at $COMMIT; tag and push it before publishing" >&2
fi

# Without a provenance attestation (which carries per-build data) the image id
# stays the same across cached rebuilds and changes when the toolchain does.
docker build -q --provenance=false -t hrneo-build "$ROOT/tools/docker" >/dev/null
IMAGE=$(docker image inspect -f '{{.Id}}' hrneo-build)
BIN_SHA=$(docker run --rm -e VER="$VER" -e UPVER="$UPVER" -e ARCH="$ARCH" \
    -v "$HR/Neo/source":/src -v "$ROOT":/release -w /src "$IMAGE" sh -euc '
  make clean >&2
  make check >&2
  sh /release/tools/test-ipk.sh /src >&2
  sh /release/tools/test-install-feed.sh >&2
  make aarch64 CC_AARCH64=gcc VERSION="$UPVER" >&2
  GOT=$(./build/hrneo-aarch64 --version)
  echo "$GOT" >&2
  [ "$GOT" = "hrneo v$UPVER" ] || { echo "build.sh: the binary says \"$GOT\", want \"hrneo v$UPVER\"" >&2; exit 1; }
  IPK=$(sh /release/tools/build-ipk.sh /src build/hrneo-aarch64 "$VER" "$ARCH" /release/keenetic/aarch64-k3.10)
  echo "$IPK" >&2
  BIN=$(sha256sum build/hrneo-aarch64)
  PKG=$(tar -xzOf "$IPK" ./data.tar.gz | tar -xzOf - ./opt/bin/hrneo | sha256sum)
  [ "${PKG%% *}" = "${BIN%% *}" ] || { echo "build.sh: the packaged opt/bin/hrneo is not build/hrneo-aarch64" >&2; exit 1; }
  echo "${BIN%% *}"
')
printf 'version %s\ncommit %s\nimage %s\nbinary %s\n' "$VER" "$COMMIT" "$IMAGE" "$BIN_SHA" \
    > "$OUT/hrneo_${UPVER}_$ARCH.ipk.source"
echo "$OUT/hrneo_${UPVER}_$ARCH.ipk"
cat "$OUT/hrneo_${UPVER}_$ARCH.ipk.source"
