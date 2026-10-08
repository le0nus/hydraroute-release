#!/bin/sh
# keenetic/install-feed.sh against fakes. Run inside hrneo-build:
#   sh tools/test-install-feed.sh
# Each scenario runs the installer in its own busybox sh, as on the router, from
# a copy whose /opt/ paths point into a scratch root. That root's /opt/bin holds
# the fakes (opkg, curl, wget) and busybox's sha256sum and mktemp; the rest of
# PATH holds only busybox applets, so a tool a scenario removes is missing.
# The fake opkg keeps the installed version, flags and state, installs what the
# control file of the given ipk says and compares versions the dpkg way, with
# digit runs compared as strings (leading zeros dropped, then length, then
# digits), so big numbers compare right. The feed is the output of the real
# make-index.sh, or a hand-written index where a scenario says so. Every
# scenario checks the exit code and that no temporary file is left; most check
# the whole log of opkg, curl and wget calls, so order and absence count.
# Writes only under a temporary directory.
set -u
TOOLS=$(cd "$(dirname "$0")" && pwd)
T=$(mktemp -d)
trap 'rm -rf "$T"' EXIT
RAW=https://raw.githubusercontent.com/le0nus/hydraroute-release/main/keenetic
URL="$RAW/aarch64-k3.10"
LE2=hrneo_3.21.0-1le2_aarch64-3.10.ipk
LE3=hrneo_3.21.0-1le3_aarch64-3.10.ipk
BIG2=hrneo_3.21.0-1le9007199254740992_aarch64-3.10.ipk
BIG3=hrneo_3.21.0-1le9007199254740993_aarch64-3.10.ipk
R="$T/root"
ST="$T/st"
SYS="$T/sys"
FIX="$T/fix"
EXTRA="$T/extra"
PRISTINE="$T/feed/keenetic/aarch64-k3.10"
CONF="$R/opt/etc/opkg/customfeeds.conf"
INSTALLER="$T/install-feed.sh"
FAILS=0
NAME=

fail() {
    echo "test-install-feed: $NAME: $*" >&2
    FAILS=$((FAILS + 1))
}

# --- fakes ------------------------------------------------------------------

