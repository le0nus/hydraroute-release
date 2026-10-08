#!/bin/sh
# Add the le0nus HydraRoute feed to Entware opkg, install hrneo from it and hold it.
# Usage: curl -fsSL https://raw.githubusercontent.com/le0nus/hydraroute-release/main/keenetic/install-feed.sh | sh
# Everything runs from main on the last line, so a truncated download runs nothing.
#
# Fork builds carry opkg epoch 1 (1:3.21.0-1le2), so opkg ranks them above any
# upstream hrneo and no force is needed. A newer hrneo already installed stays:
# this never downgrades, and says how to go back by hand. The package file is
# downloaded here and installed only if its size and sha256 match the feed's
# index, because opkg checks SHA256sum only for packages it downloads itself.
# Exit code 0: hrneo from the feed is installed and held; 1: it is not, and the
# message says why and what to do; 129, 130, 143: stopped by HUP, INT, TERM.
# Its temporary directory goes in every case.
set -eu

BASE="https://raw.githubusercontent.com/le0nus/hydraroute-release/main/keenetic"
FEED=le0nus-hr
CONF=/opt/etc/opkg/customfeeds.conf
TMP=

die() {
    echo "install-feed: $*" >&2
    exit 1
}

cleanup() {
    if [ -n "$TMP" ]; then
        rm -rf "$TMP"
    fi
}

fetch() {
    if command -v curl > /dev/null 2>&1; then
        curl -fsSL --connect-timeout 30 --max-time 600 "$1"
    else
        wget -q -T 30 -O- "$1"
    fi
}

# Whether opkg ranks version $1 above version $2.
newer() {
    rc=0
    opkg compare-versions "$1" '>>' "$2" < /dev/null || rc=$?
    case $rc in
        0) return 0 ;;
        1) return 1 ;;
    esac
    die "opkg compare-versions $1 '>>' $2 failed (exit $rc)"
}

# Sets CUR (the installed hrneo version, empty if none), CUR_WANT, CUR_FLAGS
# and CUR_STATE from the hrneo record of opkg status (Status: want flags state).
read_status() {
    if ! STATUS=$(opkg status hrneo); then
        die "opkg status hrneo failed"
    fi
    REC=$(printf '%s\n' "$STATUS" | awk '
        $1 == "Package:" { p = ($2 == "hrneo"); n += p }
        p && $1 == "Version:" { v = $2 }
        p && $1 == "Status:" { w = $2; f = $3; s = $4; if (NF != 4) bad = 1 }
        END {
            if (n == 0) exit
            if (n > 1 || bad || v == "" || s == "") print "bad"
            else print "ok", v, w, f, s
        }')
    read -r KIND CUR CUR_WANT CUR_FLAGS CUR_STATE <<EOF
$REC
EOF
    case $KIND in
        ''|ok) ;;
        *) die "cannot read the hrneo record of opkg status:
$STATUS" ;;
    esac
}

held() {
    case ",$CUR_FLAGS," in
        *,hold,*) return 0 ;;
    esac
    return 1
}

# Whether opkg shows WANT fully installed: wanted, unpacked and configured.
fully_installed() {
    [ "$CUR" = "$WANT" ] && [ "$CUR_WANT" = install ] && [ "$CUR_STATE" = installed ]
}

