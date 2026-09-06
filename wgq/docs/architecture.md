# Architecture

The topology, the defence layers, and the identity system. The threat
model these serve is in [threat-model.md](threat-model.md); the sourced
rationale is in [DESIGN.md](../DESIGN.md).

## Topology

```
sys-net ── sys-firewall ─┬─ sys-wgq-work ── sys-fw-work ── [client qubes]
                         ├─ wgq-mgmt                             (provisioning only)
                         └─ sys-whonix                           (optional)
```

One VPN qube per identity zone, not one qube with policy routing. That is
forced by the topology, not a preference: all client traffic reaches the VPN
qube appearing to come from `sys-fw-work`, so per-client policy inside
the VPN qube is impossible.

Clients point at `sys-fw-<zone>` permanently. Switching which VPN backs
them is one command and touches no client:

```sh
qvm-prefs sys-fw-work netvm sys-wgq-other
```

Do not put a firewall qube between `sys-wgq-*` and `sys-whonix`.
Whonix-Gateway does not respect the qubes-firewall service, so rules on qubes
behind it have no effect.

---

## Defence layers

| Layer | Enforced by | Survives VPN qube compromise |
|---|---|---|
| `qvm-firewall sys-wgq-work` → endpoints only | `sys-firewall`, upstream | **Yes** |
| `sys-fw-work` | a separate Xen domain | **Yes** |
| `/etc/qubes/qubes-firewall.d/50-wgq` | inside the VPN qube, at firewall start | No |

---

## Identity and ownership

**Identity.** wgq qubes wear their own Qubes labels — `wgq` (red, like
sys-net: the edge), `wgq-fw` (green, like sys-firewall: the filter),
`wgq-mgmt` (yellow) and `wgq-tpl` (black, like stock templates) —
created as named custom labels via the Admin API, so no stock colour is
claimed. Qubes computes an icon name as `servicevm-<label>` for a
netvm-style qube and `<class>-<label>` otherwise, which is what scopes
the icons to wgq alone: every wgq cube carries a shield and a recessed
RJ45 socket (wgq-mgmt trades the shield for a terminal prompt), and no
stock icon file is shadowed. A VPN or firewall qube is created as a
plain AppVM and only gains its `servicevm` mark a moment later, so it
briefly wears the `appvm-<label>` name; the icon set ships that name
too (same art), so the qube shows its cube from birth and a running
menu never caches a blank — otherwise each new zone would cost a
relogin. The labels and icon files install with `wgq.wg-icons` (first
in the apply plan; zones, mgmt and the template include it too), the
icons living in dom0's `/usr/share/icons` as package-unowned files (the
one path every GUI process searches; updates leave unowned files
alone). A menu already running when a qube's label *changes* keeps its
stale icon cache until the next login — the once-per-install template
relabel is the one place that still shows.

Two policy files make the identity permanent rather than merely
default. `30-wgq-labels.policy` denies every VM the wgq label names
themselves (the label name is the qrexec argument, so it can be pinned
by name). `30-wgq-creation.policy` restates the Admin API's deny
default for creating qubes, cloning them and changing labels — adding
nothing today, but sorted at 30 so a later broad `admin.*` allow to
some management qube can never quietly include the power to mint or
dress qubes. A qube's *name* cannot be pinned by policy (it travels in
the call payload, invisible to policy) and does not need to be: the
label is the identity Qubes draws, and both files together keep it
dom0's alone.

**Ownership.** Every qube wgq creates carries the `created-by-wgq` tag,
and everything that lists, rewires or destroys by the `sys-fw-*` name
grammar checks it first: a stranger's qube that happens to share the
naming is never listed as a zone, never routed through, never converged
by a salt re-run, and never offered for removal. A qube wearing a wgq
label is adopted and tagged automatically (only dom0 can dress a qube,
so the label is proof); anything else is refused with the one command
that adopts it — `qvm-tags <qube> add created-by-wgq` — for installs
that predate the tag. The single deliberate exception is `wgq panic`
with no `-z`: the emergency stop sweeps by name, unfiltered, because
blocking a similarly-named stranger's qube is a recoverable
inconvenience while skipping an untagged wgq qube is an open line.

---

## Layout

```
wgq/
├── dom0/30-wgq.policy      two qrexec lines; read before copying
├── wg-template.sls         the formula: clone + configure the template
├── wg-mgmt.sls            the formula: create the qubes
├── top.sls                 optional, for qubesctl top.enable
├── template/               files installed into the template root
│   ├── etc/qubes/qubes-firewall.d/50-wgq
│   ├── etc/systemd/system/wg-tunnel.service
│   └── usr/sbin/wg-tunnel
├── src/wgq/                the tool
├── test/verify.sh          runs in a client qube
└── DESIGN.md               why the design is what it is, with sources
```

wgq lives inside the qubes collection but depends on none of it at
install time: the subtree above is everything that enters dom0. The
deterministic zipapp builder it uses at build time is shared, at the
repository root (`tools/mkzipapp.py`).

Nothing installs into `/usr/local`: in template-based qubes that directory
is the qube's own `/rw/usrlocal`, seeded from the template once on first
boot and never updated again (`qubes-core-agent-linux`, `init/setup-rw.sh`).
Files there would silently freeze at whatever version each qube first saw.

Inside a zone qube:

```
/rw/config/wg/
├── private.key             0600, generated there, never copied out
├── public.key
├── peers/<name>.conf       0600
├── peers/<name>.meta       endpoint, resolver, provider
└── wg0.conf -> peers/<name>.conf     the active peer
```

The interface name is pinned to `wg0` so the firewall rule can name the
tunnel statically instead of naming the uplink. The symlink is the only
record of which peer is active — one source of truth.