mkdir -p "$T/fakes" "$SYS"
cat > "$T/fakes/opkg" <<'EOF'
#!/bin/sh
# Fake Entware opkg. State in $ST: version (empty: hrneo not installed),
# want (none: install), flags, state. Knobs: arch, arch_rc, update_rc,
# status_rc, status_fail_calls (numbers of the status calls that fail),
# compare_rc, flag_mode (fail: exit 1; noop: says it set the flag and does
# not; noop-hold: the same for hold only), install_modes (one line per install: ok, fail-before, nothing,
# postinst-fails, fail-after, unpacked-ok; none left: ok), install_hang
# (install writes installer.pid and opkg.pid, then waits for $ST/go before
# it changes anything; a kill then leaves the state as it was), hold_hang
# (the same for "flag hold", with hold.pid and $ST/go2).
echo "opkg $*" >> "$ST/log"
knob() { cat "$ST/$1" 2>/dev/null; }
VERCMP='
function ord(c) {
    if (c == "" || c ~ /[0-9]/) return 0
    if (c == "~") return -1
    if (c ~ /[A-Za-z]/) return index(PR, c)
    return index(PR, c) + 256
}
function verrev(x, y,    cx, cy, dx, dy) {
    while (x != "" || y != "") {
        while ((x != "" && substr(x, 1, 1) !~ /[0-9]/) || (y != "" && substr(y, 1, 1) !~ /[0-9]/)) {
            cx = ord(substr(x, 1, 1)); cy = ord(substr(y, 1, 1))
            if (cx != cy) return cx < cy ? -1 : 1
            x = substr(x, 2); y = substr(y, 2)
        }
        dx = ""; while (x != "" && substr(x, 1, 1) ~ /[0-9]/) { dx = dx substr(x, 1, 1); x = substr(x, 2) }
        dy = ""; while (y != "" && substr(y, 1, 1) ~ /[0-9]/) { dy = dy substr(y, 1, 1); y = substr(y, 2) }
        sub(/^0+/, "", dx); sub(/^0+/, "", dy)
        if (length(dx) != length(dy)) return length(dx) < length(dy) ? -1 : 1
        if (dx != dy) return ("x" dx) < ("x" dy) ? -1 : 1
    }
    return 0
}
function parts(v, P,    i) {
    P["e"] = "0"
    if ((i = index(v, ":")) > 0) { P["e"] = substr(v, 1, i - 1); v = substr(v, i + 1) }
    P["u"] = v; P["r"] = ""
    if (match(v, /-[^-]*$/)) { P["u"] = substr(v, 1, RSTART - 1); P["r"] = substr(v, RSTART + 1) }
}
BEGIN {
    PR = "!#$%&()*+,-./0123456789:;<=>?@ABCDEFGHIJKLMNOPQRSTUVWXYZ[]^_`abcdefghijklmnopqrstuvwxyz{|}"
    parts(a, A); parts(b, B)
    r = verrev(A["e"], B["e"])
    if (r == 0) r = verrev(A["u"], B["u"])
    if (r == 0) r = verrev(A["r"], B["r"])
    print r
}'
cmpv() { awk -v a="$1" -v b="$2" "$VERCMP"; }
case "$1" in
    print-architecture)
        cat "$ST/arch"
        exit "$(knob arch_rc)"
        ;;
    update)
        exit "$(knob update_rc)"
        ;;
    list-installed)
        [ ! -s "$ST/version" ] || echo "hrneo - $(knob version)"
        ;;
    status)
        n=$(($(knob status_calls || echo 0) + 1))
        echo "$n" > "$ST/status_calls"
        for c in $(knob status_fail_calls); do
            [ "$c" != "$n" ] || exit 255
        done
        rc=$(knob status_rc)
        [ "$rc" = 0 ] || exit "$rc"
        [ -s "$ST/version" ] || exit 0
        printf 'Package: hrneo\nVersion: %s\nDepends: libc, ipset, iptables, ip-full\nStatus: %s %s %s\nArchitecture: aarch64-3.10\nInstalled-Time: 1700000000\n\n' \
            "$(knob version)" "$(knob want)" "$(knob flags)" "$(knob state)"
        ;;
    flag)
        if [ "$2" = hold ] && [ -e "$ST/hold_hang" ]; then
            echo "$PPID" > "$ST/installer.pid"
            echo "$$" > "$ST/hold.pid"
            while [ ! -e "$ST/go2" ]; do usleep 20000; done
        fi
        [ "$(knob flag_mode)" != fail ] || exit 1
        if [ ! -s "$ST/version" ]; then
            echo " * opkg_flag_cmd: Package $3 is not installed." >&2
            exit 0
        fi
        case "$(knob flag_mode):$2" in
            noop:*|noop-hold:hold) ;;
            *) echo "$2" > "$ST/flags" ;;
        esac
        echo "Setting flags for package $3 to $2."
        ;;
    install)
        shift
        opts=
        while [ $# -gt 1 ]; do
            opts="$opts $1"
            shift
        done
        new=$(tar -xzOf "$1" ./control.tar.gz | tar -xzOf - ./control | awk '$1 == "Version:" {print $2}')
        [ -n "$new" ] || { echo " * opkg_install_cmd: Cannot read $1." >&2; exit 255; }
        if [ -e "$ST/install_hang" ]; then
            echo "$PPID" > "$ST/installer.pid"
            echo "$$" > "$ST/opkg.pid"
            while [ ! -e "$ST/go" ]; do usleep 20000; done
        fi
        mode=$(head -n 1 "$ST/install_modes")
        sed -i 1d "$ST/install_modes"
        old=$(knob version)
        if [ -n "$old" ]; then
            r=$(cmpv "$old" "$new")
            if [ "$r" = 0 ] && [ "$opts" != " --force-reinstall" ]; then
                echo "Package hrneo ($new) installed in root is up to date."
                exit 0
            fi
            if [ "$r" = 1 ] && [ "$opts" != " --force-downgrade" ]; then
                echo "Not downgrading package hrneo on root from $old to $new."
                exit 0
            fi
        fi
        case "${mode:-ok}" in
            fail-before)
                echo " * opkg_install_cmd: Cannot install package hrneo." >&2
                exit 255
                ;;
            nothing) exit 0 ;;
        esac
        echo "$new" > "$ST/version"
        echo install > "$ST/want"
        echo user > "$ST/flags"
        case "${mode:-ok}" in
            ok)
                echo installed > "$ST/state"
                echo "Configuring hrneo."
                ;;
            postinst-fails)
                echo unpacked > "$ST/state"
                echo ' * pkg_run_script: package "hrneo" postinst script returned status 1.' >&2
                exit 1
                ;;
            fail-after)
                echo installed > "$ST/state"
                echo " * opkg_install_cmd: Cannot install package hrneo." >&2
                exit 1
                ;;
            unpacked-ok) echo unpacked > "$ST/state" ;;
        esac
        ;;
    compare-versions)
        rc=$(knob compare_rc)
        [ -z "$rc" ] || exit "$rc"
        r=$(cmpv "$2" "$4")
        case "$3" in
            '<<') [ "$r" -lt 0 ] ;;
            '>>') [ "$r" -gt 0 ] ;;
            '=') [ "$r" -eq 0 ] ;;
            '<='|'<') [ "$r" -le 0 ] ;;
            '>='|'>') [ "$r" -ge 0 ] ;;
            *) echo "Unknown operator: $3." >&2; exit 255 ;;
        esac
        exit $?
        ;;
    *)
        echo "fake opkg: unexpected command: $*" >&2
        exit 255
        ;;
esac
exit 0
EOF

cat > "$T/fakes/fetch" <<'EOF'
#!/bin/sh
# Fake curl and wget: the URL is the last argument; any .../aarch64-k3.10/<name>
# serves $FIX/<name>. fetch_modes lines "<name> <mode>": fail; cut (part of the
# file, then an error); short (part of the file, no error); hang (waits for
# $ST/go, its pid in $ST/fetch.pid).
tool=${0##*/}
for url; do :; done
echo "$tool $url" >> "$ST/log"
name=${url##*/}
case "$url" in
    */aarch64-k3.10/"$name") ;;
    *) echo "$tool: (22) The requested URL returned error: 404" >&2; exit 22 ;;
esac
mode=$(awk -v n="$name" '$1 == n {print $2}' "$ST/fetch_modes")
case "$mode" in
    fail) echo "$tool: (22) The requested URL returned error: 404" >&2; exit 22 ;;
    cut) head -c 100 "$FIX/$name"; echo "$tool: (18) transfer closed with outstanding read data remaining" >&2; exit 18 ;;
    short) head -c 100 "$FIX/$name"; exit 0 ;;
    hang)
        echo $$ > "$ST/fetch.pid"
        while [ ! -e "$ST/go" ]; do usleep 20000; done
        exit 28
        ;;
esac
[ -f "$FIX/$name" ] || { echo "$tool: (22) The requested URL returned error: 404" >&2; exit 22; }
cat "$FIX/$name"
EOF

