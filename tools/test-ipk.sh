#!/bin/sh
# The package and the scripts in it, checked with fakes. Run inside hrneo-build:
#   sh tools/test-ipk.sh <Neo/source of the fork checkout>
# 1. build-ipk.sh: the epoch goes into control only; archive layout, modes,
#    owners and the fork's files byte for byte. make-index.sh: one whole
#    record per ipk, Packages.gz the same text, the feed root as an argument.
# 2. build.sh with fake git and docker; the container script runs here with a
#    fake make: make, the tag and the file names get the version without the
#    epoch, the binary's own version is checked, <ipk>.source records the
#    version, the commit, the image and the sha256 of the packaged binary.
# 3. postinst, prerm and S99hrneo taken out of the built ipk and run, each in
#    its own busybox sh, from copies whose /opt/, /var/run/ and /proc/locks
#    point into a scratch root with fake rc.func, hrneo, pidof, sleep, lsmod,
#    iptables, ip6tables and rmmod. Each scenario checks the exit code and the
#    whole call log, so order and absence count.
# Writes only under a temporary directory; the fork checkout is only read.
set -u
SRC=$(cd "$1" && pwd)
TOOLS=$(cd "$(dirname "$0")" && pwd)
T=$(mktemp -d)
trap 'rm -rf "$T"' EXIT
VER=1:3.21.0-1le2
IPKNAME=hrneo_3.21.0-1le2_aarch64-3.10.ipk
FAILS=0
NAME=

fail() {
    echo "test-ipk: $NAME: $*" >&2
    FAILS=$((FAILS + 1))
}

finish() {
    [ "$FAILS" = 0 ] || { echo "test-ipk: $FAILS failures" >&2; exit 1; }
    echo "test-ipk: OK"
    exit 0
}

entry() {   # <tar.gz> <member>: "<mode> <uid/gid>" of that member
    tar --numeric-owner -tvzf "$1" | awk -v m="$2" '$NF == m {print $1, $2}'
}

# --- 1. build-ipk.sh and make-index.sh --------------------------------------

NAME=build-ipk
printf '#!/bin/sh\necho "hrneo v3.21.0-1le2"\n' > "$T/hrneo-bin"
FEED="$T/feed"
OUT="$FEED/keenetic/aarch64-k3.10"
mkdir -p "$OUT"
sh "$TOOLS/build-ipk.sh" "$SRC" "$T/hrneo-bin" "$VER" aarch64-3.10 "$OUT" > "$T/out" 2>&1 ||
    fail "exit $?: $(cat "$T/out")"
[ "$(cat "$T/out")" = "$OUT/$IPKNAME" ] || fail "printed '$(cat "$T/out")', want $OUT/$IPKNAME"
[ "$(ls "$OUT")" = "$IPKNAME" ] || fail "no $IPKNAME, the out dir holds: $(ls "$OUT" | tr '\n' ' ')"
IPK=$(ls "$OUT"/hrneo_*.ipk 2>/dev/null | head -n 1)
[ -n "$IPK" ] || { fail "no ipk at all"; finish; }

P="$T/pkg"
mkdir -p "$P/control" "$P/data"
members=$(tar -tzf "$IPK" | tr '\n' ' ')
[ "$members" = "./debian-binary ./control.tar.gz ./data.tar.gz " ] || fail "ipk members: $members"
tar -xzf "$IPK" -C "$P"
tar -xzf "$P/control.tar.gz" -C "$P/control"
tar -xzf "$P/data.tar.gz" -C "$P/data"
[ "$(cat "$P/debian-binary")" = 2.0 ] || fail "debian-binary: $(cat "$P/debian-binary")"

sed -e "s/@VERSION@/$VER/" -e 's/@ARCH@/aarch64-3.10/' \
    -e 's/^Maintainer: .*/Maintainer: le0nus (fork of Ground_Zerro HydraRoute)/' \
    "$SRC/ipk/control/control.in" | grep -v '^Installed-Size:' > "$T/want-control"
grep -v '^Installed-Size:' "$P/control/control" | cmp -s - "$T/want-control" ||
    fail "control:
$(cat "$P/control/control")
want (Installed-Size aside):
$(cat "$T/want-control")"
grep -qx "Version: $VER" "$P/control/control" || fail "control has no Version: $VER"
grep -qx 'Installed-Size: [1-9][0-9]*' "$P/control/control" || fail "control Installed-Size"

