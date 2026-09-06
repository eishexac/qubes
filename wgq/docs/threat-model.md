# Threat model

What wgq protects against, what it deliberately does not, and the one
thing to understand before trusting it. The design rationale behind
every claim here is sourced line by line in [DESIGN.md](../DESIGN.md).

**What this protects against**

- The tunnel dropping. Clients get nothing rather than falling back to the
  clear — not slow traffic, not degraded traffic, nothing.
- The VPN qube being compromised and trying to reach anywhere except its
  allowlisted endpoints.
- Client DNS reaching a resolver outside the tunnel.
- A misconfiguration silently producing a qube that forwards in the clear.
  If the rules cannot be proven to have landed, forwarding is switched off.
- A zone qube that is not configured yet: it forwards nothing until its
  first `wgq switch` succeeds, rather than acting as a plain proxy.

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
