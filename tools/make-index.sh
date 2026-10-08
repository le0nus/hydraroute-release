#!/bin/sh
# Generate opkg Packages and Packages.gz for every keenetic/<arch>/ directory.
# Usage: tools/make-index.sh [feed root, default: this repository]
set -eu
ROOT=${1:-$(cd "$(dirname "$0")/.." && pwd)}
for dir in "$ROOT"/keenetic/*/; do
    ls "$dir"*.ipk >/dev/null 2>&1 || continue
    : > "$dir/Packages"
    for ipk in "$dir"*.ipk; do
        tar -xzOf "$ipk" ./control.tar.gz | tar -xzOf - ./control | sed '/^$/d' >> "$dir/Packages"
        {
            echo "Filename: $(basename "$ipk")"
            echo "Size: $(wc -c < "$ipk" | tr -d ' ')"
            echo "SHA256sum: $(sha256sum "$ipk" | cut -d' ' -f1)"
            echo
        } >> "$dir/Packages"
    done
    gzip -9nc "$dir/Packages" > "$dir/Packages.gz"
done
