# hydraroute-release

opkg feed for a fork of [HydraRoute Neo](https://github.com/Ground-Zerro/HydraRoute) (`hrneo`), AGPL-3.0.
Fork sources: https://github.com/le0nus/HydraRoute (branch `fix/netfilter-window`).

Fork changes: HydraRoute CONNMARK rules are restored on every netfilter hook call instead of
up to 3 s later, and live ipset entries get their timeout refreshed.

Install on Keenetic (Entware): `curl -fsSL https://le0nus.github.io/hydraroute-release/keenetic/install-feed.sh | sh`