# The rest of the installer's PATH: busybox applets only.
for a in awk basename cat chmod cp cut date dirname env grep gzip head ln ls mkdir mv \
         printf rm sed sleep sort tail tar touch tr usleep wc; do
    ln -s /bin/busybox "$SYS/$a"
done

# --- fixture feed -------------------------------------------------------------

mkipk() {   # <file> <version>: a minimal hrneo ipk with that version
    d=$(mktemp -d "$T/ipk.XXXXXX")
    mkdir -p "$d/c" "$d/d/opt/bin"
    printf 'Package: hrneo\nVersion: %s\nDepends: libc\nArchitecture: aarch64-3.10\nInstalled-Size: 1\nMaintainer: test\nDescription: test package\nSection: net\n' \
        "$2" > "$d/c/control"
    printf '#!/bin/sh\necho "hrneo v%s"\n' "${2#*:}" > "$d/d/opt/bin/hrneo"
    echo 2.0 > "$d/debian-binary"
    (cd "$d/c" && tar -czf ../control.tar.gz ./) &&
        (cd "$d/d" && tar -czf ../data.tar.gz ./) &&
        (cd "$d" && tar -czf "$1" ./debian-binary ./control.tar.gz ./data.tar.gz) ||
        { echo "test-install-feed: cannot make $1" >&2; exit 1; }
    rm -rf "$d"
}

record() {  # <ipk> <version> [arch]: an index record for it, as make-index.sh writes one
    printf 'Package: hrneo\nVersion: %s\nArchitecture: %s\nFilename: %s\nSize: %s\nSHA256sum: %s\n\n' \
        "$2" "${3:-aarch64-3.10}" "${1##*/}" "$(wc -c < "$1" | tr -d ' ')" "$(sha256sum "$1" | cut -d' ' -f1)"
}

sum_of() { sha256sum "$1" | cut -d' ' -f1; }
size_of() { wc -c < "$1" | tr -d ' '; }

mkdir -p "$PRISTINE" "$EXTRA" "$T/mi/tools"
mkipk "$PRISTINE/$LE2" 1:3.21.0-1le2
mkipk "$EXTRA/$LE3" 1:3.21.0-1le3
mkipk "$EXTRA/$BIG2" 1:3.21.0-1le9007199254740992
mkipk "$EXTRA/$BIG3" 1:3.21.0-1le9007199254740993
# make-index.sh runs from a copy: whatever its default root, it never touches this repository.
cp "$TOOLS/make-index.sh" "$T/mi/tools/"
sh "$T/mi/tools/make-index.sh" "$T/feed" > "$T/out" 2>&1 ||
    { echo "test-install-feed: make-index.sh failed: $(cat "$T/out")" >&2; exit 1; }
[ -s "$PRISTINE/Packages" ] || { echo "test-install-feed: make-index.sh wrote no $PRISTINE/Packages" >&2; exit 1; }
LE2_SUM=$(sum_of "$PRISTINE/$LE2")
LE2_SIZE=$(size_of "$PRISTINE/$LE2")

sed "s#/opt/#$R/opt/#g" "$TOOLS/../keenetic/install-feed.sh" > "$INSTALLER"

# --- harness ------------------------------------------------------------------

# A fresh router: Entware with the fakes, hrneo not installed, no feed file,
# the fixture feed, every opkg command working.
scenario() {
    NAME=$1
    rm -rf "$ST" "$R" "$FIX" "$T/tmp"
    mkdir -p "$ST" "$R/opt/bin" "$R/opt/etc/opkg" "$FIX" "$T/tmp"
    cp "$PRISTINE"/* "$FIX/"
    cp "$T/fakes/opkg" "$R/opt/bin/opkg"
    cp "$T/fakes/fetch" "$R/opt/bin/curl"
    cp "$T/fakes/fetch" "$R/opt/bin/wget"
    chmod 0755 "$R/opt/bin/opkg" "$R/opt/bin/curl" "$R/opt/bin/wget"
    ln -s /bin/busybox "$R/opt/bin/sha256sum"
    ln -s /bin/busybox "$R/opt/bin/mktemp"
    printf 'arch all 1\narch noarch 1\narch aarch64-3.10 10\n' > "$ST/arch"
    for k in arch_rc update_rc status_rc; do echo 0 > "$ST/$k"; done
    : > "$ST/version"
    : > "$ST/log"
    : > "$ST/install_modes"
    : > "$ST/fetch_modes"
}

installed() {   # <version> <flags> [state] [want]
    echo "$1" > "$ST/version"
    echo "$2" > "$ST/flags"
    echo "${3:-installed}" > "$ST/state"
    echo "${4:-install}" > "$ST/want"
}

# run <exit code> [script]: the installer (or another script) in its own busybox sh.
run() {
    want=$1
    env -i PATH="$SYS" TMPDIR="$T/tmp" ST="$ST" FIX="$FIX" /bin/busybox sh "${2:-$INSTALLER}" > "$T/out" 2>&1
    got=$?
    [ "$got" = "$want" ] || fail "exit $got, want $want; output: $(cat "$T/out")"
    left=$(ls -A "$T/tmp")
    [ -z "$left" ] || fail "left in TMPDIR: $left"
}

log_is() {
    got=$(sed "s#$T/tmp/[^/ ]*/#TMP/#g" "$ST/log")
    [ "$got" = "$1" ] || fail "log:
$got
want:
$1"
}

log_lacks() {
    if grep -q -e "$1" "$ST/log"; then fail "log has '$1': $(cat "$ST/log")"; fi
}

