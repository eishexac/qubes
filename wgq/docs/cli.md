# The wgq command line

Every dom0 command is `sudo wgq …` (sudo is structural: the entrypoint
is a symlink into root-only `/srv/salt`, so the file that runs is
always the one the airlock approved). Six grammar rules cover
everything:

1. **The zone is the first argument** of every zone verb:
   `wgq disconnect work`.
2. **Nothing is implied.** Name no zone and, on a terminal, a picker
   asks — even with one zone. Without a terminal the command refuses
   and lists the zones: scripts get neither prompts nor guesses. The
   picker is a numbered menu from the standard library; with `fzf`
   installed in dom0 (`sudo qubes-dom0-update fzf` — Fedora's own
   repo, no new trust anchor) it upgrades to fuzzy typing.
3. **`-z <zone>` works anywhere** on the line and means the same thing
   in every position. `--zone` *after* a management verb belongs to
   that verb's own CLI inside the qube.
4. **Listing verbs speak `--json`** (`servers`, `peer list`, `status`,
   `zone list`): one parseable document on stdout, human notes on
   stderr.
5. **Version and verbose read conventionally.** `--version`/`-V` print
   the version; `--verbose`/`-v` widen output on the verbs that have a
   wall to hide (`zone add`) — `-v` is verbose, as everywhere in Unix,
   so version is `-V`.
6. **Refusals name their fix.** An error that doesn't tell you the
   next command is a bug; report it.

Zone names are painted in their zone's colour on a terminal; pipes and
`NO_COLOR` always get plain text — the previews below show the plain
form.

## Zones

```console
$ sudo wgq zone add media --color blue
wgq-zone: creating sys-wgq-media + sys-fw-media via salt (can take a minute)...
wgq-zone: zone media wears blue
wgq-zone: zone media is up (sys-wgq-media + sys-fw-media)
wgq-zone: attach clients with: wgq zone attach media <qube>

$ sudo wgq zone list
work                   vpn=sys-wgq-work   clients: work media
media                  vpn=sys-wgq-media  clients: none

$ sudo wgq zone rename wgq vault
wgq-zone: rename plan: sys-wgq -> sys-wgq-vault, sys-fw-wgq -> sys-fw-vault (clone, retag, rewire, remove)
wgq-zone: clients (personal) go DARK for the duration and follow to sys-fw-vault
type the new name to confirm: vault
```

`zone attach <zone> <qube>` / `zone detach <qube>` wire clients —
explicit names, never discovery. `zone remove` refuses while clients
are attached.

## Connection

```console
$ sudo wgq disconnect work
wgq: zone work is dark: the kill switch holds, clients get nothing until: sudo wgq connect work

$ sudo wgq connect work
wgq: zone work connected (ok peer=se-mma-wg-001 dns=10.64.0.1)
```

`up`/`down` are the same pair in WireGuard's vocabulary. With no zone
named, the picker:

```console
$ sudo wgq disconnect
  1) work
  2) media
zone number(s), space-separated: 1 2
```

## Settings

Layered: zone override beats global beats built-in; `default` clears
the named layer; `get` names the layer that answered.

```console
$ sudo wgq set --global dns 10.64.0.1
wgq: global dns = 10.64.0.1

$ sudo wgq set work dns 9.9.9.9
wgq: zone dns = 9.9.9.9

$ sudo wgq get work
autoconnect: on (default)
dns:         9.9.9.9 (zone override)
tunnel:      ok peer=se-mma-wg-001 dns=9.9.9.9

$ sudo wgq set work autoconnect off
wgq: zone work will boot sealed (tunnel down, forwarding refused) until an explicit connect
```

## Provisioning

Framed `qvm-run`s, printed before they run. Management verbs land in
wgq-mgmt; key handling lands in the zone's VPN qube; the key never
leaves it.

```console
$ sudo wgq credential ivpn
$ sudo wgq keygen media
$ sudo wgq pubkey media | sudo wgq provision --provider ivpn --zone media
$ sudo wgq sync media
$ sudo wgq switch media se-mma-wg-001
$ sudo wgq firewall --zone media
```

Own server or API-less provider: `wgq peer add` / `wgq peer import`
(refuses a config carrying a private key). `wgq servers --provider …`
lists endpoints, no credential needed.

## Proof and health

