# Security

## Status of this code

**wgq has never been run end to end, and has not been audited.** It is
published so its reasoning can be checked. Read `README.md` before deciding
whether it fits your threat model, and `DESIGN.md` for why each
decision was made and which upstream source it came from.

## Reporting

Use GitHub's private vulnerability reporting on this repository
(**Security → Report a vulnerability**). That keeps the report private until
there is a fix.

Please do not open a public issue for anything that would let someone's
traffic leak before it is fixed.

There is no bounty, no SLA, and one maintainer. You will get an honest
answer, which may be "yes, and I do not know when I will fix it".

## What counts as a vulnerability here

The project's job is that traffic either goes through the tunnel or goes
nowhere. Anything that breaks that is in scope:

- A path by which client traffic reaches the uplink when the tunnel is down.
- A rule that appears to apply but does not — installed into the wrong chain,
  bypassed by flow offload, or silently skipped.
- Anything that moves a private key out of the qube that generated it, or
  writes one somewhere it can be read.
- An account credential reaching a log, an error message, a config file, or
  Salt.
- A config or allowlist that is emitted despite being incomplete. The design
  requires refusing to write rather than writing something partly correct.
- Path traversal or injection through a peer name, a config file, or a
  provider API response.

## What is out of scope

These are properties of the design, documented in `README.md`, not defects:

- **Your VPN provider sees your traffic.** This moves trust; it does not
  remove it.
- **A compromised `sys-firewall` defeats layer 1**, because that is where the
  allowlist is enforced.
- **A compromised VPN qube can exfiltrate over UDP to an allowlisted
  endpoint.** Layer 1 constrains where that qube can talk, not what it says.
- **The in-qube nftables rules do not survive root in that qube.** They are
  defence against tunnel loss, not against compromise.
- **A compromised template** is upstream of every qube built from it.
- **DNS chosen above the tunnel**, such as a browser doing DoH. The DNAT
  pins plaintext DNS; it cannot pin what a browser encrypts.

## Cryptography

None is implemented here. Key generation is `wg genkey`, and the tunnel is
WireGuard as shipped by `wireguard-tools`. If you have found a problem with
either, report it upstream.
