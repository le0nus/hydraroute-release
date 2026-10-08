# hydraroute-release

opkg feed for a fork of [HydraRoute Neo](https://github.com/Ground-Zerro/HydraRoute) (`hrneo`), AGPL-3.0.
Fork sources: https://github.com/le0nus/HydraRoute (development branch `feat/raw-guard`).
The published package hrneo 1:3.21.0-1le2 is built from tag
[`v3.21.0-1le2`](https://github.com/le0nus/HydraRoute/tree/v3.21.0-1le2/Neo/source).

Every published version has a matching tag `v<version>` in the fork, pushed before the package.
Next to each package, `hrneo_<version>_<arch>.ipk.source` records the fork commit, the
`hrneo-build` image id and the sha256 of the binary; `tools/build.sh` refuses to build from
uncommitted sources.

Changes in 3.21.0-1le2: traffic to addresses from the lists of Keenetic policy targets gets its
policy mark in the `raw` table (chain `HRNEO_GUARD`), so it no longer leaves through the WAN while
NDMS rebuilds iptables (DHCP renewals, WAN changes) or while hrneo restarts or is dead; with the
tunnel down it is dropped. The ipset is kept across restarts (`KeepIpsetOnRestart`),
`neo raw-off` and `neo ipset-clean` are new, and `/var/run/hrneo-status` reports the guard and the
path state of each policy. Details: `Neo/docs/HRNEO.CONF.md` in the fork, section
"Защита от утечек (raw guard)".

From 1:3.21.0-1le2 on, fork versions carry opkg epoch 1, so opkg ranks them above any upstream
hrneo and `opkg install hrneo` no longer switches back to upstream's package. The epoch is only
in the package's Version: the tag, the file name and `hrneo --version` leave it out
(`v3.21.0-1le2`, `hrneo_3.21.0-1le2_aarch64-3.10.ipk`, `hrneo v3.21.0-1le2`).

## Feed address

The feed is served from the `main` branch of this repository through raw.githubusercontent.com:

    src/gz le0nus-hr https://raw.githubusercontent.com/le0nus/hydraroute-release/main/keenetic/aarch64-k3.10

GitHub Pages (`le0nus.github.io/hydraroute-release`) is not used. Pages deploys only through a
GitHub Actions workflow, and Actions are disabled for this repository, so the Pages site is stale
(it still serves the 3.21.0-1le1 feed) and is not updated any more.

Install on Keenetic (Entware): `curl -fsSL https://raw.githubusercontent.com/le0nus/hydraroute-release/main/keenetic/install-feed.sh | sh`

The installer puts the feed into `/opt/etc/opkg/customfeeds.conf` (in place of an older line of
the same feed, such as the old Pages one), downloads the package and installs it only if its size
and sha256 match the feed's index, then checks that opkg shows it fully installed and holds it.
Run it again to update to a newer fork version or to finish an installation that failed half way.
It never downgrades: with a newer hrneo installed it stops and says how to go back by hand.

## Publishing

`Packages` and `Packages.gz` are generated locally in the `hrneo-build` container and committed
next to the packages. The index lists only the current package. Older packages and their
`.source` files stay in `keenetic/aarch64-k3.10/`, so their URLs keep working, but they are not in
the index. A release:

1. Tag the fork commit `v<version>` and push the tag.
2. `tools/build.sh <fork checkout> 1:<version>`. It removes the other `hrneo_*` files from
   `keenetic/aarch64-k3.10/`: restore the published ones with `git checkout -- <files>`.
3. Commit and push the new `.ipk` and `.source` on their own.
4. Copy the new `.ipk` alone into `<stage>/keenetic/aarch64-k3.10/`, run
   `docker run --rm -v "$PWD":/r:ro -v <stage>:/stage -w /r hrneo-build sh tools/make-index.sh /stage`
   and copy its `Packages` and `Packages.gz` into `keenetic/aarch64-k3.10/`.
5. Commit and push the index. The package goes out first, so a client that reads the new index
   never asks for a file that is not there yet.

## Going back to an older version

hrneo's prerm takes its raw guard down only when the package is removed, not on a version
change, and an older hrneo left with the raw chain `HRNEO_GUARD` of a newer one leaks new
connections. So take the guard down first:

1. `neo raw-off` stops hrneo, waits until it has exited and removes `HRNEO_GUARD` from the IPv4
   and IPv6 raw tables. Go on only if it exits 0, or 3 (removed, but hrneo's status file was not
   saved). 1 means not fully removed and 2 that hrneo is running again: fix that and run it again.
2. Neither `iptables -w -t raw -S` nor `ip6tables -w -t raw -S` may show `HRNEO_GUARD`.
3. Only then install the older version: `opkg flag user hrneo`,
   `opkg install --force-downgrade <older hrneo .ipk>`, `opkg flag hold hrneo`. The older
   packages stay downloadable from the feed directory, for example
   `https://raw.githubusercontent.com/le0nus/hydraroute-release/main/keenetic/aarch64-k3.10/hrneo_3.21.0-1le1_aarch64-3.10.ipk`.