```console
$ sudo wgq verify work --kill-rounds 3
wgq verify: zone work: client work, endpoint 149.22.83.100:2049, resolver 10.64.0.1
wgq verify: [1] exit 149.22.83.98 differs from clearnet 212.104.102.11
wgq verify: [1b] UDP exit 149.22.83.98 matches the tunnel exit (WebRTC-safe)
wgq verify: [2] system DNS answers, arbitrary resolvers are intercepted
wgq verify: [3] nothing escaped with the tunnel down (3 round(s)), and recovery was proven each time
wgq verify: [4] skip: upstream pcap audit is not orchestrated yet
wgq verify: leak-tight: yes (4 passed, 1 skipped)

$ sudo wgq doctor
identity   icons 6/6 ok
identity   policies 3/3 ok
tree       /srv/salt/wgq present, /usr/local/bin/wgq wired ok
ownership  sys-wgq-work tagged ok
zone work  chain sys-fw-work -> sys-wgq-work -> sys-firewall ok
zone work  clients: work media
zone work  firewall state: ok peer=se-mma-wg-001 dns=9.9.9.9
zone work  kill switch installed ok
zone work  accel fast path absent ok
zone work  no-accel hook present ok
zone work  resolver override 9.9.9.9 materialized ok

wgq: doctor: nothing broken
```

## Seeing

```console
$ sudo wgq tree
sys-net
└─ sys-firewall
   ├─ zone work      ok peer=se-mma-wg-001 dns=9.9.9.9
   │  sys-wgq-work ─ sys-fw-work
   │  └─ work media
   └─ zone media     halted (boots sealed: autoconnect off)
      sys-wgq-media ─ sys-fw-media
      └─ (no clients; attach: sudo wgq zone attach media <qube>)
mgmt: wgq-mgmt (running, via sys-firewall)
routes: dom0-updates sys-fw-work | template-updates stock | clock sys-net | new-qubes sys-firewall
```

```console
$ sudo wgq top
wgq top ── 21:14:03 ── every 2s ── q quits

zone work      ok peer=se-mma-wg-001 dns=9.9.9.9 · hs 12s
  rx    1.2MB/s ▂▃▅█▆▃▁▂   tx  301.4KB/s ▁▁▂▃▂▁▁▁
  drops 42
  └─ work         down 1.1GB · up 204.7MB
  └─ media        down 320.6MB · up 88.1MB
```

```console
$ sudo wgq logs work
── zone work ── the last 100 lines, merged ──
2026-09-08T09:14:02 wgq-firewall: kill switch installed
2026-09-08T09:14:03 wg-tunnel[412]: up: peer se-mma-wg-001, endpoint 149.22.83.100:2049
```

`logs <zone>` is the zone's journal — the firewall script's lines, the
tunnel unit and the qubes-firewall daemon, interleaved by journald
itself; `-f` follows live, `-n`/`--since` scope it, and everything a
qube prints is stripped to printing characters first.

The drop counter is the seal working, live: a tick where it moves says
`(+3 THIS TICK: something tried to leave outside the tunnel)`.
`top <zone>` filters; `top <zone> --once` prints one plain snapshot.

## System traffic

```console
$ sudo wgq route list
dom0-updates      sys-fw-work      (via zone work)
template-updates  stock policy     (default)
clock             sys-net          (stock)
new-qubes         sys-firewall     (stock)

$ sudo wgq route template-updates work
wgq route: this role needs a qrexec policy line; the exact file that would be installed:
--- /etc/qubes/policy.d/51-wgq-routes.policy ---
qubes.UpdatesProxy * @type:TemplateVM @default allow target=sys-fw-work
---
Install it and enable the proxy on sys-fw-work? [y/N]
```

`clock` is allowed but argued with (a clock source behind the tunnel
can never fix a badly wrong clock — the cold-boot paradox); `default`
takes any role back to stock.

## Maintenance

```console
$ sudo wgq restart
wgq restart: restart plan:
wgq restart:   debian-13-wgq: shut down (templates stay halted)
wgq restart:   zone work: sys-fw-work + sys-wgq-work down, then up
wgq restart:   wgq-mgmt: down, then up
wgq restart: these running clients go DARK while their zone bounces: work media
Run the cycle? [y/N]
```

`panic [-z zone]` is the emergency stop: deny-all enforced upstream of
the zone, VPN qube killed, recovery deliberate. `uninstall` tears down
step by step — system routes reset first, then zones, mgmt, template,
identity, policy.

Updating wgq itself: pull through the airlock (`airlock pull <qube>
wgq <repo>`); it fetches the repo's own airlock first and offers the
replacement before anything else. See [install.md](install.md).