for m in ./control ./conffiles; do
    [ "$(entry "$P/control.tar.gz" "$m")" = "-rw-r--r-- 0/0" ] || fail "$m: $(entry "$P/control.tar.gz" "$m")"
done
for m in ./postinst ./prerm; do
    [ "$(entry "$P/control.tar.gz" "$m")" = "-rwxr-xr-x 0/0" ] || fail "$m missing or not 0755 root: '$(entry "$P/control.tar.gz" "$m")'"
done
for f in postinst prerm conffiles; do
    cmp -s "$P/control/$f" "$SRC/ipk/control/$f" || fail "packaged $f differs from the fork's"
done

[ "$(entry "$P/data.tar.gz" ./opt/bin/hrneo)" = "-rwxr-xr-x 0/0" ] || fail "opt/bin/hrneo: $(entry "$P/data.tar.gz" ./opt/bin/hrneo)"
cmp -s "$P/data/opt/bin/hrneo" "$T/hrneo-bin" || fail "packaged hrneo is not the given binary"
for m in ./opt/etc/init.d/S99hrneo ./opt/etc/ndm/netfilter.d/015-hrneo.sh ./opt/etc/ndm/ifstatechanged.d/015-hrneo.sh; do
    [ "$(entry "$P/data.tar.gz" "$m")" = "-rwxr-xr-x 0/0" ] || fail "$m: $(entry "$P/data.tar.gz" "$m")"
done
(cd "$SRC/ipk/rootfs" && find . -type f) > "$T/rootfs-files"
while read -r f; do
    cmp -s "$SRC/ipk/rootfs/$f" "$P/data/$f" || fail "packaged $f differs from the fork's"
done < "$T/rootfs-files"
others=$(tar --numeric-owner -tvzf "$P/data.tar.gz" | awk '$2 != "0/0"')
[ -z "$others" ] || fail "data not owned by 0/0: $others"
while read -r f; do
    [ -f "$P/data$f" ] || fail "conffile $f is not in the package"
done < "$P/control/conffiles"

NAME=build-ipk-bad-version
for v in '' 1:2:3.21.0-1le2 a:3.21.0-1le2 :3.21.0-1le2 3.21/0-1le2 '3.21.0 1le2' '3.21.0&1le2'; do
    rm -rf "$T/bad"
    mkdir -p "$T/bad"
    if sh "$TOOLS/build-ipk.sh" "$SRC" "$T/hrneo-bin" "$v" aarch64-3.10 "$T/bad" > "$T/out" 2>&1; then
        fail "accepted version '$v'"
    fi
    [ -z "$(ls "$T/bad")" ] || fail "version '$v' left: $(ls "$T/bad")"
done

# make-index.sh runs from copies, so that whatever root it takes by default
# is a scratch one and never this repository.
NAME=make-index
mkdir -p "$T/mi/tools"
cp "$TOOLS/make-index.sh" "$T/mi/tools/"
sh "$T/mi/tools/make-index.sh" "$FEED" > "$T/out" 2>&1 || fail "exit $?: $(cat "$T/out")"
{
    sed '/^$/d' "$P/control/control"
    printf 'Filename: %s\nSize: %s\nSHA256sum: %s\n\n' "${IPK##*/}" \
        "$(wc -c < "$IPK" | tr -d ' ')" "$(sha256sum "$IPK" | cut -d' ' -f1)"
} > "$T/want-index"
cmp -s "$OUT/Packages" "$T/want-index" || fail "Packages:
$(cat "$OUT/Packages" 2>/dev/null)
want:
$(cat "$T/want-index")"
grep -qx "Version: $VER" "$OUT/Packages" 2>/dev/null || fail "Packages Version"
grep -qx "Filename: $IPKNAME" "$OUT/Packages" 2>/dev/null || fail "Packages Filename"
gzip -dc "$OUT/Packages.gz" 2>/dev/null | cmp -s - "$OUT/Packages" || fail "Packages.gz differs from Packages"

