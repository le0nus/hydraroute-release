# hydraroute-release

opkg feed for a fork of [HydraRoute Neo](https://github.com/Ground-Zerro/HydraRoute) (`hrneo`), AGPL-3.0.
Fork sources: https://github.com/le0nus/HydraRoute (development branch `fix/netfilter-window`).
The published package hrneo 3.21.0-1le1 is built from tag
[`v3.21.0-1le1`](https://github.com/le0nus/HydraRoute/tree/v3.21.0-1le1/Neo/source).

Every published version has a matching tag `v<version>` in the fork, pushed before the package.
Next to each package, `hrneo_<version>_<arch>.ipk.source` records the fork commit, the
`hrneo-build` image id and the sha256 of the binary; `tools/build.sh` refuses to build from
uncommitted sources.

Changes in 3.21.0-1le1: HydraRoute CONNMARK rules are restored on every netfilter hook call
instead of up to 3 s later, and live ipset entries get their timeout refreshed.

Install on Keenetic (Entware): `curl -fsSL https://raw.githubusercontent.com/le0nus/hydraroute-release/main/keenetic/install-feed.sh | sh`

From 1:3.21.0-1le2 on, fork versions carry opkg epoch 1, so opkg ranks them above any upstream
hrneo and `opkg install hrneo` no longer switches back to upstream's package. The epoch is only
in the package's Version: the tag, the file name and `hrneo --version` leave it out
(`v3.21.0-1le2`, `hrneo_3.21.0-1le2_aarch64-3.10.ipk`, `hrneo v3.21.0-1le2`).

The installer puts the feed into `/opt/etc/opkg/customfeeds.conf` (in place of an older line of
the same feed), downloads the package and installs it only if its size and sha256 match the
feed's index, then checks that opkg shows it fully installed and holds it. Run it again to update
to a newer fork version or to finish an installation that failed half way. It never downgrades:
with a newer hrneo installed it stops and says how to go back by hand.

## Going back to an older version

hrneo's prerm takes its raw guard down only when the package is removed, not on a version
change, and an older hrneo left with the raw chain `HRNEO_GUARD` of a newer one leaks new
connections. So take the guard down first:

1. `neo raw-off` stops hrneo, waits until it has exited and removes `HRNEO_GUARD` from the IPv4
   and IPv6 raw tables. Go on only if it exits 0, or 3 (removed, but hrneo's status file was not
   saved). 1 means not fully removed and 2 that hrneo is running again: fix that and run it again.
2. Neither `iptables -w -t raw -S` nor `ip6tables -w -t raw -S` may show `HRNEO_GUARD`.
3. Only then: `opkg flag user hrneo`, `opkg install --force-downgrade <older hrneo .ipk>`,
   `opkg flag hold hrneo`.