# Makes "src/gz le0nus-hr <BASE>/<DIR>" the one line of this feed in CONF. An
# older line of it with another address (the GitHub Pages one) would have opkg
# read the feed twice; other feeds and comments stay as they are.
set_feed() {
    LINE="src/gz $FEED $BASE/$DIR"
    mkdir -p "${CONF%/*}" || die "cannot create ${CONF%/*}"
    if [ ! -f "$CONF" ]; then
        echo "$LINE" > "$CONF" || die "cannot write $CONF"
        return 0
    fi
    COUNT=$(awk -v f="$FEED" -v l="$LINE" '
        ($1 == "src" || $1 == "src/gz") && $2 == f { n++; if ($0 == l) e++ }
        END { print n + 0, e + 0 }' "$CONF") || die "cannot read $CONF"
    [ "$COUNT" != "1 1" ] || return 0
    { awk -v f="$FEED" '!(($1 == "src" || $1 == "src/gz") && $2 == f)' "$CONF" &&
        echo "$LINE"; } > "$CONF.new" || die "cannot write $CONF.new"
    mv "$CONF.new" "$CONF" || die "cannot replace $CONF"
}

# Reads the hrneo record for ARCH from $TMP/Packages into WANT, IPK, SIZE and
# SUM. A record ends at a blank line, and every field comes from the one
# record that names both hrneo and ARCH; such a record that is incomplete or
# malformed stops the install. Of several such records the highest version
# wins; two with the same version stop it.
pick_record() {
    awk -v arch="$ARCH" '
        function reset() { pkg = ar = ver = fn = size = sum = why = ""; split("", seen) }
        function end_record() {
            if (pkg == "hrneo" && ar == arch) {
                if (why == "" && (ver == "" || fn == "" || size == "" || sum == ""))
                    why = "a Version, Filename, Size or SHA256sum field is missing"
                if (why == "" && ver !~ /^[0-9A-Za-z.+~:-]+$/) why = "bad Version " ver
                if (why == "" && ver !~ /le[0-9]/) why = "Version " ver " is not a fork version"
                if (why == "" && (fn !~ /^[A-Za-z0-9][A-Za-z0-9._+~-]*\.ipk$/ || index(fn, "..")))
                    why = "bad Filename " fn
                if (why == "" && size !~ /^[1-9][0-9]*$/) why = "bad Size " size
                if (why == "" && (length(sum) != 64 || sum ~ /[^0-9A-Fa-f]/)) why = "bad SHA256sum " sum
                if (why != "") {
                    gsub(/[^ -~]/, "?", why)
                    print "bad", why
                } else {
                    print "ok", ver, fn, size, tolower(sum)
                }
            }
            reset()
        }
        BEGIN { reset() }
        /^[ \t]*$/ { end_record(); next }
        /^[ \t]/ { next }
        {
            i = index($0, ":")
            if (i == 0) { why = "a line without a colon"; next }
            name = substr($0, 1, i - 1)
            val = substr($0, i + 1)
            sub(/^[ \t]+/, "", val)
            sub(/[ \t]+$/, "", val)
            if (name in seen) why = "two " name " fields"
            seen[name] = 1
            if (name == "Package") pkg = val
            else if (name == "Architecture") ar = val
            else if (name == "Version") ver = val
            else if (name == "Filename") fn = val
            else if (name == "Size") size = val
            else if (name == "SHA256sum") sum = val
        }
        END { end_record() }' "$TMP/Packages" > "$TMP/records" || die "cannot read $TMP/Packages"
    WANT=
    while read -r KIND REST; do
        [ "$KIND" = ok ] ||
            die "$BASE/$DIR/Packages has a broken hrneo record for $ARCH: $REST; not installing"
        read -r V F Z S <<EOF
$REST
EOF
        if [ -z "$WANT" ] || newer "$V" "$WANT"; then
            WANT=$V IPK=$F SIZE=$Z SUM=$S
        elif ! newer "$WANT" "$V"; then
            die "$BASE/$DIR/Packages lists hrneo $V for $ARCH twice; not installing"
        fi
    done < "$TMP/records"
    [ -n "$WANT" ] || die "$BASE/$DIR/Packages has no hrneo record for $ARCH"
}

# Holds hrneo, then checks that opkg shows WANT installed and held.
hold() {
    opkg flag hold hrneo || die "opkg flag hold hrneo failed"
    read_status
    if ! fully_installed || ! held; then
        die "opkg status shows hrneo ${CUR:-not installed}, status ${CUR_WANT:-none} ${CUR_FLAGS:-none} ${CUR_STATE:-none}; expected $WANT installed and held"
    fi
}

refuse() {
    cat >&2 <<EOF
install-feed: hrneo $CUR is installed, newer than $WANT in $FEED; not downgrading.
To go back to an older hrneo by hand, take the raw guard down first: hrneo's
prerm does that only when the package is removed, and an older hrneo left with
this one's raw chain (HRNEO_GUARD) lets new connections out unprotected.
  neo raw-off       # stops hrneo, waits for it to exit, removes HRNEO_GUARD;
                    # go on only if it exits 0 or 3 (3: removed, status file not saved)
  iptables -w -t raw -S; ip6tables -w -t raw -S    # neither may show HRNEO_GUARD
  opkg flag user hrneo
  opkg install --force-downgrade <the older hrneo .ipk>
  opkg flag hold hrneo
EOF
    exit 1
}

# opkg install failed or left hrneo short of WANT installed: put back the
# hold the installed package had and say what to do.
install_failed() {
    if [ -n "$CUR" ] && [ -n "$WAS_HELD" ]; then
        opkg flag hold hrneo > /dev/null || echo "install-feed: opkg flag hold hrneo failed too" >&2
    fi
    cat >&2 <<EOF
install-feed: opkg install exited with code $RC; opkg status shows hrneo ${CUR:-not installed}${CUR:+, status $CUR_WANT $CUR_FLAGS $CUR_STATE}; expected $WANT installed.
See the opkg output above. Fix what it names and run this installer again: it
finishes or repeats the installation. Or install by hand:
  curl -fsSLo /tmp/$IPK $BASE/$DIR/$IPK
  sha256sum /tmp/$IPK     # must print $SUM
  opkg flag user hrneo
  opkg install --force-reinstall /tmp/$IPK
  opkg flag hold hrneo
EOF
    exit 1
}

main() {
    # Non-interactive shells (ssh host cmd, cron) lack the Entware paths: opkg is
    # not found, or wget resolves to busybox, which cannot fetch https feeds.
    export PATH="/opt/sbin:/opt/bin:/opt/usr/sbin:/opt/usr/bin:$PATH"

    # Everything needed, checked before anything changes.
    command -v opkg > /dev/null 2>&1 || die "opkg not found; this needs Entware"
    command -v sha256sum > /dev/null 2>&1 ||
        die "sha256sum not found; opkg install coreutils-sha256sum and run this again"
    command -v mktemp > /dev/null 2>&1 ||
        die "mktemp not found; opkg install coreutils-mktemp and run this again"
    command -v curl > /dev/null 2>&1 || command -v wget > /dev/null 2>&1 ||
        die "neither curl nor wget found; opkg install curl and run this again"

    trap cleanup EXIT
    trap 'exit 129' HUP
    trap 'exit 130' INT
    trap 'exit 143' TERM
    TMP=$(mktemp -d) || die "mktemp -d failed"
    [ -d "$TMP" ] || die "mktemp -d made no directory"

    if ! ARCHES=$(opkg print-architecture); then
        die "opkg print-architecture failed"
    fi
    ARCH=$(printf '%s\n' "$ARCHES" | awk '$1 == "arch" && $2 !~ /_kn$/ && $2 ~ /-[0-9]+\.[0-9]+$/ {print $2; exit}')
    case "$ARCH" in
        aarch64-3.10) DIR=aarch64-k3.10 ;;
        *) die "unsupported architecture: ${ARCH:-none found} (only aarch64-3.10 is built so far)" ;;
    esac

    set_feed
    opkg update || die "opkg update failed; fix the feed it names above and run this again"

    fetch "$BASE/$DIR/Packages" > "$TMP/Packages" || die "cannot download $BASE/$DIR/Packages"
    pick_record
    read_status

    if [ -n "$CUR" ] && [ "$CUR" != "$WANT" ] && newer "$CUR" "$WANT"; then
        refuse
    fi
    if fully_installed; then
        hold
        echo "hrneo $WANT is already installed and held"
        return 0
    fi

    fetch "$BASE/$DIR/$IPK" > "$TMP/$IPK" || die "cannot download $BASE/$DIR/$IPK"
    GOT=$(wc -c < "$TMP/$IPK") || die "cannot read $TMP/$IPK"
    GOT=${GOT##* }
    [ "$GOT" = "$SIZE" ] ||
        die "$IPK is $GOT bytes, $BASE/$DIR/Packages says $SIZE; the download was cut short or the feed is being updated; not installing"
    SUMLINE=$(sha256sum "$TMP/$IPK") || die "sha256sum failed on $TMP/$IPK"
    GOT=${SUMLINE%% *}
    [ "$GOT" = "$SUM" ] || die "sha256 of $IPK is $GOT, $BASE/$DIR/Packages says $SUM; not installing"

    # The hold is released for the install, as the stage-1 installer did, and
    # set again below; if the install fails, the old package gets it back.
    WAS_HELD=
    if [ -n "$CUR" ]; then
        if held; then
            WAS_HELD=1
        fi
        opkg flag user hrneo > /dev/null || die "opkg flag user hrneo failed"
    fi
    # The same version not fully installed: an earlier run stopped half way.
    FORCE=
    if [ "$CUR" = "$WANT" ]; then
        FORCE=--force-reinstall
    fi
    RC=0
    opkg install $FORCE "$TMP/$IPK" || RC=$?
    read_status
    if [ "$RC" != 0 ] || ! fully_installed; then
        install_failed
    fi
    hold
    echo "hrneo $WANT installed from $FEED and held"
}

main "$@"