out_has() {
    grep -qF -e "$1" "$T/out" || fail "output lacks '$1': $(cat "$T/out")"
}

out_lacks() {
    if grep -qF -e "$1" "$T/out"; then fail "output has '$1': $(cat "$T/out")"; fi
}

# run_signalled <signal> <exit code> <finish|killed>: runs the installer and,
# once opkg install has started in the fake, sends the signal to the
# installer alone; then opkg is let finish its job, or is killed as well
# (as a Ctrl-C to the whole process group would).
run_signalled() {
    touch "$ST/install_hang"
    (
        n=0
        while [ ! -s "$ST/opkg.pid" ] && [ "$n" -lt 500 ]; do
            usleep 20000
            n=$((n + 1))
        done
        kill -"$1" "$(cat "$ST/installer.pid")"
        usleep 200000
        if [ "$3" = killed ]; then
            kill -TERM "$(cat "$ST/opkg.pid")"
        else
            touch "$ST/go"
        fi
    ) &
    run "$2"
    wait
}

state_is() {    # <version> <flags> <state>: and the want is install
    got="$(cat "$ST/version") $(cat "$ST/want" 2>/dev/null) $(cat "$ST/flags" 2>/dev/null) $(cat "$ST/state" 2>/dev/null)"
    [ "$got" = "$1 install $2 $3" ] || fail "opkg state: $got, want $1 install $2 $3"
}

not_installed() {
    [ ! -s "$ST/version" ] || fail "hrneo $(cat "$ST/version") got installed"
}

no_conf() {
    [ ! -e "$CONF" ] || fail "customfeeds.conf changed: $(cat "$CONF")"
}

conf_is() {
    [ "$(cat "$CONF" 2>/dev/null)" = "$1" ] || fail "customfeeds.conf:
$(cat "$CONF" 2>/dev/null)
want:
$1"
}

# The start every run that gets as far as the index shares, then the version check.
PRE_LOG="opkg print-architecture
opkg update
curl $URL/Packages"
HEAD_LOG="$PRE_LOG
opkg status hrneo"
INSTALL_LE2="curl $URL/$LE2
opkg install TMP/$LE2
opkg status hrneo
opkg flag hold hrneo
opkg status hrneo"

# --- the script itself ----------------------------------------------------------

NAME=script
grep -qxF "BASE=\"$RAW\"" "$TOOLS/../keenetic/install-feed.sh" || fail "BASE is not $RAW"
/bin/busybox sh -n "$INSTALLER" || fail "busybox sh -n"
[ "$(tail -n 1 "$INSTALLER")" = 'main "$@"' ] || fail "the last line is not main \"\$@\""

scenario truncated-download
# A download cut anywhere before the last line runs nothing.
sed '$d' "$INSTALLER" > "$T/cut.sh"
run 0 "$T/cut.sh"
log_is ""
no_conf
head -n 40 "$INSTALLER" > "$T/cut.sh"
env -i PATH="$SYS" TMPDIR="$T/tmp" ST="$ST" FIX="$FIX" /bin/busybox sh "$T/cut.sh" > "$T/out" 2>&1
log_is ""
no_conf

# --- installs and version decisions ------------------------------------------------

scenario fresh-install
run 0
log_is "$HEAD_LOG
$INSTALL_LE2"
state_is 1:3.21.0-1le2 hold installed
conf_is "src/gz le0nus-hr $URL"
out_has "hrneo 1:3.21.0-1le2 installed from le0nus-hr and held"
out_has "Setting flags for package hrneo to hold."

scenario over-newer-upstream
# opkg ranks epoch 1 above any upstream version: no force needed.
installed 3.22.0-1 user
run 0
log_is "$HEAD_LOG
opkg compare-versions 3.22.0-1 >> 1:3.21.0-1le2
curl $URL/$LE2
opkg flag user hrneo
opkg install TMP/$LE2
opkg status hrneo
opkg flag hold hrneo
opkg status hrneo"
state_is 1:3.21.0-1le2 hold installed

scenario over-stage1-held
installed 3.21.0-1le1 hold
run 0
log_is "$HEAD_LOG
opkg compare-versions 3.21.0-1le1 >> 1:3.21.0-1le2
curl $URL/$LE2
opkg flag user hrneo
opkg install TMP/$LE2
opkg status hrneo
opkg flag hold hrneo
opkg status hrneo"
state_is 1:3.21.0-1le2 hold installed
log_lacks force

scenario same-version-held
installed 1:3.21.0-1le2 hold
run 0
log_is "$HEAD_LOG
opkg flag hold hrneo
opkg status hrneo"
state_is 1:3.21.0-1le2 hold installed
out_has "hrneo 1:3.21.0-1le2 is already installed and held"

scenario same-version-not-held
installed 1:3.21.0-1le2 user
run 0
log_is "$HEAD_LOG
opkg flag hold hrneo
opkg status hrneo"
state_is 1:3.21.0-1le2 hold installed

scenario same-version-unpacked
# An earlier run's install stopped half way (postinst failed): install again.
installed 1:3.21.0-1le2 hold unpacked
run 0
log_is "$HEAD_LOG
curl $URL/$LE2
opkg flag user hrneo
opkg install --force-reinstall TMP/$LE2
opkg status hrneo
opkg flag hold hrneo
opkg status hrneo"
state_is 1:3.21.0-1le2 hold installed

