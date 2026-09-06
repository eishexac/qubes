# wgq

Leak-tight WireGuard proxy qubes for Qubes OS.

A Salt formula plus a single-file tool that provisions one VPN qube per
identity zone, with an endpoint allowlist enforced outside the qube it
constrains.

> [!WARNING]
> **Young software, one machine of history.** It has been run end to end
> on real hardware (see Status), and its kill test has caught real bugs —
> but that is one author, one machine, one provider. Do not make it your
> only defence against a VPN leak yet. If you need the battle-tested
> path today, use [Solene's forum guide][solene] — the best-tested
> community reference for 4.2 and 4.3.

[solene]: https://forum.qubes-os.org/t/wireguard-vpn-setup-4-2-and-4-3/19141

---

## Status

**Last tested against: Qubes OS 4.3 on hardware, 2026-09-04 — a full
end-to-end run.** Target: `debian-13-minimal` (Debian 13 "trixie").

The run, on a live machine with a live IVPN account: install through the
airlock → zone created → `credential` → `keygen` → `provision` (key
registered, peers written) → `sync` → `switch` (handshake) → `firewall`
(the `admin.vm.firewall.Set` grant exercised, `ask` prompt observed) →
client attached → `test/verify.sh` from the client:

- Check 1 (exit address differs from clearnet): **PASS**
- Check 2 (DNS pinned; queries to arbitrary resolvers intercepted): **PASS**
- Check 3 (kill test — nothing escapes with the tunnel down): **PASS**,
  three consecutive runs
- Check 4 (upstream pcap audit): optional, not run

The kill test earned its keep twice over. It caught a real leak — an
nftables flowtable fast path that bypassed the kill switch for offloaded
DNS flows, sealed by installing the rules atomically and removing the
fast path from VPN qubes — and then it caught its own detector treating
dig's stdout error notices as answers. Both fixes are in this tree; the
hunt is written into the commit history.

Also verified on the same machine: **Tor over VPN** — pointing
`sys-whonix` at the zone's firewall qube gives
`anon-whonix → sys-whonix → sys-fw-<zone> → sys-wgq-<zone> → tunnel`,
so the ISP sees only WireGuard, never a Tor handshake. The kill switch
composes: tunnel down means Whonix goes dark rather than bootstrapping
Tor over clearnet.

Still unobserved: a server retirement, a dom0 update over an installed
zone, and the Mullvad backend against a live account (the IVPN backend
is now exercised; Mullvad remains source-verified only). Note that IVPN
registration is session-based and not idempotent: each provisioning run
consumes one of the account's session slots (2 on Standard, 7 on Pro)
until the API refuses with its session-limit status.

### Next

Direction settled, not yet built:

- **Named zones only.** The reserved default zone `wgq` (bare `sys-wgq`
  + `sys-fw-wgq`) will be retired: every zone gets a chosen name, no
  hidden default to reach for. Explicitness won every argument it was
  in during the hardware runs; the singleton is the last implicit thing
  left.
- **An interactive server picker.** `provision`/`switch` today take
  `--filter`/`--server`/`--count`; the plan is a drill-down menu —
  country, city, server — over the fetched list, stdlib only.
- **Multiple accounts.** One credential per provider today; the shape
  for several (per-zone accounts? named credentials?) is open.
- **Architecture diagrams.** DESIGN.md cites source line by line but
  draws nothing; the zone topology, the packet path through the chains,
  and the kill-switch story deserve figures.

---

---

## Quickstart

Install through the airlock ([docs/install.md](docs/install.md)), then
the whole lifecycle is dom0 commands:

```sh
sudo wgq credential ivpn
sudo wgq keygen
sudo wgq pubkey | sudo wgq provision --provider ivpn --zone wgq
sudo wgq sync
sudo wgq switch <peer>
sudo wgq firewall --zone wgq
sudo wgq verify --kill-rounds 3
sudo wgq doctor
```

Point clients at `sys-fw-<zone>` and they inherit fail-closed: tunnel
down means they get nothing, never clear traffic.

---

## Documentation

| | |
|---|---|
| [docs/threat-model.md](docs/threat-model.md) | what this protects against, what it does not, and what it refuses to do |
| [docs/architecture.md](docs/architecture.md) | topology, defence layers, identity and ownership, layout |
| [docs/install.md](docs/install.md) | the verified install, step by step, and uninstall |
| [docs/lifecycle.md](docs/lifecycle.md) | provisioning, zones, connect/disconnect, settings, panic |
| [docs/verify.md](docs/verify.md) | proving the zone leak-tight: verify, doctor, the manual script |
| [DESIGN.md](DESIGN.md) | why the design is what it is, with sources |
| [CHANGELOG.md](CHANGELOG.md) | what changed, for the operator |

Security policy and key fingerprint: [SECURITY.md](../SECURITY.md), at
the repository root.
