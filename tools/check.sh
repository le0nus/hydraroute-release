#!/bin/sh
# Run the hrneo unit tests and the feed tool tests in the build container.
# Usage: tools/check.sh <path-to-HydraRoute-checkout>
set -eu
HR=$(cd "$1" && pwd)
ROOT=$(cd "$(dirname "$0")/.." && pwd)
docker build -q -t hrneo-build "$ROOT/tools/docker" >/dev/null
docker run --rm -v "$HR/Neo/source":/src -v "$ROOT":/release -w /src hrneo-build sh -euc '
  make clean && make check
  sh /release/tools/test-ipk.sh /src
  sh /release/tools/test-install-feed.sh
'