scenario same-version-marked-for-removal
# Installed and configured, but opkg wants it gone: not complete, install again.
installed 1:3.21.0-1le2 hold installed deinstall
run 0
log_is "$HEAD_LOG
curl $URL/$LE2
opkg flag user hrneo
opkg install --force-reinstall TMP/$LE2
opkg status hrneo
opkg flag hold hrneo
opkg status hrneo"
state_is 1:3.21.0-1le2 hold installed

scenario newer-fork-installed
installed 1:3.21.0-1le3 hold
run 1
log_is "$HEAD_LOG
opkg compare-versions 1:3.21.0-1le3 >> 1:3.21.0-1le2"
state_is 1:3.21.0-1le3 hold installed
out_has "hrneo 1:3.21.0-1le3 is installed, newer than 1:3.21.0-1le2"
out_has "not downgrading"
out_has "neo raw-off"
out_has "exits 0 or 3"
out_has "HRNEO_GUARD"

scenario newer-fork-unpacked
installed 1:3.21.0-1le3 user unpacked
run 1
log_is "$HEAD_LOG
opkg compare-versions 1:3.21.0-1le3 >> 1:3.21.0-1le2"
state_is 1:3.21.0-1le3 user unpacked

scenario le2-to-le3
cp "$EXTRA/$LE3" "$FIX/"
record "$FIX/$LE3" 1:3.21.0-1le3 > "$FIX/Packages"
installed 1:3.21.0-1le2 hold
run 0
log_is "$HEAD_LOG
opkg compare-versions 1:3.21.0-1le2 >> 1:3.21.0-1le3
curl $URL/$LE3
opkg flag user hrneo
opkg install TMP/$LE3
opkg status hrneo
opkg flag hold hrneo
opkg status hrneo"
state_is 1:3.21.0-1le3 hold installed

scenario big-numbers-upgrade
# Floating point takes both for 9007199254740992; opkg does not.
cp "$EXTRA/$BIG3" "$FIX/"
record "$FIX/$BIG3" 1:3.21.0-1le9007199254740993 > "$FIX/Packages"
installed 1:3.21.0-1le9007199254740992 hold
run 0
state_is 1:3.21.0-1le9007199254740993 hold installed

scenario big-numbers-no-downgrade
cp "$EXTRA/$BIG2" "$FIX/"
record "$FIX/$BIG2" 1:3.21.0-1le9007199254740992 > "$FIX/Packages"
installed 1:3.21.0-1le9007199254740993 hold
run 1
log_lacks "^opkg install"
state_is 1:3.21.0-1le9007199254740993 hold installed
out_has "not downgrading"

# --- the index --------------------------------------------------------------------

scenario index-picks-highest
cp "$EXTRA/$LE3" "$FIX/"
{ record "$FIX/$LE3" 1:3.21.0-1le3; record "$FIX/$LE2" 1:3.21.0-1le2; } > "$FIX/Packages"
run 0
state_is 1:3.21.0-1le3 hold installed

scenario index-picks-highest-big
cp "$EXTRA/$BIG2" "$EXTRA/$BIG3" "$FIX/"
{ record "$FIX/$BIG2" 1:3.21.0-1le9007199254740992; record "$FIX/$BIG3" 1:3.21.0-1le9007199254740993; } > "$FIX/Packages"
run 0
state_is 1:3.21.0-1le9007199254740993 hold installed

scenario index-same-version-twice
{ record "$FIX/$LE2" 1:3.21.0-1le2; record "$FIX/$LE2" 1:3.21.0-1le2; } > "$FIX/Packages"
run 1
out_has "lists hrneo 1:3.21.0-1le2 for aarch64-3.10 twice"
log_is "$PRE_LOG
opkg compare-versions 1:3.21.0-1le2 >> 1:3.21.0-1le2
opkg compare-versions 1:3.21.0-1le2 >> 1:3.21.0-1le2"
not_installed

scenario index-other-arch-first
# The record for another architecture comes first, with its own file and sum.
cp "$FIX/$LE2" "$FIX/hrneo_3.21.0-1le2_mipsel-3.4.ipk"
printf 'x' >> "$FIX/hrneo_3.21.0-1le2_mipsel-3.4.ipk"
{ record "$FIX/hrneo_3.21.0-1le2_mipsel-3.4.ipk" 1:3.21.0-1le2 mipsel-3.4; record "$FIX/$LE2" 1:3.21.0-1le2; } > "$FIX/Packages"
run 0
log_is "$HEAD_LOG
$INSTALL_LE2"
state_is 1:3.21.0-1le2 hold installed

scenario index-fields-from-one-record
# The aarch64 record lacks SHA256sum; the next record (another arch) has one.
cat > "$FIX/Packages" <<EOF
Package: hrneo
Version: 1:3.21.0-1le2
Architecture: aarch64-3.10
Filename: $LE2
Size: $LE2_SIZE

Package: hrneo
Version: 1:3.21.0-1le2
Architecture: mipsel-3.4
Filename: hrneo_3.21.0-1le2_mipsel-3.4.ipk
Size: $LE2_SIZE
SHA256sum: $LE2_SUM

EOF
run 1
log_is "$PRE_LOG"
not_installed
out_has "broken hrneo record for aarch64-3.10: "
out_has "is missing"

scenario index-busy
# Other packages around it, continuation lines, its fields in another order,
# no blank line at the end.
cat > "$FIX/Packages" <<EOF
Package: hrweb
Version: 1.0-1
Architecture: aarch64-3.10
Filename: hrweb_1.0-1_aarch64-3.10.ipk
Size: 10
SHA256sum: 0000000000000000000000000000000000000000000000000000000000000000
Description: web UI
 Version: 9:9.9-9
 Filename: evil.ipk