NAME=make-index-default-root
mkdir -p "$T/mi/keenetic/aarch64-k3.10"
cp "$IPK" "$T/mi/keenetic/aarch64-k3.10/"
(cd / && sh "$T/mi/tools/make-index.sh") > "$T/out" 2>&1 || fail "exit $?: $(cat "$T/out")"
cmp -s "$T/mi/keenetic/aarch64-k3.10/Packages" "$T/want-index" || fail "Packages in the script's own root"

# --- 2. build.sh with fake git and docker -------------------------------------

B="$T/b"
BLOG="$B/log"
BCOMMIT=0123456789abcdef0123456789abcdef01234567
BIMAGE=sha256:89abcdef0123456789abcdef0123456789abcdef0123456789abcdef01234567
mkdir -p "$B/bin" "$B/run"
cat > "$B/bin/git" <<'EOF'
#!/bin/sh
# Fake git -C <dir> ...: $BST/dirty is the status, $BST/tag the one tag at HEAD.
shift 2
case "$1" in
    status) cat "$BST/dirty" ;;
    rev-parse)
        if [ "$2" = HEAD ]; then
            echo "$BCOMMIT"
            exit 0
        fi
        for ref; do :; done
        [ "$ref" = "refs/tags/$(cat "$BST/tag")^{commit}" ] || exit 1
        echo "$BCOMMIT"
        ;;
    *) exit 1 ;;
esac
EOF
cat > "$B/bin/docker" <<'EOF'
#!/bin/sh
# Fake docker: build and image inspect answer; run executes the container
# script here, with the -e variables set, each -v mount's container path in
# the script replaced by its host path, and the fake make first in PATH.
echo "docker $1" >> "$BLOG"
case "$1" in
    build) exit 0 ;;
    image) echo "$BIMAGE"; exit 0 ;;
    run) shift ;;
    *) exit 125 ;;
esac
maps=
wd=
while [ $# -gt 0 ]; do
    case "$1" in
        --rm) shift ;;
        -e) export "$2"; shift 2 ;;
        -v) maps="$maps $2"; shift 2 ;;
        -w) wd=$2; shift 2 ;;
        *) break ;;
    esac
