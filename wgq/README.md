# wgq

Leak-tight WireGuard proxy qubes for Qubes OS.

A Salt formula plus a single-file tool that provisions one VPN qube per
identity zone, with an endpoint allowlist enforced outside the qube it
constrains.

> [!WARNING]
> **This has never been run.** Not once, end to end, on any machine.
>
> It is public so the reasoning can be checked, not because it is ready to
> protect anyone. Do not make it your only defence against a VPN leak. If you
> need something to rely on today, use [Solene's forum guide][solene] — the
> best-tested community reference for 4.2 and 4.3.

[solene]: https://forum.qubes-os.org/t/wireguard-vpn-setup-4-2-and-4-3/19141

---

## Status

**Last tested against: nothing.**

Target: Qubes OS 4.3, `debian-13-minimal` (Debian 13 "trixie").

Everything here was written against upstream source rather than from
recollection — `qubes-core-agent-linux`, `qubes-core-admin`,
`wireguard-tools`, `mullvadvpn-app` — and `DESIGN.md` cites the file
and line behind every decision. That is worth something, and it is not the
same as having run it. Reading source tells you what the code says; only
running it tells you what the system does.

Two things need a live 4.3 machine before anyone relies on them:

1. **The `qvm-firewall` block.** `qvm-firewall reset` installs a single
   `action=accept` rule, per `qubesadmin/tools/qvm_firewall.py`. The emitted
   sequence follows from that. Nobody has watched it run.
2. **The `admin.vm.firewall.Set` grant.** The policy syntax and the `ask`
   prompt behaviour are read from Qubes' own policy headers, not observed.

The IVPN backend's request and response shapes have been verified against
their open-source client's source (`ivpn/desktop-app`), but it has still
never been exercised against a live account, and says so in the module
docstring. Note that IVPN registration is session-based and not idempotent:
each provisioning run consumes one of the account's session slots (2 on
Standard, 7 on Pro) until the API refuses with its session-limit status.

### What would make this ready

- [ ] The two items above confirmed on hardware, with real output pasted here
- [ ] One zone provisioned end to end
- [ ] `test/verify.sh` passing all four checks, including the kill test
- [ ] Survived one server retirement and one dom0 update

Until those are ticked, treat this as a design under review rather than a
tool. Issues and corrections are welcome — that is the point of it being
here.

---

## Threat model

**What this protects against**

- The tunnel dropping. Clients get nothing rather than falling back to the
  clear — not slow traffic, not degraded traffic, nothing.
- The VPN qube being compromised and trying to reach anywhere except its
  allowlisted endpoints.
- Client DNS reaching a resolver outside the tunnel.
- A misconfiguration silently producing a qube that forwards in the clear.
  If the rules cannot be proven to have landed, forwarding is switched off.

**What it does not protect against**

- Your VPN provider. They see everything the tunnel carries. This project
  moves trust; it does not remove it.
- Traffic correlation by anyone watching both ends.
- A compromised template, which is upstream of every qube built from it.
- A compromised `sys-firewall`. Layer 1 is enforced *there*, so an attacker
  who owns it can lift the allowlist.
- Exfiltration by an already-compromised VPN qube over UDP to an
  allowlisted endpoint. Layer 1 constrains *where* that qube can talk, not
  *what* it says.
- Anything above the tunnel: browser fingerprinting, logins, DoH to a
  resolver of the browser's choosing.

**The one thing to understand**

`qvm-firewall` rules are the real protection. They live in dom0 at
`/var/lib/qubes/appvms/<vm>/firewall.xml` and are implemented by the VPN
qube's *net* qube, so they cannot be modified from inside the qube they
constrain, and they fail closed: if the firewall service is not running when
a qube starts, no traffic passes.

The nftables rules inside the VPN qube are defence in depth against **tunnel
loss**, not against **compromise**. Anything running as root in that qube can
remove them. Do not read the in-qube kill switch as a second security
boundary; it is a correctness backstop for the common failure.

---

## Topology

```
sys-net ── sys-firewall ─┬─ sys-vpn-work ── sys-firewall-work ── [client qubes]
                         ├─ wgq-mgmt                             (provisioning only)
                         └─ sys-whonix                           (optional)
```