Package: hrneo-tools
Version: 1:9.9-9le9
Architecture: aarch64-3.10
Filename: $LE2
Size: $LE2_SIZE
SHA256sum: $LE2_SUM

SHA256sum: $LE2_SUM
Description: DNS-based policy routing daemon for Keenetic
 SHA256sum: 1111111111111111111111111111111111111111111111111111111111111111
Size: $LE2_SIZE
Filename: $LE2
Architecture: aarch64-3.10
Version: 1:3.21.0-1le2
Package: hrneo
EOF
run 0
log_is "$HEAD_LOG
$INSTALL_LE2"
state_is 1:3.21.0-1le2 hold installed

scenario index-uppercase-sum
record "$FIX/$LE2" 1:3.21.0-1le2 | sed "s/^SHA256sum: .*/SHA256sum: $(echo "$LE2_SUM" | tr 'a-f' 'A-F')/" > "$FIX/Packages"
grep -q '^SHA256sum: [0-9A-F]*[A-F]' "$FIX/Packages" || fail "fixture has no upper-case sum"
run 0
state_is 1:3.21.0-1le2 hold installed

scenario index-no-hrneo
record "$FIX/$LE2" 1:3.21.0-1le2 | sed 's/^Package: hrneo$/Package: hrneo-web/' > "$FIX/Packages"
run 1
out_has "has no hrneo record for aarch64-3.10"
log_is "$PRE_LOG"
not_installed

scenario index-other-arch-only
record "$FIX/$LE2" 1:3.21.0-1le2 mipsel-3.4 > "$FIX/Packages"
run 1
out_has "has no hrneo record for aarch64-3.10"
not_installed

# One broken record at a time: <name>|<sed expression on the le2 record>|<part of the message>
while IFS='|' read -r c expr why; do
    scenario "index-$c"
    record "$FIX/$LE2" 1:3.21.0-1le2 | sed "$expr" > "$FIX/Packages"
    run 1
    out_has "broken hrneo record for aarch64-3.10: "
    out_has "$why"
    log_is "$PRE_LOG"
    not_installed
done <<EOF
no-version|/^Version:/d|is missing
no-filename|/^Filename:/d|is missing
no-size|/^Size:/d|is missing
no-sum|/^SHA256sum:/d|is missing
empty-sum|s/^SHA256sum:.*/SHA256sum:/|is missing
sum-63|s/^\(SHA256sum: \)./\1/|bad SHA256sum
sum-65|s/^SHA256sum: .*/&0/|bad SHA256sum
sum-not-hex|s/^\(SHA256sum: \)./\1g/|bad SHA256sum
filename-dir|s#^Filename: .*#Filename: sub/$LE2#|bad Filename
filename-up|s#^Filename: .*#Filename: ../$LE2#|bad Filename
filename-dots|s#^Filename: .*#Filename: hrneo..ipk#|bad Filename
filename-dash|s#^Filename: .*#Filename: -$LE2#|bad Filename
filename-not-ipk|s#^Filename: .*#Filename: hrneo.tar.gz#|bad Filename
filename-space|s#^Filename: .*#Filename: hrneo x .ipk#|bad Filename
size-not-number|s/^Size: .*/Size: 12k/|bad Size
size-zero|s/^Size: .*/Size: 0/|bad Size
not-fork-version|s/^Version: .*/Version: 3.22.0-1/|not a fork version
version-space|s/^Version: .*/Version: 1:3.21.0-1le2 x/|bad Version
two-versions|/^Version:/p|two Version fields
two-packages|s/^Package: hrneo/Package: hrweb\nPackage: hrneo/|two Package fields
line-without-colon|/^Size:/a garbage|a line without a colon
EOF

# --- failures before anything changes -----------------------------------------------

for tool in opkg sha256sum mktemp; do
    scenario "missing-$tool"
    rm "$R/opt/bin/$tool"
    run 1
    out_has "$tool not found"
    log_is ""
    no_conf
done

scenario missing-curl-and-wget
rm "$R/opt/bin/curl" "$R/opt/bin/wget"
run 1
out_has "neither curl nor wget"
log_is ""
no_conf

scenario wget-without-curl
rm "$R/opt/bin/curl"
run 0
log_is "opkg print-architecture
opkg update
wget $URL/Packages
opkg status hrneo
wget $URL/$LE2
opkg install TMP/$LE2
opkg status hrneo
opkg flag hold hrneo
opkg status hrneo"
state_is 1:3.21.0-1le2 hold installed

scenario mktemp-fails
rm "$R/opt/bin/mktemp"
printf '#!/bin/sh\necho "mktemp: cannot create" >&2\nexit 1\n' > "$R/opt/bin/mktemp"
chmod 0755 "$R/opt/bin/mktemp"
run 1
out_has "mktemp -d failed"
log_is ""
no_conf

scenario print-architecture-fails
echo 255 > "$ST/arch_rc"
run 1
out_has "opkg print-architecture failed"
log_is "opkg print-architecture"
no_conf

scenario unsupported-arch
printf 'arch all 1\narch noarch 1\narch mipsel-3.4 10\n' > "$ST/arch"
run 1
out_has "unsupported architecture: mipsel-3.4"
log_is "opkg print-architecture"
no_conf

# --- the feed line -------------------------------------------------------------------

scenario feed-line-replaces-pages
printf 'src/gz entware http://bin.entware.net/aarch64-k3.10\nsrc/gz le0nus-hr https://le0nus.github.io/hydraroute-release/keenetic/aarch64-k3.10\n# src/gz le0nus-hr http://old\n' > "$CONF"
run 0
conf_is "src/gz entware http://bin.entware.net/aarch64-k3.10
# src/gz le0nus-hr http://old
src/gz le0nus-hr $URL"

