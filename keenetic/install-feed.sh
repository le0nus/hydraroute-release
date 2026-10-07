#!/bin/sh
# Add the le0nus HydraRoute feed to Entware opkg, install hrneo from it and hold it.
# Usage: curl -fsSL https://le0nus.github.io/hydraroute-release/keenetic/install-feed.sh | sh
# Everything runs from main on the last line, so a truncated download runs nothing.
set -eu

BASE="https://le0nus.github.io/hydraroute-release/keenetic"
CONF=/opt/etc/opkg/customfeeds.conf

die() {
    echo "install-feed: $*" >&2
    exit 1
}

fetch() {
    if command -v curl >/dev/null 2>&1; then
        curl -fsSL "$1"
    else
        wget -qO- "$1"
    fi
}

installed_version() {
    opkg list-installed hrneo 2>/dev/null | awk '$1 == "hrneo" {print $3}'
}

main() {
    # Non-interactive shells (ssh host cmd, cron) lack the Entware paths: opkg is
    # not found, or wget resolves to busybox, which cannot fetch https feeds.
    export PATH="/opt/sbin:/opt/bin:/opt/usr/sbin:/opt/usr/bin:$PATH"

    ARCH=$(opkg print-architecture | awk '/^arch/ && $2 !~ /_kn$/ && $2 ~ /-[0-9]+\.[0-9]+$/ {print $2; exit}')
    case "$ARCH" in
        aarch64-3.10) DIR=aarch64-k3.10 ;;
        *) die "unsupported architecture: $ARCH (only aarch64-3.10 is built so far)" ;;
    esac

    LINE="src/gz le0nus-hr $BASE/$DIR"
    mkdir -p /opt/etc/opkg
    grep -qxF "$LINE" "$CONF" 2>/dev/null || echo "$LINE" >> "$CONF"
    opkg update

    # Upstream's feed is configured on every HydraRoute router and opkg takes the
    # highest version across feeds, even over a package given by URL. A local
    # package file is installed as given, so download the fork's package first.
    PACKAGES=$(fetch "$BASE/$DIR/Packages") || die "cannot download $BASE/$DIR/Packages"
    WANT=$(echo "$PACKAGES" | awk '$1 == "Package:" {p = ($2 == "hrneo")} p && $1 == "Version:" {print $2; exit}')
    IPK=$(echo "$PACKAGES" | awk '$1 == "Package:" {p = ($2 == "hrneo")} p && $1 == "Filename:" {print $2; exit}')
    [ -n "$WANT" ] && [ -n "$IPK" ] || die "hrneo is missing from $BASE/$DIR/Packages"
    case "$WANT" in
        *le[0-9]*) ;;
        *) die "$BASE/$DIR/Packages offers hrneo $WANT, which is not a fork version" ;;
    esac
    TMP=$(mktemp -d)
    trap 'rm -rf "$TMP"' EXIT
    fetch "$BASE/$DIR/$IPK" > "$TMP/$IPK" || die "cannot download $BASE/$DIR/$IPK"

    # Installing resets the hold flag, so hold the package again afterwards.
    [ -z "$(installed_version)" ] || opkg flag user hrneo >/dev/null
    opkg install --force-downgrade "$TMP/$IPK" || true

    VER=$(installed_version)
    if [ "$VER" != "$WANT" ]; then
        case "$VER" in *le[0-9]*) opkg flag hold hrneo >/dev/null ;; esac
        cat >&2 <<EOF
install-feed: hrneo ${VER:-is not installed}${VER:+ is installed}, expected the le0nus fork build $WANT.
See the opkg output above. To install the fork build by hand:
  curl -fsSLo /tmp/$IPK $BASE/$DIR/$IPK
  opkg install --force-downgrade /tmp/$IPK
  opkg flag hold hrneo
EOF
        exit 1
    fi
    opkg flag hold hrneo
    echo "hrneo $VER installed from le0nus-hr and held"
}

main "$@"