One VPN qube per identity zone, not one qube with policy routing. That is
forced by the topology, not a preference: all client traffic reaches the VPN
qube appearing to come from `sys-firewall-work`, so per-client policy inside
the VPN qube is impossible.

Clients point at `sys-firewall-<zone>` permanently. Switching which VPN backs
them is one command and touches no client:

```sh
qvm-prefs sys-firewall-work netvm sys-vpn-other
```

Do not put a firewall qube between `sys-vpn-*` and `sys-whonix`.
Whonix-Gateway does not respect the qubes-firewall service, so rules on qubes
behind it have no effect.

---

## Defence layers

| Layer | Enforced by | Survives VPN qube compromise |
|---|---|---|
| `qvm-firewall sys-vpn-work` → endpoints only | `sys-firewall`, upstream | **Yes** |
| `sys-firewall-work` | a separate Xen domain | **Yes** |
| `/etc/qubes/qubes-firewall.d/50-wgq` | inside the VPN qube, at firewall start | No |

---

## Install

Read every file before it enters dom0. There are three, and they are all
text: two Salt states and two lines of qrexec policy.

```sh
# the whole collection, or sparse-checkout just this project -- see the
# repository README; wgq/ is self-contained either way
git clone <the qubes repo> && cd qubes/wgq
make                          # builds dist/wgq, one ~100 KB file
make check                    # syntax, shellcheck, unit tests, Salt render
```

The build is deterministic: the same tree produces byte-identical output, so
`sha256sum dist/wgq` is comparable across machines. A release's attached
artifact is only ever a convenience -- rebuild and compare instead of
trusting it.

**1. Copy the formula into dom0** (from the qube holding the clone):

```sh
# in dom0
qvm-run --pass-io <qube> 'tar -C /path/to/qubes -c wgq' | sudo tar -C /srv/salt -x
less /srv/salt/wgq/salt/wg-template.sls
less /srv/salt/wgq/salt/wg-qubes.sls
less /srv/salt/wgq/dom0/30-wgq.policy
```

**2. Build the template:**

```sh
sudo qubesctl --show-output state.apply wgq.wg-template
sudo qubesctl --skip-dom0 --targets=wgq-debian-13 --show-output \
    state.apply wgq.wg-template
```

The first invocation clones `debian-13-minimal` and bootstraps
`qubes-mgmt-salt-vm-connector` over `qvm-run`. That step cannot be a Salt
state: it is the package that makes a qube salt-manageable.

**3. Create the qubes:**

```sh
sudo qubesctl --show-output state.apply wgq.wg-qubes
```

**4. Optionally install the policy** that lets `wgq firewall` apply the
allowlist for you:

```sh
sudo cp /srv/salt/wgq/dom0/30-wgq.policy /etc/qubes/policy.d/30-wgq.policy
```

Without it, `wgq firewall` prints a `qvm-firewall` block for you to paste.
With it, the same rules are applied by `admin.vm.firewall.Set` — one atomic
call, no rule numbers to miscount — and the default `ask` action raises a
dom0 confirmation each time. Read the file; it explains the trade.

---

## Use

**Once per zone qube**, inside it:

```sh
sudo wgq keygen                 # prints the public key; never regenerates silently
```

**In `wgq-mgmt`:**

```sh
install -m 600 /dev/null /rw/config/mullvad-account
printf '%s\n' <16-digit account> > /rw/config/mullvad-account

wgq servers --provider mullvad --filter se
wgq provision --zone work --provider mullvad --filter se-mma --count 2 \
    --pubkey <the key from keygen>
qvm-copy ~/.local/share/wgq/zones/work
```

**Back in the zone qube:**

```sh
sudo wgq apply ~/QubesIncoming/wgq-mgmt/work/peers
sudo wgq switch se-mma-wg-001
wgq status
```

**And in `wgq-mgmt`:**

```sh
wgq firewall --zone work
```

Then point a client at `sys-firewall-work` and run the verifier from it.

### Your own server, or any provider without an API

The data model does not care where a peer came from. Generate the key in the
qube, add the public half to your server, then record the rest:

```sh
wgq peer add --zone home --name home-gw \
    --server-pubkey <your server's public key> \
    --endpoint 203.0.113.5:51820 \
    --address 10.10.0.2 \
    --dns 10.10.0.1
```

Or import a config you already have:

```sh
wgq peer import --zone home --name home-gw ~/wg0.conf --dns 10.10.0.1
```

Import refuses a config carrying a real `PrivateKey`, because moving one
through the management qube would defeat the whole key-handling design. It
lifts the `DNS =` line into metadata, where it becomes a DNAT rule that
actually pins clients — `wg-quick` could not apply it anyway, since Debian
minimal ships no `resolvconf`.

A private endpoint (your own box on a LAN) needs `--allow-private-endpoint`.
Provider-sourced endpoints are always required to be publicly routable.

---

## Verify

This is the part nobody ships, and it matters more than the rest. Run it from
a **client** qube — never the VPN qube, whose own egress to the endpoint is
deliberately permitted.

```sh
qvm-copy test/verify.sh          # into a client qube
./verify.sh --dns 10.64.0.1 --endpoint 185.65.135.170:51820 \
            --provider mullvad --peer se-mma-wg-001
```

Four checks:

1. The public address is the tunnel exit. **Needs an anchor** —
   `--provider mullvad`, `--exit-ip`, or `--clearnet-ip`. Without one it
   reports SKIP, because a check that cannot fail is worse than no check.
2. Client DNS is pinned. Proven by aiming a query at `192.0.2.1`
   (TEST-NET-1, which can never legitimately answer): a reply means the DNAT
   is intercepting, so a client that sets its own resolver cannot escape it.
3. **The kill test.** With `wg-tunnel` stopped in the VPN qube, the client
   gets nothing. This is the check that separates a working kill switch from
   a lucky one.
4. A capture from the upstream firewall qube holds only allowlisted UDP.

Checks 3 and 4 need a hand elsewhere — stopping the tunnel is a dom0 command,
and the capture is taken in `sys-firewall`. The script walks you through both
and tells you exactly what to run where. A skipped check exits non-zero.

---

## What this deliberately does not do

- **Execute `qvm-firewall` without asking.** With the policy installed the
  rules are applied through the Admin API, but the default action is `ask`,
  so you still approve every change to the security boundary. Without it,
  the block is printed for you to paste.
- **Integrate provider clients.** Vendor daemons manipulate nftables to
  prevent leaks in ways that assume an ordinary Linux host, and their
  anti-leak logic misfires on Qubes' topology. IVPN's own Qubes guide has you
  hand-patch `/opt/ivpn/etc/firewall.sh` and warns the patch will be
  overwritten by the next update. Config files only.
- **Support NymVPN.** They still publish no standalone WireGuard configs
  (checked August 2026; it remains roadmap-only). The zk-nym credential
  system rotates, so a static config expires at the next rotation, and
  dynamic gateway selection means there is no fixed endpoint to allowlist —
  which removes layer 1 entirely. That is not a provider plugin; it is a
  different architecture, and it belongs in a different repository. Revisit
  if their router-level WireGuard support ships with fixed gateways.
- **Distribute a template or a compiled binary.** Your trust anchors stay
  Debian and ITL. `dist/wgq` is a zipapp, so it is a single file *and*
  readable: `unzip -p dist/wgq wgq/fwrules.py`. Because the build is
  deterministic, a downloaded release artifact is verifiable against your
  own `make` rather than trusted; the signed tag, not the upload, is the
  thing to check.

---

## Layout

```
wgq/
├── dom0/30-wgq.policy      two qrexec lines; read before copying
├── salt/                   the formula
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

---

## Notes

The Qubes Salt API is provisional and can change between minor releases. The
states here are written for 4.3.

`qubes-core-agent-passwordless-root` is installed because minimal templates
omit it. It means anything running as the user in these qubes can become
root. For a qube with no user sessions that provides network to others, that
is an acceptable trade; if it is not acceptable to you, drop it from
`salt/wg-template.sls` and use `qvm-run -u root` from dom0 instead.

`make check` runs `shellcheck` when it is installed. Install it before
sending patches that touch shell.