scenario feed-line-kept
printf 'src/gz entware http://bin.entware.net/aarch64-k3.10\nsrc/gz le0nus-hr %s\nsrc/gz other http://example.invalid/x\n' "$URL" > "$CONF"
cp "$CONF" "$T/conf-before"
run 0
cmp -s "$CONF" "$T/conf-before" || fail "customfeeds.conf rewritten: $(cat "$CONF")"

scenario feed-line-twice
printf 'src/gz le0nus-hr %s\nsrc/gz le0nus-hr %s\n' "$URL" "$URL" > "$CONF"
run 0
conf_is "src/gz le0nus-hr $URL"

# --- failures on the way ----------------------------------------------------------------

scenario update-fails
echo 1 > "$ST/update_rc"
run 1
out_has "opkg update failed"
log_is "opkg print-architecture
opkg update"
not_installed

scenario packages-download-fails
echo "Packages fail" > "$ST/fetch_modes"
run 1
out_has "cannot download $URL/Packages"
log_is "opkg print-architecture
opkg update
curl $URL/Packages"
not_installed

scenario status-fails
echo 255 > "$ST/status_rc"
run 1
out_has "opkg status hrneo failed"
log_is "$HEAD_LOG"
not_installed

scenario compare-fails
installed 3.21.0-1le1 hold
echo 255 > "$ST/compare_rc"
run 1
out_has "opkg compare-versions"
log_lacks "^curl $URL/hrneo"
log_lacks "^opkg flag"
state_is 3.21.0-1le1 hold installed

for mode in fail cut; do
    scenario "ipk-download-$mode"
    installed 3.21.0-1le1 hold
    echo "$LE2 $mode" > "$ST/fetch_modes"
    run 1
    out_has "cannot download $URL/$LE2"
    log_is "$HEAD_LOG
opkg compare-versions 3.21.0-1le1 >> 1:3.21.0-1le2
curl $URL/$LE2"
    state_is 3.21.0-1le1 hold installed
done

scenario ipk-short
# The connection closed early without an error.
echo "$LE2 short" > "$ST/fetch_modes"
run 1
out_has "$LE2 is 100 bytes, $URL/Packages says $LE2_SIZE"
log_lacks "^opkg install"
not_installed

scenario ipk-tampered
# Same size, other bytes.
dd if=/dev/zero of="$FIX/$LE2" bs="$LE2_SIZE" count=1 2>/dev/null
run 1
out_has "sha256 of $LE2 is"
out_has "Packages says $LE2_SUM"
log_lacks "^opkg install"
not_installed

scenario sha256sum-fails
rm "$R/opt/bin/sha256sum"
printf '#!/bin/sh\necho "sha256sum: read error" >&2\nexit 1\n' > "$R/opt/bin/sha256sum"
chmod 0755 "$R/opt/bin/sha256sum"
run 1
out_has "sha256sum failed on"
out_lacks "sha256 of"
log_lacks "^opkg install"
not_installed

# opkg install fails; the installer restores the hold the old version had,
# says what to do, and a second run finishes the job.
scenario install-fails-before-unpack
installed 3.21.0-1le1 hold
echo fail-before > "$ST/install_modes"
run 1
log_is "$HEAD_LOG
opkg compare-versions 3.21.0-1le1 >> 1:3.21.0-1le2
curl $URL/$LE2
opkg flag user hrneo
opkg install TMP/$LE2
opkg status hrneo
opkg flag hold hrneo
opkg status hrneo"
state_is 3.21.0-1le1 hold installed
out_has "opkg install exited with code 255"
out_has "hrneo 3.21.0-1le1 is held again"
out_has "run this installer again"
: > "$ST/log"
run 0
state_is 1:3.21.0-1le2 hold installed

scenario install-postinst-fails
installed 3.21.0-1le1 hold
echo postinst-fails > "$ST/install_modes"
run 1
state_is 1:3.21.0-1le2 hold unpacked
out_has "opkg install exited with code 1"
: > "$ST/log"
run 0
log_is "$HEAD_LOG
curl $URL/$LE2
opkg flag user hrneo
opkg install --force-reinstall TMP/$LE2
opkg status hrneo
opkg flag hold hrneo
opkg status hrneo"
state_is 1:3.21.0-1le2 hold installed

scenario fresh-install-postinst-fails
# Nothing was held before, so nothing is held after the failure.
echo postinst-fails > "$ST/install_modes"
run 1
state_is 1:3.21.0-1le2 user unpacked
log_lacks "^opkg flag hold"
: > "$ST/log"
run 0
state_is 1:3.21.0-1le2 hold installed

scenario install-fails-after-version-change
installed 3.21.0-1le1 hold
echo fail-after > "$ST/install_modes"
run 1
state_is 1:3.21.0-1le2 hold installed
out_has "opkg install exited with code 1"
: > "$ST/log"
run 0
log_is "$HEAD_LOG
opkg flag hold hrneo
opkg status hrneo"
state_is 1:3.21.0-1le2 hold installed

scenario install-does-nothing
installed 3.21.0-1le1 hold
echo nothing > "$ST/install_modes"
run 1
out_has "opkg install exited with code 0"
out_has "3.21.0-1le1"
state_is 3.21.0-1le1 hold installed

