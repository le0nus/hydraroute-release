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

Install on Keenetic (Entware): `curl -fsSL https://le0nus.github.io/hydraroute-release/keenetic/install-feed.sh | sh`

The installer installs the fork's package even when another feed (upstream's) has a higher
hrneo version, checks that the fork version ended up installed and holds it. Run it again to
update to a newer fork version. The hold stops `opkg upgrade`, but `opkg install hrneo` still
takes the highest version across feeds and would replace the fork with upstream's package.