done
[ "$1" = "$BIMAGE" ] || { echo "fake docker: image $1, want $BIMAGE" >&2; exit 125; }
[ "$2 $3" = "sh -euc" ] || { echo "fake docker: want sh -euc, got $2 $3" >&2; exit 125; }
script=$4
for m in $maps; do
    h=${m%%:*}
    c=${m#*:}
    script=$(printf '%s\n' "$script" | sed -e "s#$c\\([/ ]\\)#$h\\1#g" -e "s#$c\$#$h#")
    [ "$wd" != "$c" ] || wd=$h
done
cd "$wd" || exit 125
PATH="$BRUN:$PATH" exec sh -euc "$script"
EOF
cat > "$B/run/make" <<'EOF'
#!/bin/sh
# Fake make: "aarch64 ... VERSION=<v>" writes a build/hrneo-aarch64 that
# prints "hrneo v<v>", or "hrneo v<$BST/binver>" when that is set.
echo "make $*" >> "$BLOG"
case "$1" in
    clean) rm -rf build ;;
    aarch64)
        v=
        for a; do
            case "$a" in VERSION=*) v=${a#VERSION=} ;; esac
        done
        [ ! -s "$BST/binver" ] || v=$(cat "$BST/binver")
        mkdir -p build
        printf '#!/bin/sh\necho "hrneo v%s"\n' "$v" > build/hrneo-aarch64
        chmod 0755 build/hrneo-aarch64
        ;;
esac
EOF
chmod 0755 "$B/bin/git" "$B/bin/docker" "$B/run/make"

# A feed repository with build.sh, build-ipk.sh and logging test scripts,
# and a fork checkout with the real ipk files; clean, no tag.
bscenario() {
    NAME=$1
    rm -rf "$B/repo" "$B/hr" "$B/st"
    : > "$BLOG"
    mkdir -p "$B/repo/tools" "$B/hr/Neo/source" "$B/st"
    cp "$TOOLS/build.sh" "$TOOLS/build-ipk.sh" "$B/repo/tools/"
    printf '#!/bin/sh\necho "test-ipk${*:+ $*}" >> "$BLOG"\n' > "$B/repo/tools/test-ipk.sh"
    printf '#!/bin/sh\necho "test-install-feed${*:+ $*}" >> "$BLOG"\n' > "$B/repo/tools/test-install-feed.sh"
    chmod 0755 "$B"/repo/tools/*
    cp -a "$SRC/ipk" "$B/hr/Neo/source/"
    : > "$B/st/dirty"
    echo none > "$B/st/tag"
    : > "$B/st/binver"
    BOUT="$B/repo/keenetic/aarch64-k3.10"
}

brun() {    # <0 | nonzero>: build.sh <fork checkout> 1:3.21.0-1le2
    PATH="$B/bin:$PATH" BLOG="$BLOG" BST="$B/st" BRUN="$B/run" BCOMMIT="$BCOMMIT" BIMAGE="$BIMAGE" \
        sh "$B/repo/tools/build.sh" "$B/hr" "$VER" > "$T/out" 2> "$T/err"
    got=$?
    case "$1:$got" in
        0:0) ;;
        nonzero:0|0:*) fail "exit $got, want $1; stderr: $(cat "$T/err")" ;;
    esac
}

bscenario build
brun 0
BIN="$B/hr/Neo/source/build/hrneo-aarch64"
[ "$(cat "$BLOG")" = "docker build
docker image
docker run
make clean
make check
test-ipk $B/hr/Neo/source
test-install-feed
make aarch64 CC_AARCH64=gcc VERSION=3.21.0-1le2" ] || fail "calls:
$(cat "$BLOG")"
[ "$(ls "$BOUT" 2>/dev/null | tr '\n' ' ')" = "$IPKNAME $IPKNAME.source " ] ||
    fail "out dir holds: $(ls "$BOUT" 2>/dev/null | tr '\n' ' ')"
[ -x "$BIN" ] && [ "$("$BIN")" = "hrneo v3.21.0-1le2" ] || fail "binary built with the wrong VERSION: $("$BIN" 2>&1)"
BIN_SHA=$(sha256sum "$BIN" | cut -d' ' -f1)
printf 'version %s\ncommit %s\nimage %s\nbinary %s\n' "$VER" "$BCOMMIT" "$BIMAGE" "$BIN_SHA" > "$T/want-source"
cmp -s "$BOUT/$IPKNAME.source" "$T/want-source" || fail ".source:
$(cat "$BOUT/$IPKNAME.source" 2>/dev/null)
want:
$(cat "$T/want-source")"
pkgsha=$(tar -xzOf "$BOUT/$IPKNAME" ./data.tar.gz 2>/dev/null | tar -xzOf - ./opt/bin/hrneo 2>/dev/null | sha256sum | cut -d' ' -f1)
[ "$pkgsha" = "$BIN_SHA" ] || fail "the packaged binary is not build/hrneo-aarch64"
tar -xzOf "$BOUT/$IPKNAME" ./control.tar.gz 2>/dev/null | tar -xzOf - ./control 2>/dev/null |
    grep -qx "Version: $VER" || fail "packaged control Version"
[ "$(cat "$T/out")" = "$BOUT/$IPKNAME
$(cat "$T/want-source")" ] || fail "stdout: $(cat "$T/out")"
grep -qF "warning: tag v3.21.0-1le2 does not point at $BCOMMIT" "$T/err" || fail "no tag warning: $(cat "$T/err")"

bscenario build-tagged
echo v3.21.0-1le2 > "$B/st/tag"
brun 0
if grep -q 'warning: tag' "$T/err"; then fail "tag warning with the tag in place: $(cat "$T/err")"; fi

bscenario build-dirty
echo ' M Neo/source/src/main.c' > "$B/st/dirty"
brun nonzero
[ ! -s "$BLOG" ] || fail "went on: $(cat "$BLOG")"
grep -qF 'uncommitted changes' "$T/err" || fail "stderr: $(cat "$T/err")"

bscenario build-binary-version
# The binary does not say the version it was built as: nothing is packaged.
echo 3.21.0-1 > "$B/st/binver"
brun nonzero
[ -z "$(ls "$BOUT" 2>/dev/null)" ] || fail "out dir holds: $(ls "$BOUT" | tr '\n' ' ')"
grep -qF 'hrneo v3.21.0-1' "$T/err" || fail "stderr does not name the binary's version: $(cat "$T/err")"

bscenario build-packaged-binary-differs
# The package ends up with another binary than the one built: no provenance.
sed -i 's#^install -D -m 0755 "$BIN" "$WORK/data/opt/bin/hrneo"$#&; echo >> "$WORK/data/opt/bin/hrneo"#' \
    "$B/repo/tools/build-ipk.sh"
grep -q 'echo >> "$WORK/data/opt/bin/hrneo"' "$B/repo/tools/build-ipk.sh" || fail "could not alter the build-ipk.sh copy"
brun nonzero
[ ! -e "$BOUT/$IPKNAME.source" ] || fail "wrote $IPKNAME.source"
grep -qF 'is not build/hrneo-aarch64' "$T/err" || fail "stderr: $(cat "$T/err")"

# --- 3. the package's scripts, taken out of the built ipk -----------------------

L="$T/life"
export FAKE_LOG="$L/log" FAKE_ST="$L/state" FAKE_LOCKS="$L/locks"
S99="$L/opt/etc/init.d/S99hrneo"
PRERM="$L/prerm"
POSTINST="$L/postinst"
mkdir -p "$L/opt/etc/init.d" "$L/opt/bin" "$L/run"

NAME=package-scripts
copy() {    # <packaged file> <copy>: the copy with its system paths in the scratch root
    if [ ! -f "$1" ]; then
        fail "${1#"$P"/} is not in the package"
        : > "$2"
    else
        sed -e "s#/opt/#$L/opt/#g" -e "s#/var/run/#$L/run/#g" -e "s#/proc/locks#$FAKE_LOCKS#g" "$1" > "$2"
    fi
    chmod 0755 "$2"
}
copy "$P/data/opt/etc/init.d/S99hrneo" "$S99"
copy "$P/control/prerm" "$PRERM"
copy "$P/control/postinst" "$POSTINST"

# rc.func is sourced by the init script: it logs its action; stop makes the
# process go (ok), take 3 more polls (slow) or stay (stuck); start fails
# when start_rc says so.
cat > "$L/opt/etc/init.d/rc.func" <<'EOF'
echo "rc.func $1 caller=${2:-} ARGS=$ARGS" >> "$FAKE_LOG"
case "$1" in
    stop)
        case "$(cat "$FAKE_ST/stop_mode")" in
            ok) echo 0 > "$FAKE_ST/alive" ;;
            slow) echo 3 > "$FAKE_ST/alive" ;;
        esac
        ;;
    start)
        echo 99 > "$FAKE_ST/alive"
        [ "$(cat "$FAKE_ST/start_rc")" = 0 ] || exit 1
        ;;
esac
EOF
# pidof: alive holds how many more polls see the process; 99 means for good.
cat > "$L/opt/bin/pidof" <<'EOF'
#!/bin/sh
n=$(cat "$FAKE_ST/alive")
[ "$n" -gt 0 ] || exit 1
[ "$n" = 99 ] || echo $((n - 1)) > "$FAKE_ST/alive"
echo 4242
EOF
cat > "$L/opt/bin/hrneo" <<'EOF'
#!/bin/sh
echo "hrneo $*" >> "$FAKE_LOG"
exit "$(cat "$FAKE_ST/hrneo_rc")"
EOF
for ipt in iptables ip6tables; do
    cat > "$L/opt/bin/$ipt" <<EOF
#!/bin/sh
echo "$ipt \$*" >> "\$FAKE_LOG"
cat "\$FAKE_ST/$ipt.out"
exit "\$(cat "\$FAKE_ST/$ipt.rc")"
EOF
done
cat > "$L/opt/bin/lsmod" <<'EOF'
#!/bin/sh
cat "$FAKE_ST/lsmod"
EOF
for cmd in sleep rmmod; do
    printf '#!/bin/sh\necho "%s $*" >> "$FAKE_LOG"\n' "$cmd" > "$L/opt/bin/$cmd"
done
chmod 0755 "$L"/opt/bin/*

EMPTY_RAW='-P PREROUTING ACCEPT
-P OUTPUT ACCEPT'
SLEEPS='sleep 1
sleep 1
sleep 1
sleep 1
sleep 1
sleep 1
sleep 1
sleep 1
sleep 1
sleep 1'
REMOVE_ALL="rc.func stop caller= ARGS=
hrneo --raw-off
iptables -w -t raw -S
rmmod iptable_raw
ip6tables -w -t raw -S
rmmod ip6table_raw"

# A fresh router: hrneo running and stopping when asked, its lock free,
# hrneo --raw-off working, both raw modules loaded with empty tables.
scenario() {
    NAME=$1
    rm -rf "$FAKE_ST" "$L/run/hrneo.lock" "$L/opt/bin/neo" "$L/opt/etc/init.d/rc.unslung"
    mkdir -p "$FAKE_ST"
    : > "$FAKE_LOG"
    : > "$FAKE_LOCKS"
    echo 99 > "$FAKE_ST/alive"
    echo ok > "$FAKE_ST/stop_mode"
    echo 0 > "$FAKE_ST/start_rc"
    echo 0 > "$FAKE_ST/hrneo_rc"
    for ipt in iptables ip6tables; do
        printf '%s\n' "$EMPTY_RAW" > "$FAKE_ST/$ipt.out"
        echo 0 > "$FAKE_ST/$ipt.rc"
    done
    printf 'iptable_raw 2158 0 - Live 0x0\nip6table_raw 2168 0 - Live 0x0\n' > "$FAKE_ST/lsmod"
}

# run <exit code> <script> <args...>: the script in its own busybox sh.
run() {
    want=$1
    shift
    /bin/busybox sh "$@" > "$T/out" 2>&1
    got=$?
    [ "$got" = "$want" ] || fail "exit $got, want $want; output: $(cat "$T/out")"
}

log_is() {
    [ "$(cat "$FAKE_LOG")" = "$1" ] || fail "log:
$(cat "$FAKE_LOG")
want:
$1"
}

out_has() {
    grep -qF -e "$1" "$T/out" || fail "output lacks '$1': $(cat "$T/out")"
}

# S99hrneo
scenario s99-start
run 0 "$S99" start
log_is "rc.func start caller= ARGS="

scenario s99-restart-keeps-sets
run 0 "$S99" restart
log_is "rc.func restart caller= ARGS="

scenario raw-off
run 0 "$S99" raw-off
log_is "rc.func stop caller= ARGS=
hrneo --raw-off"
out_has "RawGuard=true puts the raw guard back"

scenario raw-off-slow-stop
echo slow > "$FAKE_ST/stop_mode"
run 0 "$S99" raw-off
log_is "rc.func stop caller= ARGS=
sleep 1
sleep 1
sleep 1
hrneo --raw-off"

scenario raw-off-stop-timeout
echo stuck > "$FAKE_ST/stop_mode"
run 1 "$S99" raw-off
log_is "rc.func stop caller= ARGS=
$SLEEPS"
out_has "hrneo did not stop within 10 s"

scenario raw-off-lock-held
# No hrneo process, but /proc/locks shows the lock taken.
: > "$L/run/hrneo.lock"
set -- $(ls -i "$L/run/hrneo.lock")
echo "1: FLOCK  ADVISORY  WRITE 4242 00:4f:$1 0 EOF" > "$FAKE_LOCKS"
echo 0 > "$FAKE_ST/alive"
run 1 "$S99" raw-off
log_is "rc.func stop caller= ARGS=
$SLEEPS"

for rc in 1 2 3; do
    scenario "raw-off-exit-$rc"
    echo "$rc" > "$FAKE_ST/hrneo_rc"
    run "$rc" "$S99" raw-off
    log_is "rc.func stop caller= ARGS=
hrneo --raw-off"
done
out_has "RawGuard=true puts the raw guard back"

scenario ipset-clean
run 0 "$S99" ipset-clean awg
log_is "rc.func stop caller=awg ARGS=
rc.func start caller=awg ARGS=--KeepIpsetOnRestart false --clearIPSet true"

scenario ipset-clean-slow-stop
echo slow > "$FAKE_ST/stop_mode"
run 0 "$S99" ipset-clean
log_is "rc.func stop caller= ARGS=
sleep 1
sleep 1
sleep 1
rc.func start caller= ARGS=--KeepIpsetOnRestart false --clearIPSet true"

scenario ipset-clean-stop-timeout
echo stuck > "$FAKE_ST/stop_mode"
run 1 "$S99" ipset-clean
log_is "rc.func stop caller= ARGS=
$SLEEPS"

# prerm: nothing unless the package is removed
scenario prerm-upgrade
run 0 "$PRERM" upgrade 1:3.21.0-1le3
log_is ""

scenario prerm-other-actions
run 0 "$PRERM" failed-upgrade 1:3.21.0-1le3
run 0 "$PRERM"
log_is ""

scenario prerm-remove
run 0 "$PRERM" remove
log_is "$REMOVE_ALL"

scenario prerm-remove-status-unsaved
echo 3 > "$FAKE_ST/hrneo_rc"
run 0 "$PRERM" remove
log_is "$REMOVE_ALL"
out_has "warning: raw guard removed, but its status file was not saved"

for rc in 1 2; do
    scenario "prerm-remove-raw-off-exit-$rc"
    echo "$rc" > "$FAKE_ST/hrneo_rc"
    run 1 "$PRERM" remove
    log_is "rc.func stop caller= ARGS=
hrneo --raw-off"
    out_has "package kept"
done

scenario prerm-remove-stop-timeout
echo stuck > "$FAKE_ST/stop_mode"
run 1 "$PRERM" remove
log_is "rc.func stop caller= ARGS=
$SLEEPS"
out_has "package kept"

scenario prerm-remove-dump-fails
echo 1 > "$FAKE_ST/iptables.rc"
run 0 "$PRERM" remove
log_is "rc.func stop caller= ARGS=
hrneo --raw-off
iptables -w -t raw -S
ip6tables -w -t raw -S
rmmod ip6table_raw"
out_has "iptables -t raw -S failed, iptable_raw stays loaded"

scenario prerm-remove-not-provably-empty
# A foreign rule, a foreign chain, a foreign policy, an empty dump: the module stays.
for dump in "$EMPTY_RAW
-A PREROUTING -p udp -m udp --dport 9 -j CT --notrack" "$EMPTY_RAW
-N FOREIGN" "-P PREROUTING DROP
-P OUTPUT ACCEPT" ""; do
    : > "$FAKE_LOG"
    printf '%s\n' "$dump" > "$FAKE_ST/iptables.out"
    [ -n "$dump" ] || : > "$FAKE_ST/iptables.out"
    echo 99 > "$FAKE_ST/alive"
    run 0 "$PRERM" remove
    log_is "rc.func stop caller= ARGS=
hrneo --raw-off
iptables -w -t raw -S
ip6tables -w -t raw -S
rmmod ip6table_raw"
done

scenario prerm-remove-module-not-loaded
printf 'iptable_raw 2158 0 - Live 0x0\nxt_CT 3000 0 - Live 0x0\n' > "$FAKE_ST/lsmod"
run 0 "$PRERM" remove
log_is "rc.func stop caller= ARGS=
hrneo --raw-off
iptables -w -t raw -S
rmmod iptable_raw"

scenario prerm-remove-again
echo 0 > "$FAKE_ST/alive"
: > "$FAKE_ST/lsmod"
run 0 "$PRERM" remove
log_is "rc.func stop caller= ARGS=
hrneo --raw-off"

# postinst: neo link, stop, start; a failed start does not fail the install.
scenario postinst
run 0 "$POSTINST" configure
log_is "rc.func stop caller= ARGS=
rc.func start caller= ARGS="
[ "$(readlink "$L/opt/bin/neo")" = "$S99" ] || fail "neo -> $(readlink "$L/opt/bin/neo")"

scenario postinst-start-fails
echo 1 > "$FAKE_ST/start_rc"
run 0 "$POSTINST" configure
out_has "Failed to start the HR Neo service"

scenario postinst-rc-unslung
printf '%s\n' '#!/bin/sh' '[ $ACTION = stop -o $ACTION = restart -o $ACTION = kill ] && ORDER="-r"' 'for i in $(ls /opt/etc/init.d/S*); do :; done' \
    > "$L/opt/etc/init.d/rc.unslung"
run 0 "$POSTINST" configure
run 0 "$POSTINST" configure
[ "$(grep -c '^\[ \$ACTION = start \] && sleep 10$' "$L/opt/etc/init.d/rc.unslung")" = 1 ] ||
    fail "rc.unslung: $(cat "$L/opt/etc/init.d/rc.unslung")"
[ "$(sed -n 3p "$L/opt/etc/init.d/rc.unslung")" = '[ $ACTION = start ] && sleep 10' ] ||
    fail "rc.unslung: $(cat "$L/opt/etc/init.d/rc.unslung")"

finish