# Once the hold of the installed package is released, every way out but
# success puts it back and checks it: a status error, a failed command, a
# signal (after opkg has finished). The exit code stays that of the cause.
scenario status-fails-after-install
installed 3.21.0-1le1 hold
echo 2 > "$ST/status_fail_calls"
run 1
log_is "$HEAD_LOG
opkg compare-versions 3.21.0-1le1 >> 1:3.21.0-1le2
curl $URL/$LE2
opkg flag user hrneo
opkg install TMP/$LE2
opkg status hrneo
opkg flag hold hrneo
opkg status hrneo"
state_is 1:3.21.0-1le2 hold installed
out_has "opkg status hrneo failed"
out_has "hrneo 1:3.21.0-1le2 is held again"

scenario status-fails-after-failed-install
installed 3.21.0-1le1 hold
echo fail-before > "$ST/install_modes"
echo 2 > "$ST/status_fail_calls"
run 1
state_is 3.21.0-1le1 hold installed
out_has "hrneo 3.21.0-1le1 is held again"

scenario status-keeps-failing-after-install
installed 3.21.0-1le1 hold
echo 2 3 4 5 6 > "$ST/status_fail_calls"
run 1
state_is 1:3.21.0-1le2 hold installed
out_has "the hold is not confirmed"

scenario flag-user-fails
# Nothing could be changed, and the hold cannot be set either: said so.
installed 3.21.0-1le1 hold
echo fail > "$ST/flag_mode"
run 1
log_lacks "^opkg install"
state_is 3.21.0-1le1 hold installed
out_has "opkg flag user hrneo failed"
out_has "may be left without its hold"

for sig in HUP:129 INT:130 PIPE:141 TERM:143; do
    s=${sig%%:*}
    code=${sig#*:}
    scenario "signal-$s-during-install"
    # opkg finishes the install; the new package gets the hold back.
    installed 3.21.0-1le1 hold
    run_signalled "$s" "$code" finish
    log_is "$HEAD_LOG
opkg compare-versions 3.21.0-1le1 >> 1:3.21.0-1le2
curl $URL/$LE2
opkg flag user hrneo
opkg install TMP/$LE2
opkg flag hold hrneo
opkg status hrneo"
    state_is 1:3.21.0-1le2 hold installed
    out_has "hrneo 1:3.21.0-1le2 is held again"

    scenario "signal-$s-kills-install"
    # opkg dies of it too, before changing anything: the old package is held again.
    installed 3.21.0-1le1 hold
    run_signalled "$s" "$code" killed
    state_is 3.21.0-1le1 hold installed
    out_has "hrneo 3.21.0-1le1 is held again"
done

scenario hold-does-not-come-back
# opkg flag hold says it worked, but opkg status shows no hold: said so.
installed 3.21.0-1le1 hold
echo fail-before > "$ST/install_modes"
echo noop-hold > "$ST/flag_mode"
run 1
state_is 3.21.0-1le1 user installed
out_has "hrneo 3.21.0-1le1 is still not held: run opkg flag hold hrneo"

scenario signal-while-putting-hold-back
# A Ctrl-C while the hold goes back (to the installer and to that opkg) does
# not cut it short.
installed 3.21.0-1le1 hold
echo fail-before > "$ST/install_modes"
touch "$ST/hold_hang"
(
    n=0
    while [ ! -s "$ST/hold.pid" ] && [ "$n" -lt 500 ]; do
        usleep 20000
        n=$((n + 1))
    done
    kill -INT "$(cat "$ST/installer.pid")" "$(cat "$ST/hold.pid")"
    usleep 200000
    touch "$ST/go2"
) &
run 1
wait
state_is 3.21.0-1le1 hold installed
out_has "hrneo 3.21.0-1le1 is held again"

scenario signal-INT-during-fresh-install
# Nothing was held before: nothing to put back.
run_signalled INT 130 finish
log_lacks "^opkg flag"
state_is 1:3.21.0-1le2 user installed

scenario install-ok-but-unpacked
# opkg says nothing went wrong, but hrneo is not configured: not held, not done.
echo unpacked-ok > "$ST/install_modes"
run 1
out_has "opkg install exited with code 0"
state_is 1:3.21.0-1le2 user unpacked
log_lacks "^opkg flag hold"

scenario hold-fails
echo fail > "$ST/flag_mode"
run 1
out_has "opkg flag hold hrneo failed"

scenario hold-does-not-stick
echo noop > "$ST/flag_mode"
run 1
out_has "expected 1:3.21.0-1le2 installed and held"

# --- signals ----------------------------------------------------------------------------

for sig in TERM:143 HUP:129; do
    scenario "signal-${sig%%:*}"
    echo "$LE2 hang" > "$ST/fetch_modes"
    env -i PATH="$SYS" TMPDIR="$T/tmp" ST="$ST" FIX="$FIX" /bin/busybox sh "$INSTALLER" > "$T/out" 2>&1 &
    pid=$!
    n=0
    while [ ! -s "$ST/fetch.pid" ] && [ "$n" -lt 200 ]; do
        usleep 20000
        n=$((n + 1))
    done
    if [ -s "$ST/fetch.pid" ]; then
        kill -"${sig%%:*}" "$pid"
        kill -TERM "$(cat "$ST/fetch.pid")"
    else
        fail "the download never started: $(cat "$T/out")"
        touch "$ST/go"
    fi
    wait "$pid"
    got=$?
    [ "$got" = "${sig#*:}" ] || fail "exit $got, want ${sig#*:}; output: $(cat "$T/out")"
    left=$(ls -A "$T/tmp")
    [ -z "$left" ] || fail "left in TMPDIR: $left"
    log_lacks "^opkg install"
done

[ "$FAILS" = 0 ] || { echo "test-install-feed: $FAILS failures" >&2; exit 1; }
echo "test-install-feed: OK"
